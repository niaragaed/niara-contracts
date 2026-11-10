// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetToken} from "../../src/AssetToken.sol";
import {BackingGateway} from "../../src/BackingGateway.sol";
import {NiaraSettlement} from "../../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../../src/CashbackDistributor.sol";
import {ListingRegistry} from "../../src/ListingRegistry.sol";
import {NativeAssetToken} from "../../src/NativeAssetToken.sol";
import {IListingRegistry} from "../../src/interfaces/IListingRegistry.sol";
import {IAssetToken} from "../../src/interfaces/IAssetToken.sol";
import {MockUSDT} from "../mocks/MockUSDT.sol";
import {MockWBTC} from "../mocks/MockWBTC.sol";

/// @notice Stateful fuzzing actor: exposes one action per public function (request, attest,
/// mint, redeem, settle, withdrawals, pauses) so Foundry's invariant engine explores
/// random sequences of these steps across multiple actors.
/// @dev In most calls the parameters are bounded (`bound`) to valid states, maximizing
/// productive sequences (real mint, real settle etc.), but a fraction of each call
/// (`_chaos`, ~1 in 5) ignores those guards on purpose and tries the invalid path
/// (zero address, zero quantity, wrong state, amounts beyond the real balance/approval).
/// We don't wrap external calls in try/catch: with `fail_on_revert = false` (see
/// foundry.toml), a genuine revert is tolerated by the invariant runner and atomically
/// undoes any side effect of this call (including the "ghost" variables below), so
/// there is no need to catch it manually, and catching it only hid those revert paths
/// from the fuzzer's exploration.
/// "Ghost" variables (`ghost_sum*`) accumulate totals that do not exist as state in the
/// real protocol, used by the invariants to check accounting over time (not only the
/// current balance).
contract Handler is Test {
    // Regular state variables (not `immutable`) on purpose: a constructor with this many
    // simultaneous `immutable`s makes Solidity's codegen run out of stack
    // ("stack too deep") in the final constructor step.
    AssetToken public assetEquity;
    AssetToken public assetCommodity;
    BackingGateway public gateway;
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    MockUSDT public usdt;
    MockWBTC public wbtc;

    address[] public actors;
    address public operator;
    address public custodian;
    address public settlementOperator;
    address public admin;

    // Native (v1) side: registry, two factory instruments (one per trading mode), the
    // listing authority, the native issuer, and a payment token that is never listed.
    ListingRegistry public registry;
    NativeAssetToken public nativeEquity;
    NativeAssetToken public nativeBond;
    MockUSDT public unlistedPayment;
    address public listingAuthority;
    address public nativeIssuer;

    uint256[] public backingRequestIds;
    uint256[] public redemptionRequestIds;

    /// @notice Successful settlements whose asset was not an Approved Equity listing, or
    /// whose payment token was not an Approved Currency listing. Must stay zero.
    uint256 public ghost_illegalSettlements;

    /// @notice Successful settlements (sanity: shows the fuzzer reaches the happy path).
    uint256 public ghost_successfulSettlements;

    /// @notice Historical cashback credited with a Currency listing as the asset. Must stay zero.
    uint256 public ghost_cashbackCreditedToCurrency;

    /// @notice Per native token: total minted through approved issuance batches / total burned.
    mapping(address token => uint256) public ghost_nativeIssued;
    mapping(address token => uint256) public ghost_nativeBurned;

    /// @notice True once a token has been delisted (Delisted must then be permanent).
    mapping(address token => bool) public ghost_everDelisted;

    /// @notice Historical sum of fees recorded in the CashbackDistributor, per settlement
    /// currency (never decreases).
    mapping(address paymentToken => uint256) public ghost_sumFeesRecorded;

    /// @notice Historical sum of credited cashback (not the current balance; withdrawals do
    /// not reduce this value), per settlement currency.
    mapping(address paymentToken => uint256) public ghost_sumCashbackCredited;

    /// @dev Grouped in a struct (instead of ~12 loose parameters) to avoid "stack too
    /// deep" in constructor finalization: a single memory pointer instead of a dozen
    /// simultaneous stack variables.
    struct Config {
        AssetToken assetEquity;
        AssetToken assetCommodity;
        BackingGateway gateway;
        NiaraSettlement settlement;
        CashbackDistributor distributor;
        MockUSDT usdt;
        MockWBTC wbtc;
        address[] actors;
        address operator;
        address custodian;
        address settlementOperator;
        address admin;
    }

    /// @dev Native-side configuration, in its own struct for the same stack reason.
    struct NativeConfig {
        ListingRegistry registry;
        NativeAssetToken nativeEquity;
        NativeAssetToken nativeBond;
        MockUSDT unlistedPayment;
        address listingAuthority;
        address nativeIssuer;
    }

    constructor(Config memory config, NativeConfig memory nativeConfig) {
        registry = nativeConfig.registry;
        nativeEquity = nativeConfig.nativeEquity;
        nativeBond = nativeConfig.nativeBond;
        unlistedPayment = nativeConfig.unlistedPayment;
        listingAuthority = nativeConfig.listingAuthority;
        nativeIssuer = nativeConfig.nativeIssuer;
        assetEquity = config.assetEquity;
        assetCommodity = config.assetCommodity;
        gateway = config.gateway;
        settlement = config.settlement;
        distributor = config.distributor;
        usdt = config.usdt;
        wbtc = config.wbtc;
        actors = config.actors;
        operator = config.operator;
        custodian = config.custodian;
        settlementOperator = config.settlementOperator;
        admin = config.admin;
    }

    // ── Selection helpers ──────────────────────────────────────────────────────────────

    function _pickAsset(uint256 seed) internal view returns (AssetToken) {
        return seed % 2 == 0 ? assetEquity : assetCommodity;
    }

    function _pickPaymentToken(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? address(usdt) : address(wbtc);
    }

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _distinctActor(uint256 seed, address other) internal view returns (address) {
        uint256 idx = seed % actors.length;
        address candidate = actors[idx];
        if (candidate == other) {
            candidate = actors[(idx + 1) % actors.length];
        }
        return candidate;
    }

    /// @dev ~1 in 5 calls takes the "chaotic" path (invalid on purpose) instead of the
    /// path bounded to valid states.
    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    // ── Backing (issuance) ──────────────────────────────────────────────────────────────

    function requestBacking(uint256 assetSeed, uint256 quantitySeed) external {
        address asset = _chaos(assetSeed) ? address(0) : address(_pickAsset(assetSeed));
        uint256 quantity = _chaos(quantitySeed) ? 0 : bound(quantitySeed, 1, 1_000_000 ether);

        vm.prank(operator);
        uint256 requestId = gateway.requestBacking(asset, quantity);
        backingRequestIds.push(requestId);
    }

    function attestBacking(uint256 idxSeed, uint256 acquiredSeed) external {
        if (backingRequestIds.length == 0) return;
        uint256 requestId = backingRequestIds[idxSeed % backingRequestIds.length];
        (,, uint256 quantityRequested,,, BackingGateway.RequestStatus status,) = gateway.backingRequests(requestId);

        // Most of the time it only targets PENDING requests; a fraction skips this check
        // on purpose to reach RequestNotPending.
        if (status != BackingGateway.RequestStatus.PENDING && !_chaos(idxSeed)) return;

        uint256 quantityAcquired = _chaos(acquiredSeed)
            ? acquiredSeed % 2_000_000 ether // may exceed quantityRequested, or be zero.
            : bound(acquiredSeed, 1, quantityRequested == 0 ? 1 : quantityRequested);

        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256(abi.encode("backing-proof", requestId, acquiredSeed)), quantityAcquired);
    }

    function mintAttested(uint256 idxSeed, uint256 toSeed) external {
        if (backingRequestIds.length == 0) return;
        uint256 requestId = backingRequestIds[idxSeed % backingRequestIds.length];
        (,,,,, BackingGateway.RequestStatus status, bool minted) = gateway.backingRequests(requestId);

        bool eligible = status == BackingGateway.RequestStatus.SETTLED && !minted;
        if (!eligible && !_chaos(idxSeed)) return;

        address to = _chaos(toSeed) ? address(0) : _actorAt(toSeed);

        vm.prank(operator);
        gateway.mintAttested(requestId, to);
    }

    function cancelBackingRequest(uint256 idxSeed) external {
        if (backingRequestIds.length == 0) return;
        uint256 requestId = backingRequestIds[idxSeed % backingRequestIds.length];
        (,,,,, BackingGateway.RequestStatus status,) = gateway.backingRequests(requestId);

        if (status != BackingGateway.RequestStatus.PENDING && !_chaos(idxSeed)) return;

        vm.prank(operator);
        gateway.cancelBackingRequest(requestId);
    }

    // ── Resgate (queima) ────────────────────────────────────────────────────────────────

    function redemptionRequest(uint256 actorSeed, uint256 assetSeed, uint256 quantitySeed) external {
        address actor = _actorAt(actorSeed);
        address asset = _chaos(assetSeed) ? address(0) : address(_pickAsset(assetSeed));
        uint256 balance = asset == address(0) ? 0 : AssetToken(asset).balanceOf(actor);

        uint256 quantity;
        if (_chaos(quantitySeed)) {
            quantity = quantitySeed % 2; // sometimes 0 (ZeroQuantity), sometimes 1 even without a balance.
        } else if (balance == 0) {
            return;
        } else {
            quantity = bound(quantitySeed, 1, balance);
        }

        if (asset != address(0) && quantity > 0) {
            vm.prank(actor);
            AssetToken(asset).approve(address(gateway), quantity);
        }

        vm.prank(actor);
        uint256 requestId = gateway.redemptionRequest(asset, quantity);
        redemptionRequestIds.push(requestId);
    }

    function redemptionAttest(uint256 idxSeed) external {
        if (redemptionRequestIds.length == 0) return;
        uint256 requestId = redemptionRequestIds[idxSeed % redemptionRequestIds.length];
        (,,,, BackingGateway.RequestStatus status) = gateway.redemptionRequests(requestId);

        if (status != BackingGateway.RequestStatus.PENDING && !_chaos(idxSeed)) return;

        vm.prank(custodian);
        gateway.redemptionAttest(requestId, keccak256(abi.encode("redemption-proof", requestId)));
    }

    function cancelRedemptionRequest(uint256 idxSeed) external {
        if (redemptionRequestIds.length == 0) return;
        uint256 requestId = redemptionRequestIds[idxSeed % redemptionRequestIds.length];
        (,,,, BackingGateway.RequestStatus status) = gateway.redemptionRequests(requestId);

        if (status != BackingGateway.RequestStatus.PENDING && !_chaos(idxSeed)) return;

        vm.prank(custodian);
        gateway.cancelRedemptionRequest(requestId);
    }

    // ── Atomic settlement ──────────────────────────────────────────────────────────────

    function settle(
        uint256 buyerSeed,
        uint256 sellerSeed,
        uint256 assetSeed,
        uint256 paymentSeed,
        uint256 assetAmountSeed,
        uint256 paymentAmountSeed
    ) external {
        address buyer = _actorAt(buyerSeed);
        address seller = _chaos(sellerSeed) ? buyer : _distinctActor(sellerSeed, buyer);
        address asset = _pickSettleAsset(assetSeed);
        address paymentToken = _pickSettlePayment(paymentSeed);

        uint256 assetAmount = _pickAssetAmount(asset, seller, assetAmountSeed);
        if (assetAmount == 0) return;
        uint256 paymentAmount = _pickPaymentAmount(paymentToken, buyer, paymentAmountSeed);

        vm.prank(seller);
        IERC20(asset).approve(address(settlement), assetAmount);
        vm.prank(buyer);
        IERC20(paymentToken).approve(address(settlement), paymentAmount);

        uint256 cashbackBefore = distributor.cashbackBalance(asset, paymentToken);
        vm.prank(settlementOperator);
        uint256 feeCharged = settlement.settle(asset, paymentToken, buyer, seller, assetAmount, paymentAmount);
        _recordSettleGhosts(asset, paymentToken, feeCharged, cashbackBefore);
    }

    /// @dev Spans every listing situation: backed tokens (never listable), the native
    /// Equity (order-book class), the native FixedIncome (P2P class) and a Currency used
    /// as the asset leg. Only the native Equity, while Approved, may ever settle.
    function _pickSettleAsset(uint256 seed) internal view returns (address) {
        uint256 pick = seed % 6;
        if (pick == 0) return address(assetEquity);
        if (pick == 1) return address(assetCommodity);
        if (pick == 2) return address(nativeBond);
        if (pick == 3) return address(usdt);
        return address(nativeEquity); // weighted: most settles target the legal asset.
    }

    /// @dev Listed currencies most of the time; sometimes a never-listed token or a
    /// non-Currency listing (the native Equity) as payment.
    function _pickSettlePayment(uint256 seed) internal view returns (address) {
        uint256 pick = seed % 8;
        if (pick == 0) return address(unlistedPayment);
        if (pick == 1) return address(nativeEquity);
        return pick % 2 == 0 ? address(usdt) : address(wbtc);
    }

    function _pickAssetAmount(address asset, address seller, uint256 seed) internal view returns (uint256) {
        if (_chaos(seed)) return seed % 2_000_000 ether; // may exceed the real balance/approval, or be zero.
        uint256 sellerBalance = IERC20(asset).balanceOf(seller);
        if (sellerBalance == 0) return 0;
        return bound(seed, 1, sellerBalance);
    }

    function _pickPaymentAmount(address paymentToken, address buyer, uint256 seed) internal returns (uint256) {
        // Ensures the buyer has enough liquidity most of the time, so the fuzzed call is not
        // wasted on a no-op for lack of balance; the mocks allow free minting, test use only.
        // The native Equity cannot be minted freely: the buyer pays with what it holds.
        if (paymentToken == address(usdt)) {
            usdt.mint(buyer, 1_000_000e6);
        } else if (paymentToken == address(wbtc)) {
            wbtc.mint(buyer, 1_000e8);
        } else if (paymentToken == address(unlistedPayment)) {
            unlistedPayment.mint(buyer, 1_000_000e6);
        }

        if (_chaos(seed)) return seed % 2_000_000e8; // may exceed the newly funded balance, or be zero.
        uint256 buyerBalance = IERC20(paymentToken).balanceOf(buyer);
        if (buyerBalance == 0) return seed % 1_000e6; // nothing held: likely reverts, still explored.
        return bound(seed, 1, buyerBalance);
    }

    function _recordSettleGhosts(address asset, address paymentToken, uint256 feeCharged, uint256 cashbackBefore)
        internal
    {
        ghost_sumFeesRecorded[paymentToken] += feeCharged;
        uint256 credited = distributor.cashbackBalance(asset, paymentToken) - cashbackBefore;
        ghost_sumCashbackCredited[paymentToken] += credited;
        ghost_successfulSettlements++;

        // Reached only if settle did NOT revert. The registry cannot change inside settle, so
        // reading the listings now reflects what settle saw.
        IListingRegistry.Listing memory assetListing = registry.getListing(asset);
        IListingRegistry.Listing memory paymentListing = registry.getListing(paymentToken);
        bool assetOk = assetListing.status == IListingRegistry.ListingStatus.Approved
            && assetListing.assetClass == IListingRegistry.AssetClass.Equity;
        bool paymentOk = paymentListing.status == IListingRegistry.ListingStatus.Approved
            && paymentListing.assetClass == IListingRegistry.AssetClass.Currency;
        if (!assetOk || !paymentOk) ghost_illegalSettlements++;
        bool assetIsCurrency = assetListing.status != IListingRegistry.ListingStatus.None
            && assetListing.assetClass == IListingRegistry.AssetClass.Currency;
        if (assetIsCurrency) ghost_cashbackCreditedToCurrency += credited;
    }

    // ── Listings and native issuance ────────────────────────────────────────────────────

    /// @dev Tokens whose listing status the fuzzer drives (the two native instruments and
    /// the two listed currencies).
    function _pickListedToken(uint256 seed) internal view returns (address) {
        uint256 pick = seed % 4;
        if (pick == 0) return address(nativeEquity);
        if (pick == 1) return address(nativeBond);
        if (pick == 2) return address(usdt);
        return address(wbtc);
    }

    /// @notice Approve / suspend / delist through the listing authority. Delisting is final,
    /// so it is kept rare (1 in 50 calls); otherwise one early delist would end all
    /// productive sequences. Illegal transitions are attempted too and simply revert.
    function setListingStatus(uint256 tokenSeed, uint256 actionSeed) external {
        address token = _pickListedToken(tokenSeed);
        vm.prank(listingAuthority);
        if (actionSeed % 50 == 0) {
            registry.delist(token);
            ghost_everDelisted[token] = true;
        } else if (actionSeed % 2 == 0) {
            registry.approveListing(token);
        } else {
            registry.suspendListing(token);
        }
    }

    function _pickNative(uint256 seed) internal view returns (NativeAssetToken) {
        return seed % 2 == 0 ? nativeEquity : nativeBond;
    }

    /// @notice The native issuer requests a batch to a random actor. A fraction of calls
    /// comes from a non-issuer, or with a zero amount, on purpose.
    function requestIssuance(uint256 tokenSeed, uint256 amountSeed, uint256 actorSeed) external {
        NativeAssetToken token = _pickNative(tokenSeed);
        address caller = _chaos(actorSeed) ? _actorAt(actorSeed) : nativeIssuer;
        uint256 amount = _chaos(amountSeed) ? 0 : bound(amountSeed, 1, 1_000_000 ether);

        vm.prank(caller);
        registry.requestIssuance(address(token), amount, _actorAt(actorSeed), keccak256(abi.encode(amountSeed)));
    }

    /// @notice The listing authority approves a batch (existing or not, executed or not).
    function approveIssuance(uint256 tokenSeed, uint256 batchSeed) external {
        NativeAssetToken token = _pickNative(tokenSeed);
        uint256 count = registry.nextBatchId(address(token));
        uint256 batchId = (count == 0 || _chaos(batchSeed)) ? batchSeed % (count + 2) : batchSeed % count;
        (uint256 amount,,,) = registry.issuanceBatches(address(token), batchId);

        vm.prank(listingAuthority);
        registry.approveIssuance(address(token), batchId);
        ghost_nativeIssued[address(token)] += amount;
    }

    /// @notice A holder burns part of its native balance with a random reason.
    function burnNative(uint256 tokenSeed, uint256 actorSeed, uint256 amountSeed) external {
        NativeAssetToken token = _pickNative(tokenSeed);
        address holder = _actorAt(actorSeed);
        uint256 balance = token.balanceOf(holder);
        uint256 amount;
        if (_chaos(amountSeed) || balance == 0) {
            amount = amountSeed % 2; // zero (ZeroAmount) or 1 possibly without a balance.
        } else {
            amount = bound(amountSeed, 1, balance);
        }

        vm.prank(holder);
        token.burnWithReason(amount, NativeAssetToken.BurnReason(amountSeed % 2), bytes32(amountSeed));
        ghost_nativeBurned[address(token)] += amount;
    }

    // ── Saques ──────────────────────────────────────────────────────────────────────────

    function withdrawCashback(uint256 assetSeed, uint256 paymentSeed) external {
        // The native Equity is the only asset that can actually accrue cashback in v1.
        address asset = assetSeed % 3 == 0 ? address(_pickAsset(assetSeed / 3)) : address(nativeEquity);
        address paymentToken = _pickPaymentToken(paymentSeed);
        address issuer = IAssetToken(asset).issuerWallet();

        // No available-balance guard on purpose: most of the time there is nothing to
        // withdraw yet, exercising NothingToWithdraw organically.
        vm.prank(issuer);
        distributor.withdraw(asset, paymentToken);
    }

    function withdrawProtocolFees(uint256 paymentSeed, uint256 amountSeed) external {
        address paymentToken = _pickPaymentToken(paymentSeed);
        uint256 available = distributor.protocolBalance(paymentToken);

        uint256 amount;
        if (_chaos(amountSeed) || available == 0) {
            amount = amountSeed % 1_000_000e8; // may exceed what is available, including zero.
        } else {
            amount = bound(amountSeed, 1, available);
        }

        vm.prank(admin);
        distributor.withdrawProtocolFees(paymentToken, admin, amount);
    }

    // ── Pauses (emergency) ──────────────────────────────────────────────────────────────

    function toggleGatewayPause() external {
        // `vm.prank` only applies to the NEXT external call; it must not be consumed by
        // reading `paused()` before the call that actually needs the prank (the same
        // pitfall documented at the top of test/AssetToken.t.sol).
        bool isPaused = gateway.paused();
        vm.prank(admin);
        if (isPaused) {
            gateway.unpause();
        } else {
            gateway.pause();
        }
    }

    function toggleSettlementPause() external {
        bool isPaused = settlement.paused();
        vm.prank(admin);
        if (isPaused) {
            settlement.unpause();
        } else {
            settlement.pause();
        }
    }

    function toggleAssetPause(uint256 assetSeed) external {
        AssetToken asset = _pickAsset(assetSeed);
        bool isPaused = asset.paused();
        vm.prank(admin);
        if (isPaused) {
            asset.unpause();
        } else {
            asset.pause();
        }
    }
}

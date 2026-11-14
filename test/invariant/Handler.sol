// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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

    /// @notice Match ids that already settled successfully, and the count of settlements that
    /// succeeded with an id already in this set. The count must stay zero.
    mapping(bytes16 matchId => bool) public ghost_matchSettled;
    bytes16[] public ghost_settledMatchIds;
    uint256 public ghost_replayedSettlements;
    uint128 internal matchCounter;

    /// @notice Successful settlements, cashback withdrawals or protocol-fee withdrawals while
    /// the protocol was paused. Must stay zero (spec §3.3, pause principle).
    uint256 public ghost_payoutsWhilePaused;

    /// @notice Successful cashback withdrawals on a listing whose cashback was frozen. Must
    /// stay zero (spec §9.5).
    uint256 public ghost_withdrawalsWhileFrozen;

    /// @notice Settlements on a frozen listing that credited a cashback different from the
    /// unfrozen formula. Must stay zero: the freeze never stops accrual.
    uint256 public ghost_frozenAccrualMismatch;

    /// @notice Settlements that succeeded on a frozen listing (sanity: the fuzzer reaches it).
    uint256 public ghost_settlementsWhileFrozen;

    /// @notice Successful settlements paid in a token other than `settlement.feeToken()`
    /// (USDT). Must stay zero (spec invariant 12).
    uint256 public ghost_settlementsOutsideFeeToken;

    /// @notice Successful settlements where the USDT receiver (the seller) did not get
    /// exactly `paymentAmount - fee`, or the buyer did not get its asset leg in full. Must
    /// stay zero (spec invariant 12).
    uint256 public ghost_feeNotPaidByUsdtReceiver;

    /// @notice Successful settlements whose fee was not `ceil(paymentAmount * feeBps /
    /// 10_000)`. Must stay zero (spec section 3.4).
    uint256 public ghost_feeNotCeiling;

    /// @notice Successful settlements that left the seller with nothing. Must stay zero
    /// (`ZeroSellerProceeds`).
    uint256 public ghost_sellerGotNothing;

    /// @notice Successful settlements with an active fee that charged no fee. Must stay zero:
    /// the fee rounds up, so no amount trades fee-free.
    uint256 public ghost_feeFreeSettlements;

    /// @notice Historical cashback credited with a Currency listing as the asset. Must stay zero.
    uint256 public ghost_cashbackCreditedToCurrency;

    /// @notice Per native token: total minted through approved issuance batches / total burned.
    mapping(address token => uint256) public ghost_nativeIssued;
    mapping(address token => uint256) public ghost_nativeBurned;

    /// @notice True once a token has been delisted (Delisted must then be permanent).
    mapping(address token => bool) public ghost_everDelisted;

    /// @notice Batches executed while the registry was paused or the listing was not
    /// Approved. Must stay zero (spec invariant 11, second half).
    uint256 public ghost_illegalIssuances;

    /// @notice `requestIssuance` calls accepted on a listing that was not `Approved`. Must
    /// stay zero (issuance rule, spec §3.12 and invariant 11).
    uint256 public ghost_illegalRequests;

    /// @notice `requestIssuance` calls whose outcome (success, or the exact error) or effects
    /// (batch counter, stored batch) differed from the prediction. Must stay zero.
    uint256 public ghost_issuanceRequestMismatches;

    // ── Listing fee (spec §3.13) ────────────────────────────────────────────────────────

    /// @notice Three more issuer listings (Equity, FixedIncome, Credit) that start `Pending`:
    /// the fuzzer quotes their listing fee, pays it and drives their status and issuance.
    address[] public feeListings;

    /// @notice `quoteListing` / `payListingFee` calls whose outcome (success, or the exact
    /// error) differed from the handler's prediction, or whose effects did. Must stay zero.
    uint256 public ghost_listingFeeMismatches;

    /// @notice Successful `approveListing` calls on a non-Currency listing that had not paid
    /// its listing fee. Must stay zero.
    uint256 public ghost_unpaidApprovals;

    /// @notice Successful payments per listing (must never exceed 1) and their sum, in USDT.
    mapping(address token => uint256) public ghost_listingFeePayments;
    uint256 public ghost_sumListingFeesPaid;

    /// @notice Successful quotes and payments (sanity: the fuzzer reaches both).
    uint256 public ghost_quotes;
    uint256 public ghost_payments;

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

    /// @notice Registers the three `Pending` issuer listings the listing-fee actions work on.
    /// Called once by the test's setUp; not a fuzz target.
    function initListingFee(address[] calldata feeListings_) external {
        require(feeListings.length == 0, "already initialized");
        for (uint256 i = 0; i < feeListings_.length; i++) {
            feeListings.push(feeListings_[i]);
        }
    }

    function feeListingCount() external view returns (uint256) {
        return feeListings.length;
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

    /// @dev One settle attempt, grouped in a struct to stay clear of "stack too deep".
    struct SettleCase {
        bytes16 matchId;
        address buyer;
        address seller;
        address asset;
        address paymentToken;
        uint256 assetAmount;
        uint256 paymentAmount;
        uint256 cashbackBefore;
        uint256 sellerPaymentBefore;
        uint256 buyerAssetBefore;
    }

    function settle(
        uint256 buyerSeed,
        uint256 sellerSeed,
        uint256 assetSeed,
        uint256 paymentSeed,
        uint256 assetAmountSeed,
        uint256 paymentAmountSeed
    ) external {
        SettleCase memory c;
        c.buyer = _actorAt(buyerSeed);
        c.seller = _chaos(sellerSeed) ? c.buyer : _distinctActor(sellerSeed, c.buyer);
        c.asset = _pickSettleAsset(assetSeed);
        c.paymentToken = _pickSettlePayment(paymentSeed);

        c.assetAmount = _pickAssetAmount(c.asset, c.seller, assetAmountSeed);
        if (c.assetAmount == 0) return;
        c.paymentAmount = _pickPaymentAmount(c.paymentToken, c.buyer, paymentAmountSeed);

        vm.prank(c.seller);
        IERC20(c.asset).approve(address(settlement), c.assetAmount);
        vm.prank(c.buyer);
        IERC20(c.paymentToken).approve(address(settlement), c.paymentAmount);

        c.matchId = _pickMatchId(buyerSeed);
        c.cashbackBefore = distributor.cashbackBalance(c.asset, c.paymentToken);
        c.sellerPaymentBefore = IERC20(c.paymentToken).balanceOf(c.seller);
        c.buyerAssetBefore = IERC20(c.asset).balanceOf(c.buyer);
        vm.prank(settlementOperator);
        uint256 feeCharged = settlement.settle(
            c.matchId, c.asset, c.paymentToken, c.buyer, c.seller, c.assetAmount, c.paymentAmount
        );
        _recordSettleOutcome(c, feeCharged);
    }

    /// @dev Reached only if settle did not revert.
    function _recordSettleOutcome(SettleCase memory c, uint256 feeCharged) internal {
        if (ghost_matchSettled[c.matchId]) ghost_replayedSettlements++;
        ghost_matchSettled[c.matchId] = true;
        ghost_settledMatchIds.push(c.matchId);
        _recordSettleGhosts(c.asset, c.paymentToken, feeCharged, c.cashbackBefore);
        if (registry.paused()) ghost_payoutsWhilePaused++;
        if (registry.getListing(c.asset).cashbackFrozen) {
            ghost_settlementsWhileFrozen++;
            uint256 credited = distributor.cashbackBalance(c.asset, c.paymentToken) - c.cashbackBefore;
            if (credited != (feeCharged * distributor.cashbackBps()) / 10_000) ghost_frozenAccrualMismatch++;
        }

        // The party receiving USDT (the seller) pays the fee out of it; the other party
        // receives its leg in full.
        bool sellerPaidFee =
            IERC20(c.paymentToken).balanceOf(c.seller) - c.sellerPaymentBefore == c.paymentAmount - feeCharged;
        bool buyerGotFullLeg = IERC20(c.asset).balanceOf(c.buyer) - c.buyerAssetBefore == c.assetAmount;
        if (!sellerPaidFee || !buyerGotFullLeg) ghost_feeNotPaidByUsdtReceiver++;

        // The fee rounds up, and the seller is still left with something.
        uint256 feeBps = settlement.feeBps();
        if (feeCharged != (c.paymentAmount * feeBps + 9_999) / 10_000) ghost_feeNotCeiling++;
        if (feeBps > 0 && feeCharged == 0) ghost_feeFreeSettlements++;
        if (c.paymentAmount - feeCharged == 0) ghost_sellerGotNothing++;
    }

    /// @dev A fresh match id most of the time; the chaotic path replays one that already
    /// settled (must revert MatchAlreadySettled).
    function _pickMatchId(uint256 seed) internal returns (bytes16) {
        uint256 settled = ghost_settledMatchIds.length;
        if (_chaos(seed / 7) && settled > 0) return ghost_settledMatchIds[seed % settled];
        return bytes16(++matchCounter);
    }

    /// @notice Number of match ids that settled (for the invariant's per-id check).
    function settledMatchCount() external view returns (uint256) {
        return ghost_settledMatchIds.length;
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

    /// @dev The fee token (USDT) most of the time; sometimes an Approved Currency that is
    /// not the fee token (WBTC), a never-listed token or a non-Currency listing (the native
    /// Equity) as payment.
    function _pickSettlePayment(uint256 seed) internal view returns (address) {
        uint256 pick = seed % 8;
        if (pick == 0) return address(unlistedPayment);
        if (pick == 1) return address(nativeEquity);
        if (pick == 2) return address(wbtc);
        return address(usdt);
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
        if (paymentToken != settlement.feeToken()) ghost_settlementsOutsideFeeToken++;
        bool assetIsCurrency = assetListing.status != IListingRegistry.ListingStatus.None
            && assetListing.assetClass == IListingRegistry.AssetClass.Currency;
        if (assetIsCurrency) ghost_cashbackCreditedToCurrency += credited;
    }

    // ── Listings and native issuance ────────────────────────────────────────────────────

    /// @dev Tokens whose listing status the fuzzer drives (the two native instruments, the
    /// two listed currencies and the three listing-fee listings).
    function _pickListedToken(uint256 seed) internal view returns (address) {
        uint256 pick = seed % 7;
        if (pick == 0) return address(nativeEquity);
        if (pick == 1) return address(nativeBond);
        if (pick == 2) return address(usdt);
        if (pick == 3) return address(wbtc);
        return feeListings[pick - 4];
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
            // Reached only if approveListing did not revert: it must never approve a
            // non-Currency listing that has not paid its listing fee.
            IListingRegistry.Listing memory listing = registry.getListing(token);
            bool unpaid = registry.getListingFeeQuote(token).listingFeePaid == 0;
            if (listing.assetClass != IListingRegistry.AssetClass.Currency && unpaid) ghost_unpaidApprovals++;
        } else {
            registry.suspendListing(token);
        }
    }

    /// @dev Mostly the two seeded instruments; one time in four, a listing-fee listing (so
    /// issuance is refused while `Pending` or `Quoted` and succeeds only once paid).
    function _pickNative(uint256 seed) internal view returns (NativeAssetToken) {
        uint256 pick = seed % 8;
        if (pick < 6) return pick % 2 == 0 ? nativeEquity : nativeBond;
        return NativeAssetToken(feeListings[(seed / 8) % feeListings.length]);
    }

    // ── Listing fee (spec §3.13): outcome predicted exactly ─────────────────────────────

    /// @dev The listing-fee candidates: the three fee listings, the two instruments that paid
    /// at setup, and a Currency listing.
    function _pickFeeCandidate(uint256 seed) internal view returns (address) {
        uint256 pick = seed % 6;
        if (pick < 3) return feeListings[pick];
        if (pick == 3) return address(nativeEquity);
        if (pick == 4) return address(nativeBond);
        return address(usdt);
    }

    /// @notice The listing authority (or, chaotically, a trader) quotes a listing fee with a
    /// random valuation, rate and expiry, in and out of bounds. The handler predicts the
    /// exact outcome; a success stores `ceil(valuation * bps / 10_000)`.
    function quoteListing(uint256 tokenSeed, uint256 valuationSeed, uint256 bpsSeed, uint256 expirySeed) external {
        address token = _pickFeeCandidate(tokenSeed);
        address caller = _chaos(tokenSeed / 7) ? _actorAt(tokenSeed / 35) : listingAuthority;
        uint256 valuation = _chaos(valuationSeed) ? 0 : bound(valuationSeed, 1, 1e30);
        uint16 bps;
        if (_chaos(bpsSeed)) bps = (bpsSeed / 5) % 2 == 0 ? 0 : uint16(bound(bpsSeed, 101, 1_000));
        else bps = uint16(bound(bpsSeed, 1, 100));
        uint256 offset;
        if (_chaos(expirySeed)) offset = (expirySeed / 5) % 2 == 0 ? 0 : bound(expirySeed, 30 days + 1, 400 days);
        else offset = bound(expirySeed, 1, 30 days);
        uint64 expiresAt = uint64(block.timestamp + offset);

        bytes memory expected = _predictQuote(token, caller, valuation, bps, offset, expiresAt);
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(registry).call(
            abi.encodeCall(ListingRegistry.quoteListing, (token, valuation, bps, expiresAt))
        );
        if (!_matches(ok, ret, expected)) {
            ghost_listingFeeMismatches++;
            return;
        }
        if (!ok) return;
        ghost_quotes++;
        ListingRegistry.ListingFeeQuote memory quote = registry.getListingFeeQuote(token);
        bool stored = quote.valuation == valuation && quote.listingFeeBps == bps
            && quote.listingFee == (valuation * bps + 9_999) / 10_000 && quote.listingFeeToken == address(usdt)
            && quote.quoteExpiresAt == expiresAt && quote.listingFeePaid == 0
            && registry.getListing(token).status == IListingRegistry.ListingStatus.Quoted;
        if (!stored) ghost_listingFeeMismatches++;
    }

    /// @dev The error `quoteListing` must raise, in the contract's check order, or "" for
    /// a success.
    function _predictQuote(address token, address caller, uint256 valuation, uint16 bps, uint256 offset, uint64 expiresAt)
        internal
        view
        returns (bytes memory)
    {
        bytes32 role = registry.LISTING_AUTHORITY_ROLE();
        if (!registry.hasRole(role, caller)) {
            return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role);
        }
        IListingRegistry.Listing memory listing = registry.getListing(token);
        if (listing.assetClass == IListingRegistry.AssetClass.Currency) {
            return abi.encodeWithSelector(ListingRegistry.CurrencyHasNoListingFee.selector, token);
        }
        if (listing.status != IListingRegistry.ListingStatus.Pending && listing.status != IListingRegistry.ListingStatus.Quoted)
        {
            return abi.encodeWithSelector(ListingRegistry.InvalidStatusTransition.selector, token, listing.status);
        }
        if (valuation == 0) return abi.encodeWithSelector(ListingRegistry.ZeroValuation.selector);
        if (bps == 0 || bps > 100) return abi.encodeWithSelector(ListingRegistry.InvalidListingFeeBps.selector, bps);
        if (offset == 0 || offset > 30 days) {
            return abi.encodeWithSelector(ListingRegistry.InvalidExpiry.selector, expiresAt);
        }
        return "";
    }

    /// @notice The issuer (or, chaotically, a trader) pays a listing fee: on a quoted, an
    /// unquoted, an already-paid or a Currency listing, sometimes at the quote's expiry
    /// boundary, sometimes while paused. The handler funds the issuer with the fee and
    /// predicts the exact outcome; a success approves the listing and records the fee once.
    function payListingFee(uint256 tokenSeed, uint256 callerSeed) external {
        address token = _pickFeeCandidate(tokenSeed);
        address caller = _chaos(callerSeed) ? _actorAt(callerSeed / 5) : nativeIssuer;
        ListingRegistry.ListingFeeQuote memory quote = registry.getListingFeeQuote(token);
        IListingRegistry.ListingStatus status = registry.getListing(token).status;

        // One call in four on a quoted listing lands on the expiry boundary: one second
        // before (payable) or exactly at it (expired). Time only moves forward.
        if (status == IListingRegistry.ListingStatus.Quoted && (callerSeed / 25) % 4 == 0) {
            uint256 target = uint256(quote.quoteExpiresAt) - 1 + (callerSeed / 100) % 2;
            if (target > block.timestamp) vm.warp(target);
        }
        if (status == IListingRegistry.ListingStatus.Quoted) usdt.mint(nativeIssuer, quote.listingFee);

        bytes memory expected = _predictPay(token, caller, status, quote.quoteExpiresAt);
        uint256 collectedBefore = distributor.listingFeesCollected(address(usdt));
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(registry).call(abi.encodeCall(ListingRegistry.payListingFee, (token)));
        if (!_matches(ok, ret, expected)) {
            ghost_listingFeeMismatches++;
            return;
        }
        if (!ok) return;
        ghost_payments++;
        ghost_listingFeePayments[token]++;
        ghost_sumListingFeesPaid += quote.listingFee;
        bool effects = registry.getListing(token).status == IListingRegistry.ListingStatus.Approved
            && registry.getListingFeeQuote(token).listingFeePaid == quote.listingFee
            && distributor.listingFeesCollected(address(usdt)) == collectedBefore + quote.listingFee;
        if (!effects) ghost_listingFeeMismatches++;
    }

    /// @dev The error `payListingFee` must raise, in the contract's check order, or "".
    function _predictPay(address token, address caller, IListingRegistry.ListingStatus status, uint64 expiresAt)
        internal
        view
        returns (bytes memory)
    {
        if (registry.paused()) return abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        if (caller != registry.getListing(token).issuer) return abi.encodeWithSelector(ListingRegistry.NotIssuer.selector);
        if (status != IListingRegistry.ListingStatus.Quoted) {
            return abi.encodeWithSelector(ListingRegistry.ListingNotQuoted.selector, token, status);
        }
        if (block.timestamp >= expiresAt) {
            return abi.encodeWithSelector(ListingRegistry.QuoteExpired.selector, token, expiresAt);
        }
        return "";
    }

    /// @dev True when a call's outcome is the predicted one: success for "", otherwise a
    /// revert with exactly the predicted data.
    function _matches(bool ok, bytes memory ret, bytes memory expected) internal pure returns (bool) {
        if (expected.length == 0) return ok;
        return !ok && keccak256(ret) == keccak256(expected);
    }

    /// @notice The listing authority freezes or unfreezes cashback on a native listing, or
    /// (chaotic path) tries it on a Currency listing, which always reverts.
    function toggleCashbackFreeze(uint256 tokenSeed) external {
        address token = _chaos(tokenSeed) ? address(usdt) : address(_pickNative(tokenSeed / 5));
        bool frozen = registry.getListing(token).cashbackFrozen;
        vm.prank(listingAuthority);
        if (frozen) {
            registry.unfreezeCashback(token);
        } else {
            registry.freezeCashback(token);
        }
    }

    /// @notice The native issuer requests a batch to a random actor. A fraction of calls
    /// comes from a non-issuer, or with a zero amount, on purpose. The outcome is predicted
    /// exactly (issuance rule, spec §3.12: only an `Approved` listing accepts a request), in
    /// the contract's check order, and a refused request must leave `nextBatchNo` untouched.
    function requestIssuance(uint256 tokenSeed, uint256 amountSeed, uint256 actorSeed) external {
        address token = address(_pickNative(tokenSeed));
        address caller = _chaos(actorSeed) ? _actorAt(actorSeed) : nativeIssuer;
        uint256 amount = _chaos(amountSeed) ? 0 : bound(amountSeed, 1, 1_000_000 ether);
        address recipient = _actorAt(actorSeed);

        // Chaotic path: a zero doc hash (EmptyDocHash).
        bytes32 docHash = _chaos(tokenSeed / 2) ? bytes32(0) : keccak256(abi.encode(amountSeed));

        bytes memory expected = _predictRequest(token, caller, amount, recipient, docHash);
        uint256 nextBefore = registry.nextBatchNo(token);

        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(registry).call(abi.encodeCall(ListingRegistry.requestIssuance, (token, amount, recipient, docHash)));
        if (!_matches(ok, ret, expected)) {
            ghost_issuanceRequestMismatches++;
            return;
        }

        // A refused request creates no batch; an accepted one creates exactly the next one.
        if (registry.nextBatchNo(token) != (ok ? nextBefore + 1 : nextBefore)) ghost_issuanceRequestMismatches++;
        if (!ok) return;
        (uint256 stored,,, ListingRegistry.IssuanceStatus status,,) = registry.issuanceBatches(token, nextBefore);
        if (stored != amount || status != ListingRegistry.IssuanceStatus.Requested) ghost_issuanceRequestMismatches++;
        // Reached only on success: a request accepted off an `Approved` listing is illegal.
        if (registry.getListing(token).status != IListingRegistry.ListingStatus.Approved) ghost_illegalRequests++;
    }

    /// @dev The error `requestIssuance` must raise, in the contract's check order, or "".
    function _predictRequest(address token, address caller, uint256 amount, address recipient, bytes32 docHash)
        internal
        view
        returns (bytes memory)
    {
        IListingRegistry.Listing memory listing = registry.getListing(token);
        if (caller != listing.issuer) return abi.encodeWithSelector(ListingRegistry.NotIssuer.selector);
        if (listing.status != IListingRegistry.ListingStatus.Approved) {
            return abi.encodeWithSelector(ListingRegistry.IssuanceNotAllowed.selector, token, listing.status);
        }
        if (amount == 0) return abi.encodeWithSelector(ListingRegistry.ZeroAmount.selector);
        if (recipient == address(0)) return abi.encodeWithSelector(ListingRegistry.ZeroAddress.selector);
        if (docHash == bytes32(0)) return abi.encodeWithSelector(ListingRegistry.EmptyDocHash.selector);
        return "";
    }

    /// @dev Batches are numbered 1..next-1. The bounded path picks one of them; the chaotic
    /// path (or no batch yet) may pick 0 or a number past the last one.
    function _pickBatchNo(NativeAssetToken token, uint256 seed) internal view returns (uint256) {
        uint256 next = registry.nextBatchNo(address(token));
        if (next <= 1 || _chaos(seed)) return seed % (next + 2);
        return 1 + (seed % (next - 1));
    }

    /// @notice The listing authority approves a batch (existing or not, executed or not).
    function approveIssuance(uint256 tokenSeed, uint256 batchSeed) external {
        NativeAssetToken token = _pickNative(tokenSeed);
        uint256 batchNo = _pickBatchNo(token, batchSeed);
        (uint256 amount,,,,,) = registry.issuanceBatches(address(token), batchNo);

        vm.prank(listingAuthority);
        registry.approveIssuance(address(token), batchNo);
        ghost_nativeIssued[address(token)] += amount;
        // Reached only if approveIssuance did not revert: record any execution that
        // happened while paused or on a non-Approved listing (must never happen).
        bool listingApproved =
            registry.getListing(address(token)).status == IListingRegistry.ListingStatus.Approved;
        if (registry.paused() || !listingApproved) ghost_illegalIssuances++;
    }

    /// @notice The listing authority rejects a batch (existing or not, open or resolved).
    /// Rejection never mints, so it never touches the supply ghosts.
    function rejectIssuance(uint256 tokenSeed, uint256 batchSeed) external {
        NativeAssetToken token = _pickNative(tokenSeed);
        uint256 batchNo = _pickBatchNo(token, batchSeed);

        vm.prank(listingAuthority);
        registry.rejectIssuance(address(token), batchNo);
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

        // Chaotic path: a zero reference (EmptyReference).
        bytes32 ref = _chaos(tokenSeed / 2) ? bytes32(0) : keccak256(abi.encode(amountSeed));

        vm.prank(holder);
        token.burnWithReason(amount, NativeAssetToken.BurnReason(amountSeed % 2), ref);
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
        if (registry.paused()) ghost_payoutsWhilePaused++;
        if (registry.getListing(asset).cashbackFrozen) ghost_withdrawalsWhileFrozen++;
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
        if (registry.paused()) ghost_payoutsWhilePaused++;
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

    /// @notice Toggles the protocol's shared pause (held by the ListingRegistry): blocks
    /// approveIssuance, settle and both CashbackDistributor withdrawals.
    function toggleRegistryPause() external {
        bool isPaused = registry.paused();
        vm.prank(admin);
        if (isPaused) {
            registry.unpause();
        } else {
            registry.pause();
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

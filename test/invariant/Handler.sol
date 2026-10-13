// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetToken} from "../../src/AssetToken.sol";
import {BackingGateway} from "../../src/BackingGateway.sol";
import {NiaraSettlement} from "../../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../../src/CashbackDistributor.sol";
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

    uint256[] public backingRequestIds;
    uint256[] public redemptionRequestIds;

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

    constructor(Config memory config) {
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
        AssetToken asset = _pickAsset(assetSeed);
        address paymentToken = _pickPaymentToken(paymentSeed);

        uint256 assetAmount = _pickAssetAmount(asset, seller, assetAmountSeed);
        if (assetAmount == 0) return;
        uint256 paymentAmount = _pickPaymentAmount(paymentToken, buyer, paymentAmountSeed);

        vm.prank(seller);
        asset.approve(address(settlement), assetAmount);
        vm.prank(buyer);
        IERC20(paymentToken).approve(address(settlement), paymentAmount);

        uint256 cashbackBefore = distributor.cashbackBalance(address(asset), paymentToken);
        vm.prank(settlementOperator);
        uint256 feeCharged = settlement.settle(address(asset), paymentToken, buyer, seller, assetAmount, paymentAmount);
        _recordSettleGhosts(asset, paymentToken, feeCharged, cashbackBefore);
    }

    function _pickAssetAmount(AssetToken asset, address seller, uint256 seed) internal view returns (uint256) {
        if (_chaos(seed)) return seed % 2_000_000 ether; // may exceed the real balance/approval, or be zero.
        uint256 sellerBalance = asset.balanceOf(seller);
        if (sellerBalance == 0) return 0;
        return bound(seed, 1, sellerBalance);
    }

    function _pickPaymentAmount(address paymentToken, address buyer, uint256 seed) internal returns (uint256) {
        // Ensures the buyer has enough liquidity most of the time, so the fuzzed call is not
        // wasted on a no-op for lack of balance; the mock allows free minting, test use only.
        if (paymentToken == address(usdt)) {
            usdt.mint(buyer, 1_000_000e6);
        } else {
            wbtc.mint(buyer, 1_000e8);
        }

        if (_chaos(seed)) return seed % 2_000_000e8; // may exceed the newly funded balance, or be zero.
        uint256 buyerBalance = IERC20(paymentToken).balanceOf(buyer);
        return bound(seed, 1, buyerBalance);
    }

    function _recordSettleGhosts(AssetToken asset, address paymentToken, uint256 feeCharged, uint256 cashbackBefore)
        internal
    {
        ghost_sumFeesRecorded[paymentToken] += feeCharged;
        uint256 cashbackAfter = distributor.cashbackBalance(address(asset), paymentToken);
        ghost_sumCashbackCredited[paymentToken] += (cashbackAfter - cashbackBefore);
    }

    // ── Saques ──────────────────────────────────────────────────────────────────────────

    function withdrawCashback(uint256 assetSeed, uint256 paymentSeed) external {
        AssetToken asset = _pickAsset(assetSeed);
        address paymentToken = _pickPaymentToken(paymentSeed);
        address issuer = asset.issuerWallet();

        // No available-balance guard on purpose: most of the time there is nothing to
        // withdraw yet, exercising NothingToWithdraw organically.
        vm.prank(issuer);
        distributor.withdraw(address(asset), paymentToken);
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

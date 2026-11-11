// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {P2PEscrow} from "../../src/P2PEscrow.sol";
import {NiaraSettlement} from "../../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../../src/CashbackDistributor.sol";
import {ListingRegistry} from "../../src/ListingRegistry.sol";
import {IListingRegistry} from "../../src/interfaces/IListingRegistry.sol";

/// @notice Handler for the P2PEscrow invariant suite (test/P2PEscrowInvariant.t.sol). It runs
/// random sequences of open / accept / cancel / expire (valid and invalid: wrong signers,
/// invalid markets, zero amounts, reused ids, expiries in and out of the window, replays of
/// resolved deals), donations straight into the escrow, sweeps, pause toggles, listing
/// suspensions and reinstatements, clock jumps and timelocked fee / cashback changes.
///
/// Like the Solana fuzzer (`tests/test_invariants.rs`), it keeps a model and predicts the
/// outcome of every escrow call exactly (status, signer, clock, pause, listings); a call
/// that succeeds or fails against the prediction is counted in `ghost_predictionMismatches`.
/// It also models every party's balance of every token, so a deposit that is stranded, paid
/// twice or paid to the wrong party breaks the model.
contract EscrowHandler is Test {
    uint256 public constant MAX_OPEN_DEALS = 8;
    uint256 internal constant MAX_DEAL_AMOUNT = 1e24;

    P2PEscrow public immutable escrow;
    NiaraSettlement public immutable settlement;
    CashbackDistributor public immutable distributor;
    ListingRegistry public immutable registry;
    address public immutable admin;
    address public immutable listingAuthority;
    address public immutable donor;
    address public immutable sink;
    address public immutable usdt;
    uint256 public immutable timelockDelay;

    address[] public actors;
    /// @dev bond (FixedIncome), credit (Credit), equity (Equity), usdt, brl, eur.
    address[] public tokens;
    /// @dev Everyone whose balances the model tracks.
    address[] public holders;

    /// @dev The handler's own record of a deal: the terms it sent and the rates in force when
    /// it opened, never read back from the escrow.
    struct Tracked {
        bytes32 key;
        address proposer;
        address counterparty;
        address asset;
        address payment;
        bool sell;
        uint256 assetAmount;
        uint256 paymentAmount;
        uint16 feeBps;
        uint16 cashbackBps;
        uint64 expiresAt;
        P2PEscrow.DealStatus status;
    }

    bool internal _initialized;
    Tracked[] internal _deals;
    uint256 public openDeals;
    uint128 internal _idCounter;
    mapping(address proposer => bytes16[]) internal _usedIds;
    mapping(address proposer => mapping(bytes16 dealId => bool)) internal _idUsed;

    /// @notice Expected balance of `token` held by `holder`.
    mapping(address holder => mapping(address token => uint256)) public modelBalance;
    /// @notice Expected sum of open deposits per token.
    mapping(address token => uint256) public modelEscrowed;
    /// @notice Tokens sent straight to the escrow and not swept yet.
    mapping(address token => uint256) public unsweptDonations;

    /// @notice How many times each deal's deposit left the escrow.
    mapping(bytes32 dealKey => uint256) public ghost_payouts;
    mapping(address asset => uint256) public ghost_cashbackAccrued;
    uint256 public ghost_protocolFees;

    uint256 public ghost_predictionMismatches;
    uint256 public ghost_acceptedAtOrAfterExpiry;
    uint256 public ghost_expiredBeforeExpiry;
    uint256 public ghost_tradedWhileBlocked;
    uint256 public ghost_snapshotMismatches;
    uint256 public ghost_sweepAmountMismatches;

    uint256 public ghost_opened;
    uint256 public ghost_executed;
    uint256 public ghost_cancelled;
    uint256 public ghost_expired;
    uint256 public ghost_swept;

    constructor(
        P2PEscrow escrow_,
        NiaraSettlement settlement_,
        CashbackDistributor distributor_,
        ListingRegistry registry_,
        address admin_,
        address listingAuthority_,
        address donor_,
        address sink_,
        address[] memory actors_,
        address[] memory tokens_,
        uint256 timelockDelay_
    ) {
        escrow = escrow_;
        settlement = settlement_;
        distributor = distributor_;
        registry = registry_;
        admin = admin_;
        listingAuthority = listingAuthority_;
        donor = donor_;
        sink = sink_;
        actors = actors_;
        tokens = tokens_;
        usdt = tokens_[3];
        timelockDelay = timelockDelay_;

        for (uint256 i = 0; i < actors_.length; i++) {
            holders.push(actors_[i]);
        }
        holders.push(donor_);
        holders.push(sink_);
        holders.push(address(escrow_));
        holders.push(address(distributor_));
    }

    /// @notice Loads the starting balances into the model. Called once by the test, after
    /// funding; it is not a fuzz target and cannot run again (re-reading the real balances
    /// mid-run would hide any divergence from the model).
    function init() external {
        require(!_initialized, "already initialized");
        _initialized = true;
        for (uint256 h = 0; h < holders.length; h++) {
            for (uint256 t = 0; t < tokens.length; t++) {
                modelBalance[holders[h]][tokens[t]] = IERC20(tokens[t]).balanceOf(holders[h]);
            }
        }
    }

    // ── Views for the invariants ───────────────────────────────────────────────────────

    function dealCount() external view returns (uint256) {
        return _deals.length;
    }

    function dealAt(uint256 i) external view returns (Tracked memory) {
        return _deals[i];
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    // ── openDeal ───────────────────────────────────────────────────────────────────────

    struct OpenCase {
        address proposer;
        address counterparty;
        address asset;
        address payment;
        bool sell;
        uint256 assetAmount;
        uint256 paymentAmount;
        uint64 expiresAt;
        bytes16 dealId;
        uint16 feeBps;
        uint16 cashbackBps;
    }

    /// @dev One open attempt. Two times out of three every input is valid (the call can
    /// still fail on the protocol's state: pause, suspended listing); otherwise exactly one
    /// input is broken, picked by `fault`.
    function openDeal(uint256 seed, bool sell, uint256 assetAmount, uint256 paymentAmount) external {
        if (openDeals >= MAX_OPEN_DEALS) return;
        seed = _mix(seed);
        uint256 fault = (seed >> 200) % 36;
        OpenCase memory c;
        c.proposer = actors[seed % actors.length];
        c.counterparty = actors[(seed + 1 + (seed >> 8) % (actors.length - 1)) % actors.length];
        (c.asset, c.payment) = _validMarket(seed >> 16);
        c.sell = sell;
        c.assetAmount = bound(_mix(assetAmount), 1e6, MAX_DEAL_AMOUNT);
        c.paymentAmount = bound(_mix(paymentAmount), 1e6, MAX_DEAL_AMOUNT);
        c.expiresAt = uint64(block.timestamp + 1 + (seed >> 32) % 2 days);
        c.dealId = bytes16(++_idCounter);

        if (fault == 0) c.assetAmount = 0;
        else if (fault == 1) c.paymentAmount = 0;
        else if (fault == 2) (c.assetAmount, c.paymentAmount) = (1 + (seed >> 64) % 300, 1 + (seed >> 80) % 300);
        else if (fault == 3) c.counterparty = c.proposer;
        else if (fault == 4) c.counterparty = address(0);
        else if (fault == 5) c.expiresAt = uint64(block.timestamp);
        else if (fault == 6) c.expiresAt = uint64(block.timestamp + 30 days + 1);
        else if (fault == 7) c.expiresAt = uint64(block.timestamp + 30 days); // the valid edge
        else if (fault == 8) c.dealId = bytes16(0);
        else if (fault == 9) c.dealId = _reusedDealId(c.proposer, seed >> 64, c.dealId);
        else if (fault < 13) (c.asset, c.payment) = _anyMarket(seed >> 64);
        // The rates in force now, read by the handler itself: what the deal must carry.
        c.feeBps = settlement.feeBps();
        c.cashbackBps = distributor.cashbackBps();

        bool expected = _predictOpen(c);
        P2PEscrow.DealTerms memory terms = P2PEscrow.DealTerms({
            counterparty: c.counterparty,
            assetToken: c.asset,
            paymentToken: c.payment,
            proposerSide: c.sell ? P2PEscrow.DealSide.Sell : P2PEscrow.DealSide.Buy,
            assetAmount: c.assetAmount,
            paymentAmount: c.paymentAmount
        });
        vm.prank(c.proposer);
        try escrow.openDeal(c.dealId, terms, c.expiresAt) returns (bytes32 dealKey) {
            if (!expected) ghost_predictionMismatches++;
            _recordOpened(c, dealKey);
        } catch {
            if (expected) ghost_predictionMismatches++;
        }
    }

    function _predictOpen(OpenCase memory c) internal view returns (bool) {
        if (c.dealId == bytes16(0) || _idUsed[c.proposer][c.dealId]) return false;
        if (c.assetAmount == 0 || c.paymentAmount == 0) return false;
        if (c.counterparty == address(0) || c.counterparty == c.proposer) return false;
        if (c.expiresAt <= block.timestamp || c.expiresAt > block.timestamp + 30 days) return false;
        if (!_marketOpen(c.asset, c.payment)) return false;
        uint256 usdtAmount = c.payment == usdt ? c.paymentAmount : c.assetAmount;
        if (c.feeBps > 0 && (usdtAmount * c.feeBps) / 10_000 == 0) return false;
        return true;
    }

    /// @dev Whether a deal in this market may open or execute right now: not paused, two
    /// different tokens, an Approved P2P-class asset, an Approved Currency payment and
    /// exactly one USDT leg (the payment for FixedIncome/Credit).
    function _marketOpen(address asset, address payment) internal view returns (bool) {
        if (registry.paused()) return false;
        if (asset == payment) return false;
        IListingRegistry.Listing memory assetListing = registry.getListing(asset);
        if (assetListing.status != IListingRegistry.ListingStatus.Approved) return false;
        if (assetListing.assetClass == IListingRegistry.AssetClass.Equity) return false;
        IListingRegistry.Listing memory paymentListing = registry.getListing(payment);
        if (paymentListing.status != IListingRegistry.ListingStatus.Approved) return false;
        if (paymentListing.assetClass != IListingRegistry.AssetClass.Currency) return false;
        if (payment == usdt) return true;
        return assetListing.assetClass == IListingRegistry.AssetClass.Currency && asset == usdt;
    }

    function _recordOpened(OpenCase memory c, bytes32 dealKey) internal {
        ghost_opened++;
        openDeals++;
        _idUsed[c.proposer][c.dealId] = true;
        _usedIds[c.proposer].push(c.dealId);

        P2PEscrow.Deal memory stored = escrow.getDeal(dealKey);
        if (stored.feeBps != c.feeBps || stored.cashbackBps != c.cashbackBps) ghost_snapshotMismatches++;

        (address depositToken, uint256 depositAmount) =
            c.sell ? (c.asset, c.assetAmount) : (c.payment, c.paymentAmount);
        modelBalance[c.proposer][depositToken] -= depositAmount;
        modelBalance[address(escrow)][depositToken] += depositAmount;
        modelEscrowed[depositToken] += depositAmount;

        _deals.push(
            Tracked({
                key: dealKey,
                proposer: c.proposer,
                counterparty: c.counterparty,
                asset: c.asset,
                payment: c.payment,
                sell: c.sell,
                assetAmount: c.assetAmount,
                paymentAmount: c.paymentAmount,
                feeBps: c.feeBps,
                cashbackBps: c.cashbackBps,
                expiresAt: c.expiresAt,
                status: P2PEscrow.DealStatus.Open
            })
        );
    }

    // ── acceptDeal ─────────────────────────────────────────────────────────────────────

    function acceptDeal(uint256 dealSeed, uint256 callerSeed) external {
        if (_deals.length == 0) return;
        Tracked storage d = _pickDeal(dealSeed);
        callerSeed = _mix(callerSeed);
        address caller = _chaos(callerSeed) ? actors[(callerSeed / 16) % actors.length] : d.counterparty;

        bool marketOpen = _marketOpen(d.asset, d.payment);
        bool expected = caller == d.counterparty && d.status == P2PEscrow.DealStatus.Open
            && block.timestamp < d.expiresAt && marketOpen;

        vm.prank(caller);
        try escrow.acceptDeal(d.key) {
            if (!expected) ghost_predictionMismatches++;
            if (block.timestamp >= d.expiresAt) ghost_acceptedAtOrAfterExpiry++;
            if (!marketOpen) ghost_tradedWhileBlocked++;
            _recordExecuted(d);
        } catch {
            if (expected) ghost_predictionMismatches++;
        }
    }

    function _recordExecuted(Tracked storage d) internal {
        ghost_executed++;
        openDeals--;
        ghost_payouts[d.key]++;
        d.status = P2PEscrow.DealStatus.Executed;

        // The fee is on the USDT leg, at the rates recorded when the deal opened; whoever
        // receives that leg pays it, the other party gets its leg in full.
        bool feeOnPayment = d.payment == usdt;
        uint256 fee = ((feeOnPayment ? d.paymentAmount : d.assetAmount) * d.feeBps) / 10_000;
        uint256 cashback = registry.getListing(d.asset).cashbackEligible ? (fee * d.cashbackBps) / 10_000 : 0;
        uint256 assetNet = d.assetAmount - (feeOnPayment ? 0 : fee);
        uint256 paymentNet = d.paymentAmount - (feeOnPayment ? fee : 0);

        if (d.sell) {
            // Proposer escrowed the asset; the counterparty pays.
            modelBalance[address(escrow)][d.asset] -= d.assetAmount;
            modelEscrowed[d.asset] -= d.assetAmount;
            modelBalance[d.counterparty][d.asset] += assetNet;
            modelBalance[d.counterparty][d.payment] -= d.paymentAmount;
            modelBalance[d.proposer][d.payment] += paymentNet;
        } else {
            // Proposer escrowed the payment; the counterparty delivers the asset.
            modelBalance[address(escrow)][d.payment] -= d.paymentAmount;
            modelEscrowed[d.payment] -= d.paymentAmount;
            modelBalance[d.counterparty][d.payment] += paymentNet;
            modelBalance[d.counterparty][d.asset] -= d.assetAmount;
            modelBalance[d.proposer][d.asset] += assetNet;
        }
        modelBalance[address(distributor)][usdt] += fee;
        ghost_cashbackAccrued[d.asset] += cashback;
        ghost_protocolFees += fee - cashback;
    }

    // ── cancelDeal / expireDeal ────────────────────────────────────────────────────────

    function cancelDeal(uint256 dealSeed, uint256 callerSeed) external {
        if (_deals.length == 0) return;
        Tracked storage d = _pickDeal(dealSeed);
        callerSeed = _mix(callerSeed);
        address caller = _chaos(callerSeed) ? actors[(callerSeed / 16) % actors.length] : d.proposer;

        // Nothing but the signer and the status: no pause, no listing, no clock.
        bool expected = caller == d.proposer && d.status == P2PEscrow.DealStatus.Open;

        vm.prank(caller);
        try escrow.cancelDeal(d.key) {
            if (!expected) ghost_predictionMismatches++;
            ghost_cancelled++;
            _recordRefunded(d, P2PEscrow.DealStatus.Cancelled);
        } catch {
            if (expected) ghost_predictionMismatches++;
        }
    }

    function expireDeal(uint256 dealSeed, uint256 callerSeed) external {
        if (_deals.length == 0) return;
        Tracked storage d = _pickDeal(dealSeed);
        address caller = actors[callerSeed % actors.length];

        // Nothing but the status and the clock: anyone, in any protocol state.
        bool expected = d.status == P2PEscrow.DealStatus.Open && block.timestamp >= d.expiresAt;

        vm.prank(caller);
        try escrow.expireDeal(d.key) {
            if (!expected) ghost_predictionMismatches++;
            if (block.timestamp < d.expiresAt) ghost_expiredBeforeExpiry++;
            ghost_expired++;
            _recordRefunded(d, P2PEscrow.DealStatus.Expired);
        } catch {
            if (expected) ghost_predictionMismatches++;
        }
    }

    function _recordRefunded(Tracked storage d, P2PEscrow.DealStatus finalStatus) internal {
        openDeals--;
        ghost_payouts[d.key]++;
        d.status = finalStatus;
        (address depositToken, uint256 depositAmount) =
            d.sell ? (d.asset, d.assetAmount) : (d.payment, d.paymentAmount);
        modelBalance[address(escrow)][depositToken] -= depositAmount;
        modelEscrowed[depositToken] -= depositAmount;
        modelBalance[d.proposer][depositToken] += depositAmount;
    }

    // ── Donations and sweeps ───────────────────────────────────────────────────────────

    /// @notice Sends tokens straight to the escrow, outside any deal.
    function donate(uint256 tokenSeed, uint256 amount) external {
        address token = tokens[tokenSeed % tokens.length];
        amount = bound(_mix(amount), 1, 1e20);
        vm.prank(donor);
        IERC20(token).transfer(address(escrow), amount);
        modelBalance[donor][token] -= amount;
        modelBalance[address(escrow)][token] += amount;
        unsweptDonations[token] += amount;
    }

    function sweepExcess(uint256 tokenSeed, uint256 callerSeed) external {
        address token = tokens[tokenSeed % tokens.length];
        callerSeed = _mix(callerSeed);
        address caller = _chaos(callerSeed) ? actors[(callerSeed / 16) % actors.length] : admin;
        uint256 excess = unsweptDonations[token];

        bool expected = caller == admin && !registry.paused() && excess > 0;

        vm.prank(caller);
        try escrow.sweepExcess(token, sink) returns (uint256 amount) {
            if (!expected) ghost_predictionMismatches++;
            // Exactly the donations: a sweep can never reach a deposit.
            if (amount != excess) ghost_sweepAmountMismatches++;
            ghost_swept++;
            unsweptDonations[token] = 0;
            modelBalance[address(escrow)][token] -= amount;
            modelBalance[sink][token] += amount;
        } catch {
            if (expected) ghost_predictionMismatches++;
        }
    }

    // ── Protocol state ─────────────────────────────────────────────────────────────────

    /// @notice Pauses one time in four, unpauses otherwise, so the protocol is unpaused most
    /// of the time and deals actually open and execute between pauses.
    function togglePause(uint256 seed) external {
        // Read before the prank: `registry.paused()` is an external call and would consume it.
        bool isPaused = registry.paused();
        bool wantPaused = _mix(seed) % 4 == 0;
        if (wantPaused == isPaused) return;
        vm.prank(admin);
        if (wantPaused) registry.pause();
        else registry.unpause();
    }

    /// @notice One time in three, suspends one Approved listing; otherwise reinstates every
    /// Suspended one. USDT is a leg of every valid deal, so a suspension that lingered would
    /// stop the whole run: this keeps suspensions frequent but short.
    function toggleListing(uint256 tokenSeed, uint256 seed) external {
        if (_mix(seed) % 3 == 0) {
            address token = tokens[_mix(tokenSeed) % tokens.length];
            if (registry.getListing(token).status != IListingRegistry.ListingStatus.Approved) return;
            vm.prank(listingAuthority);
            registry.suspendListing(token);
            return;
        }
        for (uint256 t = 0; t < tokens.length; t++) {
            if (registry.getListing(tokens[t]).status != IListingRegistry.ListingStatus.Suspended) continue;
            vm.prank(listingAuthority);
            registry.approveListing(tokens[t]);
        }
    }

    /// @notice Jumps to the expiry boundary of a deal (one second before, exactly at, or one
    /// second after `expiresAt`) and tries to accept it and then to expire it right there.
    /// Random clock jumps almost never land on the boundary, and that is where invariant 7
    /// can break by one second.
    function probeExpiryBoundary(uint256 dealSeed, uint256 offsetSeed) external {
        if (_deals.length == 0) return;
        Tracked storage d = _pickDeal(dealSeed);
        uint256 target = uint256(d.expiresAt) + (_mix(offsetSeed) % 3) - 1;
        if (target <= block.timestamp) return;
        vm.warp(target);
        // Seeds whose hash is not "chaos": the right signer for both calls.
        this.acceptDeal(dealSeed, 1);
        this.expireDeal(dealSeed, 1);
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(_mix(secondsSeed), 1, 1 days));
    }

    /// @notice Timelocked fee change (0 to MAX_FEE_BPS). Deals already open keep their rate.
    function changeFeeBps(uint256 seed) external {
        uint16 newFeeBps = uint16(seed % 101);
        vm.prank(admin);
        settlement.proposeSetFeeBps(newFeeBps);
        vm.warp(block.timestamp + timelockDelay);
        vm.prank(admin);
        settlement.executeSetFeeBps(newFeeBps);
    }

    /// @notice Timelocked cashback change (0 to 100% of the fee). Open deals keep their rate.
    function changeCashbackBps(uint256 seed) external {
        uint16 newCashbackBps = uint16(seed % 10_001);
        vm.prank(admin);
        distributor.proposeSetCashbackBps(newCashbackBps);
        vm.warp(block.timestamp + timelockDelay);
        vm.prank(admin);
        distributor.executeSetCashbackBps(newCashbackBps);
    }

    // ── Pickers ────────────────────────────────────────────────────────────────────────

    /// @dev True for roughly 1 seed in 16: the deliberately invalid path.
    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 16 == 0;
    }

    function _pickDeal(uint256 seed) internal view returns (Tracked storage) {
        // Recent deals most of the time (they are the ones still open), any deal otherwise.
        seed = _mix(seed);
        uint256 count = _deals.length;
        if (seed % 4 != 0 && count > MAX_OPEN_DEALS) return _deals[count - 1 - (seed >> 8) % MAX_OPEN_DEALS];
        return _deals[(seed >> 8) % count];
    }

    /// @dev One of the six valid markets: bond and credit paid in USDT, BRL/EUR against USDT
    /// in both directions (so the fee sits on the payment leg or on the asset leg).
    function _validMarket(uint256 seed) internal view returns (address asset, address payment) {
        uint256 pick = seed % 6;
        if (pick == 0) return (tokens[0], usdt);
        if (pick == 1) return (tokens[1], usdt);
        if (pick == 2) return (tokens[4], usdt);
        if (pick == 3) return (tokens[5], usdt);
        if (pick == 4) return (usdt, tokens[4]);
        return (usdt, tokens[5]);
    }

    /// @dev Any pair of the six tokens, most of them invalid: Equity asset, no USDT leg,
    /// non-currency payment, same token.
    function _anyMarket(uint256 seed) internal view returns (address asset, address payment) {
        return (tokens[seed % tokens.length], tokens[(seed >> 8) % tokens.length]);
    }

    /// @dev An id this proposer already used (must revert, whatever became of that deal),
    /// or `fresh` if it has not used any yet.
    function _reusedDealId(address proposer, uint256 seed, bytes16 fresh) internal view returns (bytes16) {
        uint256 used = _usedIds[proposer].length;
        return used == 0 ? fresh : _usedIds[proposer][seed % used];
    }

    /// @dev Spreads the fuzzer's inputs (often 0, 1 or other edge values) uniformly.
    function _mix(uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed)));
    }
}

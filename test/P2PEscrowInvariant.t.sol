// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {P2PEscrow} from "../src/P2PEscrow.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {EscrowHandler} from "./invariant/EscrowHandler.sol";

/// @notice Stateful fuzzing of P2PEscrow. Mirrors the two escrow invariants of the Solana
/// program (EXCHANGE-MULTICHAIN-DESIGN.md §3.9):
///
///   6. an escrowed deposit always ends in exactly one place: the counterparty (executed)
///      or the proposer (cancelled / expired). It is never stranded and never paid twice;
///   7. no `acceptDeal` at or after `expiresAt`; no `expireDeal` before it.
///
/// The `EscrowHandler` predicts the outcome of every escrow call from its own model and
/// tracks every party's balance of every token; the functions below check, after EVERY
/// call of the sequence, that the contract agrees with the model.
contract P2PEscrowInvariantTest is Test {
    P2PEscrow public escrow;
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    ListingRegistry public registry;
    EscrowHandler public handler;

    address public admin = makeAddr("admin");
    address public listingAuthority = makeAddr("listingAuthority");
    address public issuer = makeAddr("issuer");
    address public donor = makeAddr("donor");
    address public sink = makeAddr("sink");

    /// @dev The minimum, so the timelocked fee changes of the handler do not jump the clock
    /// past every open deal's expiry.
    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant FUNDING = 1e30;

    address[] internal actors;
    /// @dev bond (FixedIncome), credit (Credit), equity (Equity), usdt, brl, eur.
    address[] internal tokens;

    function setUp() public {
        registry = new ListingRegistry(admin, listingAuthority, TIMELOCK_DELAY);
        // 2000 bps: the rate script/Deploy.s.sol constructs the distributor with. The handler
        // then moves it anywhere in 0..10_000 through the timelock.
        distributor = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, 2_000);
        MockUSDT usdt = new MockUSDT();
        settlement =
            new NiaraSettlement(admin, address(distributor), address(registry), address(usdt), TIMELOCK_DELAY);
        escrow = new P2PEscrow(admin, address(settlement), address(registry), TIMELOCK_DELAY);

        // Role wiring through the timelock, as in production.
        bytes32 escrowRole = distributor.ESCROW_ROLE();
        vm.prank(admin);
        distributor.proposeGrantRole(escrowRole, address(escrow));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        distributor.executeGrantRole(escrowRole, address(escrow));

        actors.push(makeAddr("trader1"));
        actors.push(makeAddr("trader2"));
        actors.push(makeAddr("trader3"));

        tokens.push(_listedNative(IListingRegistry.AssetClass.FixedIncome));
        tokens.push(_listedNative(IListingRegistry.AssetClass.Credit));
        tokens.push(_listedNative(IListingRegistry.AssetClass.Equity));
        tokens.push(address(usdt));
        tokens.push(address(new MockUSDT()));
        tokens.push(address(new MockUSDT()));
        for (uint256 t = 3; t < 6; t++) {
            vm.prank(listingAuthority);
            registry.listCurrency(tokens[t]);
        }

        for (uint256 a = 0; a < actors.length; a++) {
            _fund(actors[a]);
            for (uint256 t = 0; t < tokens.length; t++) {
                vm.prank(actors[a]);
                IERC20(tokens[t]).approve(address(escrow), type(uint256).max);
            }
        }
        _fund(donor);

        handler = new EscrowHandler(
            escrow, settlement, distributor, registry, admin, listingAuthority, donor, sink, actors, tokens, TIMELOCK_DELAY
        );
        handler.init();
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    /// @dev The fuzz targets: every handler action, and nothing else (`init` in particular).
    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](12);
        selectors[11] = EscrowHandler.probeExpiryBoundary.selector;
        selectors[0] = EscrowHandler.openDeal.selector;
        selectors[1] = EscrowHandler.acceptDeal.selector;
        selectors[2] = EscrowHandler.cancelDeal.selector;
        selectors[3] = EscrowHandler.expireDeal.selector;
        selectors[4] = EscrowHandler.donate.selector;
        selectors[5] = EscrowHandler.sweepExcess.selector;
        selectors[6] = EscrowHandler.togglePause.selector;
        selectors[7] = EscrowHandler.toggleListing.selector;
        selectors[8] = EscrowHandler.warp.selector;
        selectors[9] = EscrowHandler.changeFeeBps.selector;
        selectors[10] = EscrowHandler.changeCashbackBps.selector;
    }

    /// @dev Printed with `-vv`: how much of each path the last run actually exercised.
    function afterInvariant() public view {
        console2.log("deals opened   ", handler.ghost_opened());
        console2.log("deals executed ", handler.ghost_executed());
        console2.log("deals cancelled", handler.ghost_cancelled());
        console2.log("deals expired  ", handler.ghost_expired());
        console2.log("sweeps         ", handler.ghost_swept());
    }

    function _listedNative(IListingRegistry.AssetClass assetClass) internal returns (address token) {
        AssetTokenFactory factory = registry.factory();
        vm.prank(issuer);
        token = factory.createAssetToken("Instrument", "INST", assetClass, keccak256("doc"));
        vm.prank(issuer);
        registry.submitListing(token);
        vm.prank(listingAuthority);
        registry.approveListing(token);
    }

    /// @dev Native instruments through approved issuance batches, currencies minted.
    function _fund(address to) internal {
        for (uint256 t = 0; t < 3; t++) {
            vm.prank(issuer);
            uint256 batchNo = registry.requestIssuance(tokens[t], FUNDING, to, keccak256("seed"));
            vm.prank(listingAuthority);
            registry.approveIssuance(tokens[t], batchNo);
        }
        for (uint256 t = 3; t < 6; t++) {
            MockUSDT(tokens[t]).mint(to, FUNDING);
        }
    }

    // ── Invariant 6: a deposit ends in exactly one place ───────────────────────────────

    /// @notice Every party's balance of every token is exactly what the model says: each
    /// deposit went to the counterparty (executed, minus the fee if it was the USDT leg) or
    /// back to the proposer (cancelled / expired), once. A deposit paid twice, paid to the
    /// wrong party or left behind breaks an equality here.
    function invariant_Inv6_BalancesMatchTheModel() public view {
        uint256 holderCount = handler.holderCount();
        for (uint256 h = 0; h < holderCount; h++) {
            address holder = handler.holders(h);
            for (uint256 t = 0; t < tokens.length; t++) {
                assertEq(
                    IERC20(tokens[t]).balanceOf(holder), handler.modelBalance(holder, tokens[t]), "balance != model"
                );
            }
        }
    }

    /// @notice A deal's deposit leaves the escrow exactly once when the deal is resolved and
    /// never while it is open, and the contract's status is the model's.
    function invariant_Inv6_EachDepositPaidOutExactlyOnce() public view {
        uint256 count = handler.dealCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowHandler.Tracked memory d = handler.dealAt(i);
            assertEq(uint8(escrow.getDeal(d.key).status), uint8(d.status), "status != model");
            uint256 payouts = handler.ghost_payouts(d.key);
            assertEq(payouts, d.status == P2PEscrow.DealStatus.Open ? 0 : 1, "deposit not paid exactly once");
        }
    }

    /// @notice Per-deal accounting: `totalEscrowed` is the sum of the open deals' deposits,
    /// and the escrow holds exactly that plus the donations nobody swept yet. Nothing else
    /// is ever left in the contract, and donations never mix with deposits.
    function invariant_Inv6_EscrowHoldsExactlyOpenDepositsPlusDonations() public view {
        uint256[] memory openDeposits = new uint256[](tokens.length);
        uint256 count = handler.dealCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowHandler.Tracked memory d = handler.dealAt(i);
            if (d.status != P2PEscrow.DealStatus.Open) continue;
            (address depositToken, uint256 depositAmount) =
                d.sell ? (d.asset, d.assetAmount) : (d.payment, d.paymentAmount);
            openDeposits[_tokenIndex(depositToken)] += depositAmount;
        }
        for (uint256 t = 0; t < tokens.length; t++) {
            assertEq(escrow.totalEscrowed(tokens[t]), openDeposits[t], "totalEscrowed != sum of open deposits");
            assertEq(
                IERC20(tokens[t]).balanceOf(address(escrow)),
                openDeposits[t] + handler.unsweptDonations(tokens[t]),
                "escrow balance != open deposits + donations"
            );
        }
    }

    /// @notice Never stranded: whatever the protocol's state (paused, listings suspended,
    /// fee changed, any clock), the proposer of every open deal can take its exact deposit
    /// back right now. Each refund is tried on a snapshot and rolled back.
    function invariant_Inv6_EveryOpenDepositIsRefundableNow() public {
        uint256 count = handler.dealCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowHandler.Tracked memory d = handler.dealAt(i);
            if (d.status != P2PEscrow.DealStatus.Open) continue;
            (address depositToken, uint256 depositAmount) =
                d.sell ? (d.asset, d.assetAmount) : (d.payment, d.paymentAmount);

            uint256 snapshotId = vm.snapshotState();
            uint256 before = IERC20(depositToken).balanceOf(d.proposer);
            vm.prank(d.proposer);
            escrow.cancelDeal(d.key);
            assertEq(IERC20(depositToken).balanceOf(d.proposer), before + depositAmount, "refund != deposit");
            vm.revertToState(snapshotId);
        }
    }

    // ── Invariant 7: the expiry boundary ───────────────────────────────────────────────

    /// @notice No deal was ever accepted at or after `expiresAt`, none expired before it.
    function invariant_Inv7_NoAcceptAfterExpiryNoExpireBefore() public view {
        assertEq(handler.ghost_acceptedAtOrAfterExpiry(), 0, "accepted at or after expiresAt");
        assertEq(handler.ghost_expiredBeforeExpiry(), 0, "expired before expiresAt");
    }

    /// @notice Every escrow call ended as the model predicted from the signer, the deal's
    /// status, the clock, the pause and the listings. This is invariant 7 in both directions
    /// (a live deal can always be accepted by its counterparty, an expired one can always be
    /// expired by anyone) and the pause principle (open / accept blocked, cancel / expire
    /// never) checked on every call.
    function invariant_EveryCallMatchesThePrediction() public view {
        assertEq(handler.ghost_predictionMismatches(), 0, "an escrow call contradicted the model");
        assertEq(handler.ghost_tradedWhileBlocked(), 0, "deal executed while paused or not Approved");
    }

    // ── Fees ───────────────────────────────────────────────────────────────────────────

    /// @notice Every deal carries the fee and cashback rates in force when it opened.
    function invariant_DealsCarryTheRatesOfTheirOpening() public view {
        assertEq(handler.ghost_snapshotMismatches(), 0, "deal rates != rates at open");
    }

    /// @notice The distributor's books equal the fees and cashback the model computed from
    /// each deal's own rates: USDT only, cashback only for the eligible listings, never for
    /// a Currency.
    function invariant_FeeAccountingMatchesTheDeals() public view {
        address usdt = tokens[3];
        uint256 cashbackTotal;
        for (uint256 t = 0; t < tokens.length; t++) {
            uint256 accrued = distributor.cashbackBalance(tokens[t], usdt);
            assertEq(accrued, handler.ghost_cashbackAccrued(tokens[t]), "cashback != model");
            if (t >= 2) assertEq(accrued, 0, "Equity or Currency accrued deal cashback");
            cashbackTotal += accrued;
            if (tokens[t] != usdt) {
                assertEq(distributor.protocolBalance(tokens[t]), 0, "fee charged outside USDT");
                assertEq(IERC20(tokens[t]).balanceOf(address(distributor)), 0, "distributor holds a non-USDT token");
            }
        }
        assertEq(distributor.protocolBalance(usdt), handler.ghost_protocolFees(), "protocol fees != model");
        assertEq(IERC20(usdt).balanceOf(address(distributor)), cashbackTotal + handler.ghost_protocolFees());
    }

    /// @notice A sweep moves exactly the donations, never part of a deposit.
    function invariant_SweepsTakeOnlyDonations() public view {
        assertEq(handler.ghost_sweepAmountMismatches(), 0, "sweep amount != unswept donations");
    }

    function _tokenIndex(address token) internal view returns (uint256) {
        for (uint256 t = 0; t < tokens.length; t++) {
            if (tokens[t] == token) return t;
        }
        revert("unknown token");
    }
}

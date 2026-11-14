// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {ListingFeeHelpers} from "./helpers/ListingFeeHelpers.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockWBTC} from "./mocks/MockWBTC.sol";
import {Handler} from "./invariant/Handler.sol";

/// @notice Stateful fuzzing invariant tests (Foundry `invariant_*`): the `Handler`
/// runs random sequences of request/attest/mint/burn (via redemptionAttest)/settle/
/// redeem, listing status changes, listing-fee quotes and payments (spec §3.13) and native
/// issuance/burns, triggered by different actors (operator, custodian, settlementOperator,
/// listing authority, native issuer and three traders), and the functions below check that
/// the protocol's core invariants hold after EVERY call in the sequence, not only in
/// hand-written scenarios.
///
/// Listing fee, like the Solana fuzzer: the two seeded instruments are approved by quote and
/// payment at setup, and three more issuer listings (Equity, FixedIncome, Credit) start
/// `Pending`. Random `quoteListing` and `payListingFee` calls have their outcome predicted
/// exactly, `approveListing` never approves an unpaid listing, and issuance on the new
/// listings is refused while `Pending` or `Quoted` and succeeds only once paid.
contract InvariantTest is ListingFeeHelpers {
    AssetToken public assetEquity;
    AssetToken public assetCommodity;
    BackingGateway public gateway;
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    ListingRegistry public registry;
    NativeAssetToken public nativeEquity;
    NativeAssetToken public nativeBond;
    MockUSDT public usdt;
    MockWBTC public wbtc;
    MockUSDT public unlistedPayment;
    Handler public handler;

    address public admin = makeAddr("admin");
    address public listingAuthority = makeAddr("listingAuthority");
    address public nativeIssuer = makeAddr("nativeIssuer");
    address public issuerEquity = makeAddr("issuerEquity");
    address public issuerCommodity = makeAddr("issuerCommodity");
    address public operator = makeAddr("operator");
    address public custodian = makeAddr("custodian");
    address public settlementOperator = makeAddr("settlementOperator");

    uint256 public constant TIMELOCK_DELAY = 2 days;

    uint256 public seededNativeEquitySupply;
    uint256 public seededNativeBondSupply;

    /// @dev The three listings that start Pending, and the listing fees paid at setup.
    address[] public feeListings;
    uint256 public setupListingFees;

    function setUp() public {
        _deployContracts();
        _wireRoles();
        _deployHandlerAndTargets();
    }

    function _deployContracts() internal {
        registry = new ListingRegistry(admin, listingAuthority, TIMELOCK_DELAY);
        // 2000 bps: the rate script/Deploy.s.sol constructs the distributor with.
        distributor = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, 2_000);
        usdt = new MockUSDT();
        settlement =
            new NiaraSettlement(admin, address(distributor), address(registry), address(usdt), TIMELOCK_DELAY);
        gateway = new BackingGateway(admin, TIMELOCK_DELAY);
        assetEquity = new AssetToken(
            "Apple Inc. - Niara Tokenized Equity",
            "nAAPL",
            "AAPL",
            AssetToken.AssetClass.EQUITY,
            "US",
            issuerEquity,
            admin,
            TIMELOCK_DELAY
        );
        assetCommodity = new AssetToken(
            "Niara Tokenized Gold",
            "nXAU",
            "XAU",
            AssetToken.AssetClass.COMMODITY,
            "US",
            issuerCommodity,
            admin,
            TIMELOCK_DELAY
        );
        wbtc = new MockWBTC();
        unlistedPayment = new MockUSDT();

        // Native instruments: one per trading mode. Resolve the factory before pranking.
        AssetTokenFactory factory = registry.factory();
        vm.prank(nativeIssuer);
        nativeEquity = NativeAssetToken(
            factory.createAssetToken("Acme Shares", "ACME", IListingRegistry.AssetClass.Equity, keccak256("acme"))
        );
        vm.prank(nativeIssuer);
        nativeBond = NativeAssetToken(
            factory.createAssetToken("Acme 2030 Bond", "ACME30", IListingRegistry.AssetClass.FixedIncome, keccak256("b"))
        );
    }

    /// @dev Lists both native instruments (Approved) and both currencies, and seeds each
    /// actor with an initial native batch so the fuzzer reaches productive settlements.
    /// `unlistedPayment` is never listed.
    function _listAndSeed(address[] memory actors) internal {
        _submitAndApprove(nativeEquity);
        _submitAndApprove(nativeBond);
        vm.prank(listingAuthority);
        registry.listCurrency(address(usdt));
        vm.prank(listingAuthority);
        registry.listCurrency(address(wbtc));

        for (uint256 i = 0; i < actors.length; i++) {
            _seedBatch(nativeEquity, actors[i], 1_000 ether);
            _seedBatch(nativeBond, actors[i], 1_000 ether);
        }
    }

    /// @dev Submit, then approve by quoting and paying the listing fee (spec §3.13).
    function _submitAndApprove(NativeAssetToken token) internal {
        vm.prank(nativeIssuer);
        registry.submitListing(address(token));
        setupListingFees += _approveByFee(registry, listingAuthority, address(token));
    }

    /// @dev Three more issuer listings, one per issuer class, left Pending for the fuzzer.
    function _submitFeeListings() internal {
        AssetTokenFactory factory = registry.factory();
        IListingRegistry.AssetClass[3] memory classes = [
            IListingRegistry.AssetClass.Equity,
            IListingRegistry.AssetClass.FixedIncome,
            IListingRegistry.AssetClass.Credit
        ];
        for (uint256 i = 0; i < classes.length; i++) {
            vm.prank(nativeIssuer);
            address token = factory.createAssetToken("Fee Listing", "FEE", classes[i], keccak256(abi.encode("fee", i)));
            vm.prank(nativeIssuer);
            registry.submitListing(token);
            feeListings.push(token);
        }
        vm.prank(nativeIssuer);
        usdt.approve(address(registry), type(uint256).max);
    }

    function _seedBatch(NativeAssetToken token, address to, uint256 amount) internal {
        vm.prank(nativeIssuer);
        uint256 batchNo = registry.requestIssuance(address(token), amount, to, keccak256("seed"));
        vm.prank(listingAuthority);
        registry.approveIssuance(address(token), batchNo);
    }

    function _wireRoles() internal {
        // Role wiring: every grant goes through the timelock, as in production.
        _wireListingFee(registry, distributor, address(settlement), admin);
        _grantRoleOn(address(distributor), distributor.SETTLEMENT_ROLE(), address(settlement));
        _grantRoleOn(address(settlement), settlement.SETTLEMENT_OPERATOR_ROLE(), settlementOperator);
        _grantRoleOn(address(gateway), gateway.OPERATOR_ROLE(), operator);
        _grantRoleOn(address(gateway), gateway.CUSTODIAN_ROLE(), custodian);
        _grantRoleOn(address(assetEquity), assetEquity.MINTER_ROLE(), address(gateway));
        _grantRoleOn(address(assetEquity), assetEquity.BURNER_ROLE(), address(gateway));
        _grantRoleOn(address(assetCommodity), assetCommodity.MINTER_ROLE(), address(gateway));
        _grantRoleOn(address(assetCommodity), assetCommodity.BURNER_ROLE(), address(gateway));

        _setBackingGateway(assetEquity, address(gateway));
        _setBackingGateway(assetCommodity, address(gateway));
    }

    function _deployHandlerAndTargets() internal {
        address[] memory actors = new address[](3);
        actors[0] = makeAddr("actor1");
        actors[1] = makeAddr("actor2");
        actors[2] = makeAddr("actor3");

        _listAndSeed(actors);
        seededNativeEquitySupply = nativeEquity.totalSupply();
        seededNativeBondSupply = nativeBond.totalSupply();
        _submitFeeListings();

        handler = new Handler(
            Handler.Config({
                assetEquity: assetEquity,
                assetCommodity: assetCommodity,
                gateway: gateway,
                settlement: settlement,
                distributor: distributor,
                usdt: usdt,
                wbtc: wbtc,
                actors: actors,
                operator: operator,
                custodian: custodian,
                settlementOperator: settlementOperator,
                admin: admin
            }),
            Handler.NativeConfig({
                registry: registry,
                nativeEquity: nativeEquity,
                nativeBond: nativeBond,
                unlistedPayment: unlistedPayment,
                listingAuthority: listingAuthority,
                nativeIssuer: nativeIssuer
            })
        );

        handler.initListingFee(feeListings);

        // Restricts the invariant fuzzer to the Handler, and within it only to protocol
        // actions, never to helpers inherited from Test (e.g. IS_TEST).
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](21);
        selectors[0] = Handler.requestBacking.selector;
        selectors[1] = Handler.attestBacking.selector;
        selectors[2] = Handler.mintAttested.selector;
        selectors[3] = Handler.cancelBackingRequest.selector;
        selectors[4] = Handler.redemptionRequest.selector;
        selectors[5] = Handler.redemptionAttest.selector;
        selectors[6] = Handler.cancelRedemptionRequest.selector;
        selectors[7] = Handler.settle.selector;
        selectors[8] = Handler.withdrawCashback.selector;
        selectors[9] = Handler.withdrawProtocolFees.selector;
        selectors[10] = Handler.toggleGatewayPause.selector;
        selectors[11] = Handler.toggleAssetPause.selector;
        selectors[12] = Handler.setListingStatus.selector;
        selectors[13] = Handler.requestIssuance.selector;
        selectors[14] = Handler.approveIssuance.selector;
        selectors[15] = Handler.burnNative.selector;
        selectors[16] = Handler.rejectIssuance.selector;
        selectors[17] = Handler.toggleRegistryPause.selector;
        selectors[18] = Handler.toggleCashbackFreeze.selector;
        selectors[19] = Handler.quoteListing.selector;
        selectors[20] = Handler.payListingFee.selector;
    }

    function _grantRoleOn(address target, bytes32 role, address account) internal {
        vm.prank(admin);
        (bool ok1,) = target.call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, account));
        require(ok1, "propose failed");
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        (bool ok2,) = target.call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, account));
        require(ok2, "execute failed");
    }

    function _setBackingGateway(AssetToken token, address gw) internal {
        vm.prank(admin);
        token.proposeSetBackingGateway(gw);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        token.executeSetBackingGateway(gw);
    }

    // ── Invariante central: totalSupply <= totalAtestado ──────────────────────────────

    function invariant_TotalSupplyNeverExceedsAttested_Equity() public view {
        assertLe(assetEquity.totalSupply(), gateway.totalAttested(address(assetEquity)));
    }

    function invariant_TotalSupplyNeverExceedsAttested_Commodity() public view {
        assertLe(assetCommodity.totalSupply(), gateway.totalAttested(address(assetCommodity)));
    }

    // ── Invariant: credited cashback never exceeds the fees received ──────────────────

    function invariant_CashbackCreditedNeverExceedsFeesReceived_USDT() public view {
        assertLe(handler.ghost_sumCashbackCredited(address(usdt)), handler.ghost_sumFeesRecorded(address(usdt)));
    }

    function invariant_CashbackCreditedNeverExceedsFeesReceived_WBTC() public view {
        assertLe(handler.ghost_sumCashbackCredited(address(wbtc)), handler.ghost_sumFeesRecorded(address(wbtc)));
    }

    // ── Invariant: NiaraSettlement never holds the parties' balances ──────────────────

    function invariant_SettlementNeverRetainsFunds() public view {
        assertEq(assetEquity.balanceOf(address(settlement)), 0);
        assertEq(assetCommodity.balanceOf(address(settlement)), 0);
        assertEq(nativeEquity.balanceOf(address(settlement)), 0);
        assertEq(nativeBond.balanceOf(address(settlement)), 0);
        assertEq(usdt.balanceOf(address(settlement)), 0);
        assertEq(wbtc.balanceOf(address(settlement)), 0);
        assertEq(unlistedPayment.balanceOf(address(settlement)), 0);
    }

    // ── Listing invariants (EXCHANGE-MULTICHAIN-DESIGN.md, 3.9: #3, #8, #9, #10) ──────

    /// @notice No settlement ever succeeds unless the asset is an Approved Equity listing and
    /// the payment token an Approved Currency listing (covers non-approved, non-Equity,
    /// backed/unlisted assets, and unlisted or non-Currency payment tokens).
    function invariant_NoSettlementOnNonApprovedOrNonEquityListing() public view {
        assertEq(handler.ghost_illegalSettlements(), 0);
    }

    /// @notice Assets that can never pass the gate have never accrued any cashback: the
    /// FixedIncome instrument (P2P class) and the backed tokens (not listable).
    function invariant_NonEquityAndUnlistedAssetsNeverAccrueCashback() public view {
        address[3] memory payments = [address(usdt), address(wbtc), address(unlistedPayment)];
        for (uint256 i = 0; i < payments.length; i++) {
            assertEq(distributor.cashbackBalance(address(nativeBond), payments[i]), 0);
            assertEq(distributor.cashbackBalance(address(assetEquity), payments[i]), 0);
            assertEq(distributor.cashbackBalance(address(assetCommodity), payments[i]), 0);
        }
    }

    /// @notice A Currency listing never accrues cashback, and is never cashback-eligible,
    /// even after suspend / re-approve cycles.
    function invariant_CurrencyNeverAccruesCashback() public view {
        address[2] memory currencies = [address(usdt), address(wbtc)];
        address[3] memory payments = [address(usdt), address(wbtc), address(unlistedPayment)];
        for (uint256 c = 0; c < currencies.length; c++) {
            assertFalse(registry.getListing(currencies[c]).cashbackEligible);
            assertEq(uint8(registry.getListing(currencies[c]).assetClass), uint8(IListingRegistry.AssetClass.Currency));
            for (uint256 p = 0; p < payments.length; p++) {
                assertEq(distributor.cashbackBalance(currencies[c], payments[p]), 0);
            }
        }
        assertEq(handler.ghost_cashbackCreditedToCurrency(), 0);
    }

    /// @notice Fees are only ever charged in the fee token (USDT): no settlement pays in
    /// anything else, no fee or cashback is ever recorded in another token, and the USDT
    /// receiver pays the fee while the other party receives its leg in full (spec
    /// invariant 12).
    function invariant_FeesOnlyInFeeToken() public view {
        assertEq(settlement.feeToken(), address(usdt));
        assertEq(handler.ghost_settlementsOutsideFeeToken(), 0);
        assertEq(handler.ghost_feeNotPaidByUsdtReceiver(), 0);
        // The fee is the ceiling of `paymentAmount * feeBps / 10_000` (spec section 3.4): it
        // is never truncated to zero while active, and the seller still gets something.
        assertEq(handler.ghost_feeNotCeiling(), 0, "fee is not the ceiling");
        assertEq(handler.ghost_feeFreeSettlements(), 0, "settled fee-free with an active fee");
        assertEq(handler.ghost_sellerGotNothing(), 0, "seller left with nothing");

        address[3] memory others = [address(wbtc), address(unlistedPayment), address(nativeEquity)];
        for (uint256 i = 0; i < others.length; i++) {
            assertEq(handler.ghost_sumFeesRecorded(others[i]), 0);
            assertEq(distributor.protocolBalance(others[i]), 0);
            assertEq(distributor.cashbackBalance(address(nativeEquity), others[i]), 0);
        }
        assertEq(wbtc.balanceOf(address(distributor)), 0);
        assertEq(unlistedPayment.balanceOf(address(distributor)), 0);
    }

    /// @notice Native supply only moves through approved issuance batches and holder burns:
    /// totalSupply == seeded + Σ executed batches − Σ burned. Neither the issuer nor the
    /// listing authority can mint outside a requested-and-approved batch.
    function invariant_NativeSupplyEqualsIssuedMinusBurned() public view {
        assertEq(
            nativeEquity.totalSupply(),
            seededNativeEquitySupply + handler.ghost_nativeIssued(address(nativeEquity))
                - handler.ghost_nativeBurned(address(nativeEquity))
        );
        assertEq(
            nativeBond.totalSupply(),
            seededNativeBondSupply + handler.ghost_nativeIssued(address(nativeBond))
                - handler.ghost_nativeBurned(address(nativeBond))
        );
        for (uint256 i = 0; i < feeListings.length; i++) {
            assertEq(
                NativeAssetToken(feeListings[i]).totalSupply(),
                handler.ghost_nativeIssued(feeListings[i]) - handler.ghost_nativeBurned(feeListings[i])
            );
        }
    }

    // ── Invariant 13: listing fee (EXCHANGE-MULTICHAIN-DESIGN.md §3.13) ────────────────

    /// @notice Every `quoteListing` / `payListingFee` outcome was the predicted one, and
    /// `approveListing` never approved an unpaid listing.
    function invariant_Inv13_ListingFeeOutcomesMatchThePrediction() public view {
        assertEq(handler.ghost_listingFeeMismatches(), 0, "listing-fee outcome != prediction");
        assertEq(handler.ghost_unpaidApprovals(), 0, "approveListing approved an unpaid listing");
    }

    /// @notice Every non-Currency listing that is Approved or Suspended paid exactly
    /// `ceil(valuation * listingFeeBps / 10_000)`, once, with `1 <= listingFeeBps <= 100`;
    /// an unpaid listing has paid nothing; Currency listings have no quote; and the
    /// distributor's `listingFeesCollected` is the sum of what was paid, every fee counted
    /// as protocol revenue (spec invariant 13).
    function invariant_Inv13_ListingFeePaidOnceAndExactly() public view {
        address[5] memory issuerListings =
            [address(nativeEquity), address(nativeBond), feeListings[0], feeListings[1], feeListings[2]];
        uint256 sum;
        for (uint256 i = 0; i < issuerListings.length; i++) {
            address token = issuerListings[i];
            IListingRegistry.ListingStatus status = registry.getListing(token).status;
            ListingRegistry.ListingFeeQuote memory quote = registry.getListingFeeQuote(token);
            bool approvedOnce =
                status == IListingRegistry.ListingStatus.Approved || status == IListingRegistry.ListingStatus.Suspended;
            if (approvedOnce) {
                assertGe(quote.listingFeeBps, 1);
                assertLe(quote.listingFeeBps, registry.MAX_LISTING_FEE_BPS());
                assertEq(quote.listingFee, (quote.valuation * quote.listingFeeBps + 9_999) / 10_000);
                assertEq(quote.listingFeePaid, quote.listingFee, "approved without paying the quoted fee");
            }
            if (status == IListingRegistry.ListingStatus.Pending || status == IListingRegistry.ListingStatus.Quoted) {
                assertEq(quote.listingFeePaid, 0, "a payment without approval");
            }
            assertLe(handler.ghost_listingFeePayments(token), 1, "paid twice");
            sum += quote.listingFeePaid;
        }
        assertEq(distributor.listingFeesCollected(address(usdt)), sum, "ledger != sum of payments");
        assertEq(sum, setupListingFees + handler.ghost_sumListingFeesPaid(), "payments != model");
        assertEq(distributor.listingFeesCollected(address(wbtc)), 0);
        address[2] memory currencies = [address(usdt), address(wbtc)];
        for (uint256 c = 0; c < currencies.length; c++) {
            assertEq(registry.getListingFeeQuote(currencies[c]).listingFee, 0, "a Currency listing was quoted");
        }
    }

    /// @dev Printed with `-vv`: how much of the listing-fee paths the last run exercised.
    function afterInvariant() public view {
        console2.log("listing-fee quotes  ", handler.ghost_quotes());
        console2.log("listing-fee payments", handler.ghost_payments());
    }

    /// @notice No batch executes unless the listing is Approved and the registry is not
    /// paused (spec invariant 11, second half).
    function invariant_NoIssuanceWhilePausedOrNotApproved() public view {
        assertEq(handler.ghost_illegalIssuances(), 0);
        assertEq(handler.ghost_illegalRequests(), 0, "a batch was requested on a non-Approved listing");
        assertEq(handler.ghost_issuanceRequestMismatches(), 0, "requestIssuance outcome != prediction");
    }

    /// @notice One shared pause: while the registry is paused, no settlement, cashback
    /// withdrawal or protocol-fee withdrawal ever succeeds (and no batch executes, see
    /// invariant_NoIssuanceWhilePausedOrNotApproved). Every contract reads the same flag.
    function invariant_NoPayoutWhilePaused() public view {
        assertEq(handler.ghost_payoutsWhilePaused(), 0);
        assertEq(settlement.paused(), registry.paused());
        assertEq(distributor.paused(), registry.paused());
    }

    /// @notice Per-listing cashback freeze (spec §9.5): no cashback withdrawal ever succeeds
    /// on a frozen listing, accrual is never affected by it, and Currency listings are never
    /// frozen (they cannot be).
    function invariant_NoCashbackWithdrawalWhileFrozen() public view {
        assertEq(handler.ghost_withdrawalsWhileFrozen(), 0);
        assertEq(handler.ghost_frozenAccrualMismatch(), 0);
        assertFalse(registry.getListing(address(usdt)).cashbackFrozen);
        assertFalse(registry.getListing(address(wbtc)).cashbackFrozen);
    }

    /// @notice Replay protection: a match id settles at most once, and every id that settled
    /// is marked in `settledMatches`.
    function invariant_MatchIdSettlesAtMostOnce() public view {
        assertEq(handler.ghost_replayedSettlements(), 0);
        uint256 count = handler.settledMatchCount();
        for (uint256 i = 0; i < count; i++) {
            assertTrue(settlement.settledMatches(handler.ghost_settledMatchIds(i)));
        }
    }

    /// @notice Delisted is final: once delisted, a token never leaves that status.
    function invariant_DelistedIsFinal() public view {
        address[4] memory tokens = [address(nativeEquity), address(nativeBond), address(usdt), address(wbtc)];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (handler.ghost_everDelisted(tokens[i])) {
                assertEq(uint8(registry.getListing(tokens[i]).status), uint8(IListingRegistry.ListingStatus.Delisted));
            }
        }
    }

    /// @notice Listing class is fixed for life: status changes never alter the class.
    function invariant_ListingClassNeverChanges() public view {
        assertEq(uint8(registry.getListing(address(nativeEquity)).assetClass), uint8(IListingRegistry.AssetClass.Equity));
        assertEq(
            uint8(registry.getListing(address(nativeBond)).assetClass), uint8(IListingRegistry.AssetClass.FixedIncome)
        );
    }
}

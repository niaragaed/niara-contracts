// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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
/// redeem, listing status changes and native issuance/burns, triggered by different actors
/// (operator, custodian, settlementOperator, listing authority, native issuer and three
/// traders), and the functions below check that the protocol's core invariants hold
/// after EVERY call in the sequence, not only in hand-written scenarios.
contract InvariantTest is Test {
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

    function setUp() public {
        _deployContracts();
        _wireRoles();
        _deployHandlerAndTargets();
    }

    function _deployContracts() internal {
        distributor = new CashbackDistributor(admin, TIMELOCK_DELAY);
        registry = new ListingRegistry(admin, listingAuthority, TIMELOCK_DELAY);
        settlement = new NiaraSettlement(admin, address(distributor), address(registry), TIMELOCK_DELAY);
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
        usdt = new MockUSDT();
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

    function _submitAndApprove(NativeAssetToken token) internal {
        vm.prank(nativeIssuer);
        registry.submitListing(address(token));
        vm.prank(listingAuthority);
        registry.approveListing(address(token));
    }

    function _seedBatch(NativeAssetToken token, address to, uint256 amount) internal {
        vm.prank(nativeIssuer);
        uint256 batchNo = registry.requestIssuance(address(token), amount, to, keccak256("seed"));
        vm.prank(listingAuthority);
        registry.approveIssuance(address(token), batchNo);
    }

    function _wireRoles() internal {
        // Role wiring: every grant goes through the timelock, as in production.
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

        // Restricts the invariant fuzzer to the Handler, and within it only to protocol
        // actions, never to helpers inherited from Test (e.g. IS_TEST).
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](19);
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
        selectors[11] = Handler.toggleSettlementPause.selector;
        selectors[12] = Handler.toggleAssetPause.selector;
        selectors[13] = Handler.setListingStatus.selector;
        selectors[14] = Handler.requestIssuance.selector;
        selectors[15] = Handler.approveIssuance.selector;
        selectors[16] = Handler.burnNative.selector;
        selectors[17] = Handler.rejectIssuance.selector;
        selectors[18] = Handler.toggleRegistryPause.selector;
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
    }

    /// @notice No batch executes unless the listing is Approved and the registry is not
    /// paused (spec invariant 11, second half).
    function invariant_NoIssuanceWhilePausedOrNotApproved() public view {
        assertEq(handler.ghost_illegalIssuances(), 0);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockWBTC} from "./mocks/MockWBTC.sol";
import {Handler} from "./invariant/Handler.sol";

/// @notice Testes de invariante com fuzzing stateful (Foundry `invariant_*`): o `Handler`
/// executa sequências aleatórias de request/attest/mint/burn(via redemptionAttest)/settle/
/// redeem, disparadas por atores diferentes (operator, custodian, settlementOperator, e três
/// traders), e as funções abaixo verificam que os invariantes centrais do protocolo se
/// mantêm após CADA chamada da sequência, não apenas em cenários manualmente escritos.
contract InvariantTest is Test {
    AssetToken public assetEquity;
    AssetToken public assetCommodity;
    BackingGateway public gateway;
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    MockUSDT public usdt;
    MockWBTC public wbtc;
    Handler public handler;

    address public admin = makeAddr("admin");
    address public issuerEquity = makeAddr("issuerEquity");
    address public issuerCommodity = makeAddr("issuerCommodity");
    address public operator = makeAddr("operator");
    address public custodian = makeAddr("custodian");
    address public settlementOperator = makeAddr("settlementOperator");

    uint256 public constant TIMELOCK_DELAY = 2 days;

    function setUp() public {
        _deployContracts();
        _wireRoles();
        _deployHandlerAndTargets();
    }

    function _deployContracts() internal {
        distributor = new CashbackDistributor(admin, TIMELOCK_DELAY);
        settlement = new NiaraSettlement(admin, address(distributor), TIMELOCK_DELAY);
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
    }

    function _wireRoles() internal {
        // Fiação de papéis — cada concessão passa pelo timelock, como em produção.
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
            })
        );

        // Restringe o fuzzer de invariantes ao Handler, e dentro dele apenas às ações de
        // protocolo — nunca aos helpers herdados de Test (ex.: IS_TEST).
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
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

    // ── Invariante: cashback creditado nunca excede as taxas recebidas ────────────────

    function invariant_CashbackCreditedNeverExceedsFeesReceived_USDT() public view {
        assertLe(handler.ghost_sumCashbackCredited(address(usdt)), handler.ghost_sumFeesRecorded(address(usdt)));
    }

    function invariant_CashbackCreditedNeverExceedsFeesReceived_WBTC() public view {
        assertLe(handler.ghost_sumCashbackCredited(address(wbtc)), handler.ghost_sumFeesRecorded(address(wbtc)));
    }

    // ── Invariante: NiaraSettlement nunca retém saldo das partes ──────────────────────

    function invariant_SettlementNeverRetainsFunds() public view {
        assertEq(assetEquity.balanceOf(address(settlement)), 0);
        assertEq(assetCommodity.balanceOf(address(settlement)), 0);
        assertEq(usdt.balanceOf(address(settlement)), 0);
        assertEq(wbtc.balanceOf(address(settlement)), 0);
    }
}

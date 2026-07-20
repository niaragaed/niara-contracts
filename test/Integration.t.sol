// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// @notice Exercita o fluxo completo de ponta a ponta com os quatro contratos reais
/// interligados: lastro atestado → mint → liquidação atômica com cobrança de taxa →
/// cashback creditado ao emissor → saque do cashback → resgate do ativo pelo detentor.
contract IntegrationTest is Test {
    AssetToken public assetToken;
    BackingGateway public gateway;
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    MockUSDT public usdt;

    address public admin = makeAddr("admin");
    address public issuer = makeAddr("issuer");
    address public operator = makeAddr("operator");
    address public custodian = makeAddr("custodian");
    address public settlementOperator = makeAddr("settlementOperator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");

    uint256 public constant TIMELOCK_DELAY = 2 days;

    function setUp() public {
        distributor = new CashbackDistributor(admin, TIMELOCK_DELAY);
        settlement = new NiaraSettlement(admin, address(distributor), TIMELOCK_DELAY);
        gateway = new BackingGateway(admin, TIMELOCK_DELAY);
        assetToken = new AssetToken(
            "Apple Inc. - Niara Tokenized Equity",
            "nAAPL",
            "AAPL",
            AssetToken.AssetClass.EQUITY,
            "US",
            issuer,
            admin,
            TIMELOCK_DELAY
        );
        usdt = new MockUSDT();

        // Fiação de papéis — cada concessão passa pelo timelock, como em produção.
        _grantRoleOn(address(distributor), distributor.SETTLEMENT_ROLE(), address(settlement));
        _grantRoleOn(address(settlement), settlement.SETTLEMENT_OPERATOR_ROLE(), settlementOperator);
        _grantRoleOn(address(gateway), gateway.OPERATOR_ROLE(), operator);
        _grantRoleOn(address(gateway), gateway.CUSTODIAN_ROLE(), custodian);
        _grantRoleOn(address(assetToken), assetToken.MINTER_ROLE(), address(gateway));
        _grantRoleOn(address(assetToken), assetToken.BURNER_ROLE(), address(gateway));

        vm.prank(admin);
        assetToken.proposeSetBackingGateway(address(gateway));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        assetToken.executeSetBackingGateway(address(gateway));

        usdt.mint(buyer, 1_000_000e6);
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

    function test_FullLifecycle_BackingToSettlementToCashbackToRedemption() public {
        // 1. Lastro: pedido → atestação → mint para o vendedor.
        vm.prank(operator);
        uint256 requestId = gateway.requestBacking(address(assetToken), 1_000 ether);

        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof-custody-1"), 1_000 ether);

        vm.prank(operator);
        gateway.mintAttested(requestId, seller);

        assertEq(assetToken.balanceOf(seller), 1_000 ether);
        assertEq(assetToken.totalSupply(), 1_000 ether);

        // 2. Liquidação atômica: vendedor entrega 100 nAAPL, comprador paga 10.000 USDT.
        vm.prank(seller);
        assetToken.approve(address(settlement), 100 ether);
        vm.prank(buyer);
        usdt.approve(address(settlement), 10_000e6);

        vm.prank(settlementOperator);
        uint256 feeCharged = settlement.settle(address(assetToken), address(usdt), buyer, seller, 100 ether, 10_000e6);

        uint256 expectedFee = (10_000e6 * settlement.feeBps()) / 10_000;
        assertEq(feeCharged, expectedFee);
        assertEq(assetToken.balanceOf(buyer), 100 ether);
        assertEq(assetToken.balanceOf(seller), 900 ether);
        assertEq(usdt.balanceOf(seller), 10_000e6 - expectedFee);
        assertEq(usdt.balanceOf(address(distributor)), expectedFee);

        // 3. Cashback: emissor saca a parcela creditada.
        uint256 expectedCashback = (expectedFee * distributor.cashbackBps()) / 10_000;
        assertEq(distributor.cashbackBalance(address(assetToken), address(usdt)), expectedCashback);

        vm.prank(issuer);
        distributor.withdraw(address(assetToken), address(usdt));
        assertEq(usdt.balanceOf(issuer), expectedCashback);

        // 4. Resgate: comprador devolve parte dos tokens pelo ativo real.
        vm.prank(buyer);
        assetToken.approve(address(gateway), 40 ether);
        vm.prank(buyer);
        uint256 redemptionId = gateway.redemptionRequest(address(assetToken), 40 ether);

        uint256 attestedBefore = gateway.totalAttested(address(assetToken));

        vm.prank(custodian);
        gateway.redemptionAttest(redemptionId, keccak256("proof-release-1"));

        assertEq(assetToken.balanceOf(buyer), 60 ether);
        assertEq(gateway.totalAttested(address(assetToken)), attestedBefore - 40 ether);
        assertEq(assetToken.totalSupply(), 1_000 ether - 40 ether);

        // Invariante final: em todo momento, totalSupply <= totalAttested.
        assertLe(assetToken.totalSupply(), gateway.totalAttested(address(assetToken)));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {MockBackingGateway} from "./mocks/MockBackingGateway.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockWBTC} from "./mocks/MockWBTC.sol";
import {MaliciousReentrantToken} from "./mocks/MaliciousReentrantToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract NiaraSettlementTest is Test {
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    AssetToken public assetToken;
    MockBackingGateway public gateway;
    MockUSDT public usdt;
    MockWBTC public wbtc;

    address public admin = makeAddr("admin");
    address public issuer = makeAddr("issuer");
    address public operator = makeAddr("operator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");

    uint256 public constant TIMELOCK_DELAY = 2 days;

    bytes32 public settlementOperatorRole;
    bytes32 public pauserRole;
    bytes32 public settlementRoleOnDistributor;

    function setUp() public {
        distributor = new CashbackDistributor(admin, TIMELOCK_DELAY);
        settlement = new NiaraSettlement(admin, address(distributor), TIMELOCK_DELAY);

        settlementOperatorRole = settlement.SETTLEMENT_OPERATOR_ROLE();
        pauserRole = settlement.PAUSER_ROLE();
        settlementRoleOnDistributor = distributor.SETTLEMENT_ROLE();

        _distributorGrantRole(settlementRoleOnDistributor, address(settlement));
        _settlementGrantRole(settlementOperatorRole, operator);

        gateway = new MockBackingGateway();
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
        bytes32 assetMinterRole = assetToken.MINTER_ROLE();
        _assetTokenGrantRole(assetMinterRole, admin);
        _assetTokenSetBackingGateway(address(gateway));
        gateway.setTotalAttested(address(assetToken), 1_000_000 ether);

        vm.prank(admin);
        assetToken.mint(seller, 1_000 ether);

        usdt = new MockUSDT();
        wbtc = new MockWBTC();
        usdt.mint(buyer, 1_000_000e6);
        wbtc.mint(buyer, 1_000e8);

        vm.prank(seller);
        assetToken.approve(address(settlement), type(uint256).max);
        vm.prank(buyer);
        usdt.approve(address(settlement), type(uint256).max);
        vm.prank(buyer);
        wbtc.approve(address(settlement), type(uint256).max);
    }

    // ── Helpers de governança com timelock ────────────────────────────────────────────

    function _settlementGrantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        settlement.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeGrantRole(role, account);
    }

    function _distributorGrantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        distributor.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        distributor.executeGrantRole(role, account);
    }

    function _assetTokenGrantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        assetToken.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        assetToken.executeGrantRole(role, account);
    }

    function _assetTokenSetBackingGateway(address newGateway) internal {
        vm.prank(admin);
        assetToken.proposeSetBackingGateway(newGateway);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        assetToken.executeSetBackingGateway(newGateway);
    }

    // ── Liquidação atômica ─────────────────────────────────────────────────────────────

    function test_Settle_OnlyOperator() public {
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, seller, settlementOperatorRole)
        );
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_TransfersAssetAndPayment_USDT() public {
        uint256 paymentAmount = 1_000e6; // 1000 USDT, 6 casas decimais
        uint256 expectedFee = (paymentAmount * settlement.feeBps()) / 10_000;

        vm.prank(operator);
        uint256 feeCharged = settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, paymentAmount);

        assertEq(feeCharged, expectedFee);
        assertEq(assetToken.balanceOf(buyer), 10 ether);
        assertEq(assetToken.balanceOf(seller), 990 ether);
        assertEq(usdt.balanceOf(seller), paymentAmount - expectedFee);
        assertEq(usdt.balanceOf(address(distributor)), expectedFee);
        assertEq(usdt.balanceOf(buyer), 1_000_000e6 - paymentAmount);
    }

    function test_Settle_TransfersAssetAndPayment_WBTC() public {
        uint256 paymentAmount = 1e8; // 1 WBTC, 8 casas decimais
        uint256 expectedFee = (paymentAmount * settlement.feeBps()) / 10_000;

        vm.prank(operator);
        uint256 feeCharged = settlement.settle(address(assetToken), address(wbtc), buyer, seller, 5 ether, paymentAmount);

        assertEq(feeCharged, expectedFee);
        assertEq(assetToken.balanceOf(buyer), 5 ether);
        assertEq(wbtc.balanceOf(seller), paymentAmount - expectedFee);
        assertEq(wbtc.balanceOf(address(distributor)), expectedFee);
        assertEq(wbtc.balanceOf(buyer), 1_000e8 - paymentAmount);
    }

    function test_Settle_FeeMathExact() public {
        // feeBps padrão = 50 (0,5%). 123_456_789 * 50 / 10000 = 617_283 (truncado).
        uint256 paymentAmount = 123_456_789;
        vm.prank(operator);
        uint256 feeCharged = settlement.settle(address(assetToken), address(usdt), buyer, seller, 1 ether, paymentAmount);
        assertEq(feeCharged, 617_283);
    }

    function test_Settle_RevertsWithoutSellerAllowance() public {
        vm.prank(seller);
        assetToken.approve(address(settlement), 0);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(settlement), 0, 10 ether)
        );
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsWithoutBuyerAllowance() public {
        vm.prank(buyer);
        usdt.approve(address(settlement), 0);

        vm.prank(operator);
        vm.expectRevert();
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsOnZeroAssetAmount() public {
        vm.prank(operator);
        vm.expectRevert(NiaraSettlement.ZeroAmount.selector);
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 0, 1_000e6);
    }

    function test_Settle_RevertsOnZeroPaymentAmount() public {
        vm.prank(operator);
        vm.expectRevert(NiaraSettlement.ZeroAmount.selector);
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 0);
    }

    function test_Settle_RevertsIfBuyerEqualsSeller() public {
        vm.prank(operator);
        vm.expectRevert(NiaraSettlement.BuyerEqualsSeller.selector);
        settlement.settle(address(assetToken), address(usdt), seller, seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsOnZeroTokenAddress() public {
        vm.prank(operator);
        vm.expectRevert(NiaraSettlement.ZeroAddress.selector);
        settlement.settle(address(0), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    /// @notice Arredondamento: quantias mínimas não podem truncar a taxa a zero enquanto
    /// feeBps > 0 — isso permitiria negociar sem pagar taxa via micro-transações.
    function test_Settle_RevertsWhenPaymentAmountTooSmallForFeePrecision() public {
        // feeBps = 50 → paymentAmount=1 gera fee = 0 por truncamento (1*50/10000 = 0).
        vm.prank(operator);
        vm.expectRevert(NiaraSettlement.PaymentAmountTooSmallForFeePrecision.selector);
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 1, 1);
    }

    function test_Settle_AllowsZeroFeeWhenFeeBpsIsZero() public {
        _setFeeBps(0);

        vm.prank(operator);
        uint256 feeCharged = settlement.settle(address(assetToken), address(usdt), buyer, seller, 1, 1);

        assertEq(feeCharged, 0);
        assertEq(usdt.balanceOf(address(distributor)), 0);
    }

    function test_Settle_RevertsWhenPaused() public {
        vm.prank(admin);
        settlement.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    // ── Taxa: teto rígido e timelock ───────────────────────────────────────────────────

    function _setFeeBps(uint16 newFeeBps) internal {
        vm.prank(admin);
        settlement.proposeSetFeeBps(newFeeBps);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeSetFeeBps(newFeeBps);
    }

    function test_FeeBps_CannotExceedCap() public {
        uint16 tooHigh = settlement.MAX_FEE_BPS() + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.FeeExceedsCap.selector, tooHigh));
        settlement.proposeSetFeeBps(tooHigh);
    }

    function test_FeeBps_ChangeRequiresTimelock() public {
        vm.prank(admin);
        settlement.proposeSetFeeBps(80);

        vm.prank(admin);
        vm.expectRevert();
        settlement.executeSetFeeBps(80);
    }

    function test_FeeBps_ChangeSucceedsAfterDelay() public {
        _setFeeBps(80);
        assertEq(settlement.feeBps(), 80);
    }

    function test_CashbackDistributor_ChangeRequiresTimelock() public {
        CashbackDistributor newDistributor = new CashbackDistributor(admin, TIMELOCK_DELAY);

        vm.prank(admin);
        settlement.proposeSetCashbackDistributor(address(newDistributor));

        vm.prank(admin);
        vm.expectRevert();
        settlement.executeSetCashbackDistributor(address(newDistributor));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeSetCashbackDistributor(address(newDistributor));

        assertEq(address(settlement.cashbackDistributor()), address(newDistributor));
    }

    // ── Reentrância ────────────────────────────────────────────────────────────────────

    function test_Settle_ReentrancyViaMaliciousAssetToken_Reverts() public {
        MaliciousReentrantToken evilAsset = new MaliciousReentrantToken();
        evilAsset.mint(seller, 1_000 ether);

        // Concede o papel de operador ao próprio contrato malicioso, isolando a garantia
        // sob teste (nonReentrant) da checagem de controle de acesso.
        _settlementGrantRole(settlementOperatorRole, address(evilAsset));

        vm.prank(seller);
        evilAsset.approve(address(settlement), type(uint256).max);

        bytes memory reentrantCall = abi.encodeWithSelector(
            settlement.settle.selector, address(evilAsset), address(usdt), buyer, seller, 10 ether, 1_000e6
        );
        evilAsset.arm(address(settlement), reentrantCall);

        uint256 sellerBalanceBefore = usdt.balanceOf(seller);

        vm.prank(operator);
        vm.expectRevert();
        settlement.settle(address(evilAsset), address(usdt), buyer, seller, 10 ether, 1_000e6);

        // Nada deve ter se movido: a transação inteira reverteu.
        assertEq(usdt.balanceOf(seller), sellerBalanceBefore);
        assertEq(evilAsset.balanceOf(buyer), 0);
    }

    function test_Settle_ReentrancyViaMaliciousPaymentToken_Reverts() public {
        MaliciousReentrantToken evilPayment = new MaliciousReentrantToken();
        evilPayment.mint(buyer, 1_000_000e6);

        _settlementGrantRole(settlementOperatorRole, address(evilPayment));

        vm.prank(buyer);
        evilPayment.approve(address(settlement), type(uint256).max);

        bytes memory reentrantCall = abi.encodeWithSelector(
            settlement.settle.selector, address(assetToken), address(evilPayment), buyer, seller, 10 ether, 1_000e6
        );
        evilPayment.arm(address(settlement), reentrantCall);

        uint256 sellerAssetBalanceBefore = assetToken.balanceOf(seller);

        vm.prank(operator);
        vm.expectRevert();
        settlement.settle(address(assetToken), address(evilPayment), buyer, seller, 10 ether, 1_000e6);

        assertEq(assetToken.balanceOf(seller), sellerAssetBalanceBefore);
    }

    // ── Pausable: controle de acesso ───────────────────────────────────────────────────

    function test_Pause_OnlyPauserRole() public {
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, seller, pauserRole)
        );
        settlement.pause();
    }
}

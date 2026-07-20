// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MaliciousReentrantToken} from "./mocks/MaliciousReentrantToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract CashbackDistributorTest is Test {
    CashbackDistributor public distributor;
    AssetToken public equityToken;
    AssetToken public currencyToken;
    MockUSDT public usdt;

    address public admin = makeAddr("admin");
    address public issuer = makeAddr("issuer");
    address public settlementCaller = makeAddr("settlementCaller");
    address public alice = makeAddr("alice");
    address public treasuryTarget = makeAddr("treasuryTarget");

    uint256 public constant TIMELOCK_DELAY = 2 days;

    bytes32 public settlementRole;
    bytes32 public treasuryRole;

    function setUp() public {
        distributor = new CashbackDistributor(admin, TIMELOCK_DELAY);
        settlementRole = distributor.SETTLEMENT_ROLE();
        treasuryRole = distributor.TREASURY_ROLE();

        _grantRole(settlementRole, settlementCaller);

        equityToken = new AssetToken(
            "Niara Tokenized Equity", "nEQ", "EQ1", AssetToken.AssetClass.EQUITY, "US", issuer, admin, TIMELOCK_DELAY
        );
        currencyToken = new AssetToken(
            "Niara Tokenized EUR", "nEUR", "EUR", AssetToken.AssetClass.CURRENCY, "EU", issuer, admin, TIMELOCK_DELAY
        );

        usdt = new MockUSDT();
    }

    function _grantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        distributor.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        distributor.executeGrantRole(role, account);
    }

    /// @dev Simula o NiaraSettlement: transfere a taxa para o distributor e então registra.
    function _recordFee(AssetToken asset, uint256 feeAmount) internal {
        usdt.mint(address(distributor), feeAmount);
        vm.prank(settlementCaller);
        distributor.recordFee(address(asset), address(usdt), feeAmount);
    }

    // ── recordFee ──────────────────────────────────────────────────────────────────────

    function test_RecordFee_OnlySettlementRole() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, settlementRole)
        );
        distributor.recordFee(address(equityToken), address(usdt), 100e6);
    }

    function test_RecordFee_RevertsForZeroFee() public {
        vm.prank(settlementCaller);
        vm.expectRevert(CashbackDistributor.ZeroFeeAmount.selector);
        distributor.recordFee(address(equityToken), address(usdt), 0);
    }

    function test_RecordFee_CreditsIssuerWhenEligible() public {
        uint256 feeAmount = 1_000e6;
        uint256 expectedCashback = (feeAmount * distributor.cashbackBps()) / 10_000;

        _recordFee(equityToken, feeAmount);

        assertEq(distributor.cashbackBalance(address(equityToken), address(usdt)), expectedCashback);
        assertEq(distributor.protocolBalance(address(usdt)), feeAmount - expectedCashback);
    }

    function test_RecordFee_DoesNotCreditWhenNotEligible() public {
        uint256 feeAmount = 1_000e6;

        _recordFee(currencyToken, feeAmount);

        assertEq(distributor.cashbackBalance(address(currencyToken), address(usdt)), 0);
        assertEq(distributor.protocolBalance(address(usdt)), feeAmount);
    }

    // ── withdraw (emissor) ─────────────────────────────────────────────────────────────

    function test_Withdraw_OnlyIssuerWallet() public {
        _recordFee(equityToken, 1_000e6);

        vm.prank(alice);
        vm.expectRevert(CashbackDistributor.NotIssuerWallet.selector);
        distributor.withdraw(address(equityToken), address(usdt));
    }

    function test_Withdraw_TransfersFullBalanceAndZeroesIt() public {
        uint256 feeAmount = 1_000e6;
        uint256 expectedCashback = (feeAmount * distributor.cashbackBps()) / 10_000;
        _recordFee(equityToken, feeAmount);

        vm.prank(issuer);
        distributor.withdraw(address(equityToken), address(usdt));

        assertEq(usdt.balanceOf(issuer), expectedCashback);
        assertEq(distributor.cashbackBalance(address(equityToken), address(usdt)), 0);
    }

    function test_Withdraw_RevertsWhenNothingToWithdraw() public {
        vm.prank(issuer);
        vm.expectRevert(CashbackDistributor.NothingToWithdraw.selector);
        distributor.withdraw(address(equityToken), address(usdt));
    }

    function test_Withdraw_NewIssuerWalletCanClaimAfterRotation() public {
        _recordFee(equityToken, 1_000e6);

        address newIssuer = makeAddr("newIssuer");
        vm.prank(admin);
        equityToken.proposeSetIssuerWallet(newIssuer);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        equityToken.executeSetIssuerWallet(newIssuer);

        vm.prank(issuer);
        vm.expectRevert(CashbackDistributor.NotIssuerWallet.selector);
        distributor.withdraw(address(equityToken), address(usdt));

        vm.prank(newIssuer);
        distributor.withdraw(address(equityToken), address(usdt));
        assertGt(usdt.balanceOf(newIssuer), 0);
    }

    function test_Withdraw_ReentrancyViaMaliciousPaymentToken_Reverts() public {
        MaliciousReentrantToken evilPayment = new MaliciousReentrantToken();
        evilPayment.mint(address(distributor), 1_000e6);

        vm.prank(settlementCaller);
        distributor.recordFee(address(equityToken), address(evilPayment), 1_000e6);

        bytes memory reentrantCall =
            abi.encodeWithSelector(distributor.withdraw.selector, address(equityToken), address(evilPayment));
        evilPayment.arm(address(distributor), reentrantCall);

        vm.prank(issuer);
        vm.expectRevert();
        distributor.withdraw(address(equityToken), address(evilPayment));
    }

    // ── withdrawProtocolFees (tesouraria) ──────────────────────────────────────────────

    function test_WithdrawProtocolFees_OnlyTreasuryRole() public {
        _recordFee(currencyToken, 1_000e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, treasuryRole)
        );
        distributor.withdrawProtocolFees(address(usdt), treasuryTarget, 1_000e6);
    }

    function test_WithdrawProtocolFees_RevertsIfExceedsBalance() public {
        _recordFee(currencyToken, 1_000e6);

        vm.prank(admin);
        vm.expectRevert(CashbackDistributor.InvalidWithdrawAmount.selector);
        distributor.withdrawProtocolFees(address(usdt), treasuryTarget, 1_000e6 + 1);
    }

    function test_WithdrawProtocolFees_Succeeds() public {
        _recordFee(currencyToken, 1_000e6);

        vm.prank(admin);
        distributor.withdrawProtocolFees(address(usdt), treasuryTarget, 1_000e6);

        assertEq(usdt.balanceOf(treasuryTarget), 1_000e6);
        assertEq(distributor.protocolBalance(address(usdt)), 0);
    }

    // ── cashbackBps: teto rígido e timelock ────────────────────────────────────────────

    function test_CashbackBps_CannotExceedCap() public {
        uint16 tooHigh = distributor.MAX_CASHBACK_BPS() + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.CashbackBpsExceedsCap.selector, tooHigh));
        distributor.proposeSetCashbackBps(tooHigh);
    }

    function test_CashbackBps_ChangeRequiresTimelock() public {
        vm.prank(admin);
        distributor.proposeSetCashbackBps(2_000);

        vm.prank(admin);
        vm.expectRevert();
        distributor.executeSetCashbackBps(2_000);
    }

    function test_CashbackBps_ChangeSucceedsAfterDelay() public {
        vm.prank(admin);
        distributor.proposeSetCashbackBps(2_000);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        distributor.executeSetCashbackBps(2_000);

        assertEq(distributor.cashbackBps(), 2_000);
    }
}

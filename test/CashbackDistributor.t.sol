// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MaliciousReentrantToken} from "./mocks/MaliciousReentrantToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract CashbackDistributorTest is Test {
    CashbackDistributor public distributor;
    ListingRegistry public registry;
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
        registry = new ListingRegistry(admin, admin, TIMELOCK_DELAY);
        distributor = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY);
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

    /// @dev Simulates NiaraSettlement: transfers the fee to the distributor and then records it.
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

    // ── withdraw (issuer) ──────────────────────────────────────────────────────────────

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

    // ── cashbackBps: hard cap and timelock ─────────────────────────────────────────────

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

    /// @notice `executeSetCashbackBps` validates the cap BEFORE consuming the pending
    /// proposal; this guard fires even without any `proposeSetCashbackBps` having been
    /// made (which would already block scheduling a value above the cap). Called
    /// directly to cover this defensive check, currently unreachable through the
    /// normal propose→execute flow.
    function test_ExecuteCashbackBps_DefensiveCapCheck_RevertsWithoutNeedingProposal() public {
        uint16 tooHigh = distributor.MAX_CASHBACK_BPS() + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.CashbackBpsExceedsCap.selector, tooHigh));
        distributor.executeSetCashbackBps(tooHigh);
    }

    // ── Zero address guards ────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(CashbackDistributor.ZeroAddress.selector);
        new CashbackDistributor(address(0), address(registry), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroListingRegistry() public {
        vm.expectRevert(CashbackDistributor.ZeroAddress.selector);
        new CashbackDistributor(admin, address(0), TIMELOCK_DELAY);
    }

    function test_Constructor_SetsListingRegistry() public view {
        assertEq(address(distributor.listingRegistry()), address(registry));
    }

    // ── Shared protocol pause (held by the ListingRegistry) ───────────────────────────

    function _pauseProtocol() internal {
        vm.prank(admin);
        registry.pause();
    }

    function test_Paused_MirrorsRegistryPause() public {
        assertFalse(distributor.paused());
        _pauseProtocol();
        assertTrue(distributor.paused());
        vm.prank(admin);
        registry.unpause();
        assertFalse(distributor.paused());
    }

    /// @notice The distributor has no pause of its own: only the registry can pause it.
    function test_Pause_NoLocalPauseFunctions() public {
        vm.prank(admin);
        (bool pauseOk,) = address(distributor).call(abi.encodeWithSignature("pause()"));
        assertFalse(pauseOk);
        vm.prank(admin);
        (bool unpauseOk,) = address(distributor).call(abi.encodeWithSignature("unpause()"));
        assertFalse(unpauseOk);
    }

    /// @notice Cashback is a payout based on protocol accounting: blocked while paused.
    function test_Withdraw_RevertsWhileProtocolPaused() public {
        _recordFee(equityToken, 1_000e6);
        uint256 balance = distributor.cashbackBalance(address(equityToken), address(usdt));
        _pauseProtocol();

        vm.prank(issuer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        distributor.withdraw(address(equityToken), address(usdt));

        assertEq(distributor.cashbackBalance(address(equityToken), address(usdt)), balance);
        assertEq(usdt.balanceOf(issuer), 0);
    }

    /// @notice Protocol fees are a payout based on protocol accounting: blocked while paused.
    function test_WithdrawProtocolFees_RevertsWhileProtocolPaused() public {
        _recordFee(equityToken, 1_000e6);
        uint256 available = distributor.protocolBalance(address(usdt));
        _pauseProtocol();

        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        distributor.withdrawProtocolFees(address(usdt), treasuryTarget, available);

        assertEq(distributor.protocolBalance(address(usdt)), available);
    }

    /// @notice Modifier order: `nonReentrant`, then the role, then the pause.
    function test_WithdrawProtocolFees_RoleCheckedBeforePause() public {
        _pauseProtocol();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, treasuryRole)
        );
        distributor.withdrawProtocolFees(address(usdt), treasuryTarget, 1);
    }

    /// @notice `recordFee` is not paused (it only runs inside `settle`, which is), and nothing
    /// accrued is lost: after unpausing both withdrawals pay the full balances.
    function test_Pause_RecordFeeStillAccruesAndWithdrawalsResumeAfterUnpause() public {
        _pauseProtocol();
        _recordFee(equityToken, 1_000e6);
        uint256 cashback = distributor.cashbackBalance(address(equityToken), address(usdt));
        uint256 protocolShare = distributor.protocolBalance(address(usdt));
        assertGt(cashback, 0);

        vm.prank(admin);
        registry.unpause();

        vm.prank(issuer);
        distributor.withdraw(address(equityToken), address(usdt));
        assertEq(usdt.balanceOf(issuer), cashback);

        vm.prank(admin);
        distributor.withdrawProtocolFees(address(usdt), treasuryTarget, protocolShare);
        assertEq(usdt.balanceOf(treasuryTarget), protocolShare);
    }

    function test_WithdrawProtocolFees_RevertsForZeroRecipient() public {
        _recordFee(currencyToken, 1_000e6);

        vm.prank(admin);
        vm.expectRevert(CashbackDistributor.ZeroAddress.selector);
        distributor.withdrawProtocolFees(address(usdt), address(0), 1_000e6);
    }

    // ── Per-listing cashback freeze (spec §9.5) ────────────────────────────────────────

    /// @dev A listed native Equity whose issuer is `issuer`. The registry's listing authority
    /// is `admin` in this suite.
    function _listedNative() internal returns (NativeAssetToken token) {
        AssetTokenFactory factory = registry.factory();
        vm.prank(issuer);
        token = NativeAssetToken(
            factory.createAssetToken("Acme", "ACME", IListingRegistry.AssetClass.Equity, keccak256("doc"))
        );
        vm.prank(issuer);
        registry.submitListing(address(token));
        vm.prank(admin);
        registry.approveListing(address(token));
    }

    function _recordNativeFee(NativeAssetToken asset, uint256 feeAmount) internal {
        usdt.mint(address(distributor), feeAmount);
        vm.prank(settlementCaller);
        distributor.recordFee(address(asset), address(usdt), feeAmount);
    }

    function test_Withdraw_RevertsWhileCashbackFrozen() public {
        NativeAssetToken acme = _listedNative();
        _recordNativeFee(acme, 1_000e6);
        uint256 balance = distributor.cashbackBalance(address(acme), address(usdt));
        vm.prank(admin);
        registry.freezeCashback(address(acme));

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.CashbackFrozen.selector, address(acme)));
        distributor.withdraw(address(acme), address(usdt));
        assertEq(distributor.cashbackBalance(address(acme), address(usdt)), balance);
        assertEq(usdt.balanceOf(issuer), 0);
    }

    /// @notice A non-issuer is told it is not the issuer, frozen or not.
    function test_Withdraw_IssuerCheckedBeforeFreeze() public {
        NativeAssetToken acme = _listedNative();
        _recordNativeFee(acme, 1_000e6);
        vm.prank(admin);
        registry.freezeCashback(address(acme));

        vm.prank(alice);
        vm.expectRevert(CashbackDistributor.NotIssuerWallet.selector);
        distributor.withdraw(address(acme), address(usdt));
    }

    /// @notice Accrual continues while frozen and nothing is lost: after unfreezing, the
    /// issuer withdraws everything credited before and during the freeze.
    function test_Freeze_AccrualContinuesAndUnfreezeReleasesEverything() public {
        NativeAssetToken acme = _listedNative();
        _recordNativeFee(acme, 1_000e6);
        uint256 before = distributor.cashbackBalance(address(acme), address(usdt));
        vm.prank(admin);
        registry.freezeCashback(address(acme));

        _recordNativeFee(acme, 2_000e6);
        uint256 total = distributor.cashbackBalance(address(acme), address(usdt));
        assertEq(total, before + (uint256(2_000e6) * distributor.cashbackBps()) / 10_000);

        vm.prank(admin);
        registry.unfreezeCashback(address(acme));
        vm.prank(issuer);
        distributor.withdraw(address(acme), address(usdt));
        assertEq(usdt.balanceOf(issuer), total);
        assertEq(distributor.cashbackBalance(address(acme), address(usdt)), 0);
    }

    /// @notice The freeze is per listing and only affects issuer cashback: another listing's
    /// issuer and the treasury's protocol fees are untouched.
    function test_Freeze_DoesNotAffectOtherListingsOrProtocolFees() public {
        NativeAssetToken frozenAsset = _listedNative();
        NativeAssetToken otherAsset = _listedNative();
        _recordNativeFee(frozenAsset, 1_000e6);
        _recordNativeFee(otherAsset, 1_000e6);
        vm.prank(admin);
        registry.freezeCashback(address(frozenAsset));

        uint256 otherCashback = distributor.cashbackBalance(address(otherAsset), address(usdt));
        vm.prank(issuer);
        distributor.withdraw(address(otherAsset), address(usdt));
        assertEq(usdt.balanceOf(issuer), otherCashback);

        uint256 protocolShare = distributor.protocolBalance(address(usdt));
        vm.prank(admin);
        distributor.withdrawProtocolFees(address(usdt), treasuryTarget, protocolShare);
        assertEq(usdt.balanceOf(treasuryTarget), protocolShare);
    }
}

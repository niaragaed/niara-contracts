// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {ListingFeeHelpers} from "./helpers/ListingFeeHelpers.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MaliciousReentrantToken} from "./mocks/MaliciousReentrantToken.sol";
import {MaliciousHookToken} from "./mocks/MaliciousHookToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract CashbackDistributorTest is ListingFeeHelpers {
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
    /// @dev Rate this suite's distributor is constructed with (the contract has no default).
    uint16 public constant INITIAL_CASHBACK_BPS = 1_000;

    bytes32 public settlementRole;
    bytes32 public treasuryRole;

    function setUp() public {
        registry = new ListingRegistry(admin, admin, TIMELOCK_DELAY);
        distributor = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, INITIAL_CASHBACK_BPS);
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
        new CashbackDistributor(address(0), address(registry), TIMELOCK_DELAY, INITIAL_CASHBACK_BPS);
    }

    function test_Constructor_RevertsForZeroListingRegistry() public {
        vm.expectRevert(CashbackDistributor.ZeroAddress.selector);
        new CashbackDistributor(admin, address(0), TIMELOCK_DELAY, INITIAL_CASHBACK_BPS);
    }

    function test_Constructor_SetsListingRegistry() public view {
        assertEq(address(distributor.listingRegistry()), address(registry));
    }

    // ── cashbackBps: constructor parameter ─────────────────────────────────────────────

    /// @notice There is no default: the rate is the one given at deployment.
    function test_Constructor_SetsCashbackBps() public {
        assertEq(distributor.cashbackBps(), INITIAL_CASHBACK_BPS);

        CashbackDistributor other = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, 2_000);
        assertEq(other.cashbackBps(), 2_000);
    }

    function test_Constructor_AcceptsZeroCashback() public {
        CashbackDistributor other = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, 0);
        assertEq(other.cashbackBps(), 0);
    }

    /// @notice The hard cap binds the constructor like every later change: 100% of the fee is
    /// the most that can be passed on.
    function test_Constructor_AcceptsCashbackAtTheCap() public {
        CashbackDistributor other = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, 10_000);
        assertEq(other.cashbackBps(), other.MAX_CASHBACK_BPS());
    }

    function test_Constructor_RevertsForCashbackAboveTheCap() public {
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.CashbackBpsExceedsCap.selector, uint16(10_001)));
        new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, 10_001);
    }

    function testFuzz_Constructor_CashbackBoundedByTheCap(uint16 cashbackBps_) public {
        if (cashbackBps_ > 10_000) {
            vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.CashbackBpsExceedsCap.selector, cashbackBps_));
            new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, cashbackBps_);
        } else {
            CashbackDistributor other =
                new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, cashbackBps_);
            assertEq(other.cashbackBps(), cashbackBps_);
        }
    }

    /// @notice A distributor constructed with a rate credits at that rate at once, with no
    /// proposal or wait.
    function test_Constructor_RateAppliesFromTheFirstFee() public {
        CashbackDistributor other = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, 2_000);
        vm.prank(admin);
        other.proposeGrantRole(settlementRole, settlementCaller);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        other.executeGrantRole(settlementRole, settlementCaller);

        usdt.mint(address(other), 1_000e6);
        vm.prank(settlementCaller);
        other.recordFee(address(equityToken), address(usdt), 1_000e6);

        assertEq(other.cashbackBalance(address(equityToken), address(usdt)), 200e6);
        assertEq(other.protocolBalance(address(usdt)), 800e6);
    }

    /// @notice The constructor sets the starting rate only: afterwards the timelock governs
    /// every change, and nothing takes effect before the delay.
    function test_CashbackBps_AfterConstructionOnlyTheTimelockChangesIt() public {
        vm.prank(admin);
        uint256 executeAfter = distributor.proposeSetCashbackBps(2_000);
        assertEq(executeAfter, block.timestamp + TIMELOCK_DELAY);
        assertEq(distributor.cashbackBps(), INITIAL_CASHBACK_BPS);

        vm.warp(executeAfter - 1);
        vm.prank(admin);
        vm.expectRevert();
        distributor.executeSetCashbackBps(2_000);
        assertEq(distributor.cashbackBps(), INITIAL_CASHBACK_BPS);

        vm.warp(executeAfter);
        vm.prank(admin);
        distributor.executeSetCashbackBps(2_000);
        assertEq(distributor.cashbackBps(), 2_000);
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
    /// is `admin` in this suite. The listing is approved by paying its listing fee (spec
    /// §3.13), which needs a NiaraSettlement linked to the registry; the treasury then
    /// withdraws that fee, so this suite's figures only count the fees it records itself.
    function _listedNative() internal returns (NativeAssetToken token) {
        if (address(registry.settlement()) == address(0)) {
            NiaraSettlement settlement =
                new NiaraSettlement(admin, address(distributor), address(registry), address(usdt), TIMELOCK_DELAY);
            _wireListingFee(registry, distributor, address(settlement), admin);
        }
        AssetTokenFactory factory = registry.factory();
        vm.prank(issuer);
        token = NativeAssetToken(
            factory.createAssetToken("Acme", "ACME", IListingRegistry.AssetClass.Equity, keccak256("doc"))
        );
        vm.prank(issuer);
        registry.submitListing(address(token));
        _approveByFeeAndWithdraw(registry, distributor, admin, admin, makeAddr("listingFeeSink"), address(token));
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

    // ── Checks-effects-interactions on both withdrawals ────────────────────────────────

    /// @dev Extracts the selector from raw return data (e.g. the error of a reverted call).
    function _selectorOf(bytes memory data) internal pure returns (bytes4 sel) {
        require(data.length >= 4, "return data has no selector");
        assembly {
            sel := mload(add(data, 32))
        }
    }

    /// @dev Index of the first log with `topic0`, or `type(uint256).max` if there is none.
    function _firstLogIndex(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic0) return i;
        }
        return type(uint256).max;
    }

    /// @dev Credits `feeAmount` of a hostile payment token against the eligible equity.
    function _recordFeeInHookToken(uint256 feeAmount) internal returns (MaliciousHookToken evilPayment) {
        evilPayment = new MaliciousHookToken();
        evilPayment.mint(address(distributor), feeAmount);
        vm.prank(settlementCaller);
        distributor.recordFee(address(equityToken), address(evilPayment), feeAmount);
    }

    /// @notice `CashbackWithdrawn` is emitted before the transfer, so an off-chain indexer
    /// never sees the `Transfer` before the withdrawal that caused it.
    function test_Withdraw_EmitsCashbackWithdrawnBeforeExternalTransfer() public {
        _recordFee(equityToken, 1_000e6);

        vm.recordLogs();
        vm.prank(issuer);
        distributor.withdraw(address(equityToken), address(usdt));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 eventIndex = _firstLogIndex(logs, keccak256("CashbackWithdrawn(address,address,address,uint256)"));
        uint256 transferIndex = _firstLogIndex(logs, keccak256("Transfer(address,address,uint256)"));

        assertTrue(eventIndex != type(uint256).max, "CashbackWithdrawn not emitted");
        assertTrue(transferIndex != type(uint256).max, "no Transfer emitted");
        assertLt(eventIndex, transferIndex);
        assertEq(eventIndex, 0);
    }

    /// @notice `ProtocolFeesWithdrawn` is emitted before the transfer.
    function test_WithdrawProtocolFees_EmitsProtocolFeesWithdrawnBeforeExternalTransfer() public {
        _recordFee(currencyToken, 1_000e6);

        vm.recordLogs();
        vm.prank(admin);
        distributor.withdrawProtocolFees(address(usdt), treasuryTarget, 400e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 eventIndex = _firstLogIndex(logs, keccak256("ProtocolFeesWithdrawn(address,address,uint256)"));
        uint256 transferIndex = _firstLogIndex(logs, keccak256("Transfer(address,address,uint256)"));

        assertTrue(eventIndex != type(uint256).max, "ProtocolFeesWithdrawn not emitted");
        assertTrue(transferIndex != type(uint256).max, "no Transfer emitted");
        assertLt(eventIndex, transferIndex);
        assertEq(eventIndex, 0);
    }

    /// @notice A hook that reads the cashback balance during the payout already sees zero.
    function test_Withdraw_BalanceZeroedBeforeExternalTransfer() public {
        MaliciousHookToken evilPayment = _recordFeeInHookToken(1_000e6);
        uint256 cashback = distributor.cashbackBalance(address(equityToken), address(evilPayment));
        assertGt(cashback, 0);

        evilPayment.armOnTransfer(
            address(distributor),
            abi.encodeWithSelector(distributor.cashbackBalance.selector, address(equityToken), address(evilPayment))
        );
        vm.prank(issuer);
        distributor.withdraw(address(equityToken), address(evilPayment));

        assertTrue(evilPayment.reentered());
        assertTrue(evilPayment.reentrantSucceeded());
        assertEq(abi.decode(evilPayment.reentrantReturnData(), (uint256)), 0);
        assertEq(evilPayment.balanceOf(issuer), cashback);
    }

    /// @notice A hook that reads the protocol balance during the payout already sees it
    /// decreased.
    function test_WithdrawProtocolFees_BalanceDecreasedBeforeExternalTransfer() public {
        MaliciousHookToken evilPayment = _recordFeeInHookToken(1_000e6);
        uint256 available = distributor.protocolBalance(address(evilPayment));

        evilPayment.armOnTransfer(
            address(distributor), abi.encodeWithSelector(distributor.protocolBalance.selector, address(evilPayment))
        );
        vm.prank(admin);
        distributor.withdrawProtocolFees(address(evilPayment), treasuryTarget, 100e6);

        assertTrue(evilPayment.reentered());
        assertTrue(evilPayment.reentrantSucceeded());
        assertEq(abi.decode(evilPayment.reentrantReturnData(), (uint256)), available - 100e6);
    }

    /// @notice Cross-function re-entry from the payout hook (withdraw -> withdrawProtocolFees)
    /// dies at the guard. The hostile token holds no TREASURY_ROLE, so the error would be the
    /// access-control one if `nonReentrant` were not the first modifier.
    function test_Withdraw_CrossFunctionReentrancy_RevertsViaGuard() public {
        MaliciousHookToken evilPayment = _recordFeeInHookToken(1_000e6);
        uint256 cashback = distributor.cashbackBalance(address(equityToken), address(evilPayment));
        uint256 protocolShare = distributor.protocolBalance(address(evilPayment));

        evilPayment.armOnTransfer(
            address(distributor),
            abi.encodeWithSelector(
                distributor.withdrawProtocolFees.selector, address(evilPayment), address(evilPayment), protocolShare
            )
        );
        vm.prank(issuer);
        distributor.withdraw(address(equityToken), address(evilPayment));

        assertTrue(evilPayment.reentered());
        assertFalse(evilPayment.reentrantSucceeded());
        assertEq(_selectorOf(evilPayment.reentrantReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(evilPayment.balanceOf(issuer), cashback);
        assertEq(distributor.protocolBalance(address(evilPayment)), protocolShare);
    }

    /// @notice Re-entry into `withdrawProtocolFees` from its own payout hook dies at the
    /// guard, before access control (the hostile token holds no TREASURY_ROLE).
    function test_WithdrawProtocolFees_Reentrancy_RevertsViaGuard() public {
        MaliciousHookToken evilPayment = _recordFeeInHookToken(1_000e6);
        uint256 protocolShare = distributor.protocolBalance(address(evilPayment));

        evilPayment.armOnTransfer(
            address(distributor),
            abi.encodeWithSelector(
                distributor.withdrawProtocolFees.selector, address(evilPayment), address(evilPayment), 1
            )
        );
        vm.prank(admin);
        distributor.withdrawProtocolFees(address(evilPayment), treasuryTarget, 100e6);

        assertTrue(evilPayment.reentered());
        assertFalse(evilPayment.reentrantSucceeded());
        assertEq(_selectorOf(evilPayment.reentrantReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(evilPayment.balanceOf(treasuryTarget), 100e6);
        assertEq(distributor.protocolBalance(address(evilPayment)), protocolShare - 100e6);
    }

    // ── recordDealFee (P2PEscrow) ──────────────────────────────────────────────────────

    address public escrowCaller = makeAddr("escrowCaller");

    /// @dev Grants ESCROW_ROLE to `escrowCaller` (through the timelock) and returns the role.
    function _grantEscrowRole() internal returns (bytes32 escrowRole) {
        escrowRole = distributor.ESCROW_ROLE();
        _grantRole(escrowRole, escrowCaller);
    }

    /// @dev Simulates P2PEscrow: transfers the fee to the distributor and then records it.
    function _recordDealFee(address asset, uint256 feeAmount, uint16 dealCashbackBps) internal returns (uint256) {
        usdt.mint(address(distributor), feeAmount);
        vm.prank(escrowCaller);
        return distributor.recordDealFee(asset, address(usdt), feeAmount, dealCashbackBps);
    }

    function test_RecordDealFee_OnlyEscrowRole() public {
        bytes32 escrowRole = _grantEscrowRole();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, escrowRole)
        );
        distributor.recordDealFee(address(equityToken), address(usdt), 100e6, 1_000);
    }

    /// @notice The two accounting entry points are separate: the settlement role cannot
    /// record a deal fee, and the escrow role cannot record a settlement fee.
    function test_RecordDealFee_RolesAreNotInterchangeable() public {
        bytes32 escrowRole = _grantEscrowRole();
        vm.prank(settlementCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, settlementCaller, escrowRole
            )
        );
        distributor.recordDealFee(address(equityToken), address(usdt), 100e6, 1_000);

        vm.prank(escrowCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, escrowCaller, settlementRole
            )
        );
        distributor.recordFee(address(equityToken), address(usdt), 100e6);
    }

    function test_RecordDealFee_RevertsForZeroFee() public {
        _grantEscrowRole();
        vm.prank(escrowCaller);
        vm.expectRevert(CashbackDistributor.ZeroFeeAmount.selector);
        distributor.recordDealFee(address(equityToken), address(usdt), 0, 1_000);
    }

    /// @notice The hard cashback cap also binds the rate a deal carries.
    function test_RecordDealFee_RevertsWhenDealRateExceedsCap() public {
        _grantEscrowRole();
        uint16 tooHigh = distributor.MAX_CASHBACK_BPS() + 1;
        vm.prank(escrowCaller);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.CashbackBpsExceedsCap.selector, tooHigh));
        distributor.recordDealFee(address(equityToken), address(usdt), 100e6, tooHigh);
    }

    /// @notice The cashback share uses the rate fixed on the deal, not the current
    /// `cashbackBps` (1000 here).
    function test_RecordDealFee_CreditsAtTheDealRate() public {
        _grantEscrowRole();
        NativeAssetToken acme = _listedNative();

        usdt.mint(address(distributor), 1_000e6);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackDistributor.CashbackCredited(address(acme), address(usdt), issuer, 250e6);
        vm.expectEmit(true, true, false, true, address(distributor));
        emit CashbackDistributor.FeeRecorded(address(acme), address(usdt), 1_000e6, 250e6, true);
        vm.prank(escrowCaller);
        uint256 cashback = distributor.recordDealFee(address(acme), address(usdt), 1_000e6, 2_500);

        assertEq(cashback, 250e6);
        assertEq(distributor.cashbackBalance(address(acme), address(usdt)), 250e6);
        assertEq(distributor.protocolBalance(address(usdt)), 750e6);
    }

    function test_RecordDealFee_FullCashbackAtTheCap() public {
        _grantEscrowRole();
        NativeAssetToken acme = _listedNative();
        uint256 cashback = _recordDealFee(address(acme), 1_000e6, 10_000);

        assertEq(cashback, 1_000e6);
        assertEq(distributor.protocolBalance(address(usdt)), 0);
    }

    /// @notice An eligible listing at a zero deal rate: everything is protocol revenue.
    function test_RecordDealFee_ZeroDealRateCreditsNothing() public {
        _grantEscrowRole();
        NativeAssetToken acme = _listedNative();

        usdt.mint(address(distributor), 1_000e6);
        vm.expectEmit(true, true, false, true, address(distributor));
        emit CashbackDistributor.FeeRecorded(address(acme), address(usdt), 1_000e6, 0, true);
        vm.prank(escrowCaller);
        uint256 cashback = distributor.recordDealFee(address(acme), address(usdt), 1_000e6, 0);

        assertEq(cashback, 0);
        assertEq(distributor.cashbackBalance(address(acme), address(usdt)), 0);
        assertEq(distributor.protocolBalance(address(usdt)), 1_000e6);
    }

    /// @notice A Currency listing never accrues cashback. Its token is a plain ERC-20 with
    /// no `cashbackEligible()` / `issuerWallet()`: eligibility comes from the registry.
    function test_RecordDealFee_CurrencyListingNeverAccruesCashback() public {
        _grantEscrowRole();
        MockUSDT brl = new MockUSDT();
        vm.prank(admin);
        registry.listCurrency(address(brl));

        usdt.mint(address(distributor), 1_000e6);
        vm.expectEmit(true, true, false, true, address(distributor));
        emit CashbackDistributor.FeeRecorded(address(brl), address(usdt), 1_000e6, 0, false);
        vm.prank(escrowCaller);
        uint256 cashback = distributor.recordDealFee(address(brl), address(usdt), 1_000e6, 10_000);

        assertEq(cashback, 0);
        assertEq(distributor.cashbackBalance(address(brl), address(usdt)), 0);
        assertEq(distributor.protocolBalance(address(usdt)), 1_000e6);
    }

    /// @notice A token with no listing is not eligible either.
    function test_RecordDealFee_UnlistedAssetNeverAccruesCashback() public {
        _grantEscrowRole();
        uint256 cashback = _recordDealFee(address(equityToken), 1_000e6, 10_000);

        assertEq(cashback, 0);
        assertEq(distributor.protocolBalance(address(usdt)), 1_000e6);
    }

    /// @notice Deal cashback lands in the same balance as settlement cashback, so the issuer
    /// withdraws it the same way.
    function test_RecordDealFee_CashbackIsWithdrawable() public {
        _grantEscrowRole();
        NativeAssetToken acme = _listedNative();
        _recordDealFee(address(acme), 1_000e6, 2_500);

        vm.prank(issuer);
        distributor.withdraw(address(acme), address(usdt));
        assertEq(usdt.balanceOf(issuer), 250e6);
    }

    /// @notice Like `recordFee`, it is not paused: it only runs inside `acceptDeal`, which is.
    function test_RecordDealFee_NotBlockedByPause() public {
        _grantEscrowRole();
        NativeAssetToken acme = _listedNative();
        _pauseProtocol();
        assertEq(_recordDealFee(address(acme), 1_000e6, 2_500), 250e6);
    }

    // ── recordListingFee (ListingRegistry, spec §3.13) ─────────────────────────────────

    address internal registryCaller = makeAddr("registryCaller");

    function _grantListingRegistryRole() internal returns (bytes32 role) {
        role = distributor.LISTING_REGISTRY_ROLE();
        _grantRole(role, registryCaller);
    }

    function test_RecordListingFee_OnlyListingRegistryRole() public {
        bytes32 role = _grantListingRegistryRole();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        distributor.recordListingFee(address(equityToken), address(usdt), 100e6);
    }

    /// @notice The listing-fee entry point is separate from the trading-fee ones, both ways.
    function test_RecordListingFee_RolesAreNotInterchangeable() public {
        bytes32 role = _grantListingRegistryRole();
        vm.prank(settlementCaller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, settlementCaller, role)
        );
        distributor.recordListingFee(address(equityToken), address(usdt), 100e6);

        vm.prank(registryCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, registryCaller, settlementRole
            )
        );
        distributor.recordFee(address(equityToken), address(usdt), 100e6);
    }

    function test_RecordListingFee_RevertsForZeroAmount() public {
        _grantListingRegistryRole();
        vm.prank(registryCaller);
        vm.expectRevert(CashbackDistributor.ZeroFeeAmount.selector);
        distributor.recordListingFee(address(equityToken), address(usdt), 0);
    }

    /// @notice All of a listing fee is protocol revenue: no cashback share, even for a
    /// cashback-eligible asset, and it is counted apart from trading fees.
    function test_RecordListingFee_AllProtocolRevenueNoCashback() public {
        _grantListingRegistryRole();
        _recordFee(equityToken, 1_000e6); // a trading fee first: 100 cashback, 900 protocol
        usdt.mint(address(distributor), 5_000e6);

        vm.recordLogs();
        vm.prank(registryCaller);
        distributor.recordListingFee(address(equityToken), address(usdt), 5_000e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only ListingFeeRecorded: no CashbackCredited");
        assertEq(logs[0].topics[0], keccak256("ListingFeeRecorded(address,address,uint256)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(equityToken));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(usdt));
        assertEq(abi.decode(logs[0].data, (uint256)), 5_000e6);

        assertEq(distributor.cashbackBalance(address(equityToken), address(usdt)), 100e6);
        assertEq(distributor.protocolBalance(address(usdt)), 900e6 + 5_000e6);
        assertEq(distributor.listingFeesCollected(address(usdt)), 5_000e6);
    }

    /// @notice Listing fees are withdrawable by the treasury with the trading fees' protocol
    /// share; `listingFeesCollected` is a historical sum that withdrawals do not reduce.
    function test_RecordListingFee_WithdrawableByTreasury() public {
        _grantListingRegistryRole();
        usdt.mint(address(distributor), 5_000e6);
        vm.prank(registryCaller);
        distributor.recordListingFee(address(equityToken), address(usdt), 5_000e6);

        vm.prank(admin);
        distributor.withdrawProtocolFees(address(usdt), treasuryTarget, 5_000e6);
        assertEq(usdt.balanceOf(treasuryTarget), 5_000e6);
        assertEq(distributor.protocolBalance(address(usdt)), 0);
        assertEq(distributor.listingFeesCollected(address(usdt)), 5_000e6);
    }

    /// @notice Like `recordFee`, it is not paused: it only runs inside `payListingFee`, which is.
    function test_RecordListingFee_NotBlockedByPause() public {
        _grantListingRegistryRole();
        _pauseProtocol();
        vm.prank(registryCaller);
        distributor.recordListingFee(address(equityToken), address(usdt), 1e6);
        assertEq(distributor.listingFeesCollected(address(usdt)), 1e6);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {MockBackingGateway} from "./mocks/MockBackingGateway.sol";
import {MockFeeOnTransferToken} from "./mocks/MockFeeOnTransferToken.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockWBTC} from "./mocks/MockWBTC.sol";
import {MaliciousReentrantToken} from "./mocks/MaliciousReentrantToken.sol";
import {MaliciousHookToken} from "./mocks/MaliciousHookToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract NiaraSettlementTest is Test {
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    ListingRegistry public registry;
    NativeAssetToken public assetToken;
    MockUSDT public usdt;
    MockWBTC public wbtc;

    address public admin = makeAddr("admin");
    address public listingAuthority = makeAddr("listingAuthority");
    address public issuer = makeAddr("issuer");
    address public operator = makeAddr("operator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");

    uint256 public constant TIMELOCK_DELAY = 2 days;
    bytes32 public constant DOC_HASH = keccak256("acme-offering-document");

    bytes32 public settlementOperatorRole;
    bytes32 public settlementRoleOnDistributor;

    function setUp() public {
        registry = new ListingRegistry(admin, listingAuthority, TIMELOCK_DELAY);
        distributor = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY);
        usdt = new MockUSDT();
        wbtc = new MockWBTC();
        settlement =
            new NiaraSettlement(admin, address(distributor), address(registry), address(usdt), TIMELOCK_DELAY);

        settlementOperatorRole = settlement.SETTLEMENT_OPERATOR_ROLE();
        settlementRoleOnDistributor = distributor.SETTLEMENT_ROLE();

        _distributorGrantRole(settlementRoleOnDistributor, address(settlement));
        _settlementGrantRole(settlementOperatorRole, operator);

        // Native Equity instrument: issued by the issuer, listed, approved, and a 1,000-unit
        // batch issued to the seller through the registry.
        assetToken = _issueListedNative(IListingRegistry.AssetClass.Equity, seller, 1_000 ether);

        _listCurrency(address(usdt));
        _listCurrency(address(wbtc));
        usdt.mint(buyer, 1_000_000e6);
        wbtc.mint(buyer, 1_000e8);

        vm.prank(seller);
        assetToken.approve(address(settlement), type(uint256).max);
        vm.prank(buyer);
        usdt.approve(address(settlement), type(uint256).max);
        vm.prank(buyer);
        wbtc.approve(address(settlement), type(uint256).max);
    }

    // ── Timelocked governance helpers ─────────────────────────────────────────────────

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

    /// @dev Switches the fee token through the timelock. Hostile and edge-case payment
    /// tokens can only reach the transfer legs as the configured fee token.
    function _useFeeToken(address token) internal {
        vm.prank(admin);
        settlement.proposeSetFeeToken(token);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeSetFeeToken(token);
    }

    // ── Listing helpers ────────────────────────────────────────────────────────────────

    /// @dev Creates a native instrument, submits and approves its listing, and issues
    /// `amount` to `to` through an approved batch.
    function _issueListedNative(IListingRegistry.AssetClass assetClass, address to, uint256 amount)
        internal
        returns (NativeAssetToken token)
    {
        // Resolve the factory BEFORE the prank: `registry.factory()` is itself an external
        // call and would consume it (see the note at the top of test/AssetToken.t.sol).
        AssetTokenFactory factory = registry.factory();
        vm.prank(issuer);
        token = NativeAssetToken(factory.createAssetToken("Acme Corp", "ACME", assetClass, DOC_HASH));
        vm.prank(issuer);
        registry.submitListing(address(token));
        vm.prank(listingAuthority);
        registry.approveListing(address(token));
        vm.prank(issuer);
        uint256 batchNo = registry.requestIssuance(address(token), amount, to, DOC_HASH);
        vm.prank(listingAuthority);
        registry.approveIssuance(address(token), batchNo);
    }

    function _listCurrency(address token) internal {
        vm.prank(listingAuthority);
        registry.listCurrency(token);
    }

    // ── Atomic settlement ──────────────────────────────────────────────────────────────

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

    /// @notice Fees are always in USDT, so the order book only pays in the fee token: an
    /// Approved Currency that is not the fee token (WBTC) is rejected before any transfer.
    function test_Settle_RevertsForApprovedCurrencyThatIsNotFeeToken() public {
        assertTrue(registry.isApproved(address(wbtc)));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.NotFeeToken.selector, address(wbtc)));
        settlement.settle(address(assetToken), address(wbtc), buyer, seller, 5 ether, 1e8);

        assertEq(assetToken.balanceOf(buyer), 0);
        assertEq(wbtc.balanceOf(seller), 0);
        assertEq(wbtc.balanceOf(address(distributor)), 0);
    }

    /// @notice The party receiving USDT (the seller) pays the fee, out of the USDT it
    /// receives; the buyer receives its asset leg in full.
    function test_Settle_SellerReceivingUsdtPaysTheFee() public {
        uint256 paymentAmount = 1_000e6;
        uint256 fee = (paymentAmount * settlement.feeBps()) / 10_000;

        vm.prank(operator);
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, paymentAmount);

        assertEq(assetToken.balanceOf(buyer), 10 ether);
        assertEq(usdt.balanceOf(buyer), 1_000_000e6 - paymentAmount);
        assertEq(usdt.balanceOf(seller), paymentAmount - fee);
        assertEq(usdt.balanceOf(address(distributor)), fee);
    }

    function test_Settle_FeeMathExact() public {
        // Default feeBps = 50 (0.5%). 123_456_789 * 50 / 10000 = 617_283 (truncated).
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

    /// @notice Rounding: tiny amounts cannot truncate the fee to zero while
    /// feeBps > 0; otherwise one could trade fee-free through micro-transactions.
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

    /// @notice `settle` stops under the protocol's shared pause (held by the registry), with
    /// the same error the registry raises.
    function test_Settle_RevertsWhenProtocolPaused() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
        assertEq(assetToken.balanceOf(buyer), 0);
    }

    // ── Fee: hard cap and timelock ─────────────────────────────────────────────────────

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
        CashbackDistributor newDistributor = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY);

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

    // ── Reentrancy ─────────────────────────────────────────────────────────────────────

    /// @notice The asset-side hook vector is closed structurally: a hostile asset token is
    /// not a factory token, so it can never be listed, and `settle` rejects it at the listing
    /// gate before any transfer (the hook never fires).
    function test_Settle_MaliciousAssetTokenIsRejectedByListingGate() public {
        MaliciousHookToken evilAsset = new MaliciousHookToken();
        evilAsset.mint(seller, 1_000 ether);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.NotFactoryToken.selector, address(evilAsset)));
        registry.submitListing(address(evilAsset));

        vm.prank(seller);
        evilAsset.approve(address(settlement), type(uint256).max);
        evilAsset.armOnTransferFrom(
            address(settlement),
            abi.encodeWithSelector(
                settlement.settle.selector, address(assetToken), address(usdt), buyer, seller, 1 ether, 100e6
            )
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetListingNotApproved.selector, address(evilAsset)));
        settlement.settle(address(evilAsset), address(usdt), buyer, seller, 10 ether, 1_000e6);

        assertFalse(evilAsset.reentered());
        assertEq(evilAsset.balanceOf(buyer), 0);
    }

    function test_Settle_ReentrancyViaMaliciousPaymentToken_Reverts() public {
        MaliciousReentrantToken evilPayment = new MaliciousReentrantToken();
        evilPayment.mint(buyer, 1_000_000e6);
        _listCurrency(address(evilPayment));
        _useFeeToken(address(evilPayment));

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

    /// @dev Extracts the selector from raw return data (e.g. the error of a reverted call).
    function _selectorOf(bytes memory data) internal pure returns (bytes4 sel) {
        require(data.length >= 4, "return data has no selector");
        assembly {
            sel := mload(add(data, 32))
        }
    }

    /// @notice Checks-effects-interactions: `Settled` must be emitted before any
    /// transfer, so an off-chain indexer never sees a `Transfer` from this settlement
    /// (or from a re-entry it triggered) before the `Settled` itself.
    function test_Settle_EmitsSettledBeforeExternalTransfers() public {
        vm.recordLogs();

        vm.prank(operator);
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 settledTopic = keccak256("Settled(address,address,address,address,uint256,uint256,uint256)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");

        uint256 settledIndex = type(uint256).max;
        uint256 firstTransferIndex = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == settledTopic && settledIndex == type(uint256).max) settledIndex = i;
            if (logs[i].topics[0] == transferTopic && firstTransferIndex == type(uint256).max) {
                firstTransferIndex = i;
            }
        }

        assertTrue(settledIndex != type(uint256).max, "Settled not emitted");
        assertTrue(firstTransferIndex != type(uint256).max, "no Transfer emitted");
        assertLt(settledIndex, firstTransferIndex);
        assertEq(settledIndex, 0);
    }

    /// @notice Cross-function reentrancy from a payment token with a hook: the re-entrant
    /// call dies at the guard (the first modifier) even before access control, and the
    /// legitimate settlement completes with consistent state.
    function test_Settle_CrossFunctionReentrancyFromHookIsBlockedByGuard() public {
        MaliciousHookToken evilPayment = new MaliciousHookToken();
        evilPayment.mint(buyer, 1_000_000e6);
        _listCurrency(address(evilPayment));
        _useFeeToken(address(evilPayment));

        vm.prank(buyer);
        evilPayment.approve(address(settlement), type(uint256).max);

        // The hostile token does NOT get SETTLEMENT_OPERATOR_ROLE: if `nonReentrant` were not
        // the first modifier, the observed error would be the access-control one.
        evilPayment.armOnTransferFrom(
            address(settlement),
            abi.encodeWithSelector(
                settlement.settle.selector, address(assetToken), address(evilPayment), buyer, seller, 1 ether, 100e6
            )
        );

        uint256 sellerAssetBefore = assetToken.balanceOf(seller);

        vm.prank(operator);
        uint256 feeCharged = settlement.settle(address(assetToken), address(evilPayment), buyer, seller, 10 ether, 1_000e6);

        assertTrue(evilPayment.reentered());
        assertFalse(evilPayment.reentrantSucceeded());
        assertEq(
            _selectorOf(evilPayment.reentrantReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );
        assertTrue(
            _selectorOf(evilPayment.reentrantReturnData()) != IAccessControl.AccessControlUnauthorizedAccount.selector
        );

        // Only the legitimate settlement moved value; the re-entrant one moved nothing.
        assertEq(feeCharged, 5e6);
        assertEq(assetToken.balanceOf(seller), sellerAssetBefore - 10 ether);
        assertEq(assetToken.balanceOf(buyer), 10 ether);
        assertEq(evilPayment.balanceOf(seller), 995e6);
        assertEq(evilPayment.balanceOf(address(distributor)), 5e6);
    }

    // ── Shared protocol pause (held by the ListingRegistry) ───────────────────────────

    /// @notice NiaraSettlement has no pause of its own any more: `pause()` / `unpause()` do not
    /// exist on it, and `paused()` only mirrors the registry.
    function test_Pause_NoLocalPauseFunctions() public {
        vm.prank(admin);
        (bool pauseOk,) = address(settlement).call(abi.encodeWithSignature("pause()"));
        assertFalse(pauseOk);
        vm.prank(admin);
        (bool unpauseOk,) = address(settlement).call(abi.encodeWithSignature("unpause()"));
        assertFalse(unpauseOk);
        (bool roleOk,) = address(settlement).call(abi.encodeWithSignature("PAUSER_ROLE()"));
        assertFalse(roleOk);
    }

    function test_Paused_MirrorsRegistryPause() public {
        assertFalse(settlement.paused());
        vm.prank(admin);
        registry.pause();
        assertTrue(settlement.paused());
        vm.prank(admin);
        registry.unpause();
        assertFalse(settlement.paused());
    }

    /// @notice Modifier order: `nonReentrant`, then the role, then the pause. A caller without
    /// the operator role gets the access-control error even while paused.
    function test_Settle_RoleCheckedBeforePause() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, seller, settlementOperatorRole)
        );
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    /// @notice End to end: the registry pause blocks `settle`; unpausing restores it.
    function test_PauseUnpause_EndToEnd_BlocksThenRestoresSettle() public {
        vm.prank(admin);
        registry.pause();
        assertTrue(settlement.paused());

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);

        vm.prank(admin);
        registry.unpause();
        assertFalse(settlement.paused());

        vm.prank(operator);
        uint256 feeCharged = settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
        assertGt(feeCharged, 0);
        assertEq(assetToken.balanceOf(buyer), 10 ether);
    }

    // ── Zero address guards ────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(NiaraSettlement.ZeroAddress.selector);
        new NiaraSettlement(address(0), address(distributor), address(registry), address(usdt), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroCashbackDistributor() public {
        vm.expectRevert(NiaraSettlement.ZeroAddress.selector);
        new NiaraSettlement(admin, address(0), address(registry), address(usdt), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroListingRegistry() public {
        vm.expectRevert(NiaraSettlement.ZeroAddress.selector);
        new NiaraSettlement(admin, address(distributor), address(0), address(usdt), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroFeeToken() public {
        vm.expectRevert(NiaraSettlement.ZeroAddress.selector);
        new NiaraSettlement(admin, address(distributor), address(registry), address(0), TIMELOCK_DELAY);
    }

    function test_Constructor_SetsFeeToken() public view {
        assertEq(settlement.feeToken(), address(usdt));
    }

    // ── Fee token (USDT): timelocked switch ────────────────────────────────────────────

    function test_ProposeSetFeeToken_OnlyAdmin() public {
        bytes32 adminRole = settlement.DEFAULT_ADMIN_ROLE();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, adminRole)
        );
        settlement.proposeSetFeeToken(address(wbtc));
    }

    function test_ExecuteSetFeeToken_OnlyAdmin() public {
        vm.prank(admin);
        settlement.proposeSetFeeToken(address(wbtc));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        bytes32 adminRole = settlement.DEFAULT_ADMIN_ROLE();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, adminRole)
        );
        settlement.executeSetFeeToken(address(wbtc));
    }

    function test_ProposeSetFeeToken_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(NiaraSettlement.ZeroAddress.selector);
        settlement.proposeSetFeeToken(address(0));
    }

    function test_FeeToken_ChangeRequiresTimelock() public {
        vm.prank(admin);
        uint256 executeAfter = settlement.proposeSetFeeToken(address(wbtc));
        assertEq(executeAfter, block.timestamp + TIMELOCK_DELAY);

        bytes32 actionId = keccak256(abi.encode("SET_FEE_TOKEN", address(wbtc)));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAccessControl.TimelockNotElapsed.selector, actionId, executeAfter)
        );
        settlement.executeSetFeeToken(address(wbtc));
        assertEq(settlement.feeToken(), address(usdt));
    }

    function test_ExecuteSetFeeToken_RevertsWithoutProposal() public {
        bytes32 actionId = keccak256(abi.encode("SET_FEE_TOKEN", address(wbtc)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionNotPending.selector, actionId));
        settlement.executeSetFeeToken(address(wbtc));
    }

    function test_FeeToken_ChangeEmitsEvents() public {
        vm.expectEmit(true, false, false, true, address(settlement));
        emit NiaraSettlement.FeeTokenChangeProposed(address(wbtc), block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.proposeSetFeeToken(address(wbtc));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, true, false, true, address(settlement));
        emit NiaraSettlement.FeeTokenChanged(address(usdt), address(wbtc));
        vm.prank(admin);
        settlement.executeSetFeeToken(address(wbtc));
        assertEq(settlement.feeToken(), address(wbtc));
    }

    /// @notice After a fee-token switch the old token can no longer be paid in, the new one
    /// settles (it is an Approved Currency), and cashback already credited in the old token
    /// stays withdrawable: the distributor keeps balances per token.
    function test_FeeToken_SwitchMovesSettlementToNewTokenAndKeepsOldCashback() public {
        vm.prank(operator);
        uint256 oldFee = settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
        uint256 oldCashback = (oldFee * distributor.cashbackBps()) / 10_000;
        assertEq(distributor.cashbackBalance(address(assetToken), address(usdt)), oldCashback);

        _useFeeToken(address(wbtc));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.NotFeeToken.selector, address(usdt)));
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);

        vm.prank(operator);
        uint256 newFee = settlement.settle(address(assetToken), address(wbtc), buyer, seller, 5 ether, 1e8);
        assertEq(wbtc.balanceOf(address(distributor)), newFee);
        assertEq(wbtc.balanceOf(seller), 1e8 - newFee);

        vm.prank(issuer);
        distributor.withdraw(address(assetToken), address(usdt));
        assertEq(usdt.balanceOf(issuer), oldCashback);
    }

    function test_Constructor_SetsListingRegistry() public view {
        assertEq(address(settlement.listingRegistry()), address(registry));
    }

    // ── Listing gate: asset must be an Approved Equity listing ─────────────────────────

    function test_Settle_RevertsForUnlistedAsset() public {
        MockUSDT unlisted = new MockUSDT();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetListingNotApproved.selector, address(unlisted)));
        settlement.settle(address(unlisted), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsForPendingAsset() public {
        AssetTokenFactory factory = registry.factory();
        vm.prank(issuer);
        address pending = factory.createAssetToken("Pending", "PND", IListingRegistry.AssetClass.Equity, DOC_HASH);
        vm.prank(issuer);
        registry.submitListing(pending);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetListingNotApproved.selector, pending));
        settlement.settle(pending, address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsForSuspendedAsset() public {
        vm.prank(listingAuthority);
        registry.suspendListing(address(assetToken));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetListingNotApproved.selector, address(assetToken)));
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_ResumesAfterReapproval() public {
        vm.prank(listingAuthority);
        registry.suspendListing(address(assetToken));
        vm.prank(listingAuthority);
        registry.approveListing(address(assetToken));

        vm.prank(operator);
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
        assertEq(assetToken.balanceOf(buyer), 10 ether);
    }

    function test_Settle_RevertsForDelistedAsset() public {
        vm.prank(listingAuthority);
        registry.delist(address(assetToken));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetListingNotApproved.selector, address(assetToken)));
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsForApprovedFixedIncome() public {
        NativeAssetToken bond = _issueListedNative(IListingRegistry.AssetClass.FixedIncome, seller, 100 ether);
        vm.prank(seller);
        bond.approve(address(settlement), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetNotEquity.selector, address(bond)));
        settlement.settle(address(bond), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsForApprovedCredit() public {
        NativeAssetToken loan = _issueListedNative(IListingRegistry.AssetClass.Credit, seller, 100 ether);
        vm.prank(seller);
        loan.approve(address(settlement), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetNotEquity.selector, address(loan)));
        settlement.settle(address(loan), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    /// @notice An Approved Currency is not an order-book asset: USDT cannot be the "asset"
    /// leg (Currency trades P2P), so it can never reach the cashback path through settle.
    function test_Settle_RevertsForCurrencyAsAsset() public {
        usdt.mint(seller, 1_000e6);
        vm.prank(seller);
        usdt.approve(address(settlement), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetNotEquity.selector, address(usdt)));
        settlement.settle(address(usdt), address(usdt), buyer, seller, 10e6, 1e6);
        assertEq(distributor.cashbackBalance(address(usdt), address(usdt)), 0);
    }

    /// @notice A backed AssetToken (BackingGateway path) is not a factory token, so it cannot
    /// be listed and cannot settle in v1.
    function test_Settle_RevertsForBackedAssetToken() public {
        MockBackingGateway gateway = new MockBackingGateway();
        AssetToken backed = new AssetToken(
            "Apple Inc. - Niara Tokenized Equity",
            "nAAPL",
            "AAPL",
            AssetToken.AssetClass.EQUITY,
            "US",
            issuer,
            admin,
            TIMELOCK_DELAY
        );
        gateway.setTotalAttested(address(backed), 1 ether);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetListingNotApproved.selector, address(backed)));
        settlement.settle(address(backed), address(usdt), buyer, seller, 1 ether, 1_000e6);
    }

    // ── Listing gate: payment token must be an Approved Currency listing ───────────────

    function test_Settle_RevertsForUnlistedPaymentToken() public {
        MockUSDT unlisted = new MockUSDT();
        // Even as the configured fee token, an unlisted token cannot be paid in.
        _useFeeToken(address(unlisted));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(NiaraSettlement.PaymentTokenNotApprovedCurrency.selector, address(unlisted))
        );
        settlement.settle(address(assetToken), address(unlisted), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsForSuspendedCurrency() public {
        vm.prank(listingAuthority);
        registry.suspendListing(address(usdt));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.PaymentTokenNotApprovedCurrency.selector, address(usdt)));
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsForDelistedCurrency() public {
        vm.prank(listingAuthority);
        registry.delist(address(usdt));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.PaymentTokenNotApprovedCurrency.selector, address(usdt)));
        settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);
    }

    /// @notice An Approved non-Currency listing (here another Equity) is not a valid
    /// payment token.
    function test_Settle_RevertsForApprovedEquityAsPaymentToken() public {
        NativeAssetToken other = _issueListedNative(IListingRegistry.AssetClass.Equity, buyer, 1_000 ether);
        vm.prank(buyer);
        other.approve(address(settlement), type(uint256).max);
        _useFeeToken(address(other));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.PaymentTokenNotApprovedCurrency.selector, address(other)));
        settlement.settle(address(assetToken), address(other), buyer, seller, 10 ether, 100 ether);
    }

    // ── Balance-delta check ────────────────────────────────────────────────────────────

    /// @notice A listed fee-on-transfer payment token can never break
    /// `paymentAmount == sellerProceeds + feeCharged`: the seller leg delivers less than
    /// requested and the whole settlement reverts.
    function test_Settle_RevertsForFeeOnTransferPaymentToken() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken(100); // 1% burned per transfer
        fot.mint(buyer, 1_000_000e6);
        _listCurrency(address(fot));
        _useFeeToken(address(fot));
        vm.prank(buyer);
        fot.approve(address(settlement), type(uint256).max);

        uint256 paymentAmount = 1_000e6;
        uint256 fee = (paymentAmount * settlement.feeBps()) / 10_000;
        uint256 sellerProceeds = paymentAmount - fee;
        uint256 delivered = sellerProceeds - (sellerProceeds * 100) / 10_000;

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                NiaraSettlement.TransferAmountMismatch.selector, address(fot), sellerProceeds, delivered
            )
        );
        settlement.settle(address(assetToken), address(fot), buyer, seller, 10 ether, paymentAmount);

        assertEq(fot.balanceOf(seller), 0);
        assertEq(assetToken.balanceOf(buyer), 0);
    }

    /// @notice If a token leaves the receiver with a lower balance than before, the received
    /// amount counts as zero and the settlement reverts.
    function test_Settle_RevertsWhenReceiverBalanceDecreases() public {
        MockFeeOnTransferToken shrink = new MockFeeOnTransferToken(0);
        shrink.mint(buyer, 1_000_000e6);
        shrink.mint(seller, 1_000_000e6);
        shrink.setDrainReceiver(true);
        _listCurrency(address(shrink));
        _useFeeToken(address(shrink));
        vm.prank(buyer);
        shrink.approve(address(settlement), type(uint256).max);

        uint256 paymentAmount = 1_000e6;
        uint256 sellerProceeds = paymentAmount - (paymentAmount * settlement.feeBps()) / 10_000;

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(NiaraSettlement.TransferAmountMismatch.selector, address(shrink), sellerProceeds, 0)
        );
        settlement.settle(address(assetToken), address(shrink), buyer, seller, 10 ether, paymentAmount);
    }

    /// @notice With `feeBps = 0` the fee leg is skipped and a fee-on-transfer token still
    /// fails on the seller leg.
    function test_Settle_FeeOnTransferRevertsEvenWithZeroFee() public {
        _setFeeBps(0);
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken(50);
        fot.mint(buyer, 1_000_000e6);
        _listCurrency(address(fot));
        _useFeeToken(address(fot));
        vm.prank(buyer);
        fot.approve(address(settlement), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(NiaraSettlement.TransferAmountMismatch.selector, address(fot), 1_000e6, 995e6)
        );
        settlement.settle(address(assetToken), address(fot), buyer, seller, 10 ether, 1_000e6);
    }

    /// @notice Fuzz: for any successful settlement, what the seller and the distributor
    /// received sums exactly to `paymentAmount`.
    function testFuzz_Settle_PaymentEqualsSellerPlusFee(uint256 paymentAmount, uint256 assetAmount) public {
        paymentAmount = bound(paymentAmount, 200, 1_000_000e6); // 200 * 50 / 10000 = 1 (non-zero fee)
        assetAmount = bound(assetAmount, 1, 1_000 ether);

        uint256 sellerBefore = usdt.balanceOf(seller);
        uint256 distributorBefore = usdt.balanceOf(address(distributor));
        uint256 buyerBefore = usdt.balanceOf(buyer);

        vm.prank(operator);
        uint256 fee = settlement.settle(address(assetToken), address(usdt), buyer, seller, assetAmount, paymentAmount);

        uint256 sellerGot = usdt.balanceOf(seller) - sellerBefore;
        uint256 distributorGot = usdt.balanceOf(address(distributor)) - distributorBefore;
        assertEq(sellerGot + distributorGot, paymentAmount);
        assertEq(distributorGot, fee);
        assertEq(buyerBefore - usdt.balanceOf(buyer), paymentAmount);
        assertEq(assetToken.balanceOf(buyer), assetAmount);
    }

    /// @notice Cashback still flows to the native issuer through the unchanged distributor.
    function test_Settle_CreditsCashbackToNativeIssuer() public {
        vm.prank(operator);
        uint256 fee = settlement.settle(address(assetToken), address(usdt), buyer, seller, 10 ether, 1_000e6);

        uint256 expectedCashback = (fee * distributor.cashbackBps()) / 10_000;
        assertGt(expectedCashback, 0);
        assertEq(distributor.cashbackBalance(address(assetToken), address(usdt)), expectedCashback);
        // Currency listings never accrue cashback.
        assertEq(distributor.cashbackBalance(address(usdt), address(usdt)), 0);

        vm.prank(issuer);
        distributor.withdraw(address(assetToken), address(usdt));
        assertEq(usdt.balanceOf(issuer), expectedCashback);
    }

    function test_Settle_RevertsOnZeroBuyer() public {
        vm.prank(operator);
        vm.expectRevert(NiaraSettlement.ZeroAddress.selector);
        settlement.settle(address(assetToken), address(usdt), address(0), seller, 10 ether, 1_000e6);
    }

    function test_Settle_RevertsOnZeroSeller() public {
        vm.prank(operator);
        vm.expectRevert(NiaraSettlement.ZeroAddress.selector);
        settlement.settle(address(assetToken), address(usdt), buyer, address(0), 10 ether, 1_000e6);
    }

    function test_ProposeSetCashbackDistributor_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(NiaraSettlement.ZeroAddress.selector);
        settlement.proposeSetCashbackDistributor(address(0));
    }

    // ── Defensive cap guard (redundant with the cap already checked in propose) ────────

    /// @notice `executeSetFeeBps` validates the cap BEFORE consuming the pending proposal;
    /// this guard fires even without any `proposeSetFeeBps` having been made (which would
    /// already block scheduling a value above the cap). Called directly to cover this
    /// defensive check, currently unreachable through the normal propose→execute flow.
    function test_ExecuteSetFeeBps_DefensiveCapCheck_RevertsWithoutNeedingProposal() public {
        uint16 tooHigh = settlement.MAX_FEE_BPS() + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.FeeExceedsCap.selector, tooHigh));
        settlement.executeSetFeeBps(tooHigh);
    }
}

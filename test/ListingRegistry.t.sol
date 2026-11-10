// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ListingRegistryTest is Test {
    ListingRegistry public registry;
    AssetTokenFactory public factory;
    NativeAssetToken public equity;
    MockUSDT public usdt;

    address public admin = makeAddr("admin");
    address public authority = makeAddr("authority");
    address public issuer = makeAddr("issuer");
    address public stranger = makeAddr("stranger");
    address public investor = makeAddr("investor");

    uint256 public constant TIMELOCK_DELAY = 2 days;
    bytes32 public constant DOC_HASH = keccak256("offering-document-v1");
    bytes32 public constant BATCH_DOC = keccak256("batch-1-subscription-list");

    bytes32 public listingAuthorityRole;

    function setUp() public {
        registry = new ListingRegistry(admin, authority, TIMELOCK_DELAY);
        factory = registry.factory();
        listingAuthorityRole = registry.LISTING_AUTHORITY_ROLE();
        equity = _create(issuer, IListingRegistry.AssetClass.Equity);
        usdt = new MockUSDT();
    }

    // ── Helpers ────────────────────────────────────────────────────────────────────────

    function _create(address who, IListingRegistry.AssetClass assetClass) internal returns (NativeAssetToken) {
        vm.prank(who);
        return NativeAssetToken(factory.createAssetToken("Acme", "ACME", assetClass, DOC_HASH));
    }

    function _submit(NativeAssetToken token) internal {
        vm.prank(token.issuer());
        registry.submitListing(address(token));
    }

    function _approve(address token) internal {
        vm.prank(authority);
        registry.approveListing(token);
    }

    function _suspend(address token) internal {
        vm.prank(authority);
        registry.suspendListing(token);
    }

    function _delist(address token) internal {
        vm.prank(authority);
        registry.delist(token);
    }

    function _status(address token) internal view returns (IListingRegistry.ListingStatus) {
        return registry.getListing(token).status;
    }

    function _expectTransitionRevert(address token, IListingRegistry.ListingStatus from) internal {
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.InvalidStatusTransition.selector, token, from));
    }

    /// @dev Drives `equity` to the requested status through legal transitions only.
    function _toStatus(IListingRegistry.ListingStatus target) internal {
        if (target == IListingRegistry.ListingStatus.None) return;
        _submit(equity);
        if (target == IListingRegistry.ListingStatus.Pending) return;
        if (target == IListingRegistry.ListingStatus.Delisted) {
            _delist(address(equity));
            return;
        }
        _approve(address(equity));
        if (target == IListingRegistry.ListingStatus.Suspended) _suspend(address(equity));
    }

    function _requestIssuance(uint256 amount) internal returns (uint256 batchId) {
        vm.prank(issuer);
        batchId = registry.requestIssuance(address(equity), amount, investor, BATCH_DOC);
    }

    // ── Constructor and roles ──────────────────────────────────────────────────────────

    function test_Constructor_DeploysFactoryAndGrantsRoles() public view {
        assertEq(factory.registry(), address(registry));
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(listingAuthorityRole, authority));
        assertFalse(registry.hasRole(listingAuthorityRole, admin));
        assertEq(registry.timelockDelay(), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(ListingRegistry.ZeroAddress.selector);
        new ListingRegistry(address(0), authority, TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroAuthority() public {
        vm.expectRevert(ListingRegistry.ZeroAddress.selector);
        new ListingRegistry(admin, address(0), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForInvalidTimelock() public {
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.InvalidTimelockDelay.selector, 0));
        new ListingRegistry(admin, authority, 0);
    }

    function test_GrantRole_DirectIsDisabled() public {
        vm.prank(admin);
        vm.expectRevert(TimelockedAccessControl.RoleChangeRequiresTimelock.selector);
        registry.grantRole(listingAuthorityRole, stranger);
    }

    function test_ListingAuthorityRole_GrantRequiresTimelock() public {
        vm.prank(admin);
        registry.proposeGrantRole(listingAuthorityRole, stranger);

        vm.prank(admin);
        vm.expectRevert();
        registry.executeGrantRole(listingAuthorityRole, stranger);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        registry.executeGrantRole(listingAuthorityRole, stranger);
        assertTrue(registry.hasRole(listingAuthorityRole, stranger));

        // The new authority can act immediately after the grant.
        _submit(equity);
        vm.prank(stranger);
        registry.approveListing(address(equity));
        assertTrue(registry.isApproved(address(equity)));
    }

    function test_ListingAuthorityRole_RevokeRequiresTimelock() public {
        vm.prank(admin);
        registry.proposeRevokeRole(listingAuthorityRole, authority);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        registry.executeRevokeRole(listingAuthorityRole, authority);

        _submit(equity);
        vm.prank(authority);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, authority, listingAuthorityRole)
        );
        registry.approveListing(address(equity));
    }

    // ── submitListing ──────────────────────────────────────────────────────────────────

    function test_SubmitListing_CreatesPendingListingFromToken() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit ListingRegistry.ListingSubmitted(address(equity), issuer, IListingRegistry.AssetClass.Equity, DOC_HASH);
        _submit(equity);

        IListingRegistry.Listing memory listing = registry.getListing(address(equity));
        assertEq(listing.issuer, issuer);
        assertEq(uint8(listing.assetClass), uint8(IListingRegistry.AssetClass.Equity));
        assertEq(uint8(listing.status), uint8(IListingRegistry.ListingStatus.Pending));
        assertTrue(listing.cashbackEligible);
        assertEq(listing.docHash, DOC_HASH);
        assertEq(listing.approvedAt, 0);
        assertFalse(registry.isApproved(address(equity)));
    }

    function test_SubmitListing_FixedIncomeAndCredit() public {
        NativeAssetToken bond = _create(issuer, IListingRegistry.AssetClass.FixedIncome);
        NativeAssetToken loan = _create(issuer, IListingRegistry.AssetClass.Credit);
        _submit(bond);
        _submit(loan);
        assertEq(uint8(registry.getListing(address(bond)).assetClass), uint8(IListingRegistry.AssetClass.FixedIncome));
        assertEq(uint8(registry.getListing(address(loan)).assetClass), uint8(IListingRegistry.AssetClass.Credit));
        assertTrue(registry.getListing(address(bond)).cashbackEligible);
        assertTrue(registry.getListing(address(loan)).cashbackEligible);
    }

    function test_SubmitListing_RevertsForNonFactoryToken() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.NotFactoryToken.selector, address(usdt)));
        registry.submitListing(address(usdt));
    }

    /// @notice A token from a different factory (same code, different registry) is not
    /// accepted: only this registry's factory counts.
    function test_SubmitListing_RevertsForTokenFromAnotherFactory() public {
        AssetTokenFactory otherFactory = new AssetTokenFactory(address(registry));
        vm.prank(issuer);
        address lookalike = otherFactory.createAssetToken("Fake", "FAKE", IListingRegistry.AssetClass.Equity, DOC_HASH);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.NotFactoryToken.selector, lookalike));
        registry.submitListing(lookalike);
    }

    function test_SubmitListing_RevertsForZeroAddress() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.NotFactoryToken.selector, address(0)));
        registry.submitListing(address(0));
    }

    function test_SubmitListing_OnlyIssuer() public {
        vm.prank(stranger);
        vm.expectRevert(ListingRegistry.NotIssuer.selector);
        registry.submitListing(address(equity));

        vm.prank(authority);
        vm.expectRevert(ListingRegistry.NotIssuer.selector);
        registry.submitListing(address(equity));
    }

    function test_SubmitListing_RevertsIfAlreadyListed() public {
        _submit(equity);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.ListingAlreadyExists.selector, address(equity)));
        registry.submitListing(address(equity));
    }

    function test_SubmitListing_CannotResubmitAfterDelist() public {
        _toStatus(IListingRegistry.ListingStatus.Delisted);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.ListingAlreadyExists.selector, address(equity)));
        registry.submitListing(address(equity));
    }

    // ── listCurrency ───────────────────────────────────────────────────────────────────

    function test_ListCurrency_CreatesApprovedCurrencyNeverCashbackEligible() public {
        vm.warp(1_000_000);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ListingRegistry.CurrencyListed(address(usdt), 1_000_000);
        vm.prank(authority);
        registry.listCurrency(address(usdt));

        IListingRegistry.Listing memory listing = registry.getListing(address(usdt));
        assertEq(listing.issuer, address(0));
        assertEq(uint8(listing.assetClass), uint8(IListingRegistry.AssetClass.Currency));
        assertEq(uint8(listing.status), uint8(IListingRegistry.ListingStatus.Approved));
        assertFalse(listing.cashbackEligible);
        assertEq(listing.docHash, bytes32(0));
        assertEq(listing.approvedAt, 1_000_000);
        assertTrue(registry.isApproved(address(usdt)));
    }

    function test_ListCurrency_OnlyListingAuthority() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, listingAuthorityRole)
        );
        registry.listCurrency(address(usdt));
    }

    function test_ListCurrency_RevertsForZeroAddress() public {
        vm.prank(authority);
        vm.expectRevert(ListingRegistry.ZeroAddress.selector);
        registry.listCurrency(address(0));
    }

    function test_ListCurrency_RevertsForFactoryToken() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.FactoryTokenCannotBeCurrency.selector, address(equity)));
        registry.listCurrency(address(equity));
    }

    function test_ListCurrency_RevertsIfAlreadyListed() public {
        vm.prank(authority);
        registry.listCurrency(address(usdt));
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.ListingAlreadyExists.selector, address(usdt)));
        registry.listCurrency(address(usdt));
    }

    function test_Currency_CanBeSuspendedReapprovedAndDelisted() public {
        vm.prank(authority);
        registry.listCurrency(address(usdt));
        _suspend(address(usdt));
        assertEq(uint8(_status(address(usdt))), uint8(IListingRegistry.ListingStatus.Suspended));
        _approve(address(usdt));
        assertTrue(registry.isApproved(address(usdt)));
        // Re-approval never turns cashback on for a Currency.
        assertFalse(registry.getListing(address(usdt)).cashbackEligible);
        _delist(address(usdt));
        assertEq(uint8(_status(address(usdt))), uint8(IListingRegistry.ListingStatus.Delisted));
    }

    // ── Status table: every legal transition ───────────────────────────────────────────

    function test_Approve_FromPending() public {
        _submit(equity);
        vm.warp(5_000);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ListingRegistry.ListingApproved(address(equity), 5_000);
        _approve(address(equity));
        assertTrue(registry.isApproved(address(equity)));
        assertEq(registry.getListing(address(equity)).approvedAt, 5_000);
    }

    function test_Approve_FromSuspended_UpdatesApprovedAt() public {
        _toStatus(IListingRegistry.ListingStatus.Suspended);
        vm.warp(block.timestamp + 7 days);
        _approve(address(equity));
        assertTrue(registry.isApproved(address(equity)));
        assertEq(registry.getListing(address(equity)).approvedAt, uint64(block.timestamp));
    }

    function test_Suspend_FromApproved() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ListingRegistry.ListingSuspended(address(equity));
        _suspend(address(equity));
        assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Suspended));
        assertFalse(registry.isApproved(address(equity)));
    }

    function test_Delist_FromPending_IsRejection() public {
        _toStatus(IListingRegistry.ListingStatus.Pending);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ListingRegistry.ListingDelisted(address(equity), IListingRegistry.ListingStatus.Pending);
        _delist(address(equity));
        assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Delisted));
    }

    function test_Delist_FromApproved() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ListingRegistry.ListingDelisted(address(equity), IListingRegistry.ListingStatus.Approved);
        _delist(address(equity));
        assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Delisted));
    }

    function test_Delist_FromSuspended() public {
        _toStatus(IListingRegistry.ListingStatus.Suspended);
        _delist(address(equity));
        assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Delisted));
    }

    // ── Status table: every illegal transition ─────────────────────────────────────────

    function test_Approve_RevertsFromNone() public {
        vm.prank(authority);
        _expectTransitionRevert(address(equity), IListingRegistry.ListingStatus.None);
        registry.approveListing(address(equity));
    }

    function test_Approve_RevertsFromApproved() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.prank(authority);
        _expectTransitionRevert(address(equity), IListingRegistry.ListingStatus.Approved);
        registry.approveListing(address(equity));
    }

    function test_Approve_RevertsFromDelisted() public {
        _toStatus(IListingRegistry.ListingStatus.Delisted);
        vm.prank(authority);
        _expectTransitionRevert(address(equity), IListingRegistry.ListingStatus.Delisted);
        registry.approveListing(address(equity));
    }

    function test_Suspend_RevertsFromNone() public {
        vm.prank(authority);
        _expectTransitionRevert(address(equity), IListingRegistry.ListingStatus.None);
        registry.suspendListing(address(equity));
    }

    function test_Suspend_RevertsFromPending() public {
        _toStatus(IListingRegistry.ListingStatus.Pending);
        vm.prank(authority);
        _expectTransitionRevert(address(equity), IListingRegistry.ListingStatus.Pending);
        registry.suspendListing(address(equity));
    }

    function test_Suspend_RevertsFromSuspended() public {
        _toStatus(IListingRegistry.ListingStatus.Suspended);
        vm.prank(authority);
        _expectTransitionRevert(address(equity), IListingRegistry.ListingStatus.Suspended);
        registry.suspendListing(address(equity));
    }

    function test_Suspend_RevertsFromDelisted() public {
        _toStatus(IListingRegistry.ListingStatus.Delisted);
        vm.prank(authority);
        _expectTransitionRevert(address(equity), IListingRegistry.ListingStatus.Delisted);
        registry.suspendListing(address(equity));
    }

    function test_Delist_RevertsFromNone() public {
        vm.prank(authority);
        _expectTransitionRevert(address(equity), IListingRegistry.ListingStatus.None);
        registry.delist(address(equity));
    }

    function test_Delist_RevertsFromDelisted() public {
        _toStatus(IListingRegistry.ListingStatus.Delisted);
        vm.prank(authority);
        _expectTransitionRevert(address(equity), IListingRegistry.ListingStatus.Delisted);
        registry.delist(address(equity));
    }

    /// @notice Fuzzes random sequences of status actions and checks every step against the
    /// reference table; also proves Delisted is absorbing.
    function testFuzz_StatusTable_MatchesReference(uint8[16] calldata actions) public {
        _submit(equity);
        IListingRegistry.ListingStatus expected = IListingRegistry.ListingStatus.Pending;

        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = actions[i] % 3; // 0 approve, 1 suspend, 2 delist
            IListingRegistry.ListingStatus next = _reference(expected, action);
            bool legal = next != expected;

            vm.prank(authority);
            if (!legal) _expectTransitionRevert(address(equity), expected);
            if (action == 0) registry.approveListing(address(equity));
            else if (action == 1) registry.suspendListing(address(equity));
            else registry.delist(address(equity));

            expected = next;
            assertEq(uint8(_status(address(equity))), uint8(expected));
        }
    }

    function _reference(IListingRegistry.ListingStatus s, uint8 action)
        internal
        pure
        returns (IListingRegistry.ListingStatus)
    {
        if (action == 0) {
            if (s == IListingRegistry.ListingStatus.Pending || s == IListingRegistry.ListingStatus.Suspended) {
                return IListingRegistry.ListingStatus.Approved;
            }
        } else if (action == 1) {
            if (s == IListingRegistry.ListingStatus.Approved) return IListingRegistry.ListingStatus.Suspended;
        } else {
            if (s != IListingRegistry.ListingStatus.None && s != IListingRegistry.ListingStatus.Delisted) {
                return IListingRegistry.ListingStatus.Delisted;
            }
        }
        return s; // illegal: unchanged
    }

    // ── Status actions: access control ─────────────────────────────────────────────────

    function test_Approve_OnlyListingAuthority() public {
        _submit(equity);
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, listingAuthorityRole)
        );
        registry.approveListing(address(equity));
    }

    function test_Suspend_OnlyListingAuthority() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, listingAuthorityRole)
        );
        registry.suspendListing(address(equity));
    }

    function test_Delist_OnlyListingAuthority() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, listingAuthorityRole)
        );
        registry.delist(address(equity));
    }

    // ── Views ──────────────────────────────────────────────────────────────────────────

    function test_GetListing_EmptyForUnknownToken() public view {
        IListingRegistry.Listing memory listing = registry.getListing(address(0xBEEF));
        assertEq(listing.issuer, address(0));
        assertEq(uint8(listing.status), uint8(IListingRegistry.ListingStatus.None));
        assertFalse(listing.cashbackEligible);
        assertFalse(registry.isApproved(address(0xBEEF)));
    }

    // ── requestIssuance ────────────────────────────────────────────────────────────────

    function test_RequestIssuance_WhilePending() public {
        _toStatus(IListingRegistry.ListingStatus.Pending);

        vm.expectEmit(true, true, false, true, address(registry));
        emit ListingRegistry.IssuanceRequested(address(equity), 0, 1_000 ether, investor, BATCH_DOC);
        uint256 batchId = _requestIssuance(1_000 ether);

        assertEq(batchId, 0);
        assertEq(registry.nextBatchId(address(equity)), 1);
        (uint256 amount, address recipient, bytes32 docHash, ListingRegistry.IssuanceStatus status) =
            registry.issuanceBatches(address(equity), 0);
        assertEq(amount, 1_000 ether);
        assertEq(recipient, investor);
        assertEq(docHash, BATCH_DOC);
        assertEq(uint8(status), uint8(ListingRegistry.IssuanceStatus.Requested));
        // Nothing is minted on request.
        assertEq(equity.totalSupply(), 0);
    }

    function test_RequestIssuance_WhileApproved_SequentialIdsPerToken() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        assertEq(_requestIssuance(1 ether), 0);
        assertEq(_requestIssuance(2 ether), 1);
        assertEq(_requestIssuance(3 ether), 2);

        // Another token has its own counter.
        NativeAssetToken bond = _create(issuer, IListingRegistry.AssetClass.FixedIncome);
        _submit(bond);
        vm.prank(issuer);
        assertEq(registry.requestIssuance(address(bond), 1 ether, investor, BATCH_DOC), 0);
        assertEq(registry.nextBatchId(address(equity)), 3);
        assertEq(registry.nextBatchId(address(bond)), 1);
    }

    function test_RequestIssuance_OnlyIssuer() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.prank(authority);
        vm.expectRevert(ListingRegistry.NotIssuer.selector);
        registry.requestIssuance(address(equity), 1 ether, investor, BATCH_DOC);
    }

    function test_RequestIssuance_RevertsWithoutListing() public {
        // No listing yet: the stored issuer is address(0), so the real issuer is rejected.
        vm.prank(issuer);
        vm.expectRevert(ListingRegistry.NotIssuer.selector);
        registry.requestIssuance(address(equity), 1 ether, investor, BATCH_DOC);
    }

    function test_RequestIssuance_RevertsForCurrency() public {
        vm.prank(authority);
        registry.listCurrency(address(usdt));
        vm.prank(issuer);
        vm.expectRevert(ListingRegistry.NotIssuer.selector);
        registry.requestIssuance(address(usdt), 1 ether, investor, BATCH_DOC);
    }

    function test_RequestIssuance_RevertsWhileSuspended() public {
        _toStatus(IListingRegistry.ListingStatus.Suspended);
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListingRegistry.IssuanceNotAllowed.selector, address(equity), IListingRegistry.ListingStatus.Suspended
            )
        );
        registry.requestIssuance(address(equity), 1 ether, investor, BATCH_DOC);
    }

    function test_RequestIssuance_RevertsWhenDelisted() public {
        _toStatus(IListingRegistry.ListingStatus.Delisted);
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListingRegistry.IssuanceNotAllowed.selector, address(equity), IListingRegistry.ListingStatus.Delisted
            )
        );
        registry.requestIssuance(address(equity), 1 ether, investor, BATCH_DOC);
    }

    function test_RequestIssuance_RevertsOnZeroAmount() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.prank(issuer);
        vm.expectRevert(ListingRegistry.ZeroAmount.selector);
        registry.requestIssuance(address(equity), 0, investor, BATCH_DOC);
    }

    function test_RequestIssuance_RevertsOnZeroRecipient() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.prank(issuer);
        vm.expectRevert(ListingRegistry.ZeroAddress.selector);
        registry.requestIssuance(address(equity), 1 ether, address(0), BATCH_DOC);
    }

    // ── approveIssuance ────────────────────────────────────────────────────────────────

    function test_ApproveIssuance_MintsBatch() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(1_000 ether);

        vm.expectEmit(true, true, false, true, address(registry));
        emit ListingRegistry.IssuanceExecuted(address(equity), batchId, 1_000 ether, investor, BATCH_DOC);
        vm.prank(authority);
        registry.approveIssuance(address(equity), batchId);

        assertEq(equity.balanceOf(investor), 1_000 ether);
        assertEq(equity.totalSupply(), 1_000 ether);
        (,,, ListingRegistry.IssuanceStatus status) = registry.issuanceBatches(address(equity), batchId);
        assertEq(uint8(status), uint8(ListingRegistry.IssuanceStatus.Executed));
    }

    /// @notice A batch requested while Pending can only be executed after the listing is
    /// approved.
    function test_ApproveIssuance_RequestedWhilePendingExecutesAfterApproval() public {
        _toStatus(IListingRegistry.ListingStatus.Pending);
        uint256 batchId = _requestIssuance(10 ether);

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.ListingNotApproved.selector, address(equity)));
        registry.approveIssuance(address(equity), batchId);

        _approve(address(equity));
        vm.prank(authority);
        registry.approveIssuance(address(equity), batchId);
        assertEq(equity.balanceOf(investor), 10 ether);
    }

    function test_ApproveIssuance_RevertsWhileSuspended() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);
        _suspend(address(equity));

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.ListingNotApproved.selector, address(equity)));
        registry.approveIssuance(address(equity), batchId);
    }

    function test_ApproveIssuance_RevertsWhenDelisted() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);
        _delist(address(equity));

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.ListingNotApproved.selector, address(equity)));
        registry.approveIssuance(address(equity), batchId);
        assertEq(equity.totalSupply(), 0);
    }

    function test_ApproveIssuance_RevertsTwice() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);
        vm.prank(authority);
        registry.approveIssuance(address(equity), batchId);

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.BatchNotRequested.selector, address(equity), batchId));
        registry.approveIssuance(address(equity), batchId);
        assertEq(equity.totalSupply(), 10 ether);
    }

    function test_ApproveIssuance_RevertsForUnknownBatch() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.BatchNotRequested.selector, address(equity), 7));
        registry.approveIssuance(address(equity), 7);
    }

    function test_ApproveIssuance_OnlyListingAuthority() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, listingAuthorityRole)
        );
        registry.approveIssuance(address(equity), batchId);
    }

    /// @notice Neither side can mint alone: the issuer cannot call the token's mint, and the
    /// authority cannot mint without a batch the issuer requested.
    function test_Issuance_NeitherIssuerNorAuthorityCanMintAlone() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);

        vm.prank(issuer);
        vm.expectRevert(NativeAssetToken.NotMinter.selector);
        equity.mint(issuer, 1 ether);

        vm.prank(authority);
        vm.expectRevert(NativeAssetToken.NotMinter.selector);
        equity.mint(authority, 1 ether);

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.BatchNotRequested.selector, address(equity), 0));
        registry.approveIssuance(address(equity), 0);

        assertEq(equity.totalSupply(), 0);
    }

    /// @notice Checks-effects-interactions: `IssuanceExecuted` is emitted before the
    /// token's `Transfer` (the mint), so an indexer never sees the mint first.
    function test_ApproveIssuance_EmitsIssuanceExecutedBeforeExternalTransfer() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);

        vm.recordLogs();
        vm.prank(authority);
        registry.approveIssuance(address(equity), batchId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 executedTopic = keccak256("IssuanceExecuted(address,uint256,uint256,address,bytes32)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");

        uint256 executedIndex = type(uint256).max;
        uint256 firstTransferIndex = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == executedTopic && executedIndex == type(uint256).max) executedIndex = i;
            if (logs[i].topics[0] == transferTopic && firstTransferIndex == type(uint256).max) firstTransferIndex = i;
        }

        assertTrue(executedIndex != type(uint256).max, "IssuanceExecuted not emitted");
        assertTrue(firstTransferIndex != type(uint256).max, "no Transfer emitted");
        assertLt(executedIndex, firstTransferIndex);
    }

    // ── rejectIssuance ─────────────────────────────────────────────────────────────────

    function _batchStatus(uint256 batchId) internal view returns (ListingRegistry.IssuanceStatus status) {
        (,,, status) = registry.issuanceBatches(address(equity), batchId);
    }

    function _reject(uint256 batchId) internal {
        vm.prank(authority);
        registry.rejectIssuance(address(equity), batchId);
    }

    function test_RejectIssuance_MarksRejectedAndMintsNothing() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);

        vm.expectEmit(true, true, false, true, address(registry));
        emit ListingRegistry.IssuanceRejected(address(equity), batchId, 10 ether, investor);
        _reject(batchId);

        assertEq(uint8(_batchStatus(batchId)), uint8(ListingRegistry.IssuanceStatus.Rejected));
        assertEq(equity.totalSupply(), 0);
    }

    function test_RejectIssuance_CannotApproveAfterwards() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);
        _reject(batchId);

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.BatchNotRequested.selector, address(equity), batchId));
        registry.approveIssuance(address(equity), batchId);
        assertEq(equity.totalSupply(), 0);
    }

    function test_RejectIssuance_RevertsTwice() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);
        _reject(batchId);

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.BatchNotRequested.selector, address(equity), batchId));
        registry.rejectIssuance(address(equity), batchId);
    }

    function test_RejectIssuance_RevertsForExecutedBatch() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);
        vm.prank(authority);
        registry.approveIssuance(address(equity), batchId);

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.BatchNotRequested.selector, address(equity), batchId));
        registry.rejectIssuance(address(equity), batchId);
        assertEq(equity.totalSupply(), 10 ether);
    }

    function test_RejectIssuance_RevertsForUnknownBatch() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.BatchNotRequested.selector, address(equity), 42));
        registry.rejectIssuance(address(equity), 42);
    }

    function test_RejectIssuance_OnlyListingAuthority() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, listingAuthorityRole)
        );
        registry.rejectIssuance(address(equity), batchId);
    }

    /// @notice Rejection works in every listing status, including the ones where approval
    /// is impossible (Pending, Suspended, Delisted), so no request is ever stuck open.
    function test_RejectIssuance_WhilePending() public {
        _toStatus(IListingRegistry.ListingStatus.Pending);
        uint256 batchId = _requestIssuance(10 ether);
        _reject(batchId);
        assertEq(uint8(_batchStatus(batchId)), uint8(ListingRegistry.IssuanceStatus.Rejected));
    }

    function test_RejectIssuance_WhileSuspended() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);
        _suspend(address(equity));
        _reject(batchId);
        assertEq(uint8(_batchStatus(batchId)), uint8(ListingRegistry.IssuanceStatus.Rejected));
    }

    function test_RejectIssuance_AfterDelist() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 batchId = _requestIssuance(10 ether);
        _delist(address(equity));
        _reject(batchId);
        assertEq(uint8(_batchStatus(batchId)), uint8(ListingRegistry.IssuanceStatus.Rejected));
    }

    /// @notice Rejecting one batch leaves the others untouched.
    function test_RejectIssuance_OnlyAffectsThatBatch() public {
        _toStatus(IListingRegistry.ListingStatus.Approved);
        uint256 first = _requestIssuance(10 ether);
        uint256 second = _requestIssuance(20 ether);
        _reject(first);

        vm.prank(authority);
        registry.approveIssuance(address(equity), second);
        assertEq(equity.totalSupply(), 20 ether);
        assertEq(uint8(_batchStatus(first)), uint8(ListingRegistry.IssuanceStatus.Rejected));
        assertEq(uint8(_batchStatus(second)), uint8(ListingRegistry.IssuanceStatus.Executed));
    }

    /// @notice Full native lifecycle at registry level: issue, list, request, approve,
    /// mint, and the holder burns with a reason.
    function test_NativeLifecycle_IssueListMintBurn() public {
        _submit(equity);
        uint256 batchId = _requestIssuance(500 ether);
        _approve(address(equity));
        vm.prank(authority);
        registry.approveIssuance(address(equity), batchId);

        vm.prank(investor);
        equity.burnWithReason(100 ether, NativeAssetToken.BurnReason.Redemption, keccak256("r-1"));
        assertEq(equity.totalSupply(), 400 ether);
        assertEq(equity.balanceOf(investor), 400 ether);
    }
}

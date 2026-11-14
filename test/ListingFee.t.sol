// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockFeeOnTransferToken} from "./mocks/MockFeeOnTransferToken.sol";
import {MaliciousHookToken} from "./mocks/MaliciousHookToken.sol";
import {ListingFeeHelpers} from "./helpers/ListingFeeHelpers.sol";

/// @notice The on-chain listing fee (EXCHANGE-MULTICHAIN-DESIGN.md §3.13), the EVM mirror of
/// the Solana suite `tests/test_listing_fee.rs`: `quoteListing` (listing authority) and
/// `payListingFee` (issuer), the stored quote and its events, ceil rounding, the 1% cap, the
/// expiry window, re-quoting, signers, `Currency` listings, the fee-token checks, pause,
/// double payment, rejection, the `approveListing` bypass, CEI and log order, and where the
/// fee lands (the CashbackDistributor's protocol revenue, never cashback).
contract ListingFeeTest is ListingFeeHelpers {
    ListingRegistry public registry;
    AssetTokenFactory public factory;
    CashbackDistributor public distributor;
    NiaraSettlement public settlement;
    MockUSDT public usdt;
    NativeAssetToken public equity;

    address public admin = makeAddr("admin");
    address public authority = makeAddr("authority");
    address public issuer = makeAddr("issuer");
    address public stranger = makeAddr("stranger");
    address public sink = makeAddr("sink");

    uint256 public constant TIMELOCK_DELAY = 2 days;
    bytes32 public constant DOC_HASH = keccak256("offering-document-v1");

    uint256 public constant VALUATION = 2_500_000e6;
    uint16 public constant BPS = 25;
    uint256 public constant FEE = 6_250e6; // 2,500,000 USDT * 0.25%

    bytes32 public listingAuthorityRole;

    function setUp() public {
        registry = new ListingRegistry(admin, authority, TIMELOCK_DELAY);
        factory = registry.factory();
        listingAuthorityRole = registry.LISTING_AUTHORITY_ROLE();
        usdt = new MockUSDT();
        distributor = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, 2_000);
        settlement = new NiaraSettlement(admin, address(distributor), address(registry), address(usdt), TIMELOCK_DELAY);
        _wireListingFee(registry, distributor, address(settlement), admin);

        equity = _submitNew(IListingRegistry.AssetClass.Equity);
        usdt.mint(issuer, 10 * FEE);
        vm.prank(issuer);
        usdt.approve(address(registry), type(uint256).max);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────────────

    function _submitNew(IListingRegistry.AssetClass assetClass) internal returns (NativeAssetToken token) {
        vm.prank(issuer);
        token = NativeAssetToken(factory.createAssetToken("Acme", "ACME", assetClass, DOC_HASH));
        vm.prank(issuer);
        registry.submitListing(address(token));
    }

    function _quote(address token, uint256 valuation, uint16 bps, uint64 expiresAt) internal {
        vm.prank(authority);
        registry.quoteListing(token, valuation, bps, expiresAt);
    }

    function _quoteDefault(address token) internal returns (uint64 expiresAt) {
        expiresAt = uint64(block.timestamp + 7 days);
        _quote(token, VALUATION, BPS, expiresAt);
    }

    function _pay(address token) internal {
        vm.prank(issuer);
        registry.payListingFee(token);
    }

    function _status(address token) internal view returns (IListingRegistry.ListingStatus) {
        return registry.getListing(token).status;
    }

    function _listCurrency(address token) internal {
        vm.prank(authority);
        registry.listCurrency(token);
    }

    /// @dev Switches the settlement's fee token through its timelock.
    function _useFeeToken(address token) internal {
        vm.prank(admin);
        settlement.proposeSetFeeToken(token);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeSetFeeToken(token);
    }

    function _selectorOf(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }

    function _ceil(uint256 valuation, uint16 bps) internal pure returns (uint256) {
        return (valuation * bps + 9_999) / 10_000;
    }

    // ── Quote then pay, for each issuer class ──────────────────────────────────────────

    function test_QuoteAndPay_Equity() public {
        _quoteAndPayAndCheck(equity);
    }

    function test_QuoteAndPay_FixedIncome() public {
        _quoteAndPayAndCheck(_submitNew(IListingRegistry.AssetClass.FixedIncome));
    }

    function test_QuoteAndPay_Credit() public {
        _quoteAndPayAndCheck(_submitNew(IListingRegistry.AssetClass.Credit));
    }

    function _quoteAndPayAndCheck(NativeAssetToken token) internal {
        address t = address(token);
        uint64 expiresAt = uint64(block.timestamp + 7 days);

        vm.expectEmit(true, true, false, true, address(registry));
        emit ListingRegistry.ListingQuoted(t, address(usdt), VALUATION, BPS, FEE, expiresAt);
        _quote(t, VALUATION, BPS, expiresAt);

        ListingRegistry.ListingFeeQuote memory quote = registry.getListingFeeQuote(t);
        assertEq(quote.valuation, VALUATION);
        assertEq(quote.listingFeeBps, BPS);
        assertEq(quote.listingFee, FEE);
        assertEq(quote.listingFeeToken, address(usdt));
        assertEq(quote.quoteExpiresAt, expiresAt);
        assertEq(quote.listingFeePaid, 0);
        assertEq(uint8(_status(t)), uint8(IListingRegistry.ListingStatus.Quoted));
        assertFalse(registry.isApproved(t));

        uint256 issuerBefore = usdt.balanceOf(issuer);
        vm.expectEmit(true, true, true, true, address(registry));
        emit ListingRegistry.ListingFeePaid(t, issuer, address(usdt), VALUATION, BPS, FEE);
        vm.expectEmit(true, true, false, true, address(registry));
        emit ListingRegistry.ListingApproved(
            t, issuer, registry.getListing(t).assetClass, true, DOC_HASH, uint64(block.timestamp)
        );
        vm.expectEmit(true, true, false, true, address(distributor));
        emit CashbackDistributor.ListingFeeRecorded(t, address(usdt), FEE);
        _pay(t);

        assertTrue(registry.isApproved(t));
        assertEq(registry.getListing(t).approvedAt, uint64(block.timestamp));
        assertEq(registry.getListingFeeQuote(t).listingFeePaid, FEE);
        assertEq(usdt.balanceOf(issuer), issuerBefore - FEE);
        assertEq(usdt.balanceOf(address(registry)), 0, "the registry never holds the fee");
        assertEq(usdt.balanceOf(address(distributor)), FEE);
        assertEq(distributor.protocolBalance(address(usdt)), FEE);
        assertEq(distributor.listingFeesCollected(address(usdt)), FEE);
        // Protocol revenue only: no cashback share, although the listing is eligible.
        assertTrue(registry.getListing(t).cashbackEligible);
        assertEq(distributor.cashbackBalance(t, address(usdt)), 0);
    }

    /// @notice Paying emits exactly ListingFeePaid then ListingApproved, both before the fee
    /// token's Transfer (checks-effects-interactions), then the distributor's record.
    function test_PayListingFee_EmitsListingFeePaidBeforeExternalTransfer() public {
        _quoteDefault(address(equity));
        vm.recordLogs();
        _pay(address(equity));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 feePaidSig = keccak256("ListingFeePaid(address,address,address,uint256,uint16,uint256)");
        bytes32 approvedSig = keccak256("ListingApproved(address,address,uint8,bool,bytes32,uint64)");
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        bytes32 recordedSig = keccak256("ListingFeeRecorded(address,address,uint256)");
        uint256 feePaidIdx = type(uint256).max;
        uint256 approvedIdx = type(uint256).max;
        uint256 transferIdx = type(uint256).max;
        uint256 recordedIdx = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 sig = logs[i].topics[0];
            if (sig == feePaidSig && feePaidIdx == type(uint256).max) feePaidIdx = i;
            if (sig == approvedSig && approvedIdx == type(uint256).max) approvedIdx = i;
            if (sig == transferSig && transferIdx == type(uint256).max) transferIdx = i;
            if (sig == recordedSig && recordedIdx == type(uint256).max) recordedIdx = i;
        }
        assertLt(feePaidIdx, approvedIdx, "ListingFeePaid must precede ListingApproved");
        assertLt(approvedIdx, transferIdx, "ListingApproved must precede the fee Transfer");
        assertLt(transferIdx, recordedIdx, "the distributor records a fee already in its balance");
        assertLt(recordedIdx, logs.length);
    }

    // ── Rounding and bounds ────────────────────────────────────────────────────────────

    function test_QuoteListing_RoundsUp() public {
        _quote(address(equity), 10_001, 1, uint64(block.timestamp + 1));
        assertEq(registry.getListingFeeQuote(address(equity)).listingFee, 2); // 1.0001 -> 2
        _quote(address(equity), 10_000, 1, uint64(block.timestamp + 1));
        assertEq(registry.getListingFeeQuote(address(equity)).listingFee, 1); // exact
        _quote(address(equity), 1, 1, uint64(block.timestamp + 1));
        assertEq(registry.getListingFeeQuote(address(equity)).listingFee, 1); // never free
    }

    function test_QuoteListing_AtTheCap() public {
        _quote(address(equity), 1_000_001, 100, uint64(block.timestamp + 1));
        assertEq(registry.getListingFeeQuote(address(equity)).listingFee, 10_001); // 1% of 1,000,001, up
        assertEq(registry.MAX_LISTING_FEE_BPS(), 100);
    }

    function test_QuoteListing_RevertsAboveTheCap() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.InvalidListingFeeBps.selector, uint16(101)));
        registry.quoteListing(address(equity), VALUATION, 101, uint64(block.timestamp + 1));
    }

    function test_QuoteListing_RevertsForZeroRate() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.InvalidListingFeeBps.selector, uint16(0)));
        registry.quoteListing(address(equity), VALUATION, 0, uint64(block.timestamp + 1));
    }

    function test_QuoteListing_RevertsForZeroValuation() public {
        vm.prank(authority);
        vm.expectRevert(ListingRegistry.ZeroValuation.selector);
        registry.quoteListing(address(equity), 0, BPS, uint64(block.timestamp + 1));
    }

    /// @notice A huge valuation does not overflow: the product is taken at full width.
    function test_QuoteListing_HugeValuation() public {
        _quote(address(equity), type(uint256).max, 100, uint64(block.timestamp + 1));
        assertEq(registry.getListingFeeQuote(address(equity)).listingFee, type(uint256).max / 100 + 1);
    }

    /// @notice Every in-bounds quote stores `ceil(valuation * bps / 10_000)`, between 1 and
    /// the valuation's 1% rounded up; every out-of-bounds one reverts with its exact error.
    function testFuzz_QuoteListing_OutcomeIsPredicted(uint256 valuation, uint16 bps, uint64 offset) public {
        valuation = bound(valuation, 0, type(uint128).max);
        bps = uint16(bound(bps, 0, 200));
        offset = uint64(bound(offset, 0, 31 days));
        uint64 expiresAt = uint64(block.timestamp) + offset;

        vm.prank(authority);
        if (valuation == 0) {
            vm.expectRevert(ListingRegistry.ZeroValuation.selector);
        } else if (bps == 0 || bps > 100) {
            vm.expectRevert(abi.encodeWithSelector(ListingRegistry.InvalidListingFeeBps.selector, bps));
        } else if (offset == 0 || offset > 30 days) {
            vm.expectRevert(abi.encodeWithSelector(ListingRegistry.InvalidExpiry.selector, expiresAt));
        }
        registry.quoteListing(address(equity), valuation, bps, expiresAt);

        bool valid = valuation != 0 && bps != 0 && bps <= 100 && offset != 0 && offset <= 30 days;
        ListingRegistry.ListingFeeQuote memory quote = registry.getListingFeeQuote(address(equity));
        if (!valid) {
            assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Pending));
            assertEq(quote.listingFee, 0);
            return;
        }
        assertEq(quote.listingFee, _ceil(valuation, bps));
        assertGe(quote.listingFee, 1);
        assertLe(quote.listingFee, (valuation + 99) / 100);
        assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Quoted));
    }

    // ── Expiry ─────────────────────────────────────────────────────────────────────────

    function test_QuoteListing_ExpiryWindowBoundaries() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.InvalidExpiry.selector, uint64(block.timestamp)));
        registry.quoteListing(address(equity), VALUATION, BPS, uint64(block.timestamp));

        uint64 tooLate = uint64(block.timestamp + 30 days + 1);
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.InvalidExpiry.selector, tooLate));
        registry.quoteListing(address(equity), VALUATION, BPS, tooLate);

        _quote(address(equity), VALUATION, BPS, uint64(block.timestamp + 1));
        _quote(address(equity), VALUATION, BPS, uint64(block.timestamp + 30 days));
        assertEq(registry.getListingFeeQuote(address(equity)).quoteExpiresAt, uint64(block.timestamp + 30 days));
        assertEq(registry.MAX_QUOTE_DURATION(), 30 days);
    }

    function test_PayListingFee_PayableUntilOneSecondBeforeExpiry() public {
        uint64 expiresAt = _quoteDefault(address(equity));
        vm.warp(expiresAt - 1);
        _pay(address(equity));
        assertTrue(registry.isApproved(address(equity)));
    }

    function test_PayListingFee_RevertsAtExpiry() public {
        uint64 expiresAt = _quoteDefault(address(equity));
        vm.warp(expiresAt);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.QuoteExpired.selector, address(equity), expiresAt));
        registry.payListingFee(address(equity));
        assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Quoted));
    }

    // ── Re-quoting ─────────────────────────────────────────────────────────────────────

    /// @notice A re-quote replaces every field, also after the first quote expired, and the
    /// payment takes the new fee.
    function test_QuoteListing_RequoteAfterExpiryReplacesEveryField() public {
        uint64 firstExpiry = _quoteDefault(address(equity));
        vm.warp(firstExpiry + 1);

        uint64 secondExpiry = uint64(block.timestamp + 1 days);
        _quote(address(equity), 4_000_000e6, 100, secondExpiry);
        ListingRegistry.ListingFeeQuote memory quote = registry.getListingFeeQuote(address(equity));
        assertEq(quote.valuation, 4_000_000e6);
        assertEq(quote.listingFeeBps, 100);
        assertEq(quote.listingFee, 40_000e6);
        assertEq(quote.quoteExpiresAt, secondExpiry);

        usdt.mint(issuer, 40_000e6);
        uint256 before = usdt.balanceOf(issuer);
        _pay(address(equity));
        assertEq(before - usdt.balanceOf(issuer), 40_000e6);
        assertEq(registry.getListingFeeQuote(address(equity)).listingFeePaid, 40_000e6);
    }

    // ── Signers ────────────────────────────────────────────────────────────────────────

    function test_QuoteListing_OnlyListingAuthority() public {
        address[3] memory callers = [issuer, admin, stranger];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], listingAuthorityRole
                )
            );
            registry.quoteListing(address(equity), VALUATION, BPS, uint64(block.timestamp + 1));
        }
    }

    function test_PayListingFee_OnlyIssuer() public {
        _quoteDefault(address(equity));
        address[3] memory callers = [authority, admin, stranger];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(ListingRegistry.NotIssuer.selector);
            registry.payListingFee(address(equity));
        }
    }

    /// @notice After the listing authority is rotated (timelocked grant and revoke), only the
    /// new one can quote.
    function test_QuoteListing_FollowsARotatedListingAuthority() public {
        address newAuthority = makeAddr("newAuthority");
        vm.startPrank(admin);
        registry.proposeGrantRole(listingAuthorityRole, newAuthority);
        registry.proposeRevokeRole(listingAuthorityRole, authority);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        registry.executeGrantRole(listingAuthorityRole, newAuthority);
        registry.executeRevokeRole(listingAuthorityRole, authority);
        vm.stopPrank();

        vm.prank(authority);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, authority, listingAuthorityRole)
        );
        registry.quoteListing(address(equity), VALUATION, BPS, uint64(block.timestamp + 1));

        vm.prank(newAuthority);
        registry.quoteListing(address(equity), VALUATION, BPS, uint64(block.timestamp + 1));
        assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Quoted));
    }

    // ── Currency listings ──────────────────────────────────────────────────────────────

    /// @notice A Currency listing has no listing fee, in every status it can have.
    function test_QuoteListing_RevertsForCurrencyInEveryStatus() public {
        _listCurrency(address(usdt));
        _expectCurrencyQuoteReverts(address(usdt)); // Approved
        vm.prank(authority);
        registry.suspendListing(address(usdt));
        _expectCurrencyQuoteReverts(address(usdt)); // Suspended
        vm.prank(authority);
        registry.delist(address(usdt));
        _expectCurrencyQuoteReverts(address(usdt)); // Delisted
        assertEq(registry.getListingFeeQuote(address(usdt)).listingFee, 0);
    }

    function _expectCurrencyQuoteReverts(address token) internal {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.CurrencyHasNoListingFee.selector, token));
        registry.quoteListing(token, VALUATION, BPS, uint64(block.timestamp + 1));
    }

    /// @notice Nobody can pay a listing fee for a Currency listing: it has no issuer.
    function test_PayListingFee_RevertsForCurrency() public {
        _listCurrency(address(usdt));
        vm.prank(issuer);
        vm.expectRevert(ListingRegistry.NotIssuer.selector);
        registry.payListingFee(address(usdt));
    }

    /// @notice Reinstating a suspended Currency listing is still allowed and free.
    function test_ApproveListing_ReinstatesSuspendedCurrencyForFree() public {
        _listCurrency(address(usdt));
        vm.prank(authority);
        registry.suspendListing(address(usdt));
        vm.prank(authority);
        registry.approveListing(address(usdt));
        assertTrue(registry.isApproved(address(usdt)));
        assertEq(distributor.listingFeesCollected(address(usdt)), 0);
    }

    // ── Status rules ───────────────────────────────────────────────────────────────────

    function test_QuoteListing_RevertsWithoutListing() public {
        address unknown = makeAddr("unknown");
        vm.prank(authority);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListingRegistry.InvalidStatusTransition.selector, unknown, IListingRegistry.ListingStatus.None
            )
        );
        registry.quoteListing(unknown, VALUATION, BPS, uint64(block.timestamp + 1));
    }

    /// @notice Once paid, the listing never returns to Quoted: no new quote (Approved,
    /// Suspended or Delisted) and no second payment.
    function test_PaidListing_CannotBeQuotedOrPaidAgain() public {
        _quoteDefault(address(equity));
        _pay(address(equity));

        _expectQuoteTransitionRevert(IListingRegistry.ListingStatus.Approved);
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListingRegistry.ListingNotQuoted.selector, address(equity), IListingRegistry.ListingStatus.Approved
            )
        );
        registry.payListingFee(address(equity));

        vm.prank(authority);
        registry.suspendListing(address(equity));
        _expectQuoteTransitionRevert(IListingRegistry.ListingStatus.Suspended);
        // Reinstatement is free.
        vm.prank(authority);
        registry.approveListing(address(equity));
        vm.prank(authority);
        registry.delist(address(equity));
        _expectQuoteTransitionRevert(IListingRegistry.ListingStatus.Delisted);

        assertEq(distributor.listingFeesCollected(address(usdt)), FEE, "paid exactly once");
        assertEq(usdt.balanceOf(issuer), 9 * FEE);
    }

    function _expectQuoteTransitionRevert(IListingRegistry.ListingStatus from) internal {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.InvalidStatusTransition.selector, address(equity), from));
        registry.quoteListing(address(equity), VALUATION, BPS, uint64(block.timestamp + 1));
    }

    function test_PayListingFee_RevertsWithoutQuote() public {
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListingRegistry.ListingNotQuoted.selector, address(equity), IListingRegistry.ListingStatus.Pending
            )
        );
        registry.payListingFee(address(equity));
    }

    /// @notice Rejecting a quoted listing is `delist`: final, and the quote can no longer be
    /// paid.
    function test_Delist_RejectsQuotedListing() public {
        _quoteDefault(address(equity));
        vm.prank(authority);
        registry.delist(address(equity));
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListingRegistry.ListingNotQuoted.selector, address(equity), IListingRegistry.ListingStatus.Delisted
            )
        );
        registry.payListingFee(address(equity));
        assertEq(usdt.balanceOf(address(distributor)), 0);
    }

    /// @notice The `approveListing` bypass is closed for Pending and Quoted listings.
    function test_ApproveListing_CannotBypassTheFee() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.ListingFeeNotPaid.selector, address(equity)));
        registry.approveListing(address(equity));
        _quoteDefault(address(equity));
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.ListingFeeNotPaid.selector, address(equity)));
        registry.approveListing(address(equity));
        assertFalse(registry.isApproved(address(equity)));
    }

    // ── Source of funds ────────────────────────────────────────────────────────────────

    function test_PayListingFee_RevertsWithoutAllowance() public {
        _quoteDefault(address(equity));
        vm.prank(issuer);
        usdt.approve(address(registry), FEE - 1);
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), FEE - 1, FEE)
        );
        registry.payListingFee(address(equity));
        assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Quoted));
    }

    function test_PayListingFee_RevertsWithoutBalance() public {
        _quote(address(equity), VALUATION * 100, BPS, uint64(block.timestamp + 1));
        uint256 fee = registry.getListingFeeQuote(address(equity)).listingFee;
        uint256 balance = usdt.balanceOf(issuer);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, issuer, balance, fee));
        registry.payListingFee(address(equity));
        assertEq(registry.getListingFeeQuote(address(equity)).listingFeePaid, 0);
    }

    /// @notice A fee token that delivers less than the fee reverts the whole payment.
    function test_PayListingFee_RevertsForFeeOnTransferToken() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken(100); // 1% burned in flight
        _useFeeToken(address(fot));
        _quoteDefault(address(equity));
        fot.mint(issuer, FEE);
        vm.prank(issuer);
        fot.approve(address(registry), FEE);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(ListingRegistry.TransferAmountMismatch.selector, address(fot), FEE, FEE - FEE / 100)
        );
        registry.payListingFee(address(equity));
    }

    /// @notice A fee token that leaves the distributor with less than before also reverts.
    function test_PayListingFee_RevertsWhenDistributorBalanceDecreases() public {
        MockFeeOnTransferToken shrink = new MockFeeOnTransferToken(0);
        shrink.setDrainReceiver(true);
        _useFeeToken(address(shrink));
        _quoteDefault(address(equity));
        shrink.mint(issuer, FEE);
        shrink.mint(address(distributor), 1);
        vm.prank(issuer);
        shrink.approve(address(registry), FEE);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.TransferAmountMismatch.selector, address(shrink), FEE, 0));
        registry.payListingFee(address(equity));
    }

    // ── Fee token ──────────────────────────────────────────────────────────────────────

    /// @notice The quote records the fee token in force when it was made; after a timelocked
    /// fee-token switch it can no longer be paid, until the listing authority re-quotes.
    function test_FeeTokenSwitch_VoidsAnOpenQuoteUntilRequoted() public {
        _quote(address(equity), VALUATION, BPS, uint64(block.timestamp + 30 days));
        MockUSDT newUsdt = new MockUSDT();
        _useFeeToken(address(newUsdt));

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.NotFeeToken.selector, address(usdt), address(newUsdt)));
        registry.payListingFee(address(equity));

        _quoteDefault(address(equity));
        assertEq(registry.getListingFeeQuote(address(equity)).listingFeeToken, address(newUsdt));
        newUsdt.mint(issuer, FEE);
        vm.prank(issuer);
        newUsdt.approve(address(registry), FEE);
        _pay(address(equity));
        assertEq(distributor.listingFeesCollected(address(newUsdt)), FEE);
        assertEq(distributor.listingFeesCollected(address(usdt)), 0);
        assertEq(usdt.balanceOf(issuer), 10 * FEE, "nothing taken in the old token");
    }

    // ── Pause ──────────────────────────────────────────────────────────────────────────

    /// @notice Quoting is a listing action and works while paused; paying is blocked until
    /// the unpause.
    function test_Pause_QuoteAllowedPayBlocked() public {
        vm.prank(admin);
        registry.pause();
        _quoteDefault(address(equity));

        vm.prank(issuer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.payListingFee(address(equity));

        vm.prank(admin);
        registry.unpause();
        _pay(address(equity));
        assertTrue(registry.isApproved(address(equity)));
    }

    // ── Settlement link (timelocked) ───────────────────────────────────────────────────

    function test_QuoteListing_RevertsWhileSettlementNotSet() public {
        ListingRegistry fresh = new ListingRegistry(admin, authority, TIMELOCK_DELAY);
        AssetTokenFactory freshFactory = fresh.factory();
        vm.prank(issuer);
        address token = freshFactory.createAssetToken("Acme", "ACME", IListingRegistry.AssetClass.Equity, DOC_HASH);
        vm.prank(issuer);
        fresh.submitListing(token);
        assertEq(address(fresh.settlement()), address(0));

        vm.prank(authority);
        vm.expectRevert(ListingRegistry.SettlementNotSet.selector);
        fresh.quoteListing(token, VALUATION, BPS, uint64(block.timestamp + 1));
    }

    function test_SetSettlement_GoesThroughTheTimelock() public {
        ListingRegistry fresh = new ListingRegistry(admin, authority, TIMELOCK_DELAY);
        NiaraSettlement linked =
            new NiaraSettlement(admin, address(distributor), address(fresh), address(usdt), TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, true, address(fresh));
        emit ListingRegistry.SettlementChangeProposed(address(linked), block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        uint256 executeAfter = fresh.proposeSetSettlement(address(linked));
        assertEq(executeAfter, block.timestamp + TIMELOCK_DELAY);

        bytes32 actionId = keccak256(abi.encode("SET_SETTLEMENT", address(linked)));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAccessControl.TimelockNotElapsed.selector, actionId, executeAfter)
        );
        fresh.executeSetSettlement(address(linked));

        vm.warp(executeAfter);
        vm.expectEmit(true, true, false, true, address(fresh));
        emit ListingRegistry.SettlementChanged(address(0), address(linked));
        vm.prank(admin);
        fresh.executeSetSettlement(address(linked));
        assertEq(address(fresh.settlement()), address(linked));
    }

    function test_ExecuteSetSettlement_RevertsWithoutProposal() public {
        NiaraSettlement other =
            new NiaraSettlement(admin, address(distributor), address(registry), address(usdt), TIMELOCK_DELAY);
        bytes32 actionId = keccak256(abi.encode("SET_SETTLEMENT", address(other)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionNotPending.selector, actionId));
        registry.executeSetSettlement(address(other));
    }

    function test_SetSettlement_OnlyAdmin() public {
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        vm.prank(authority);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, authority, adminRole)
        );
        registry.proposeSetSettlement(address(settlement));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        registry.executeSetSettlement(address(settlement));
    }

    function test_SetSettlement_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ListingRegistry.ZeroAddress.selector);
        registry.proposeSetSettlement(address(0));
        vm.prank(admin);
        vm.expectRevert(ListingRegistry.ZeroAddress.selector);
        registry.executeSetSettlement(address(0));
    }

    /// @notice A settlement built for another registry is refused, at both steps.
    function test_SetSettlement_RevertsForSettlementOfAnotherRegistry() public {
        ListingRegistry other = new ListingRegistry(admin, authority, TIMELOCK_DELAY);
        NiaraSettlement foreign =
            new NiaraSettlement(admin, address(distributor), address(other), address(usdt), TIMELOCK_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.SettlementRegistryMismatch.selector, address(foreign)));
        registry.proposeSetSettlement(address(foreign));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.SettlementRegistryMismatch.selector, address(foreign)));
        registry.executeSetSettlement(address(foreign));
    }

    /// @notice The fee follows the settlement's current CashbackDistributor: after a
    /// timelocked distributor switch, listing fees land in the new one.
    function test_PayListingFee_GoesToTheCurrentDistributor() public {
        CashbackDistributor newDistributor =
            new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY, 2_000);
        bytes32 role = newDistributor.LISTING_REGISTRY_ROLE();
        vm.startPrank(admin);
        settlement.proposeSetCashbackDistributor(address(newDistributor));
        newDistributor.proposeGrantRole(role, address(registry));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        settlement.executeSetCashbackDistributor(address(newDistributor));
        newDistributor.executeGrantRole(role, address(registry));
        vm.stopPrank();

        _quoteDefault(address(equity));
        _pay(address(equity));
        assertEq(usdt.balanceOf(address(newDistributor)), FEE);
        assertEq(newDistributor.listingFeesCollected(address(usdt)), FEE);
        assertEq(usdt.balanceOf(address(distributor)), 0);
    }

    /// @notice Without LISTING_REGISTRY_ROLE on the distributor, the whole payment reverts:
    /// the fee is never left unaccounted.
    function test_PayListingFee_RevertsWithoutDistributorRole() public {
        bytes32 role = distributor.LISTING_REGISTRY_ROLE();
        vm.startPrank(admin);
        distributor.proposeRevokeRole(role, address(registry));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        distributor.executeRevokeRole(role, address(registry));
        vm.stopPrank();

        _quoteDefault(address(equity));
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(registry), role)
        );
        registry.payListingFee(address(equity));
        assertEq(uint8(_status(address(equity))), uint8(IListingRegistry.ListingStatus.Quoted));
        assertEq(usdt.balanceOf(address(distributor)), 0);
    }

    // ── Hostile fee token: reentrancy ──────────────────────────────────────────────────

    function _hookFeeToken() internal returns (MaliciousHookToken evil) {
        evil = new MaliciousHookToken();
        _useFeeToken(address(evil));
        _quoteDefault(address(equity));
        evil.mint(issuer, FEE);
        vm.prank(issuer);
        evil.approve(address(registry), FEE);
    }

    /// @notice A fee token that re-enters `payListingFee` from its transfer hook dies at the
    /// guard (the first modifier), so the fee is paid once.
    function test_PayListingFee_Reentrancy_RevertsViaGuard() public {
        MaliciousHookToken evil = _hookFeeToken();
        evil.armOnTransferFrom(address(registry), abi.encodeCall(ListingRegistry.payListingFee, (address(equity))));
        _pay(address(equity));

        assertTrue(evil.reentered());
        assertFalse(evil.reentrantSucceeded());
        assertEq(_selectorOf(evil.reentrantReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(distributor.listingFeesCollected(address(evil)), FEE);
        assertEq(evil.balanceOf(address(distributor)), FEE);
    }

    /// @notice Checks-effects-interactions: what a re-entry sees during the transfer is the
    /// listing already Approved and the fee already marked paid.
    function test_PayListingFee_HookSeesListingAlreadyApprovedAndPaid() public {
        MaliciousHookToken evil = _hookFeeToken();
        evil.armOnTransferFrom(address(registry), abi.encodeCall(ListingRegistry.getListingFeeQuote, (address(equity))));
        _pay(address(equity));
        assertTrue(evil.reentrantSucceeded());
        ListingRegistry.ListingFeeQuote memory seen =
            abi.decode(evil.reentrantReturnData(), (ListingRegistry.ListingFeeQuote));
        assertEq(seen.listingFeePaid, FEE);

        MaliciousHookToken evil2 = new MaliciousHookToken();
        NativeAssetToken bond = _submitNew(IListingRegistry.AssetClass.FixedIncome);
        _useFeeToken(address(evil2));
        _quoteDefault(address(bond));
        evil2.mint(issuer, FEE);
        vm.prank(issuer);
        evil2.approve(address(registry), FEE);
        evil2.armOnTransferFrom(address(registry), abi.encodeCall(ListingRegistry.isApproved, (address(bond))));
        _pay(address(bond));
        assertTrue(evil2.reentrantSucceeded());
        assertTrue(abi.decode(evil2.reentrantReturnData(), (bool)));
    }

    // ── Where the fee goes ─────────────────────────────────────────────────────────────

    /// @notice The treasury can withdraw listing fees (protocol revenue), and they never
    /// touch issuers' cashback.
    function test_Treasury_WithdrawsListingFeesNeverCashback() public {
        _quoteDefault(address(equity));
        _pay(address(equity));
        // Some cashback accrued from a trading fee, on top of the listing fee.
        bytes32 settlementRole = distributor.SETTLEMENT_ROLE();
        address settlementCaller = makeAddr("settlementCaller");
        vm.startPrank(admin);
        distributor.proposeGrantRole(settlementRole, settlementCaller);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        distributor.executeGrantRole(settlementRole, settlementCaller);
        vm.stopPrank();
        usdt.mint(address(distributor), 1_000e6);
        vm.prank(settlementCaller);
        distributor.recordFee(address(equity), address(usdt), 1_000e6);
        uint256 cashback = distributor.cashbackBalance(address(equity), address(usdt));
        assertEq(cashback, 200e6);
        assertEq(distributor.protocolBalance(address(usdt)), FEE + 800e6);

        vm.prank(admin);
        distributor.withdrawProtocolFees(address(usdt), sink, FEE + 800e6);
        assertEq(usdt.balanceOf(sink), FEE + 800e6);
        assertEq(usdt.balanceOf(address(distributor)), cashback, "only the cashback is left");

        vm.prank(admin);
        vm.expectRevert(CashbackDistributor.InvalidWithdrawAmount.selector);
        distributor.withdrawProtocolFees(address(usdt), sink, 1);

        vm.prank(issuer);
        distributor.withdraw(address(equity), address(usdt));
        assertEq(usdt.balanceOf(address(distributor)), 0);
        assertEq(distributor.listingFeesCollected(address(usdt)), FEE, "historical, never decreases");
    }

    /// @notice Issuance batches charge no listing fee: one fee per listing, not per batch.
    function test_IssuanceBatches_ChargeNoListingFee() public {
        _quoteDefault(address(equity));
        _pay(address(equity));
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(issuer);
            uint256 batchNo = registry.requestIssuance(address(equity), 1 ether, issuer, DOC_HASH);
            vm.prank(authority);
            registry.approveIssuance(address(equity), batchNo);
        }
        assertEq(equity.totalSupply(), 3 ether);
        assertEq(distributor.listingFeesCollected(address(usdt)), FEE);
        assertEq(usdt.balanceOf(issuer), 9 * FEE);
    }
}

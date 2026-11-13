// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {P2PEscrow} from "../src/P2PEscrow.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockFeeOnTransferToken} from "./mocks/MockFeeOnTransferToken.sol";
import {MaliciousHookToken} from "./mocks/MaliciousHookToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Unit tests of P2PEscrow, the EVM mirror of the Solana deals. `alice` is the
/// proposer and `bob` the named counterparty unless a test says otherwise.
contract P2PEscrowTest is Test {
    P2PEscrow public escrow;
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    ListingRegistry public registry;
    NativeAssetToken public bond;
    NativeAssetToken public credit;
    NativeAssetToken public equity;
    MockUSDT public usdt;
    MockUSDT public brl;
    MockUSDT public eur;

    address public admin = makeAddr("admin");
    address public listingAuthority = makeAddr("listingAuthority");
    address public issuer = makeAddr("issuer");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public sink = makeAddr("sink");

    uint256 public constant TIMELOCK_DELAY = 2 days;
    bytes32 public constant DOC_HASH = keccak256("offering-document");
    bytes16 public constant DEAL_ID = bytes16(keccak256("deal-0001"));

    uint256 public constant NATIVE_START = 1_000 ether;
    uint256 public constant CURRENCY_START = 1_000_000 ether;
    uint256 public constant ASSET_AMOUNT = 10 ether;
    uint256 public constant PAYMENT_AMOUNT = 1_000e6;
    /// @dev Default fee (50 bps) and cashback (10% of the fee) on PAYMENT_AMOUNT.
    uint256 public constant FEE = 5e6;
    uint256 public constant CASHBACK = 5e5;
    uint64 public constant LIFETIME = 7 days;

    bytes32 public treasuryRole;
    bytes32 public escrowRole;

    P2PEscrow.DealSide internal constant SELL = P2PEscrow.DealSide.Sell;
    P2PEscrow.DealSide internal constant BUY = P2PEscrow.DealSide.Buy;

    function setUp() public {
        registry = new ListingRegistry(admin, listingAuthority, TIMELOCK_DELAY);
        distributor = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY);
        usdt = new MockUSDT();
        brl = new MockUSDT();
        eur = new MockUSDT();
        settlement =
            new NiaraSettlement(admin, address(distributor), address(registry), address(usdt), TIMELOCK_DELAY);
        escrow = new P2PEscrow(admin, address(settlement), address(registry), TIMELOCK_DELAY);

        treasuryRole = escrow.TREASURY_ROLE();
        escrowRole = distributor.ESCROW_ROLE();
        _distributorGrantRole(distributor, escrowRole, address(escrow));

        bond = _issueListedNative(IListingRegistry.AssetClass.FixedIncome);
        credit = _issueListedNative(IListingRegistry.AssetClass.Credit);
        equity = _issueListedNative(IListingRegistry.AssetClass.Equity);

        _listCurrency(address(usdt));
        _listCurrency(address(brl));
        _listCurrency(address(eur));

        address[3] memory currencies = [address(usdt), address(brl), address(eur)];
        address[3] memory natives = [address(bond), address(credit), address(equity)];
        address[2] memory parties = [alice, bob];
        for (uint256 p = 0; p < parties.length; p++) {
            for (uint256 i = 0; i < currencies.length; i++) {
                MockUSDT(currencies[i]).mint(parties[p], CURRENCY_START);
                vm.prank(parties[p]);
                IERC20(currencies[i]).approve(address(escrow), type(uint256).max);
            }
            for (uint256 i = 0; i < natives.length; i++) {
                vm.prank(parties[p]);
                IERC20(natives[i]).approve(address(escrow), type(uint256).max);
            }
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────────────────

    function _distributorGrantRole(CashbackDistributor target, bytes32 role, address account) internal {
        vm.prank(admin);
        target.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        target.executeGrantRole(role, account);
    }

    /// @dev A listed, approved native instrument with NATIVE_START issued to alice and bob.
    function _issueListedNative(IListingRegistry.AssetClass assetClass) internal returns (NativeAssetToken token) {
        // Resolved before the prank: `registry.factory()` is an external call and would
        // consume it (see the note at the top of test/AssetToken.t.sol).
        AssetTokenFactory factory = registry.factory();
        vm.prank(issuer);
        token = NativeAssetToken(factory.createAssetToken("Instrument", "INST", assetClass, DOC_HASH));
        vm.prank(issuer);
        registry.submitListing(address(token));
        vm.prank(listingAuthority);
        registry.approveListing(address(token));
        address[2] memory holders = [alice, bob];
        for (uint256 i = 0; i < holders.length; i++) {
            vm.prank(issuer);
            uint256 batchNo = registry.requestIssuance(address(token), NATIVE_START, holders[i], DOC_HASH);
            vm.prank(listingAuthority);
            registry.approveIssuance(address(token), batchNo);
        }
    }

    function _listCurrency(address token) internal {
        vm.prank(listingAuthority);
        registry.listCurrency(token);
    }

    function _suspend(address token) internal {
        vm.prank(listingAuthority);
        registry.suspendListing(token);
    }

    function _delist(address token) internal {
        vm.prank(listingAuthority);
        registry.delist(token);
    }

    function _pause() internal {
        vm.prank(admin);
        registry.pause();
    }

    function _setFeeBps(uint16 newFeeBps) internal {
        vm.prank(admin);
        settlement.proposeSetFeeBps(newFeeBps);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeSetFeeBps(newFeeBps);
    }

    function _setCashbackBps(uint16 newCashbackBps) internal {
        vm.prank(admin);
        distributor.proposeSetCashbackBps(newCashbackBps);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        distributor.executeSetCashbackBps(newCashbackBps);
    }

    function _useFeeToken(address token) internal {
        vm.prank(admin);
        settlement.proposeSetFeeToken(token);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeSetFeeToken(token);
    }

    /// @dev Terms with bob as counterparty and the default amounts.
    function _terms(address assetToken, address paymentToken, P2PEscrow.DealSide side)
        internal
        view
        returns (P2PEscrow.DealTerms memory)
    {
        return P2PEscrow.DealTerms({
            counterparty: bob,
            assetToken: assetToken,
            paymentToken: paymentToken,
            proposerSide: side,
            assetAmount: ASSET_AMOUNT,
            paymentAmount: PAYMENT_AMOUNT
        });
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp) + LIFETIME;
    }

    /// @dev alice opens `terms` under `dealId`, expiring LIFETIME from now.
    function _open(bytes16 dealId, P2PEscrow.DealTerms memory terms) internal returns (bytes32 dealKey) {
        uint64 expiresAt = _expiry();
        vm.prank(alice);
        dealKey = escrow.openDeal(dealId, terms, expiresAt);
    }

    /// @dev alice sells ASSET_AMOUNT of the bond to bob for PAYMENT_AMOUNT USDT.
    function _openBondSale() internal returns (bytes32) {
        return _open(DEAL_ID, _terms(address(bond), address(usdt), SELL));
    }

    function _expectOpenRevert(P2PEscrow.DealTerms memory terms, bytes memory err) internal {
        uint64 expiresAt = _expiry();
        vm.prank(alice);
        vm.expectRevert(err);
        escrow.openDeal(DEAL_ID, terms, expiresAt);
    }

    function _status(bytes32 dealKey) internal view returns (P2PEscrow.DealStatus) {
        return escrow.getDeal(dealKey).status;
    }

    /// @dev Extracts the selector from raw return data (e.g. the error of a reverted call).
    function _selectorOf(bytes memory data) internal pure returns (bytes4 sel) {
        require(data.length >= 4, "return data has no selector");
        assembly {
            sel := mload(add(data, 32))
        }
    }

    /// @dev Asserts the log with `topic0` is the very first log and precedes every Transfer.
    function _assertEmittedBeforeTransfers(Vm.Log[] memory logs, bytes32 topic0) internal pure {
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        uint256 eventIndex = type(uint256).max;
        uint256 firstTransferIndex = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic0 && eventIndex == type(uint256).max) eventIndex = i;
            if (logs[i].topics[0] == transferTopic && firstTransferIndex == type(uint256).max) {
                firstTransferIndex = i;
            }
        }
        assertTrue(eventIndex != type(uint256).max, "event not emitted");
        assertTrue(firstTransferIndex != type(uint256).max, "no Transfer emitted");
        assertLt(eventIndex, firstTransferIndex);
        assertEq(eventIndex, 0);
    }

    /// @dev A hostile currency (hook token) listed as a Currency, funded and approved for
    /// alice: she can sell it for USDT, so it sits on the escrowed leg.
    function _listedHookCurrency() internal returns (MaliciousHookToken evil) {
        evil = new MaliciousHookToken();
        _listCurrency(address(evil));
        evil.mint(alice, CURRENCY_START);
        vm.prank(alice);
        evil.approve(address(escrow), type(uint256).max);
    }

    // ── Constructor and views ──────────────────────────────────────────────────────────

    function test_Constructor_SetsState() public view {
        assertEq(address(escrow.settlement()), address(settlement));
        assertEq(address(escrow.listingRegistry()), address(registry));
        assertTrue(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(escrow.hasRole(treasuryRole, admin));
        assertEq(escrow.timelockDelay(), TIMELOCK_DELAY);
        assertEq(escrow.MAX_DEAL_DURATION(), 30 days);
    }

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(P2PEscrow.ZeroAddress.selector);
        new P2PEscrow(address(0), address(settlement), address(registry), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroSettlement() public {
        vm.expectRevert(P2PEscrow.ZeroAddress.selector);
        new P2PEscrow(admin, address(0), address(registry), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroListingRegistry() public {
        vm.expectRevert(P2PEscrow.ZeroAddress.selector);
        new P2PEscrow(admin, address(settlement), address(0), TIMELOCK_DELAY);
    }

    /// @notice The escrow and NiaraSettlement must share one registry (one pause, one set of
    /// listings).
    function test_Constructor_RevertsForRegistryMismatch() public {
        ListingRegistry other = new ListingRegistry(admin, listingAuthority, TIMELOCK_DELAY);
        vm.expectRevert(P2PEscrow.RegistryMismatch.selector);
        new P2PEscrow(admin, address(settlement), address(other), TIMELOCK_DELAY);
    }

    function test_DealKeyOf_IsScopedToTheProposer() public view {
        assertEq(escrow.dealKeyOf(alice, DEAL_ID), keccak256(abi.encode(alice, DEAL_ID)));
        assertTrue(escrow.dealKeyOf(alice, DEAL_ID) != escrow.dealKeyOf(bob, DEAL_ID));
    }

    function test_GetDeal_ReturnsEmptyForUnknownKey() public view {
        P2PEscrow.Deal memory deal = escrow.getDeal(keccak256("unknown"));
        assertEq(uint8(deal.status), uint8(P2PEscrow.DealStatus.None));
        assertEq(deal.proposer, address(0));
    }

    /// @notice The escrow has no pause of its own: it only reads the registry's.
    function test_Pause_NoLocalPauseFunctions() public {
        vm.prank(admin);
        (bool pauseOk,) = address(escrow).call(abi.encodeWithSignature("pause()"));
        assertFalse(pauseOk);
        vm.prank(admin);
        (bool unpauseOk,) = address(escrow).call(abi.encodeWithSignature("unpause()"));
        assertFalse(unpauseOk);
    }

    function test_Paused_MirrorsRegistryPause() public {
        assertFalse(escrow.paused());
        _pause();
        assertTrue(escrow.paused());
    }

    // ── openDeal ───────────────────────────────────────────────────────────────────────

    function test_OpenDeal_SellEscrowsTheAsset() public {
        uint64 expiresAt = _expiry();
        bytes32 expectedKey = escrow.dealKeyOf(alice, DEAL_ID);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit P2PEscrow.DealOpened(
            expectedKey,
            DEAL_ID,
            alice,
            bob,
            address(bond),
            address(usdt),
            SELL,
            ASSET_AMOUNT,
            PAYMENT_AMOUNT,
            50,
            1_000,
            expiresAt
        );
        bytes32 dealKey = _openBondSale();

        assertEq(dealKey, expectedKey);
        assertEq(bond.balanceOf(address(escrow)), ASSET_AMOUNT);
        assertEq(bond.balanceOf(alice), NATIVE_START - ASSET_AMOUNT);
        assertEq(usdt.balanceOf(alice), CURRENCY_START);
        assertEq(escrow.totalEscrowed(address(bond)), ASSET_AMOUNT);
        assertEq(escrow.totalEscrowed(address(usdt)), 0);

        P2PEscrow.Deal memory deal = escrow.getDeal(dealKey);
        assertEq(deal.dealId, DEAL_ID);
        assertEq(deal.proposer, alice);
        assertEq(deal.counterparty, bob);
        assertEq(deal.assetToken, address(bond));
        assertEq(deal.paymentToken, address(usdt));
        assertEq(deal.assetAmount, ASSET_AMOUNT);
        assertEq(deal.paymentAmount, PAYMENT_AMOUNT);
        assertEq(deal.feeBps, 50);
        assertEq(deal.cashbackBps, 1_000);
        assertEq(uint8(deal.proposerSide), uint8(SELL));
        assertEq(uint8(deal.status), uint8(P2PEscrow.DealStatus.Open));
        assertEq(deal.expiresAt, expiresAt);
        assertEq(deal.openedAt, uint64(block.timestamp));
        assertEq(deal.resolvedAt, 0);
    }

    function test_OpenDeal_BuyEscrowsThePayment() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), BUY));

        assertEq(usdt.balanceOf(address(escrow)), PAYMENT_AMOUNT);
        assertEq(usdt.balanceOf(alice), CURRENCY_START - PAYMENT_AMOUNT);
        assertEq(bond.balanceOf(alice), NATIVE_START);
        assertEq(escrow.totalEscrowed(address(usdt)), PAYMENT_AMOUNT);
        assertEq(escrow.totalEscrowed(address(bond)), 0);
        assertEq(uint8(escrow.getDeal(dealKey).proposerSide), uint8(BUY));
    }

    function test_OpenDeal_RevertsForZeroDealId() public {
        uint64 expiresAt = _expiry();
        vm.prank(alice);
        vm.expectRevert(P2PEscrow.ZeroDealId.selector);
        escrow.openDeal(bytes16(0), _terms(address(bond), address(usdt), SELL), expiresAt);
    }

    function test_OpenDeal_RevertsForZeroAssetAmount() public {
        P2PEscrow.DealTerms memory terms = _terms(address(bond), address(usdt), SELL);
        terms.assetAmount = 0;
        _expectOpenRevert(terms, abi.encodeWithSelector(P2PEscrow.ZeroAmount.selector));
    }

    function test_OpenDeal_RevertsForZeroPaymentAmount() public {
        P2PEscrow.DealTerms memory terms = _terms(address(bond), address(usdt), SELL);
        terms.paymentAmount = 0;
        _expectOpenRevert(terms, abi.encodeWithSelector(P2PEscrow.ZeroAmount.selector));
    }

    /// @notice v1 has no open offers: the counterparty must be named.
    function test_OpenDeal_RevertsForZeroCounterparty() public {
        P2PEscrow.DealTerms memory terms = _terms(address(bond), address(usdt), SELL);
        terms.counterparty = address(0);
        _expectOpenRevert(terms, abi.encodeWithSelector(P2PEscrow.ZeroAddress.selector));
    }

    function test_OpenDeal_RevertsWhenCounterpartyIsTheProposer() public {
        P2PEscrow.DealTerms memory terms = _terms(address(bond), address(usdt), SELL);
        terms.counterparty = alice;
        _expectOpenRevert(terms, abi.encodeWithSelector(P2PEscrow.SelfTrade.selector));
    }

    function test_OpenDeal_RevertsWhenExpiryIsNow() public {
        uint64 expiresAt = uint64(block.timestamp);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.InvalidExpiry.selector, expiresAt));
        escrow.openDeal(DEAL_ID, _terms(address(bond), address(usdt), SELL), expiresAt);
    }

    function test_OpenDeal_RevertsWhenExpiryIsInThePast() public {
        uint64 expiresAt = uint64(block.timestamp) - 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.InvalidExpiry.selector, expiresAt));
        escrow.openDeal(DEAL_ID, _terms(address(bond), address(usdt), SELL), expiresAt);
    }

    function test_OpenDeal_RevertsWhenExpiryIsMoreThan30DaysAhead() public {
        uint64 expiresAt = uint64(block.timestamp) + 30 days + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.InvalidExpiry.selector, expiresAt));
        escrow.openDeal(DEAL_ID, _terms(address(bond), address(usdt), SELL), expiresAt);
    }

    function test_OpenDeal_AcceptsExpiryExactly30DaysAhead() public {
        uint64 expiresAt = uint64(block.timestamp) + 30 days;
        vm.prank(alice);
        bytes32 dealKey = escrow.openDeal(DEAL_ID, _terms(address(bond), address(usdt), SELL), expiresAt);
        assertEq(escrow.getDeal(dealKey).expiresAt, expiresAt);
    }

    function test_OpenDeal_AcceptsExpiryOneSecondAhead() public {
        uint64 expiresAt = uint64(block.timestamp) + 1;
        vm.prank(alice);
        bytes32 dealKey = escrow.openDeal(DEAL_ID, _terms(address(bond), address(usdt), SELL), expiresAt);
        assertEq(uint8(_status(dealKey)), uint8(P2PEscrow.DealStatus.Open));
    }

    function test_OpenDeal_RevertsForDealIdAlreadyOpen() public {
        bytes32 dealKey = _openBondSale();
        _expectOpenRevert(
            _terms(address(credit), address(usdt), SELL),
            abi.encodeWithSelector(P2PEscrow.DealAlreadyExists.selector, dealKey)
        );
    }

    /// @notice A deal is never deleted: its id cannot be reopened after it was resolved.
    function test_OpenDeal_RevertsForDealIdAlreadyResolved() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(alice);
        escrow.cancelDeal(dealKey);

        _expectOpenRevert(
            _terms(address(bond), address(usdt), SELL),
            abi.encodeWithSelector(P2PEscrow.DealAlreadyExists.selector, dealKey)
        );
    }

    /// @notice Ids are scoped to the proposer: bob can use the id alice used.
    function test_OpenDeal_SameDealIdFromAnotherProposer() public {
        bytes32 aliceKey = _openBondSale();
        P2PEscrow.DealTerms memory terms = _terms(address(bond), address(usdt), SELL);
        terms.counterparty = alice;
        uint64 expiresAt = _expiry();
        vm.prank(bob);
        bytes32 bobKey = escrow.openDeal(DEAL_ID, terms, expiresAt);

        assertTrue(aliceKey != bobKey);
        assertEq(escrow.totalEscrowed(address(bond)), 2 * ASSET_AMOUNT);
    }

    function test_OpenDeal_RevertsForSameToken() public {
        _expectOpenRevert(
            _terms(address(usdt), address(usdt), SELL), abi.encodeWithSelector(P2PEscrow.SameToken.selector)
        );
    }

    function test_OpenDeal_RevertsForUnlistedAsset() public {
        MockUSDT unlisted = new MockUSDT();
        _expectOpenRevert(
            _terms(address(unlisted), address(usdt), SELL),
            abi.encodeWithSelector(P2PEscrow.ListingNotApproved.selector, address(unlisted))
        );
    }

    function test_OpenDeal_RevertsForPendingAsset() public {
        AssetTokenFactory factory = registry.factory();
        vm.prank(issuer);
        address pending =
            factory.createAssetToken("Pending", "PND", IListingRegistry.AssetClass.FixedIncome, DOC_HASH);
        vm.prank(issuer);
        registry.submitListing(pending);

        _expectOpenRevert(
            _terms(pending, address(usdt), SELL), abi.encodeWithSelector(P2PEscrow.ListingNotApproved.selector, pending)
        );
    }

    function test_OpenDeal_RevertsForSuspendedAsset() public {
        _suspend(address(bond));
        _expectOpenRevert(
            _terms(address(bond), address(usdt), SELL),
            abi.encodeWithSelector(P2PEscrow.ListingNotApproved.selector, address(bond))
        );
    }

    function test_OpenDeal_RevertsForDelistedAsset() public {
        _delist(address(bond));
        _expectOpenRevert(
            _terms(address(bond), address(usdt), SELL),
            abi.encodeWithSelector(P2PEscrow.ListingNotApproved.selector, address(bond))
        );
    }

    /// @notice Trading mode is fixed by asset class: Equity trades on the order book only.
    function test_OpenDeal_RevertsForEquityAsset() public {
        _expectOpenRevert(
            _terms(address(equity), address(usdt), SELL),
            abi.encodeWithSelector(P2PEscrow.WrongTradingMode.selector, address(equity))
        );
    }

    function test_OpenDeal_RevertsForUnlistedPayment() public {
        MockUSDT unlisted = new MockUSDT();
        _expectOpenRevert(
            _terms(address(bond), address(unlisted), SELL),
            abi.encodeWithSelector(P2PEscrow.InvalidPaymentToken.selector, address(unlisted))
        );
    }

    function test_OpenDeal_RevertsForSuspendedPayment() public {
        _suspend(address(usdt));
        _expectOpenRevert(
            _terms(address(bond), address(usdt), SELL),
            abi.encodeWithSelector(P2PEscrow.InvalidPaymentToken.selector, address(usdt))
        );
    }

    function test_OpenDeal_RevertsForDelistedPayment() public {
        _delist(address(usdt));
        _expectOpenRevert(
            _terms(address(bond), address(usdt), SELL),
            abi.encodeWithSelector(P2PEscrow.InvalidPaymentToken.selector, address(usdt))
        );
    }

    /// @notice The payment must be a Currency: a bond cannot pay for a bond.
    function test_OpenDeal_RevertsForNonCurrencyPayment() public {
        _expectOpenRevert(
            _terms(address(bond), address(credit), SELL),
            abi.encodeWithSelector(P2PEscrow.InvalidPaymentToken.selector, address(credit))
        );
    }

    /// @notice Every deal has a USDT leg: a bond is paid in USDT, not in another currency.
    function test_OpenDeal_RevertsForFixedIncomeNotPaidInFeeToken() public {
        _expectOpenRevert(
            _terms(address(bond), address(brl), SELL), abi.encodeWithSelector(P2PEscrow.NotFeeToken.selector)
        );
    }

    function test_OpenDeal_RevertsForCreditNotPaidInFeeToken() public {
        _expectOpenRevert(
            _terms(address(credit), address(eur), BUY), abi.encodeWithSelector(P2PEscrow.NotFeeToken.selector)
        );
    }

    /// @notice A Currency deal needs exactly one USDT leg: BRL <-> EUR has none.
    function test_OpenDeal_RevertsForCurrencyDealWithoutFeeTokenLeg() public {
        _expectOpenRevert(
            _terms(address(brl), address(eur), SELL), abi.encodeWithSelector(P2PEscrow.NotFeeToken.selector)
        );
    }

    function test_OpenDeal_RevertsWhileProtocolPaused() public {
        _pause();
        _expectOpenRevert(
            _terms(address(bond), address(usdt), SELL), abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
        assertEq(bond.balanceOf(address(escrow)), 0);
    }

    /// @notice As in `settle`, an active fee may not truncate to zero.
    function test_OpenDeal_RevertsWhenFeeWouldTruncateToZero() public {
        P2PEscrow.DealTerms memory terms = _terms(address(bond), address(usdt), SELL);
        terms.paymentAmount = 199; // 199 * 50 / 10_000 = 0
        _expectOpenRevert(terms, abi.encodeWithSelector(P2PEscrow.AmountTooSmallForFeePrecision.selector));
    }

    function test_OpenDeal_SmallestAmountThatPaysAFee() public {
        P2PEscrow.DealTerms memory terms = _terms(address(bond), address(usdt), SELL);
        terms.paymentAmount = 200; // 200 * 50 / 10_000 = 1
        bytes32 dealKey = _open(DEAL_ID, terms);
        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        assertEq(usdt.balanceOf(address(distributor)), 1);
        assertEq(usdt.balanceOf(alice), CURRENCY_START + 199);
    }

    /// @notice The precision rule looks at the USDT leg, whichever it is.
    function test_OpenDeal_FeePrecisionAppliesToTheAssetLegWhenUsdtIsSold() public {
        P2PEscrow.DealTerms memory terms = _terms(address(usdt), address(brl), SELL);
        terms.assetAmount = 199;
        _expectOpenRevert(terms, abi.encodeWithSelector(P2PEscrow.AmountTooSmallForFeePrecision.selector));
    }

    function test_OpenDeal_AllowsTinyAmountsWhenFeeIsZero() public {
        _setFeeBps(0);
        P2PEscrow.DealTerms memory terms = _terms(address(bond), address(usdt), SELL);
        terms.paymentAmount = 1;
        bytes32 dealKey = _open(DEAL_ID, terms);
        assertEq(escrow.getDeal(dealKey).feeBps, 0);
    }

    function test_OpenDeal_RevertsWithoutAllowance() public {
        vm.prank(alice);
        bond.approve(address(escrow), 0);
        uint64 expiresAt = _expiry();
        vm.prank(alice);
        vm.expectRevert();
        escrow.openDeal(DEAL_ID, _terms(address(bond), address(usdt), SELL), expiresAt);
        assertEq(uint8(_status(escrow.dealKeyOf(alice, DEAL_ID))), uint8(P2PEscrow.DealStatus.None));
    }

    /// @notice A token that delivers less than requested can never enter the escrow, so a
    /// deposit is always worth exactly what the deal says.
    function test_OpenDeal_RevertsForFeeOnTransferDeposit() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken(100);
        _listCurrency(address(fot));
        fot.mint(alice, 1_000_000e6);
        vm.prank(alice);
        fot.approve(address(escrow), type(uint256).max);

        P2PEscrow.DealTerms memory terms = _terms(address(fot), address(usdt), SELL);
        terms.assetAmount = 1_000e6;
        _expectOpenRevert(
            terms, abi.encodeWithSelector(P2PEscrow.TransferAmountMismatch.selector, address(fot), 1_000e6, 990e6)
        );
        assertEq(escrow.totalEscrowed(address(fot)), 0);
    }

    // ── acceptDeal: every market and side ──────────────────────────────────────────────

    /// @notice Bond sold for USDT, proposer sells: the proposer receives the USDT, so the
    /// proposer pays the fee; the counterparty receives the bond in full.
    function test_AcceptDeal_FixedIncome_ProposerSells() public {
        bytes32 dealKey = _openBondSale();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit P2PEscrow.DealExecuted(
            dealKey,
            DEAL_ID,
            alice,
            bob,
            address(bond),
            address(usdt),
            SELL,
            ASSET_AMOUNT,
            PAYMENT_AMOUNT,
            address(usdt),
            FEE,
            CASHBACK
        );
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(bond.balanceOf(bob), NATIVE_START + ASSET_AMOUNT);
        assertEq(bond.balanceOf(alice), NATIVE_START - ASSET_AMOUNT);
        assertEq(usdt.balanceOf(alice), CURRENCY_START + PAYMENT_AMOUNT - FEE);
        assertEq(usdt.balanceOf(bob), CURRENCY_START - PAYMENT_AMOUNT);
        assertEq(usdt.balanceOf(address(distributor)), FEE);
        assertEq(bond.balanceOf(address(escrow)), 0);
        assertEq(usdt.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalEscrowed(address(bond)), 0);

        assertEq(distributor.cashbackBalance(address(bond), address(usdt)), CASHBACK);
        assertEq(distributor.protocolBalance(address(usdt)), FEE - CASHBACK);

        P2PEscrow.Deal memory deal = escrow.getDeal(dealKey);
        assertEq(uint8(deal.status), uint8(P2PEscrow.DealStatus.Executed));
        assertEq(deal.resolvedAt, uint64(block.timestamp));
    }

    /// @notice Bond bought with USDT, proposer buys: the counterparty receives the USDT (out
    /// of the escrow), so the counterparty pays the fee; the proposer receives the bond in
    /// full.
    function test_AcceptDeal_FixedIncome_ProposerBuys() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), BUY));
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(bond.balanceOf(alice), NATIVE_START + ASSET_AMOUNT);
        assertEq(bond.balanceOf(bob), NATIVE_START - ASSET_AMOUNT);
        assertEq(usdt.balanceOf(bob), CURRENCY_START + PAYMENT_AMOUNT - FEE);
        assertEq(usdt.balanceOf(alice), CURRENCY_START - PAYMENT_AMOUNT);
        assertEq(usdt.balanceOf(address(distributor)), FEE);
        assertEq(usdt.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalEscrowed(address(usdt)), 0);
        assertEq(distributor.cashbackBalance(address(bond), address(usdt)), CASHBACK);
    }

    function test_AcceptDeal_Credit_ProposerSells() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(credit), address(usdt), SELL));
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(credit.balanceOf(bob), NATIVE_START + ASSET_AMOUNT);
        assertEq(usdt.balanceOf(alice), CURRENCY_START + PAYMENT_AMOUNT - FEE);
        assertEq(distributor.cashbackBalance(address(credit), address(usdt)), CASHBACK);
        assertEq(distributor.protocolBalance(address(usdt)), FEE - CASHBACK);
    }

    function test_AcceptDeal_Credit_ProposerBuys() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(credit), address(usdt), BUY));
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(credit.balanceOf(alice), NATIVE_START + ASSET_AMOUNT);
        assertEq(usdt.balanceOf(bob), CURRENCY_START + PAYMENT_AMOUNT - FEE);
        assertEq(distributor.cashbackBalance(address(credit), address(usdt)), CASHBACK);
    }

    /// @notice BRL sold for USDT, proposer sells BRL: the proposer receives USDT and pays the
    /// fee. A Currency deal never accrues cashback.
    function test_AcceptDeal_CurrencySoldForUsdt_ProposerSells() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(brl), address(usdt), SELL));

        vm.expectEmit(true, true, true, true, address(escrow));
        emit P2PEscrow.DealExecuted(
            dealKey, DEAL_ID, alice, bob, address(brl), address(usdt), SELL, ASSET_AMOUNT, PAYMENT_AMOUNT, address(usdt), FEE, 0
        );
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(brl.balanceOf(bob), CURRENCY_START + ASSET_AMOUNT);
        assertEq(brl.balanceOf(alice), CURRENCY_START - ASSET_AMOUNT);
        assertEq(usdt.balanceOf(alice), CURRENCY_START + PAYMENT_AMOUNT - FEE);
        assertEq(usdt.balanceOf(bob), CURRENCY_START - PAYMENT_AMOUNT);
        assertEq(usdt.balanceOf(address(distributor)), FEE);
        assertEq(distributor.cashbackBalance(address(brl), address(usdt)), 0);
        assertEq(distributor.protocolBalance(address(usdt)), FEE);
    }

    function test_AcceptDeal_CurrencySoldForUsdt_ProposerBuys() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(brl), address(usdt), BUY));
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(brl.balanceOf(alice), CURRENCY_START + ASSET_AMOUNT);
        assertEq(brl.balanceOf(bob), CURRENCY_START - ASSET_AMOUNT);
        assertEq(usdt.balanceOf(bob), CURRENCY_START + PAYMENT_AMOUNT - FEE);
        assertEq(usdt.balanceOf(alice), CURRENCY_START - PAYMENT_AMOUNT);
        assertEq(distributor.protocolBalance(address(usdt)), FEE);
    }

    /// @notice USDT sold for BRL, proposer sells USDT: the USDT leg is the asset leg, the
    /// counterparty receives it and pays the fee out of it; the proposer gets its BRL in full.
    function test_AcceptDeal_UsdtSoldForCurrency_ProposerSells() public {
        uint256 fee = (ASSET_AMOUNT * 50) / 10_000;
        bytes32 dealKey = _open(DEAL_ID, _terms(address(usdt), address(brl), SELL));

        vm.expectEmit(true, true, true, true, address(escrow));
        emit P2PEscrow.DealExecuted(
            dealKey, DEAL_ID, alice, bob, address(usdt), address(brl), SELL, ASSET_AMOUNT, PAYMENT_AMOUNT, address(usdt), fee, 0
        );
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(usdt.balanceOf(bob), CURRENCY_START + ASSET_AMOUNT - fee);
        assertEq(usdt.balanceOf(alice), CURRENCY_START - ASSET_AMOUNT);
        assertEq(brl.balanceOf(alice), CURRENCY_START + PAYMENT_AMOUNT);
        assertEq(brl.balanceOf(bob), CURRENCY_START - PAYMENT_AMOUNT);
        assertEq(usdt.balanceOf(address(distributor)), fee);
        assertEq(brl.balanceOf(address(distributor)), 0);
        assertEq(distributor.protocolBalance(address(usdt)), fee);
        assertEq(distributor.protocolBalance(address(brl)), 0);
    }

    /// @notice USDT bought with BRL, proposer buys USDT: the proposer receives the USDT and
    /// pays the fee; the counterparty gets the escrowed BRL in full.
    function test_AcceptDeal_UsdtSoldForCurrency_ProposerBuys() public {
        uint256 fee = (ASSET_AMOUNT * 50) / 10_000;
        bytes32 dealKey = _open(DEAL_ID, _terms(address(usdt), address(brl), BUY));
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(usdt.balanceOf(alice), CURRENCY_START + ASSET_AMOUNT - fee);
        assertEq(usdt.balanceOf(bob), CURRENCY_START - ASSET_AMOUNT);
        assertEq(brl.balanceOf(bob), CURRENCY_START + PAYMENT_AMOUNT);
        assertEq(brl.balanceOf(alice), CURRENCY_START - PAYMENT_AMOUNT);
        assertEq(usdt.balanceOf(address(distributor)), fee);
        assertEq(distributor.protocolBalance(address(usdt)), fee);
        assertEq(brl.balanceOf(address(escrow)), 0);
    }

    /// @notice Whatever the market, side and amounts: nothing is created or lost, the USDT
    /// receiver gets `amount - fee`, the other party gets its leg in full, and the escrow
    /// ends empty.
    function testFuzz_AcceptDeal_UsdtReceiverPaysTheFee(uint256 assetAmount, uint256 paymentAmount, bool sell, uint8 market)
        public
    {
        FuzzCase memory c;
        c.assetAmount = bound(assetAmount, 10_000, NATIVE_START);
        c.paymentAmount = bound(paymentAmount, 10_000, CURRENCY_START);
        market = uint8(bound(market, 0, 3));
        c.assetToken = [address(bond), address(credit), address(brl), address(usdt)][market];
        c.usdtIsAsset = market == 3;
        c.paymentToken = c.usdtIsAsset ? address(eur) : address(usdt);
        // The seller delivers the asset and receives the payment; the buyer the reverse.
        (c.seller, c.buyer) = sell ? (alice, bob) : (bob, alice);

        P2PEscrow.DealTerms memory terms = _terms(c.assetToken, c.paymentToken, sell ? SELL : BUY);
        terms.assetAmount = c.assetAmount;
        terms.paymentAmount = c.paymentAmount;

        Balances memory before = _balances(c);
        bytes32 dealKey = _open(DEAL_ID, terms);
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        _assertFuzzOutcome(c, before, _balances(c));
    }

    struct FuzzCase {
        address assetToken;
        address paymentToken;
        address seller;
        address buyer;
        uint256 assetAmount;
        uint256 paymentAmount;
        bool usdtIsAsset;
    }

    struct Balances {
        uint256 sellerAsset;
        uint256 sellerPayment;
        uint256 buyerAsset;
        uint256 buyerPayment;
    }

    function _balances(FuzzCase memory c) internal view returns (Balances memory b) {
        b.sellerAsset = IERC20(c.assetToken).balanceOf(c.seller);
        b.sellerPayment = IERC20(c.paymentToken).balanceOf(c.seller);
        b.buyerAsset = IERC20(c.assetToken).balanceOf(c.buyer);
        b.buyerPayment = IERC20(c.paymentToken).balanceOf(c.buyer);
    }

    function _assertFuzzOutcome(FuzzCase memory c, Balances memory before, Balances memory afterDeal) internal view {
        uint256 fee = ((c.usdtIsAsset ? c.assetAmount : c.paymentAmount) * 50) / 10_000;

        assertEq(afterDeal.sellerAsset, before.sellerAsset - c.assetAmount);
        assertEq(afterDeal.buyerPayment, before.buyerPayment - c.paymentAmount);
        assertEq(afterDeal.buyerAsset, before.buyerAsset + c.assetAmount - (c.usdtIsAsset ? fee : 0));
        assertEq(afterDeal.sellerPayment, before.sellerPayment + c.paymentAmount - (c.usdtIsAsset ? 0 : fee));
        assertEq(usdt.balanceOf(address(distributor)), fee);
        assertEq(IERC20(c.assetToken).balanceOf(address(escrow)), 0);
        assertEq(IERC20(c.paymentToken).balanceOf(address(escrow)), 0);
        assertEq(
            distributor.protocolBalance(address(usdt)) + distributor.cashbackBalance(c.assetToken, address(usdt)), fee
        );
    }

    // ── acceptDeal: authorization, status, expiry ──────────────────────────────────────

    function test_AcceptDeal_RevertsForOutsider() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(carol);
        vm.expectRevert(P2PEscrow.Unauthorized.selector);
        escrow.acceptDeal(dealKey);
    }

    function test_AcceptDeal_RevertsForTheProposer() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(alice);
        vm.expectRevert(P2PEscrow.Unauthorized.selector);
        escrow.acceptDeal(dealKey);
    }

    function test_AcceptDeal_RevertsForUnknownDeal() public {
        vm.prank(bob);
        vm.expectRevert(P2PEscrow.Unauthorized.selector);
        escrow.acceptDeal(keccak256("unknown"));
    }

    /// @notice A deal executes only once.
    function test_AcceptDeal_RevertsWhenAlreadyExecuted() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        uint256 bobBond = bond.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, dealKey));
        escrow.acceptDeal(dealKey);
        assertEq(bond.balanceOf(bob), bobBond);
    }

    function test_AcceptDeal_RevertsWhenCancelled() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(alice);
        escrow.cancelDeal(dealKey);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, dealKey));
        escrow.acceptDeal(dealKey);
    }

    function test_AcceptDeal_RevertsWhenExpiredAndRefunded() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(block.timestamp + LIFETIME);
        escrow.expireDeal(dealKey);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, dealKey));
        escrow.acceptDeal(dealKey);
    }

    /// @notice Expiry boundary: acceptable up to the last second before `expiresAt`.
    function test_AcceptDeal_SucceedsOneSecondBeforeExpiry() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(escrow.getDeal(dealKey).expiresAt - 1);
        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        assertEq(uint8(_status(dealKey)), uint8(P2PEscrow.DealStatus.Executed));
    }

    /// @notice Expiry boundary: not acceptable from `expiresAt` on, even if nobody expired it.
    function test_AcceptDeal_RevertsAtExpiry() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(escrow.getDeal(dealKey).expiresAt);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealHasExpired.selector, dealKey));
        escrow.acceptDeal(dealKey);
    }

    function test_AcceptDeal_RevertsAfterExpiry() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(escrow.getDeal(dealKey).expiresAt + 1 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealHasExpired.selector, dealKey));
        escrow.acceptDeal(dealKey);
    }

    /// @notice A failed acceptance changes nothing: the deal stays open and refundable.
    function test_AcceptDeal_RevertsWithoutCounterpartyAllowanceAndStaysOpen() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(bob);
        usdt.approve(address(escrow), 0);

        vm.prank(bob);
        vm.expectRevert();
        escrow.acceptDeal(dealKey);

        assertEq(uint8(_status(dealKey)), uint8(P2PEscrow.DealStatus.Open));
        assertEq(escrow.totalEscrowed(address(bond)), ASSET_AMOUNT);
        assertEq(bond.balanceOf(address(escrow)), ASSET_AMOUNT);
        assertEq(bond.balanceOf(bob), NATIVE_START);
    }

    // ── acceptDeal: pause and listing status ───────────────────────────────────────────

    function test_AcceptDeal_RevertsWhileProtocolPaused() public {
        bytes32 dealKey = _openBondSale();
        _pause();
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.acceptDeal(dealKey);
        assertEq(uint8(_status(dealKey)), uint8(P2PEscrow.DealStatus.Open));
    }

    function test_AcceptDeal_RevertsWhenAssetSuspended() public {
        bytes32 dealKey = _openBondSale();
        _suspend(address(bond));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.ListingNotApproved.selector, address(bond)));
        escrow.acceptDeal(dealKey);
    }

    function test_AcceptDeal_RevertsWhenAssetDelisted() public {
        bytes32 dealKey = _openBondSale();
        _delist(address(bond));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.ListingNotApproved.selector, address(bond)));
        escrow.acceptDeal(dealKey);
    }

    function test_AcceptDeal_RevertsWhenPaymentSuspended() public {
        bytes32 dealKey = _openBondSale();
        _suspend(address(usdt));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.InvalidPaymentToken.selector, address(usdt)));
        escrow.acceptDeal(dealKey);
    }

    function test_AcceptDeal_RevertsWhenPaymentDelisted() public {
        bytes32 dealKey = _openBondSale();
        _delist(address(usdt));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.InvalidPaymentToken.selector, address(usdt)));
        escrow.acceptDeal(dealKey);
    }

    /// @notice A suspended listing that is reinstated makes its open deals acceptable again.
    function test_AcceptDeal_SucceedsAfterListingIsReinstated() public {
        bytes32 dealKey = _openBondSale();
        _suspend(address(bond));
        vm.prank(listingAuthority);
        registry.approveListing(address(bond));

        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        assertEq(uint8(_status(dealKey)), uint8(P2PEscrow.DealStatus.Executed));
    }

    function test_AcceptDeal_SucceedsAfterUnpause() public {
        bytes32 dealKey = _openBondSale();
        _pause();
        vm.prank(admin);
        registry.unpause();

        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        assertEq(uint8(_status(dealKey)), uint8(P2PEscrow.DealStatus.Executed));
    }

    /// @notice The fee token is not part of the snapshot: after a switch, a deal whose USDT
    /// leg is the old token can no longer execute, only be refunded.
    function test_AcceptDeal_RevertsAfterFeeTokenSwitchAndDealIsRefundable() public {
        bytes32 dealKey = _openBondSale();
        _useFeeToken(address(brl));

        vm.prank(bob);
        vm.expectRevert(P2PEscrow.NotFeeToken.selector);
        escrow.acceptDeal(dealKey);

        vm.prank(alice);
        escrow.cancelDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    /// @notice A per-listing cashback freeze stops withdrawals only: deals still execute and
    /// still accrue.
    function test_AcceptDeal_AccruesCashbackWhileCashbackIsFrozen() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(listingAuthority);
        registry.freezeCashback(address(bond));

        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        assertEq(distributor.cashbackBalance(address(bond), address(usdt)), CASHBACK);
    }

    /// @notice The issuer withdraws the cashback of a deal like that of a settlement.
    function test_AcceptDeal_IssuerWithdrawsDealCashback() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        vm.prank(issuer);
        distributor.withdraw(address(bond), address(usdt));
        assertEq(usdt.balanceOf(issuer), CASHBACK);
    }

    /// @notice Without ESCROW_ROLE on the distributor nothing executes: the whole acceptance
    /// reverts and the deposit stays refundable.
    function test_AcceptDeal_RevertsWhenEscrowLacksDistributorRole() public {
        P2PEscrow unwired = new P2PEscrow(admin, address(settlement), address(registry), TIMELOCK_DELAY);
        vm.prank(alice);
        bond.approve(address(unwired), type(uint256).max);
        vm.prank(bob);
        usdt.approve(address(unwired), type(uint256).max);
        uint64 expiresAt = _expiry();
        vm.prank(alice);
        bytes32 dealKey = unwired.openDeal(DEAL_ID, _terms(address(bond), address(usdt), SELL), expiresAt);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(unwired), escrowRole
            )
        );
        unwired.acceptDeal(dealKey);

        vm.prank(alice);
        unwired.cancelDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    // ── Fee and cashback rates are fixed at open ───────────────────────────────────────

    function test_FeeSnapshot_RaiseWhileOpenDoesNotApply() public {
        _setFeeBps(20);
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), SELL));
        _setFeeBps(50);
        assertEq(escrow.getDeal(dealKey).feeBps, 20);

        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        // 20 bps of 1,000 USDT, not 50.
        assertEq(usdt.balanceOf(address(distributor)), 2e6);
        assertEq(usdt.balanceOf(alice), CURRENCY_START + PAYMENT_AMOUNT - 2e6);
    }

    function test_FeeSnapshot_CutWhileOpenDoesNotApply() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), SELL));
        _setFeeBps(0);

        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        assertEq(usdt.balanceOf(address(distributor)), FEE);
    }

    /// @notice A deal opened at fee 0 still executes, fee-free, after the fee is raised: no
    /// fee transfer and no accounting call.
    function test_FeeSnapshot_DealOpenedAtZeroFeeExecutesFeeFreeAfterARaise() public {
        _setFeeBps(0);
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), SELL));
        _setFeeBps(50);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit P2PEscrow.DealExecuted(
            dealKey, DEAL_ID, alice, bob, address(bond), address(usdt), SELL, ASSET_AMOUNT, PAYMENT_AMOUNT, address(usdt), 0, 0
        );
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(usdt.balanceOf(alice), CURRENCY_START + PAYMENT_AMOUNT);
        assertEq(usdt.balanceOf(address(distributor)), 0);
        assertEq(distributor.protocolBalance(address(usdt)), 0);
    }

    function test_FeeSnapshot_DealsOpenedAfterAChangeUseTheNewRate() public {
        _setFeeBps(20);
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), SELL));
        assertEq(escrow.getDeal(dealKey).feeBps, 20);

        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        assertEq(usdt.balanceOf(address(distributor)), 2e6);
    }

    function test_CashbackSnapshot_ChangeWhileOpenDoesNotApply() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), SELL));
        _setCashbackBps(5_000);
        assertEq(escrow.getDeal(dealKey).cashbackBps, 1_000);

        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        assertEq(distributor.cashbackBalance(address(bond), address(usdt)), CASHBACK);
        assertEq(distributor.protocolBalance(address(usdt)), FEE - CASHBACK);
    }

    function test_CashbackSnapshot_DealsOpenedAfterAChangeUseTheNewRate() public {
        _setCashbackBps(5_000);
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), SELL));
        assertEq(escrow.getDeal(dealKey).cashbackBps, 5_000);

        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        assertEq(distributor.cashbackBalance(address(bond), address(usdt)), FEE / 2);
    }

    // ── cancelDeal ─────────────────────────────────────────────────────────────────────

    function test_CancelDeal_RefundsTheAssetDeposit() public {
        bytes32 dealKey = _openBondSale();

        vm.expectEmit(true, true, false, true, address(escrow));
        emit P2PEscrow.DealCancelled(dealKey, DEAL_ID, alice, address(bond), ASSET_AMOUNT);
        vm.prank(alice);
        escrow.cancelDeal(dealKey);

        assertEq(bond.balanceOf(alice), NATIVE_START);
        assertEq(bond.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalEscrowed(address(bond)), 0);
        P2PEscrow.Deal memory deal = escrow.getDeal(dealKey);
        assertEq(uint8(deal.status), uint8(P2PEscrow.DealStatus.Cancelled));
        assertEq(deal.resolvedAt, uint64(block.timestamp));
    }

    function test_CancelDeal_RefundsThePaymentDeposit() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), BUY));
        vm.prank(alice);
        escrow.cancelDeal(dealKey);

        assertEq(usdt.balanceOf(alice), CURRENCY_START);
        assertEq(escrow.totalEscrowed(address(usdt)), 0);
    }

    function test_CancelDeal_RevertsForTheCounterparty() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(bob);
        vm.expectRevert(P2PEscrow.Unauthorized.selector);
        escrow.cancelDeal(dealKey);
    }

    function test_CancelDeal_RevertsForOutsider() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(carol);
        vm.expectRevert(P2PEscrow.Unauthorized.selector);
        escrow.cancelDeal(dealKey);
    }

    function test_CancelDeal_RevertsForUnknownDeal() public {
        vm.prank(alice);
        vm.expectRevert(P2PEscrow.Unauthorized.selector);
        escrow.cancelDeal(keccak256("unknown"));
    }

    /// @notice A deal refunds only once.
    function test_CancelDeal_RevertsWhenAlreadyCancelled() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(alice);
        escrow.cancelDeal(dealKey);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, dealKey));
        escrow.cancelDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    function test_CancelDeal_RevertsWhenExecuted() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, dealKey));
        escrow.cancelDeal(dealKey);
    }

    function test_CancelDeal_RevertsWhenExpiredAndRefunded() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(block.timestamp + LIFETIME);
        escrow.expireDeal(dealKey);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, dealKey));
        escrow.cancelDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    /// @notice The proposer can still cancel after `expiresAt`, as long as nobody expired it.
    function test_CancelDeal_SucceedsAfterExpiry() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(block.timestamp + LIFETIME + 1 days);
        vm.prank(alice);
        escrow.cancelDeal(dealKey);
        assertEq(uint8(_status(dealKey)), uint8(P2PEscrow.DealStatus.Cancelled));
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    /// @notice A pause never stops a proposer from taking back its own deposit.
    function test_CancelDeal_SucceedsWhileProtocolPaused() public {
        bytes32 dealKey = _openBondSale();
        _pause();
        vm.prank(alice);
        escrow.cancelDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    function test_CancelDeal_SucceedsWhenAssetSuspended() public {
        bytes32 dealKey = _openBondSale();
        _suspend(address(bond));
        vm.prank(alice);
        escrow.cancelDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    function test_CancelDeal_SucceedsWhenAssetDelisted() public {
        bytes32 dealKey = _openBondSale();
        _delist(address(bond));
        vm.prank(alice);
        escrow.cancelDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    function test_CancelDeal_SucceedsWhenPaymentDelistedAndPaused() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), BUY));
        _delist(address(usdt));
        _pause();
        vm.prank(alice);
        escrow.cancelDeal(dealKey);
        assertEq(usdt.balanceOf(alice), CURRENCY_START);
    }

    // ── expireDeal ─────────────────────────────────────────────────────────────────────

    /// @notice Expiry boundary: not expirable before `expiresAt`.
    function test_ExpireDeal_RevertsOneSecondBeforeExpiry() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(escrow.getDeal(dealKey).expiresAt - 1);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotExpired.selector, dealKey));
        escrow.expireDeal(dealKey);
    }

    /// @notice Expiry boundary: expirable from `expiresAt` on, by anyone; the refund goes to
    /// the proposer, never to the caller.
    function test_ExpireDeal_AnyoneRefundsTheProposerAtExpiry() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(escrow.getDeal(dealKey).expiresAt);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit P2PEscrow.DealExpired(dealKey, DEAL_ID, alice, address(bond), ASSET_AMOUNT);
        vm.prank(carol);
        escrow.expireDeal(dealKey);

        assertEq(bond.balanceOf(alice), NATIVE_START);
        assertEq(bond.balanceOf(carol), 0);
        assertEq(bond.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalEscrowed(address(bond)), 0);
        P2PEscrow.Deal memory deal = escrow.getDeal(dealKey);
        assertEq(uint8(deal.status), uint8(P2PEscrow.DealStatus.Expired));
        assertEq(deal.resolvedAt, uint64(block.timestamp));
    }

    function test_ExpireDeal_RefundsThePaymentDeposit() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), BUY));
        vm.warp(block.timestamp + LIFETIME + 1);
        vm.prank(bob);
        escrow.expireDeal(dealKey);
        assertEq(usdt.balanceOf(alice), CURRENCY_START);
        assertEq(usdt.balanceOf(bob), CURRENCY_START);
    }

    function test_ExpireDeal_RevertsForUnknownDeal() public {
        bytes32 unknown = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, unknown));
        escrow.expireDeal(unknown);
    }

    function test_ExpireDeal_RevertsWhenAlreadyExpired() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(block.timestamp + LIFETIME);
        escrow.expireDeal(dealKey);

        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, dealKey));
        escrow.expireDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    function test_ExpireDeal_RevertsWhenCancelled() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(alice);
        escrow.cancelDeal(dealKey);
        vm.warp(block.timestamp + LIFETIME);

        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, dealKey));
        escrow.expireDeal(dealKey);
    }

    function test_ExpireDeal_RevertsWhenExecuted() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        vm.warp(block.timestamp + LIFETIME);

        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.DealNotOpen.selector, dealKey));
        escrow.expireDeal(dealKey);
    }

    function test_ExpireDeal_SucceedsWhileProtocolPaused() public {
        bytes32 dealKey = _openBondSale();
        _pause();
        vm.warp(block.timestamp + LIFETIME);
        escrow.expireDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    function test_ExpireDeal_SucceedsWhenAssetSuspended() public {
        bytes32 dealKey = _openBondSale();
        _suspend(address(bond));
        vm.warp(block.timestamp + LIFETIME);
        escrow.expireDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    function test_ExpireDeal_SucceedsWhenBothListingsDelistedAndPaused() public {
        bytes32 dealKey = _openBondSale();
        _delist(address(bond));
        _delist(address(usdt));
        _pause();
        vm.warp(block.timestamp + LIFETIME);
        escrow.expireDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    // ── Per-deal accounting: tokens sent straight to the contract ──────────────────────

    /// @notice A donation of the escrowed token neither blocks the acceptance nor leaks to
    /// the counterparty: the deal moves exactly its own deposit.
    function test_Donation_DoesNotBlockOrLeakIntoAccept() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(bob);
        bond.transfer(address(escrow), 3 ether);

        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertEq(bond.balanceOf(bob), NATIVE_START - 3 ether + ASSET_AMOUNT);
        assertEq(bond.balanceOf(address(escrow)), 3 ether);
        assertEq(escrow.totalEscrowed(address(bond)), 0);
    }

    function test_Donation_DoesNotBlockOrLeakIntoCancel() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(bob);
        bond.transfer(address(escrow), 3 ether);

        vm.prank(alice);
        escrow.cancelDeal(dealKey);

        assertEq(bond.balanceOf(alice), NATIVE_START);
        assertEq(bond.balanceOf(address(escrow)), 3 ether);
    }

    function test_Donation_DoesNotBlockOrLeakIntoExpire() public {
        bytes32 dealKey = _open(DEAL_ID, _terms(address(bond), address(usdt), BUY));
        usdt.mint(address(escrow), 77e6);
        vm.warp(block.timestamp + LIFETIME);

        escrow.expireDeal(dealKey);

        assertEq(usdt.balanceOf(alice), CURRENCY_START);
        assertEq(usdt.balanceOf(address(escrow)), 77e6);
    }

    /// @notice Two open deals in the same token are accounted separately: resolving one
    /// leaves the other's deposit in place.
    function test_Accounting_DealsInTheSameTokenAreIndependent() public {
        bytes32 first = _openBondSale();
        bytes16 secondId = bytes16(keccak256("deal-0002"));
        P2PEscrow.DealTerms memory terms = _terms(address(bond), address(usdt), SELL);
        terms.assetAmount = 4 ether;
        bytes32 second = _open(secondId, terms);
        assertEq(escrow.totalEscrowed(address(bond)), ASSET_AMOUNT + 4 ether);

        vm.prank(alice);
        escrow.cancelDeal(first);
        assertEq(escrow.totalEscrowed(address(bond)), 4 ether);
        assertEq(bond.balanceOf(address(escrow)), 4 ether);

        vm.prank(bob);
        escrow.acceptDeal(second);
        assertEq(escrow.totalEscrowed(address(bond)), 0);
        assertEq(bond.balanceOf(address(escrow)), 0);
    }

    // ── sweepExcess ────────────────────────────────────────────────────────────────────

    /// @notice The treasury sweeps exactly the donation; the open deal's deposit stays and
    /// remains refundable.
    function test_SweepExcess_MovesOnlyTheExcess() public {
        bytes32 dealKey = _openBondSale();
        vm.prank(bob);
        bond.transfer(address(escrow), 3 ether);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit P2PEscrow.ExcessSwept(address(bond), sink, 3 ether);
        vm.prank(admin);
        uint256 swept = escrow.sweepExcess(address(bond), sink);

        assertEq(swept, 3 ether);
        assertEq(bond.balanceOf(sink), 3 ether);
        assertEq(bond.balanceOf(address(escrow)), ASSET_AMOUNT);
        assertEq(escrow.totalEscrowed(address(bond)), ASSET_AMOUNT);

        vm.prank(alice);
        escrow.cancelDeal(dealKey);
        assertEq(bond.balanceOf(alice), NATIVE_START);
    }

    /// @notice A token no deal ever used can be swept in full.
    function test_SweepExcess_TokenNeverEscrowed() public {
        eur.mint(address(escrow), 55e6);
        vm.prank(admin);
        assertEq(escrow.sweepExcess(address(eur), sink), 55e6);
        assertEq(eur.balanceOf(sink), 55e6);
    }

    /// @notice With nothing beyond the deposits there is nothing to sweep: deposits are
    /// never the treasury's.
    function test_SweepExcess_RevertsWhenOnlyDepositsAreHeld() public {
        _openBondSale();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.NothingToSweep.selector, address(bond)));
        escrow.sweepExcess(address(bond), sink);
    }

    function test_SweepExcess_RevertsWhenEmpty() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(P2PEscrow.NothingToSweep.selector, address(usdt)));
        escrow.sweepExcess(address(usdt), sink);
    }

    function test_SweepExcess_OnlyTreasury() public {
        usdt.mint(address(escrow), 1e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, treasuryRole)
        );
        escrow.sweepExcess(address(usdt), alice);
    }

    function test_SweepExcess_RevertsForZeroRecipient() public {
        usdt.mint(address(escrow), 1e6);
        vm.prank(admin);
        vm.expectRevert(P2PEscrow.ZeroAddress.selector);
        escrow.sweepExcess(address(usdt), address(0));
    }

    function test_SweepExcess_RevertsWhenRecipientIsTheEscrow() public {
        usdt.mint(address(escrow), 1e6);
        vm.prank(admin);
        vm.expectRevert(P2PEscrow.InvalidRecipient.selector);
        escrow.sweepExcess(address(usdt), address(escrow));
    }

    /// @notice The sweep is a payout computed from the protocol's own accounting: paused.
    function test_SweepExcess_RevertsWhileProtocolPaused() public {
        usdt.mint(address(escrow), 1e6);
        _pause();
        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.sweepExcess(address(usdt), sink);
    }

    /// @notice Modifier order: `nonReentrant`, then the role, then the pause.
    function test_SweepExcess_RoleCheckedBeforePause() public {
        _pause();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, treasuryRole)
        );
        escrow.sweepExcess(address(usdt), alice);
    }

    // ── Checks-effects-interactions: log order ─────────────────────────────────────────

    function test_OpenDeal_EmitsDealOpenedBeforeExternalTransfer() public {
        vm.recordLogs();
        _openBondSale();
        _assertEmittedBeforeTransfers(vm.getRecordedLogs(), P2PEscrow.DealOpened.selector);
    }

    function test_AcceptDeal_EmitsDealExecutedBeforeExternalTransfers() public {
        bytes32 dealKey = _openBondSale();
        vm.recordLogs();
        vm.prank(bob);
        escrow.acceptDeal(dealKey);
        _assertEmittedBeforeTransfers(vm.getRecordedLogs(), P2PEscrow.DealExecuted.selector);
    }

    function test_CancelDeal_EmitsDealCancelledBeforeExternalTransfer() public {
        bytes32 dealKey = _openBondSale();
        vm.recordLogs();
        vm.prank(alice);
        escrow.cancelDeal(dealKey);
        _assertEmittedBeforeTransfers(vm.getRecordedLogs(), P2PEscrow.DealCancelled.selector);
    }

    function test_ExpireDeal_EmitsDealExpiredBeforeExternalTransfer() public {
        bytes32 dealKey = _openBondSale();
        vm.warp(block.timestamp + LIFETIME);
        vm.recordLogs();
        escrow.expireDeal(dealKey);
        _assertEmittedBeforeTransfers(vm.getRecordedLogs(), P2PEscrow.DealExpired.selector);
    }

    function test_SweepExcess_EmitsExcessSweptBeforeExternalTransfer() public {
        usdt.mint(address(escrow), 1e6);
        vm.recordLogs();
        vm.prank(admin);
        escrow.sweepExcess(address(usdt), sink);
        _assertEmittedBeforeTransfers(vm.getRecordedLogs(), P2PEscrow.ExcessSwept.selector);
    }

    // ── Checks-effects-interactions: what a hostile token's hook sees and can do ───────

    /// @dev Re-entrant call used by the `..._RevertsViaGuard` tests. The hostile token holds
    /// no TREASURY_ROLE, so the observed error is the guard's only if `nonReentrant` is the
    /// first modifier of `sweepExcess`.
    function _reentrantSweep(address token) internal view returns (bytes memory) {
        return abi.encodeWithSelector(escrow.sweepExcess.selector, token, token);
    }

    function _assertBlockedByGuard(MaliciousHookToken evil) internal view {
        assertTrue(evil.reentered());
        assertFalse(evil.reentrantSucceeded());
        assertEq(_selectorOf(evil.reentrantReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    /// @notice While the deposit is being pulled, the hook already sees it counted as
    /// escrowed, so it could never be taken for sweepable excess.
    function test_OpenDeal_DepositAccountedBeforeExternalTransfer() public {
        MaliciousHookToken evil = _listedHookCurrency();
        evil.armOnTransferFrom(address(escrow), abi.encodeWithSelector(escrow.totalEscrowed.selector, address(evil)));

        bytes32 dealKey = _open(DEAL_ID, _terms(address(evil), address(usdt), SELL));

        assertTrue(evil.reentered());
        assertTrue(evil.reentrantSucceeded());
        assertEq(abi.decode(evil.reentrantReturnData(), (uint256)), ASSET_AMOUNT);
        assertEq(uint8(_status(dealKey)), uint8(P2PEscrow.DealStatus.Open));
    }

    function test_OpenDeal_CrossFunctionReentrancy_RevertsViaGuard() public {
        MaliciousHookToken evil = _listedHookCurrency();
        evil.mint(address(escrow), 5 ether); // something a sweep could take
        evil.armOnTransferFrom(address(escrow), _reentrantSweep(address(evil)));

        _open(DEAL_ID, _terms(address(evil), address(usdt), SELL));

        _assertBlockedByGuard(evil);
        assertEq(evil.balanceOf(address(escrow)), ASSET_AMOUNT + 5 ether);
    }

    /// @notice While the escrowed leg is being paid out, the hook already sees the deal
    /// `Executed`: it can never execute or be refunded a second time.
    function test_AcceptDeal_DealExecutedBeforeExternalTransfers() public {
        MaliciousHookToken evil = _listedHookCurrency();
        bytes32 dealKey = _open(DEAL_ID, _terms(address(evil), address(usdt), SELL));
        evil.armOnTransfer(address(escrow), abi.encodeWithSelector(escrow.getDeal.selector, dealKey));

        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        assertTrue(evil.reentered());
        assertTrue(evil.reentrantSucceeded());
        P2PEscrow.Deal memory seen = abi.decode(evil.reentrantReturnData(), (P2PEscrow.Deal));
        assertEq(uint8(seen.status), uint8(P2PEscrow.DealStatus.Executed));
        assertEq(evil.balanceOf(bob), ASSET_AMOUNT);
    }

    /// @notice A hook that tries to refund the deal it is being paid from is stopped by the
    /// guard, and the deposit is paid once.
    function test_AcceptDeal_ReentrantCancel_RevertsViaGuard() public {
        MaliciousHookToken evil = _listedHookCurrency();
        bytes32 dealKey = _open(DEAL_ID, _terms(address(evil), address(usdt), SELL));
        evil.armOnTransfer(address(escrow), abi.encodeWithSelector(escrow.expireDeal.selector, dealKey));

        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        _assertBlockedByGuard(evil);
        assertEq(evil.balanceOf(bob), ASSET_AMOUNT);
        assertEq(evil.balanceOf(alice), CURRENCY_START - ASSET_AMOUNT);
        assertEq(evil.balanceOf(address(escrow)), 0);
    }

    function test_AcceptDeal_CrossFunctionReentrancy_RevertsViaGuard() public {
        MaliciousHookToken evil = _listedHookCurrency();
        bytes32 dealKey = _open(DEAL_ID, _terms(address(evil), address(usdt), SELL));
        evil.mint(address(escrow), 5 ether);
        evil.armOnTransfer(address(escrow), _reentrantSweep(address(evil)));

        vm.prank(bob);
        escrow.acceptDeal(dealKey);

        _assertBlockedByGuard(evil);
        assertEq(evil.balanceOf(bob), ASSET_AMOUNT);
        assertEq(evil.balanceOf(address(escrow)), 5 ether);
        assertEq(usdt.balanceOf(alice), CURRENCY_START + PAYMENT_AMOUNT - FEE);
    }

    /// @notice While the refund is being paid, the hook already sees the deal `Cancelled`.
    function test_CancelDeal_DealCancelledBeforeExternalTransfer() public {
        MaliciousHookToken evil = _listedHookCurrency();
        bytes32 dealKey = _open(DEAL_ID, _terms(address(evil), address(usdt), SELL));
        evil.armOnTransfer(address(escrow), abi.encodeWithSelector(escrow.getDeal.selector, dealKey));

        vm.prank(alice);
        escrow.cancelDeal(dealKey);

        assertTrue(evil.reentrantSucceeded());
        P2PEscrow.Deal memory seen = abi.decode(evil.reentrantReturnData(), (P2PEscrow.Deal));
        assertEq(uint8(seen.status), uint8(P2PEscrow.DealStatus.Cancelled));
        assertEq(evil.balanceOf(alice), CURRENCY_START);
    }

    function test_CancelDeal_CrossFunctionReentrancy_RevertsViaGuard() public {
        MaliciousHookToken evil = _listedHookCurrency();
        bytes32 dealKey = _open(DEAL_ID, _terms(address(evil), address(usdt), SELL));
        evil.mint(address(escrow), 5 ether);
        evil.armOnTransfer(address(escrow), _reentrantSweep(address(evil)));

        vm.prank(alice);
        escrow.cancelDeal(dealKey);

        _assertBlockedByGuard(evil);
        assertEq(evil.balanceOf(alice), CURRENCY_START);
        assertEq(evil.balanceOf(address(escrow)), 5 ether);
    }

    /// @notice While the refund is being paid, the hook already sees the deal `Expired`.
    function test_ExpireDeal_DealExpiredBeforeExternalTransfer() public {
        MaliciousHookToken evil = _listedHookCurrency();
        bytes32 dealKey = _open(DEAL_ID, _terms(address(evil), address(usdt), SELL));
        vm.warp(block.timestamp + LIFETIME);
        evil.armOnTransfer(address(escrow), abi.encodeWithSelector(escrow.getDeal.selector, dealKey));

        escrow.expireDeal(dealKey);

        assertTrue(evil.reentrantSucceeded());
        P2PEscrow.Deal memory seen = abi.decode(evil.reentrantReturnData(), (P2PEscrow.Deal));
        assertEq(uint8(seen.status), uint8(P2PEscrow.DealStatus.Expired));
    }

    function test_ExpireDeal_CrossFunctionReentrancy_RevertsViaGuard() public {
        MaliciousHookToken evil = _listedHookCurrency();
        bytes32 dealKey = _open(DEAL_ID, _terms(address(evil), address(usdt), SELL));
        evil.mint(address(escrow), 5 ether);
        vm.warp(block.timestamp + LIFETIME);
        evil.armOnTransfer(address(escrow), _reentrantSweep(address(evil)));

        escrow.expireDeal(dealKey);

        _assertBlockedByGuard(evil);
        assertEq(evil.balanceOf(alice), CURRENCY_START);
        assertEq(evil.balanceOf(address(escrow)), 5 ether);
    }

    /// @notice Re-entry into `sweepExcess` from its own payout dies at the guard, before
    /// access control.
    function test_SweepExcess_Reentrancy_RevertsViaGuard() public {
        MaliciousHookToken evil = _listedHookCurrency();
        evil.mint(address(escrow), 5 ether);
        evil.armOnTransfer(address(escrow), _reentrantSweep(address(evil)));

        vm.prank(admin);
        escrow.sweepExcess(address(evil), sink);

        _assertBlockedByGuard(evil);
        assertEq(evil.balanceOf(sink), 5 ether);
    }

    /// @notice A hook on the sweep payout cannot open a deal either (cross-function).
    function test_SweepExcess_ReentrantOpenDeal_RevertsViaGuard() public {
        MaliciousHookToken evil = _listedHookCurrency();
        evil.mint(address(escrow), 5 ether);
        evil.armOnTransfer(
            address(escrow),
            abi.encodeWithSelector(
                escrow.openDeal.selector, DEAL_ID, _terms(address(evil), address(usdt), SELL), _expiry()
            )
        );

        vm.prank(admin);
        escrow.sweepExcess(address(evil), sink);

        _assertBlockedByGuard(evil);
    }
}

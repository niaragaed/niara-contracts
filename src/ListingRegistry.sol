// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {IListingRegistry} from "./interfaces/IListingRegistry.sol";
import {INiaraSettlement} from "./interfaces/INiaraSettlement.sol";
import {ICashbackDistributor} from "./interfaces/ICashbackDistributor.sol";
import {AssetTokenFactory} from "./AssetTokenFactory.sol";
import {NativeAssetToken} from "./NativeAssetToken.sol";

/// @title ListingRegistry
/// @notice Curated listing: a token only becomes tradable on Niara after the listing
/// authority approves it. Niara controls eligibility, never custody. EVM mirror of the
/// Solana `Listing` account and its instructions (EXCHANGE-MULTICHAIN-DESIGN.md, 3.2/3.3).
///
/// Status table (Delisted is final, one listing per token, no resubmission):
///
///   submitListing  : None      -> Pending    (issuer)
///   quoteListing   : Pending   -> Quoted     (listing fee quoted, spec §3.13)
///                    Quoted    -> Quoted     (re-quote, also after expiry)
///   payListingFee  : Quoted    -> Approved   (issuer pays; the only first approval)
///   approveListing : Suspended -> Approved   (reinstatement only, any class, free)
///   suspendListing : Approved  -> Suspended
///   delist         : Pending   -> Delisted   (rejection)
///                    Quoted    -> Delisted   (rejection)
///                    Approved  -> Delisted
///                    Suspended -> Delisted
///
/// Listing fee (spec §3.13): the listing authority quotes it (`quoteListing`: valuation, rate
/// at most `MAX_LISTING_FEE_BPS`, expiry) and the issuer pays it (`payListingFee`), in the
/// protocol's fee token, into the CashbackDistributor, where it is protocol revenue with no
/// cashback share. Paying is what approves an issuer listing. `Currency` listings
/// (`listCurrency`) are created `Approved` and never pay one.
///
/// Issuance: the registry is the only minter of every factory token. The issuer requests a
/// batch (`requestIssuance`), the listing authority approves it (`approveIssuance`) and the
/// registry mints it, so neither the issuer nor Niara can mint alone. Both steps need the
/// listing `Approved` (its listing fee paid); there is no queuing before approval.
///
/// Pause (spec §3.3, "Pause principle"): this is the protocol's single, shared pause, the EVM
/// mirror of Solana's `Config.paused`. It blocks payouts based on protocol accounting, never
/// a user reclaiming their own escrowed deposit. While paused: `approveIssuance` and
/// `payListingFee` here, `NiaraSettlement.settle`, and `CashbackDistributor.withdraw` /
/// `withdrawProtocolFees` (both read `paused()` through ProtocolPausable). Listing actions
/// (including `quoteListing`), `requestIssuance` and `rejectIssuance` (neither mints) stay
/// available.
/// @dev Role changes (including LISTING_AUTHORITY_ROLE) go through the inherited
/// timelock. Status changes and issuance approvals are operational and take effect
/// immediately, like the Solana `approve_listing` / `suspend_listing` / `delist`. Pause is
/// not timelocked: a circuit breaker must act immediately. The link to NiaraSettlement
/// (source of the fee token and of the CashbackDistributor) is set through the timelock too.
contract ListingRegistry is IListingRegistry, TimelockedAccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant LISTING_AUTHORITY_ROLE = keccak256("LISTING_AUTHORITY_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard, immutable cap on the listing-fee rate: 100 bps (1%) of the valuation
    /// (spec §3.13). The 0.1% floor is pricing policy, not enforced on-chain; the rate must
    /// only be at least 1 bps, so a quote is never free.
    uint16 public constant MAX_LISTING_FEE_BPS = 100;

    /// @notice Longest validity of a listing-fee quote: `expiresAt <= now + 30 days`
    /// (Solana: `MAX_QUOTE_DURATION_SECS`).
    uint64 public constant MAX_QUOTE_DURATION = 30 days;

    /// @notice The listing-fee quote of an issuer listing (spec §3.13). All zero until
    /// `quoteListing`, and always zero for `Currency` listings. Kept apart from `Listing` so
    /// the listing reads done on every settlement and deal stay the same size.
    struct ListingFeeQuote {
        /// @dev Valuation of the offering, in base units of `listingFeeToken`.
        uint256 valuation;
        /// @dev `ceil(valuation * listingFeeBps / 10_000)`.
        uint256 listingFee;
        /// @dev 0 until `payListingFee`, then equal to `listingFee`. Never reset.
        uint256 listingFeePaid;
        /// @dev The protocol's fee token when the quote was made; payable only in it.
        address listingFeeToken;
        uint16 listingFeeBps;
        /// @dev The quote is payable while `block.timestamp < quoteExpiresAt`.
        uint64 quoteExpiresAt;
    }

    enum IssuanceStatus {
        None,
        Requested,
        Executed,
        Rejected
    }

    /// @notice One requested increase of supply. Never deleted: requested, executed and
    /// rejected batches stay as the on-chain issuance record (mirrors Solana's
    /// `IssuanceBatch`).
    struct IssuanceBatch {
        uint256 amount;
        address recipient;
        bytes32 docHash;
        IssuanceStatus status;
        /// @dev Block timestamp of `requestIssuance`.
        uint64 requestedAt;
        /// @dev Block timestamp of `approveIssuance` / `rejectIssuance`; 0 while `Requested`.
        uint64 resolvedAt;
    }

    /// @notice Factory deployed by this registry; only its tokens can be submitted.
    AssetTokenFactory public immutable factory;

    mapping(address token => Listing) private _listings;

    mapping(address token => ListingFeeQuote) private _listingFeeQuotes;

    /// @notice NiaraSettlement this registry takes the fee token and the CashbackDistributor
    /// from (Solana: `Config.fee_mint` and the fee vault). Zero until set through the
    /// timelock (`proposeSetSettlement` / `executeSetSettlement`); while zero, no listing fee
    /// can be quoted or paid. Its `listingRegistry()` must be this contract.
    INiaraSettlement public settlement;

    /// @notice Issuance batches per token, indexed by batch number.
    mapping(address token => mapping(uint256 batchNo => IssuanceBatch)) public issuanceBatches;

    /// @notice Next batch number for each token. Like Solana's `next_batch_no`: 1 after
    /// `submitListing` (batches are numbered from 1, sequentially, never skipped or
    /// reused), 0 for tokens without an issuer listing (including `Currency`).
    mapping(address token => uint256) public nextBatchNo;

    event ListingSubmitted(
        address indexed token, address indexed issuer, AssetClass assetClass, bytes32 docHash
    );
    /// @notice Emitted by every path that makes a listing tradable, mirroring Solana's
    /// `ListingApproved`: `payListingFee` (issuer listings, Quoted -> Approved, right after
    /// `ListingFeePaid`), `approveListing` (reinstatement, Suspended -> Approved) and
    /// `listCurrency` (Currency listings, created Approved, with `issuer == address(0)`,
    /// `cashbackEligible == false` and `docHash == 0`). The Register indexer watches this one
    /// event on every chain and tells currencies apart by `assetClass`.
    event ListingApproved(
        address indexed token,
        address indexed issuer,
        AssetClass assetClass,
        bool cashbackEligible,
        bytes32 docHash,
        uint64 approvedAt
    );
    /// @notice The listing authority quoted the listing fee of `token` (spec §3.13). The
    /// valuation is public. Mirrors Solana's `ListingQuoted`.
    event ListingQuoted(
        address indexed token,
        address indexed feeToken,
        uint256 valuation,
        uint16 listingFeeBps,
        uint256 listingFee,
        uint64 expiresAt
    );
    /// @notice The issuer paid the quoted listing fee; `ListingApproved` follows in the same
    /// transaction. Mirrors Solana's `ListingFeePaid`.
    event ListingFeePaid(
        address indexed token,
        address indexed issuer,
        address indexed feeToken,
        uint256 valuation,
        uint16 listingFeeBps,
        uint256 amount
    );
    event SettlementChangeProposed(address indexed newSettlement, uint256 executeAfter);
    event SettlementChanged(address indexed oldSettlement, address indexed newSettlement);
    event ListingSuspended(address indexed token);
    event ListingDelisted(address indexed token, ListingStatus previousStatus);
    event IssuanceRequested(
        address indexed token, uint256 indexed batchNo, uint256 amount, address recipient, bytes32 docHash
    );
    event IssuanceExecuted(
        address indexed token, uint256 indexed batchNo, uint256 amount, address recipient, bytes32 docHash
    );
    event IssuanceRejected(address indexed token, uint256 indexed batchNo, uint256 amount, address recipient);
    /// @notice Cashback withdrawals for `token` were frozen (`frozen == true`) or unfrozen by
    /// the listing authority. Accrual is never affected. Mirrors Solana's `CashbackFreezeSet`.
    event CashbackFreezeSet(address indexed token, bool frozen, address indexed listingAuthority);

    error ZeroAddress();
    error ZeroAmount();
    error NotFactoryToken(address token);
    error FactoryTokenCannotBeCurrency(address token);
    error NotIssuer();
    error ListingAlreadyExists(address token);
    error InvalidStatusTransition(address token, ListingStatus from);
    error IssuanceNotAllowed(address token, ListingStatus status);
    error ListingNotApproved(address token);
    error BatchNotRequested(address token, uint256 batchNo);
    error EmptyDocHash();
    error NotCashbackEligible(address token);
    error CashbackAlreadyFrozen(address token);
    error CashbackNotFrozen(address token);
    error CurrencyHasNoListingFee(address token);
    error ZeroValuation();
    error InvalidListingFeeBps(uint16 listingFeeBps);
    error InvalidExpiry(uint64 expiresAt);
    error ListingNotQuoted(address token, ListingStatus status);
    error QuoteExpired(address token, uint64 expiresAt);
    error NotFeeToken(address quotedFeeToken, address feeToken);
    error ListingFeeNotPaid(address token);
    error SettlementNotSet();
    error SettlementRegistryMismatch(address settlement);
    error TransferAmountMismatch(address token, uint256 expected, uint256 received);

    /// @param admin_ Holder of DEFAULT_ADMIN_ROLE (role changes, timelock) and PAUSER_ROLE.
    /// @param listingAuthority_ Initial holder of LISTING_AUTHORITY_ROLE.
    /// @param timelockDelay_ Delay (seconds) between proposal and execution of role changes.
    constructor(address admin_, address listingAuthority_, uint256 timelockDelay_)
        TimelockedAccessControl(timelockDelay_)
    {
        if (admin_ == address(0) || listingAuthority_ == address(0)) revert ZeroAddress();
        factory = new AssetTokenFactory(address(this));
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
        _grantRole(LISTING_AUTHORITY_ROLE, listingAuthority_);
    }

    // ── Pause ───────────────────────────────────────────────────────────────────────────

    /// @notice Pauses the whole protocol in an emergency. This is the single shared pause:
    /// the other contracts read it through `paused()` (ProtocolPausable).
    /// @dev While paused, these revert `EnforcedPause`:
    /// - `ListingRegistry.approveIssuance` and `ListingRegistry.payListingFee`;
    /// - `NiaraSettlement.settle`;
    /// - `CashbackDistributor.withdraw` and `CashbackDistributor.withdrawProtocolFees`;
    /// - `P2PEscrow.openDeal`, `P2PEscrow.acceptDeal` and `P2PEscrow.sweepExcess`.
    /// Not stopped: `P2PEscrow.cancelDeal` and `P2PEscrow.expireDeal` (a user always gets their
    /// own deposit back), listing actions including `quoteListing`, `requestIssuance`,
    /// `rejectIssuance`, and cashback accrual. Pausing is immediate (not timelocked) and
    /// restricted to PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Removes the protocol pause.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @inheritdoc IListingRegistry
    function paused() public view override(IListingRegistry, Pausable) returns (bool) {
        return super.paused();
    }

    // ── Listings ────────────────────────────────────────────────────────────────────────

    /// @notice Submits a factory-issued token for listing (`Pending`). Only the token's
    /// issuer can call it. Class and document hash come from the token itself, so the
    /// listing can never disagree with the instrument. The factory only issues `Equity`,
    /// `FixedIncome` and `Credit`, so a `Currency` listing can never come from here.
    /// @param token A token deployed by `factory`.
    function submitListing(address token) external {
        if (!factory.isFactoryToken(token)) revert NotFactoryToken(token);
        NativeAssetToken instrument = NativeAssetToken(token);
        if (msg.sender != instrument.issuer()) revert NotIssuer();
        if (_listings[token].status != ListingStatus.None) revert ListingAlreadyExists(token);

        AssetClass assetClass = instrument.assetClass();
        bytes32 docHash = instrument.docHash();
        _listings[token] = Listing({
            issuer: msg.sender,
            assetClass: assetClass,
            status: ListingStatus.Pending,
            cashbackEligible: true,
            docHash: docHash,
            approvedAt: 0,
            cashbackFrozen: false
        });
        // Batch numbers start at 1 (Solana: `next_batch_no = 1` in `submit_listing`).
        nextBatchNo[token] = 1;
        emit ListingSubmitted(token, msg.sender, assetClass, docHash);
    }

    /// @notice Creates an `Approved` `Currency` listing directly (stablecoin issuers do not
    /// submit listings; Niara curates which currencies trade). Never cashback-eligible.
    /// @param token Payment token (e.g. a stablecoin). Factory tokens are rejected.
    function listCurrency(address token) external onlyRole(LISTING_AUTHORITY_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (factory.isFactoryToken(token)) revert FactoryTokenCannotBeCurrency(token);
        if (_listings[token].status != ListingStatus.None) revert ListingAlreadyExists(token);

        uint64 approvedAt = uint64(block.timestamp);
        _listings[token] = Listing({
            issuer: address(0),
            assetClass: AssetClass.Currency,
            status: ListingStatus.Approved,
            cashbackEligible: false,
            docHash: bytes32(0),
            approvedAt: approvedAt,
            cashbackFrozen: false
        });
        // Same event as approveListing (Solana's list_currency emits ListingApproved too).
        emit ListingApproved(token, address(0), AssetClass.Currency, false, bytes32(0), approvedAt);
    }

    /// @notice Reinstates a `Suspended` listing of any class, free of charge (a suspended
    /// issuer listing has already paid its listing fee). It never approves a listing for the
    /// first time: a `Pending` or `Quoted` listing is approved only by `payListingFee`.
    /// @param token Listed token.
    function approveListing(address token) external onlyRole(LISTING_AUTHORITY_ROLE) {
        Listing storage listing = _listings[token];
        ListingStatus from = listing.status;
        if (from == ListingStatus.Pending || from == ListingStatus.Quoted) revert ListingFeeNotPaid(token);
        if (from != ListingStatus.Suspended) revert InvalidStatusTransition(token, from);
        _approve(token, listing);
    }

    /// @dev Sets `Approved` and `approvedAt`, and emits `ListingApproved`.
    function _approve(address token, Listing storage listing) private {
        uint64 approvedAt = uint64(block.timestamp);
        listing.status = ListingStatus.Approved;
        listing.approvedAt = approvedAt;
        emit ListingApproved(
            token, listing.issuer, listing.assetClass, listing.cashbackEligible, listing.docHash, approvedAt
        );
    }

    // ── Listing fee (spec §3.13) ────────────────────────────────────────────────────────

    /// @notice Quotes the listing fee of a `Pending` or `Quoted` issuer listing, which becomes
    /// (or stays) `Quoted`. Re-quoting replaces every field of the quote, also after it
    /// expired, until the fee is paid. Allowed while paused (a listing action; it moves
    /// nothing).
    /// @dev The fee is `ceil(valuation * listingFeeBps / 10_000)`, in base units of the fee
    /// token in force now (`settlement.feeToken()`), which the quote records. The valuation
    /// is public: it is stored here and carried by `ListingQuoted`.
    /// @param token Token with an issuer listing.
    /// @param valuation Valuation of the offering in base units of the fee token (non-zero).
    /// @param listingFeeBps Rate, `1 <= listingFeeBps <= MAX_LISTING_FEE_BPS`.
    /// @param expiresAt End of validity: `now < expiresAt <= now + MAX_QUOTE_DURATION`.
    function quoteListing(address token, uint256 valuation, uint16 listingFeeBps, uint64 expiresAt)
        external
        onlyRole(LISTING_AUTHORITY_ROLE)
    {
        Listing storage listing = _listings[token];
        ListingStatus from = listing.status;
        // A token with no listing reads as class `Equity` (the zero value), so this only
        // catches real Currency listings, which are created Approved and never quoted.
        if (listing.assetClass == AssetClass.Currency) revert CurrencyHasNoListingFee(token);
        if (from != ListingStatus.Pending && from != ListingStatus.Quoted) revert InvalidStatusTransition(token, from);
        if (valuation == 0) revert ZeroValuation();
        if (listingFeeBps == 0 || listingFeeBps > MAX_LISTING_FEE_BPS) revert InvalidListingFeeBps(listingFeeBps);
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_QUOTE_DURATION) {
            revert InvalidExpiry(expiresAt);
        }
        address feeToken = _settlement().feeToken();

        uint256 listingFee = Math.mulDiv(valuation, listingFeeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        _listingFeeQuotes[token] = ListingFeeQuote({
            valuation: valuation,
            listingFee: listingFee,
            listingFeePaid: 0,
            listingFeeToken: feeToken,
            listingFeeBps: listingFeeBps,
            quoteExpiresAt: expiresAt
        });
        listing.status = ListingStatus.Quoted;
        emit ListingQuoted(token, feeToken, valuation, listingFeeBps, listingFee, expiresAt);
    }

    /// @notice The issuer pays the quoted listing fee and the listing becomes `Approved`: the
    /// only way an issuer listing is approved for the first time. The fee goes from the
    /// issuer (which must have approved this contract for it) to the CashbackDistributor,
    /// as protocol revenue with no cashback share. Emits `ListingFeePaid`, then
    /// `ListingApproved`. Blocked while the protocol is paused.
    /// @dev Payable once: afterwards the status never returns to `Quoted`. Only while
    /// `now < quoteExpiresAt`, and only in the fee token recorded on the quote, which must
    /// still be `settlement.feeToken()` (after a fee-token switch the listing authority
    /// re-quotes). The transfer is checked by balance delta, so a fee token that delivers
    /// less than the fee reverts everything.
    /// @param token Token with a `Quoted` listing whose issuer is the caller.
    function payListingFee(address token) external nonReentrant whenNotPaused {
        Listing storage listing = _listings[token];
        // Currency listings have issuer == address(0), so they can never pay a listing fee.
        if (msg.sender != listing.issuer) revert NotIssuer();
        if (listing.status != ListingStatus.Quoted) revert ListingNotQuoted(token, listing.status);
        ListingFeeQuote storage quote = _listingFeeQuotes[token];
        if (block.timestamp >= quote.quoteExpiresAt) revert QuoteExpired(token, quote.quoteExpiresAt);
        INiaraSettlement settlement_ = _settlement();
        address feeToken = quote.listingFeeToken;
        address currentFeeToken = settlement_.feeToken();
        if (feeToken != currentFeeToken) revert NotFeeToken(feeToken, currentFeeToken);
        address distributor = address(settlement_.cashbackDistributor());
        uint256 fee = quote.listingFee;

        // Checks-effects-interactions: the fee is marked paid, the listing approved, and
        // `ListingFeePaid` then `ListingApproved` are emitted BEFORE the fee token is called.
        // A fee token with a hook (ERC-777/ERC-1363) that re-enters during the transfer finds
        // the listing already `Approved`, so it can never pay twice (`nonReentrant` stops a
        // re-entry into this function first), and an off-chain indexer never sees the
        // `Transfer` before the events of the payment that caused it. A failed or short
        // transfer reverts everything, events included.
        quote.listingFeePaid = fee;
        emit ListingFeePaid(token, msg.sender, feeToken, quote.valuation, quote.listingFeeBps, fee);
        _approve(token, listing);

        uint256 balanceBefore = IERC20(feeToken).balanceOf(distributor);
        IERC20(feeToken).safeTransferFrom(msg.sender, distributor, fee);
        uint256 balanceAfter = IERC20(feeToken).balanceOf(distributor);
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != fee) revert TransferAmountMismatch(feeToken, fee, received);
        // As in `NiaraSettlement.settle` and `P2PEscrow.acceptDeal`, the accounting call comes
        // after the fee transfer out of necessity: the distributor accounts for a fee that must
        // already be in its balance. It is an internal protocol call and any failure reverts
        // the whole transaction, including the events above.
        ICashbackDistributor(distributor).recordListingFee(token, feeToken, fee);
    }

    /// @notice The listing-fee quote of `token` (all zero if it was never quoted).
    /// @param token Listed token.
    /// @return The stored quote, including `listingFeePaid`.
    function getListingFeeQuote(address token) external view returns (ListingFeeQuote memory) {
        return _listingFeeQuotes[token];
    }

    /// @notice Proposes the NiaraSettlement this registry takes the fee token and the
    /// CashbackDistributor from. Subject to the timelock.
    /// @param newSettlement A NiaraSettlement whose `listingRegistry()` is this contract.
    /// @return executeAfter Earliest timestamp `executeSetSettlement` can run.
    function proposeSetSettlement(address newSettlement)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        _checkSettlement(newSettlement);
        executeAfter = _scheduleAction(keccak256(abi.encode("SET_SETTLEMENT", newSettlement)));
        emit SettlementChangeProposed(newSettlement, executeAfter);
    }

    /// @notice Executes a proposed settlement link after the timelock delay. Open quotes keep
    /// their recorded fee token, so a link to a settlement with another fee token voids them
    /// (`NotFeeToken`) until they are re-quoted.
    /// @param newSettlement The proposed NiaraSettlement.
    function executeSetSettlement(address newSettlement) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkSettlement(newSettlement);
        _consumeAction(keccak256(abi.encode("SET_SETTLEMENT", newSettlement)));
        address old = address(settlement);
        settlement = INiaraSettlement(newSettlement);
        emit SettlementChanged(old, newSettlement);
    }

    /// @dev Reverts unless `newSettlement` is a non-zero contract whose registry is this one.
    function _checkSettlement(address newSettlement) private view {
        if (newSettlement == address(0)) revert ZeroAddress();
        if (address(INiaraSettlement(newSettlement).listingRegistry()) != address(this)) {
            revert SettlementRegistryMismatch(newSettlement);
        }
    }

    /// @dev The linked settlement; reverts `SettlementNotSet` while there is none.
    function _settlement() private view returns (INiaraSettlement settlement_) {
        settlement_ = settlement;
        if (address(settlement_) == address(0)) revert SettlementNotSet();
    }

    /// @notice Suspends an `Approved` listing (it can be re-approved later).
    /// @param token Listed token.
    function suspendListing(address token) external onlyRole(LISTING_AUTHORITY_ROLE) {
        Listing storage listing = _listings[token];
        if (listing.status != ListingStatus.Approved) revert InvalidStatusTransition(token, listing.status);
        listing.status = ListingStatus.Suspended;
        emit ListingSuspended(token);
    }

    /// @notice Delists a `Pending`, `Quoted`, `Approved` or `Suspended` listing. From
    /// `Pending` or `Quoted` this is how a listing is rejected. Final: a delisted token can
    /// never be approved, resubmitted or issued again.
    /// @param token Listed token.
    function delist(address token) external onlyRole(LISTING_AUTHORITY_ROLE) {
        Listing storage listing = _listings[token];
        ListingStatus from = listing.status;
        if (from == ListingStatus.None || from == ListingStatus.Delisted) {
            revert InvalidStatusTransition(token, from);
        }
        listing.status = ListingStatus.Delisted;
        emit ListingDelisted(token, from);
    }

    // ── Cashback freeze (spec §9.5) ─────────────────────────────────────────────────────

    /// @notice Freezes cashback withdrawals for one listing, without pausing the protocol
    /// (e.g. while an issuer key compromise is investigated). Accrual continues: settlements
    /// keep crediting cashback, which becomes withdrawable again after `unfreezeCashback`.
    /// @dev No timelock (containment must act at once), any listing status (cashback stays
    /// withdrawable after delisting, so it must stay freezable) and allowed while paused,
    /// like Solana's `freeze_cashback`. Reverts for listings that never accrue cashback
    /// (`Currency`, or no listing) and when already frozen.
    /// @param token Listed token whose issuer's cashback withdrawals are frozen.
    function freezeCashback(address token) external onlyRole(LISTING_AUTHORITY_ROLE) {
        _setCashbackFrozen(token, true);
    }

    /// @notice Lifts the cashback freeze of one listing; everything accrued while frozen is
    /// withdrawable again. Same rules as `freezeCashback`; reverts when not frozen.
    /// @param token Listed token whose issuer's cashback withdrawals are unfrozen.
    function unfreezeCashback(address token) external onlyRole(LISTING_AUTHORITY_ROLE) {
        _setCashbackFrozen(token, false);
    }

    function _setCashbackFrozen(address token, bool frozen) private {
        Listing storage listing = _listings[token];
        // `Currency` listings (and tokens with no listing) never accrue cashback.
        if (!listing.cashbackEligible) revert NotCashbackEligible(token);
        if (frozen && listing.cashbackFrozen) revert CashbackAlreadyFrozen(token);
        if (!frozen && !listing.cashbackFrozen) revert CashbackNotFrozen(token);
        listing.cashbackFrozen = frozen;
        emit CashbackFreezeSet(token, frozen, msg.sender);
    }

    /// @inheritdoc IListingRegistry
    function getListing(address token) external view returns (Listing memory) {
        return _listings[token];
    }

    /// @notice True if `token` has an `Approved` listing (any class).
    /// @param token Token to check.
    /// @return Whether the listing is approved.
    function isApproved(address token) external view returns (bool) {
        return _listings[token].status == ListingStatus.Approved;
    }

    // ── Issuance batches ────────────────────────────────────────────────────────────────

    /// @notice The issuer requests a new issuance batch. Allowed only while the listing is
    /// `Approved`, i.e. once its listing fee is paid (spec §3.12, issuance rule): a `Pending`,
    /// `Quoted`, `Suspended` or `Delisted` listing reverts `IssuanceNotAllowed`, creates no
    /// batch and does not advance `nextBatchNo`. Nothing is minted until the listing authority
    /// approves the batch, which also needs the listing `Approved`. Batches charge no listing
    /// fee.
    /// @dev A batch requested while `Approved` that is still open when the listing is
    /// suspended or delisted stays `Requested`: it executes after reinstatement, or the listing
    /// authority rejects it (`rejectIssuance` works in any status).
    /// @param token Factory token with a listing submitted by the caller.
    /// @param amount Amount to mint.
    /// @param recipient Who receives the batch.
    /// @param docHash Hash of the document authorizing this batch (non-zero).
    /// @return batchNo Sequential per-token batch number, starting at 1.
    function requestIssuance(address token, uint256 amount, address recipient, bytes32 docHash)
        external
        returns (uint256 batchNo)
    {
        Listing storage listing = _listings[token];
        // Currency listings have issuer == address(0), so they can never request issuance.
        if (msg.sender != listing.issuer) revert NotIssuer();
        ListingStatus status = listing.status;
        if (status != ListingStatus.Approved) revert IssuanceNotAllowed(token, status);
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (docHash == bytes32(0)) revert EmptyDocHash();

        batchNo = nextBatchNo[token]++;
        issuanceBatches[token][batchNo] = IssuanceBatch({
            amount: amount,
            recipient: recipient,
            docHash: docHash,
            status: IssuanceStatus.Requested,
            requestedAt: uint64(block.timestamp),
            resolvedAt: 0
        });
        emit IssuanceRequested(token, batchNo, amount, recipient, docHash);
    }

    /// @notice The listing authority approves a requested batch and the registry mints it.
    /// Executable only while the listing is `Approved` and the registry is not paused.
    /// @dev Check order mirrors Solana's `approve_issuance`: pause, then batch status, then
    /// listing status.
    /// @param token Factory token.
    /// @param batchNo Batch to approve.
    function approveIssuance(address token, uint256 batchNo)
        external
        nonReentrant
        onlyRole(LISTING_AUTHORITY_ROLE)
        whenNotPaused
    {
        IssuanceBatch storage batch = issuanceBatches[token][batchNo];
        if (batch.status != IssuanceStatus.Requested) revert BatchNotRequested(token, batchNo);
        if (_listings[token].status != ListingStatus.Approved) revert ListingNotApproved(token);

        // Checks-effects-interactions: the batch is marked executed and `IssuanceExecuted` is
        // emitted before the mint call, so the batch can never be minted twice and an
        // off-chain indexer sees IssuanceExecuted before the token's Transfer. The token is
        // a known factory implementation (no hooks), but the rule applies regardless.
        batch.status = IssuanceStatus.Executed;
        batch.resolvedAt = uint64(block.timestamp);
        uint256 amount = batch.amount;
        address recipient = batch.recipient;
        emit IssuanceExecuted(token, batchNo, amount, recipient, batch.docHash);

        NativeAssetToken(token).mint(recipient, amount);
    }

    /// @notice The listing authority rejects a requested batch; nothing is minted. Allowed
    /// in any listing status (e.g. to close requests left on a suspended or delisted
    /// listing). The batch stays on record as `Rejected`.
    /// @param token Factory token.
    /// @param batchNo Batch to reject.
    function rejectIssuance(address token, uint256 batchNo) external onlyRole(LISTING_AUTHORITY_ROLE) {
        IssuanceBatch storage batch = issuanceBatches[token][batchNo];
        if (batch.status != IssuanceStatus.Requested) revert BatchNotRequested(token, batchNo);
        batch.status = IssuanceStatus.Rejected;
        batch.resolvedAt = uint64(block.timestamp);
        emit IssuanceRejected(token, batchNo, batch.amount, batch.recipient);
    }
}

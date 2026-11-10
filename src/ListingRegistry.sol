// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {IListingRegistry} from "./interfaces/IListingRegistry.sol";
import {AssetTokenFactory} from "./AssetTokenFactory.sol";
import {NativeAssetToken} from "./NativeAssetToken.sol";

/// @title ListingRegistry
/// @notice Curated listing: a token only becomes tradable on Niara after the listing
/// authority approves it. Niara controls eligibility, never custody. EVM mirror of the
/// Solana `Listing` account and its instructions (EXCHANGE-MULTICHAIN-DESIGN.md, 3.2/3.3).
///
/// Status table (Delisted is final, one listing per token, no resubmission):
///
///   approveListing : Pending   -> Approved
///                    Suspended -> Approved
///   suspendListing : Approved  -> Suspended
///   delist         : Pending   -> Delisted   (rejection)
///                    Approved  -> Delisted
///                    Suspended -> Delisted
///
/// Issuance: the registry is the only minter of every factory token. The issuer requests a
/// batch (`requestIssuance`), the listing authority approves it (`approveIssuance`) and the
/// registry mints it, so neither the issuer nor Niara can mint alone.
///
/// Pause (spec §3.3, "Pause principle"): while paused, only `approveIssuance` is blocked,
/// since minting is the highest-impact action there is. Listing actions, `requestIssuance`
/// and `rejectIssuance` (neither mints) stay available.
/// @dev Role changes (including LISTING_AUTHORITY_ROLE) go through the inherited
/// timelock. Status changes and issuance approvals are operational and take effect
/// immediately, like the Solana `approve_listing` / `suspend_listing` / `delist`. Pause is
/// not timelocked: a circuit breaker must act immediately. Unlike Solana's single
/// `Config.paused`, this pause covers the registry only; NiaraSettlement has its own.
contract ListingRegistry is IListingRegistry, TimelockedAccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant LISTING_AUTHORITY_ROLE = keccak256("LISTING_AUTHORITY_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

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

    /// @notice Issuance batches per token, indexed by batch number.
    mapping(address token => mapping(uint256 batchNo => IssuanceBatch)) public issuanceBatches;

    /// @notice Next batch number for each token. Like Solana's `next_batch_no`: 1 after
    /// `submitListing` (batches are numbered from 1, sequentially, never skipped or
    /// reused), 0 for tokens without an issuer listing (including `Currency`).
    mapping(address token => uint256) public nextBatchNo;

    event ListingSubmitted(
        address indexed token, address indexed issuer, AssetClass assetClass, bytes32 docHash
    );
    event CurrencyListed(address indexed token, uint64 approvedAt);
    event ListingApproved(address indexed token, uint64 approvedAt);
    event ListingSuspended(address indexed token);
    event ListingDelisted(address indexed token, ListingStatus previousStatus);
    event IssuanceRequested(
        address indexed token, uint256 indexed batchNo, uint256 amount, address recipient, bytes32 docHash
    );
    event IssuanceExecuted(
        address indexed token, uint256 indexed batchNo, uint256 amount, address recipient, bytes32 docHash
    );
    event IssuanceRejected(address indexed token, uint256 indexed batchNo, uint256 amount, address recipient);

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

    /// @notice Pauses issuance execution (`approveIssuance`) in an emergency.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Removes the pause.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
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
            approvedAt: 0
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
            approvedAt: approvedAt
        });
        emit CurrencyListed(token, approvedAt);
    }

    /// @notice Approves a `Pending` listing, or re-approves a `Suspended` one.
    /// @param token Listed token.
    function approveListing(address token) external onlyRole(LISTING_AUTHORITY_ROLE) {
        Listing storage listing = _listings[token];
        ListingStatus from = listing.status;
        if (from != ListingStatus.Pending && from != ListingStatus.Suspended) {
            revert InvalidStatusTransition(token, from);
        }
        uint64 approvedAt = uint64(block.timestamp);
        listing.status = ListingStatus.Approved;
        listing.approvedAt = approvedAt;
        emit ListingApproved(token, approvedAt);
    }

    /// @notice Suspends an `Approved` listing (it can be re-approved later).
    /// @param token Listed token.
    function suspendListing(address token) external onlyRole(LISTING_AUTHORITY_ROLE) {
        Listing storage listing = _listings[token];
        if (listing.status != ListingStatus.Approved) revert InvalidStatusTransition(token, listing.status);
        listing.status = ListingStatus.Suspended;
        emit ListingSuspended(token);
    }

    /// @notice Delists a `Pending`, `Approved` or `Suspended` listing. Final: a delisted
    /// token can never be approved, resubmitted or issued again.
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

    /// @notice The issuer requests a new issuance batch. Allowed while the listing is
    /// `Pending` or `Approved`. Nothing is minted until the listing authority approves it.
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
        if (listing.status != ListingStatus.Pending && listing.status != ListingStatus.Approved) {
            revert IssuanceNotAllowed(token, listing.status);
        }
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

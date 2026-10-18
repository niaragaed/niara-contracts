// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {IAssetToken} from "./interfaces/IAssetToken.sol";

// This contract does NOT execute exchange orders. It records requests and attestations.
// Execution is the responsibility of an authorized off-chain agent.
// Share buybacks by the issuing company itself are a regulated activity and are NOT
// implemented here: the model assumes market acquisition by a custodian.

/// @title BackingGateway
/// @notice Coordinates an AssetToken's backing process on-chain. No smart contract can
/// execute orders on a traditional exchange: this contract only records requests
/// (`requestBacking`) and attestations from an authorized custodian (`attestBacking`), and
/// only then allows minting (`mintAttested`). The reverse path (`redemptionRequest` /
/// `redemptionAttest`) burns the token and releases the real-world asset.
/// @dev `totalAttested[asset]` is the source of truth that the AssetToken itself reads in
/// `mint` to enforce `totalSupply <= totalAttested`. This contract must hold MINTER_ROLE and
/// BURNER_ROLE on the AssetToken(s) it coordinates.
contract BackingGateway is TimelockedAccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    enum RequestStatus {
        NONE,
        PENDING,
        SETTLED,
        CANCELLED
    }

    struct BackingRequest {
        address asset;
        address requester;
        uint256 quantityRequested;
        uint256 quantityAcquired;
        bytes32 proofHash;
        RequestStatus status;
        bool minted;
    }

    struct RedemptionRequest {
        address asset;
        address requester;
        uint256 quantity;
        bytes32 proofHash;
        RequestStatus status;
    }

    /// @notice Total attested (in custody) per asset. Hard cap for `AssetToken.mint`.
    mapping(address asset => uint256) public totalAttested;

    mapping(uint256 => BackingRequest) public backingRequests;
    uint256 public nextBackingRequestId;

    mapping(uint256 => RedemptionRequest) public redemptionRequests;
    uint256 public nextRedemptionRequestId;

    event BackingRequested(uint256 indexed requestId, address indexed asset, uint256 quantity, address indexed requester);
    event BackingAttested(uint256 indexed requestId, address indexed asset, bytes32 proofHash, uint256 quantityAcquired);
    event BackingRequestCancelled(uint256 indexed requestId);
    event BackingMinted(uint256 indexed requestId, address indexed asset, address indexed to, uint256 quantity);

    event RedemptionRequested(uint256 indexed requestId, address indexed asset, address indexed requester, uint256 quantity);
    event RedemptionAttested(uint256 indexed requestId, address indexed asset, bytes32 proofHash, uint256 quantity);
    event RedemptionRequestCancelled(uint256 indexed requestId, address indexed requester, uint256 quantity);

    error ZeroAddress();
    error ZeroQuantity();
    error RequestNotPending(uint256 requestId);
    error RequestNotSettled(uint256 requestId);
    error AlreadyMinted(uint256 requestId);
    error QuantityAcquiredExceedsRequested(uint256 quantityAcquired, uint256 quantityRequested);

    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
    }

    // ── Backing (issuance) ──────────────────────────────────────────────────────────────

    /// @notice Records a request to acquire backing for `asset`. Emits an event to be
    /// consumed by an authorized off-chain agent, which executes the purchase on the
    /// traditional market. Moves no funds on-chain.
    function requestBacking(address asset, uint256 quantity)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        returns (uint256 requestId)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (quantity == 0) revert ZeroQuantity();

        requestId = nextBackingRequestId++;
        backingRequests[requestId] = BackingRequest({
            asset: asset,
            requester: msg.sender,
            quantityRequested: quantity,
            quantityAcquired: 0,
            proofHash: bytes32(0),
            status: RequestStatus.PENDING,
            minted: false
        });

        emit BackingRequested(requestId, asset, quantity, msg.sender);
    }

    /// @notice Confirms the asset was acquired and is in custody. Only CUSTODIAN_ROLE
    /// can call it. Increases `totalAttested[asset]` by `quantityAcquired`, the cap that
    /// `AssetToken.mint` respects.
    function attestBacking(uint256 requestId, bytes32 proofHash, uint256 quantityAcquired)
        external
        onlyRole(CUSTODIAN_ROLE)
        whenNotPaused
    {
        BackingRequest storage req = backingRequests[requestId];
        if (req.status != RequestStatus.PENDING) revert RequestNotPending(requestId);
        if (quantityAcquired == 0) revert ZeroQuantity();
        if (quantityAcquired > req.quantityRequested) {
            revert QuantityAcquiredExceedsRequested(quantityAcquired, req.quantityRequested);
        }

        req.quantityAcquired = quantityAcquired;
        req.proofHash = proofHash;
        req.status = RequestStatus.SETTLED;
        totalAttested[req.asset] += quantityAcquired;

        emit BackingAttested(requestId, req.asset, proofHash, quantityAcquired);
    }

    /// @notice Mints to `to` the attested quantity of a request that is already SETTLED.
    /// Can happen only once per request. The definitive lock against unbacked issuance lives
    /// in `AssetToken.mint`, not here; this function only prevents minting the same
    /// request twice.
    function mintAttested(uint256 requestId, address to) external nonReentrant onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        BackingRequest storage req = backingRequests[requestId];
        if (req.status != RequestStatus.SETTLED) revert RequestNotSettled(requestId);
        if (req.minted) revert AlreadyMinted(requestId);

        // Checks-effects-interactions: `minted` and the event are written BEFORE the mint.
        // If the AssetToken has a hook (ERC-777/ERC-1363) and re-enters another function of this
        // contract during `mint`, that re-entry already reads `minted == true`: there is no
        // window in which the request appears unminted while minting is in progress.
        req.minted = true;
        emit BackingMinted(requestId, req.asset, to, req.quantityAcquired);

        IAssetToken(req.asset).mint(to, req.quantityAcquired);
    }

    /// @notice Cancels a backing request that is still pending. No funds were moved at
    /// this stage, so cancelling is just a status change.
    function cancelBackingRequest(uint256 requestId) external onlyRole(OPERATOR_ROLE) {
        BackingRequest storage req = backingRequests[requestId];
        if (req.status != RequestStatus.PENDING) revert RequestNotPending(requestId);
        req.status = RequestStatus.CANCELLED;
        emit BackingRequestCancelled(requestId);
    }

    // ── Resgate (queima) ────────────────────────────────────────────────────────────────

    /// @notice Any holder can request redemption of their own tokens for the real-world
    /// asset. The tokens are held in custody by this contract (not burned yet) until the
    /// release of the real-world asset is attested, to allow cancellation if the off-chain
    /// release does not happen.
    function redemptionRequest(address asset, uint256 quantity) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (asset == address(0)) revert ZeroAddress();
        if (quantity == 0) revert ZeroQuantity();

        requestId = nextRedemptionRequestId++;
        redemptionRequests[requestId] = RedemptionRequest({
            asset: asset,
            requester: msg.sender,
            quantity: quantity,
            proofHash: bytes32(0),
            status: RequestStatus.PENDING
        });

        IERC20(asset).safeTransferFrom(msg.sender, address(this), quantity);

        emit RedemptionRequested(requestId, asset, msg.sender, quantity);
    }

    /// @notice Confirms the real-world asset was released off-chain. Only then are the
    /// custodied tokens burned and `totalAttested[asset]` reduced by the same quantity.
    function redemptionAttest(uint256 requestId, bytes32 proofHash) external nonReentrant onlyRole(CUSTODIAN_ROLE) whenNotPaused {
        RedemptionRequest storage req = redemptionRequests[requestId];
        if (req.status != RequestStatus.PENDING) revert RequestNotPending(requestId);

        // Checks-effects-interactions: final status, proof and `totalAttested` are written
        // and the event emitted BEFORE the burn. A re-entry from an AssetToken hook during
        // `burn` already finds the request SETTLED; `cancelRedemptionRequest`, for example,
        // reverts with `RequestNotPending` instead of returning tokens from a redemption that
        // is being settled.
        req.status = RequestStatus.SETTLED;
        req.proofHash = proofHash;
        totalAttested[req.asset] -= req.quantity;
        emit RedemptionAttested(requestId, req.asset, proofHash, req.quantity);

        IAssetToken(req.asset).burn(address(this), req.quantity);
    }

    /// @notice Cancels a pending redemption request and returns the custodied tokens to
    /// the requester. Used when the off-chain release of the real-world asset could not happen.
    function cancelRedemptionRequest(uint256 requestId) external nonReentrant onlyRole(CUSTODIAN_ROLE) {
        RedemptionRequest storage req = redemptionRequests[requestId];
        if (req.status != RequestStatus.PENDING) revert RequestNotPending(requestId);

        // Checks-effects-interactions: CANCELLED status and the event are written BEFORE the
        // custodied tokens are returned. If `req.asset` has a hook (ERC-777/ERC-1363) and
        // re-enters another function of this contract during the transfer, that re-entry already
        // finds the request CANCELLED; `redemptionAttest`, for example, reverts with
        // `RequestNotPending` instead of burning tokens from an already cancelled redemption.
        req.status = RequestStatus.CANCELLED;
        emit RedemptionRequestCancelled(requestId, req.requester, req.quantity);

        IERC20(req.asset).safeTransfer(req.requester, req.quantity);
    }

    // ── Emergency ───────────────────────────────────────────────────────────────────────

    /// @notice Pausa requestBacking, attestBacking, mintAttested e redemptionRequest.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Remove a pausa.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title TimelockedAccessControl
/// @notice Governance base for Niara's contracts: every role grant/revocation, and every
/// parameter the child contract marks as sensitive, goes through a configurable delay
/// between proposal and execution (propose/execute pattern).
/// @dev Designed to run with DEFAULT_ADMIN_ROLE (and the other admin roles) assigned to a
/// multisig wallet (e.g. Gnosis Safe). There is no multisig logic here: any address (EOA
/// or contract) can hold a role; "N of M signatures" security is entirely up to the
/// multisig used as the role holder.
///
/// `grantRole`/`revokeRole` (the standard AccessControl functions) are disabled on
/// purpose: every role change must go through `proposeGrantRole`/`executeGrantRole`
/// or `proposeRevokeRole`/`executeRevokeRole`. `renounceRole` stays available without a
/// timelock: a holder giving up its own role is always safe (it only reduces its own
/// privilege) and may be needed immediately in an emergency.
abstract contract TimelockedAccessControl is AccessControl {
    uint256 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint256 public constant MAX_TIMELOCK_DELAY = 30 days;

    /// @notice Current delay, in seconds, between proposal and execution of a sensitive action.
    uint256 public timelockDelay;

    /// @notice Timestamp (>0) from which the action identified by `actionId` can be
    /// executed. Zero means "no pending proposal".
    mapping(bytes32 => uint256) public pendingActions;

    event ActionProposed(bytes32 indexed actionId, uint256 executeAfter);
    event ActionExecuted(bytes32 indexed actionId);
    event ActionCancelled(bytes32 indexed actionId);
    event TimelockDelayChangeProposed(uint256 newDelay, uint256 executeAfter);
    event TimelockDelayChanged(uint256 oldDelay, uint256 newDelay);

    error ActionAlreadyPending(bytes32 actionId);
    error ActionNotPending(bytes32 actionId);
    error TimelockNotElapsed(bytes32 actionId, uint256 executeAfter);
    error InvalidTimelockDelay(uint256 delay);
    error RoleChangeRequiresTimelock();

    constructor(uint256 _timelockDelay) {
        if (_timelockDelay < MIN_TIMELOCK_DELAY || _timelockDelay > MAX_TIMELOCK_DELAY) {
            revert InvalidTimelockDelay(_timelockDelay);
        }
        timelockDelay = _timelockDelay;
    }

    /// @dev Records a proposal and returns the earliest execution timestamp. Reverts if an
    /// identical proposal is already pending.
    function _scheduleAction(bytes32 actionId) internal returns (uint256 executeAfter) {
        if (pendingActions[actionId] != 0) revert ActionAlreadyPending(actionId);
        executeAfter = block.timestamp + timelockDelay;
        pendingActions[actionId] = executeAfter;
        emit ActionProposed(actionId, executeAfter);
    }

    /// @dev Checks that the proposal exists and that the delay has passed, and consumes it.
    function _consumeAction(bytes32 actionId) internal {
        uint256 executeAfter = pendingActions[actionId];
        if (executeAfter == 0) revert ActionNotPending(actionId);
        if (block.timestamp < executeAfter) revert TimelockNotElapsed(actionId, executeAfter);
        delete pendingActions[actionId];
        emit ActionExecuted(actionId);
    }

    /// @notice Cancels a pending proposal before it is executed.
    function cancelAction(bytes32 actionId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingActions[actionId] == 0) revert ActionNotPending(actionId);
        delete pendingActions[actionId];
        emit ActionCancelled(actionId);
    }

    // ── Timelock delay (also subject to the timelock) ──────────────────────────────────

    function proposeSetTimelockDelay(uint256 newDelay)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (newDelay < MIN_TIMELOCK_DELAY || newDelay > MAX_TIMELOCK_DELAY) {
            revert InvalidTimelockDelay(newDelay);
        }
        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", newDelay));
        executeAfter = _scheduleAction(actionId);
        emit TimelockDelayChangeProposed(newDelay, executeAfter);
    }

    function executeSetTimelockDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", newDelay));
        _consumeAction(actionId);
        uint256 old = timelockDelay;
        timelockDelay = newDelay;
        emit TimelockDelayChanged(old, newDelay);
    }

    // ── Roles: standard grantRole/revokeRole disabled, replaced by timelocked versions ──

    /// @dev Disabled on purpose. Use `proposeGrantRole` / `executeGrantRole`.
    function grantRole(bytes32, address) public pure override {
        revert RoleChangeRequiresTimelock();
    }

    /// @dev Disabled on purpose. Use `proposeRevokeRole` / `executeRevokeRole`.
    function revokeRole(bytes32, address) public pure override {
        revert RoleChangeRequiresTimelock();
    }

    function proposeGrantRole(bytes32 role, address account)
        external
        onlyRole(getRoleAdmin(role))
        returns (uint256 executeAfter)
    {
        bytes32 actionId = keccak256(abi.encode("GRANT_ROLE", role, account));
        executeAfter = _scheduleAction(actionId);
    }

    function executeGrantRole(bytes32 role, address account) external onlyRole(getRoleAdmin(role)) {
        bytes32 actionId = keccak256(abi.encode("GRANT_ROLE", role, account));
        _consumeAction(actionId);
        _grantRole(role, account);
    }

    function proposeRevokeRole(bytes32 role, address account)
        external
        onlyRole(getRoleAdmin(role))
        returns (uint256 executeAfter)
    {
        bytes32 actionId = keccak256(abi.encode("REVOKE_ROLE", role, account));
        executeAfter = _scheduleAction(actionId);
    }

    function executeRevokeRole(bytes32 role, address account) external onlyRole(getRoleAdmin(role)) {
        bytes32 actionId = keccak256(abi.encode("REVOKE_ROLE", role, account));
        _consumeAction(actionId);
        _revokeRole(role, account);
    }
}

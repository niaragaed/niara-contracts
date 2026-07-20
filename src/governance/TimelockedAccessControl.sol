// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title TimelockedAccessControl
/// @notice Base de governança para os contratos da Niara: qualquer concessão/revogação de
/// papel, e qualquer parâmetro que o contrato filho marque como sensível, passa por um
/// atraso configurável entre proposta e execução (padrão propose/execute).
/// @dev Pensado para operar com DEFAULT_ADMIN_ROLE (e demais papéis administrativos)
/// atribuídos a uma carteira multisig (ex.: Gnosis Safe). Não há lógica de multisig aqui —
/// qualquer endereço (EOA ou contrato) pode ser titular de um papel; a segurança de "N de M
/// assinaturas" fica inteiramente a cargo do multisig usado como titular do papel.
///
/// `grantRole`/`revokeRole` (as funções padrão do AccessControl) são desabilitadas de
/// propósito — toda mudança de papel deve passar por `proposeGrantRole`/`executeGrantRole`
/// ou `proposeRevokeRole`/`executeRevokeRole`. `renounceRole` continua liberado sem timelock:
/// um titular abrir mão do próprio papel é sempre seguro (só reduz privilégio próprio) e pode
/// ser necessário imediatamente numa emergência.
abstract contract TimelockedAccessControl is AccessControl {
    uint256 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint256 public constant MAX_TIMELOCK_DELAY = 30 days;

    /// @notice Atraso atual, em segundos, entre proposta e execução de uma ação sensível.
    uint256 public timelockDelay;

    /// @notice Timestamp (>0) a partir do qual a ação identificada por `actionId` pode ser
    /// executada. Zero significa "nenhuma proposta pendente".
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

    /// @dev Registra uma proposta e retorna o timestamp mínimo de execução. Reverte se já
    /// houver uma proposta idêntica pendente.
    function _scheduleAction(bytes32 actionId) internal returns (uint256 executeAfter) {
        if (pendingActions[actionId] != 0) revert ActionAlreadyPending(actionId);
        executeAfter = block.timestamp + timelockDelay;
        pendingActions[actionId] = executeAfter;
        emit ActionProposed(actionId, executeAfter);
    }

    /// @dev Verifica que a proposta existe e que o atraso já decorreu, e a consome.
    function _consumeAction(bytes32 actionId) internal {
        uint256 executeAfter = pendingActions[actionId];
        if (executeAfter == 0) revert ActionNotPending(actionId);
        if (block.timestamp < executeAfter) revert TimelockNotElapsed(actionId, executeAfter);
        delete pendingActions[actionId];
        emit ActionExecuted(actionId);
    }

    /// @notice Cancela uma proposta pendente antes de ser executada.
    function cancelAction(bytes32 actionId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingActions[actionId] == 0) revert ActionNotPending(actionId);
        delete pendingActions[actionId];
        emit ActionCancelled(actionId);
    }

    // ── Atraso do timelock (também sujeito a timelock) ─────────────────────────────────

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

    // ── Papéis: grantRole/revokeRole padrão desabilitados, substituídos por versões com timelock ──

    /// @dev Desabilitada de propósito. Use `proposeGrantRole` / `executeGrantRole`.
    function grantRole(bytes32, address) public pure override {
        revert RoleChangeRequiresTimelock();
    }

    /// @dev Desabilitada de propósito. Use `proposeRevokeRole` / `executeRevokeRole`.
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

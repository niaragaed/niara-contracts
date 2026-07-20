// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {IAssetToken} from "./interfaces/IAssetToken.sol";

// Este contrato NÃO executa ordens em bolsa. Ele registra pedidos e atestações.
// A execução é responsabilidade de agente off-chain autorizado.
// A recompra de ações pela própria companhia emissora é atividade regulada e NÃO
// está implementada aqui — o modelo assume aquisição em mercado por custodiante.

/// @title BackingGateway
/// @notice Coordena on-chain o processo de lastro de um AssetToken. Nenhum smart contract
/// consegue executar ordens em bolsa tradicional — este contrato apenas registra pedidos
/// (`requestBacking`) e atestações de um custodiante autorizado (`attestBacking`), e só
/// então libera a cunhagem (`mintAttested`). O caminho inverso (`redemptionRequest` /
/// `redemptionAttest`) queima o token e libera o ativo real.
/// @dev `totalAttested[asset]` é a fonte da verdade que o próprio AssetToken consulta em
/// `mint` para impor `totalSupply <= totalAtestado`. Este contrato deve deter MINTER_ROLE e
/// BURNER_ROLE no(s) AssetToken(s) que coordena.
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

    /// @notice Total atestado (em custódia) por ativo. Teto rígido para `AssetToken.mint`.
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

    // ── Lastro (emissão) ────────────────────────────────────────────────────────────────

    /// @notice Registra um pedido de aquisição de lastro para `asset`. Emite um evento a
    /// ser consumido por um agente off-chain autorizado, que executa a compra no mercado
    /// tradicional. Não move nenhum fundo on-chain.
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

    /// @notice Confirma que o ativo foi adquirido e está em custódia. Só CUSTODIAN_ROLE
    /// pode chamar. Aumenta `totalAttested[asset]` em `quantityAcquired` — o teto que
    /// `AssetToken.mint` respeita.
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

    /// @notice Cunha, para `to`, a quantidade atestada de um pedido já SETTLED. Só pode
    /// ocorrer uma vez por pedido. A trava definitiva contra emissão sem lastro vive em
    /// `AssetToken.mint`, não aqui — esta função apenas evita cunhar duas vezes o mesmo
    /// pedido.
    function mintAttested(uint256 requestId, address to) external onlyRole(OPERATOR_ROLE) nonReentrant whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        BackingRequest storage req = backingRequests[requestId];
        if (req.status != RequestStatus.SETTLED) revert RequestNotSettled(requestId);
        if (req.minted) revert AlreadyMinted(requestId);

        req.minted = true;
        IAssetToken(req.asset).mint(to, req.quantityAcquired);

        emit BackingMinted(requestId, req.asset, to, req.quantityAcquired);
    }

    /// @notice Cancela um pedido de lastro ainda pendente. Nenhum fundo foi movido nesta
    /// etapa, então cancelar é apenas uma mudança de status.
    function cancelBackingRequest(uint256 requestId) external onlyRole(OPERATOR_ROLE) {
        BackingRequest storage req = backingRequests[requestId];
        if (req.status != RequestStatus.PENDING) revert RequestNotPending(requestId);
        req.status = RequestStatus.CANCELLED;
        emit BackingRequestCancelled(requestId);
    }

    // ── Resgate (queima) ────────────────────────────────────────────────────────────────

    /// @notice Qualquer detentor pode solicitar o resgate dos próprios tokens pelo ativo
    /// real. Os tokens ficam custodiados por este contrato (não são queimados ainda) até a
    /// atestação da liberação do ativo real, para permitir cancelamento caso a liberação
    /// off-chain não se concretize.
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

    /// @notice Confirma que o ativo real foi liberado off-chain. Só então os tokens
    /// custodiados são queimados e `totalAttested[asset]` é reduzido na mesma quantidade.
    function redemptionAttest(uint256 requestId, bytes32 proofHash) external onlyRole(CUSTODIAN_ROLE) nonReentrant whenNotPaused {
        RedemptionRequest storage req = redemptionRequests[requestId];
        if (req.status != RequestStatus.PENDING) revert RequestNotPending(requestId);

        req.status = RequestStatus.SETTLED;
        req.proofHash = proofHash;
        totalAttested[req.asset] -= req.quantity;

        IAssetToken(req.asset).burn(address(this), req.quantity);

        emit RedemptionAttested(requestId, req.asset, proofHash, req.quantity);
    }

    /// @notice Cancela um pedido de resgate pendente e devolve os tokens custodiados ao
    /// solicitante — usado quando a liberação off-chain do ativo real não pôde ocorrer.
    function cancelRedemptionRequest(uint256 requestId) external onlyRole(CUSTODIAN_ROLE) nonReentrant {
        RedemptionRequest storage req = redemptionRequests[requestId];
        if (req.status != RequestStatus.PENDING) revert RequestNotPending(requestId);

        req.status = RequestStatus.CANCELLED;
        IERC20(req.asset).safeTransfer(req.requester, req.quantity);

        emit RedemptionRequestCancelled(requestId, req.requester, req.quantity);
    }

    // ── Emergência ──────────────────────────────────────────────────────────────────────

    /// @notice Pausa requestBacking, attestBacking, mintAttested e redemptionRequest.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Remove a pausa.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

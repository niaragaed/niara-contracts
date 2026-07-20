// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {IBackingGateway} from "./interfaces/IBackingGateway.sol";

/// @title AssetToken
/// @notice ERC-20 representando um ativo real tokenizado, com lastro 1:1 sob custódia
/// regulada. Nunca é cunhado além do lastro atestado por um BackingGateway (ver
/// invariante em `mint`).
/// @dev A moeda de origem/emissão do ativo tokenizado não é definida aqui — este contrato
/// representa o ativo em si (ex.: uma ação, ETF, commodity ou moeda tokenizada), não uma
/// posição de liquidação. Usa 18 casas decimais (padrão ERC-20), suficiente para frações do
/// ativo subjacente.
contract AssetToken is ERC20, Pausable, TimelockedAccessControl {
    /// @notice Classe do ativo representado por este token.
    enum AssetClass {
        EQUITY,
        ETF,
        COMMODITY,
        FUND,
        CURRENCY
    }

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");

    /// @notice Ticker/ISIN ou outra referência do ativo real subjacente.
    string public assetReference;

    /// @notice Classe do ativo (imutável — corporate actions que mudem a classe exigem
    /// um novo AssetToken, não uma migração deste).
    AssetClass public immutable assetClass;

    /// @notice País de origem do ativo (ex.: "US", "BR").
    string public countryOfOrigin;

    /// @notice Verdadeiro para EQUITY e ETF — CURRENCY, COMMODITY e FUND nunca são
    /// elegíveis a cashback ao emissor (imutável, decorre da classe do ativo).
    bool public immutable cashbackEligible;

    /// @notice Carteira da empresa emissora, destinatária do cashback. Alterável apenas
    /// pelo admin, sujeito a timelock.
    address public issuerWallet;

    /// @notice Endereço do BackingGateway autorizado a atestar lastro para este token.
    /// `mint` consulta `totalAttested` deste endereço a cada chamada — trocar este
    /// endereço é tão sensível quanto trocar o próprio critério de lastro, por isso
    /// também é sujeito a timelock.
    address public backingGateway;

    event Minted(address indexed to, uint256 amount, uint256 totalAttestedAtMint);
    event Burned(address indexed from, uint256 amount);
    event IssuerWalletChangeProposed(address indexed newIssuerWallet, uint256 executeAfter);
    event IssuerWalletChanged(address indexed oldIssuerWallet, address indexed newIssuerWallet);
    event BackingGatewayChangeProposed(address indexed newBackingGateway, uint256 executeAfter);
    event BackingGatewayChanged(address indexed oldBackingGateway, address indexed newBackingGateway);

    error ZeroAddress();
    error MintExceedsAttestedBacking(uint256 requestedSupply, uint256 attested);
    error BackingGatewayNotSet();
    error NotAuthorizedToPause();

    /// @param name_ Nome do token (ex.: "Apple Inc. — Niara Tokenized Equity").
    /// @param symbol_ Símbolo do token (ex.: "nAAPL").
    /// @param assetReference_ Ticker/ISIN do ativo real.
    /// @param assetClass_ Classe do ativo.
    /// @param countryOfOrigin_ País de origem do ativo.
    /// @param issuerWallet_ Carteira inicial da empresa emissora.
    /// @param admin_ Titular inicial de DEFAULT_ADMIN_ROLE, PAUSER_ROLE e CUSTODIAN_ROLE
    /// (recomendado: um multisig).
    /// @param timelockDelay_ Atraso inicial (segundos) entre proposta e execução de
    /// mudanças sensíveis.
    constructor(
        string memory name_,
        string memory symbol_,
        string memory assetReference_,
        AssetClass assetClass_,
        string memory countryOfOrigin_,
        address issuerWallet_,
        address admin_,
        uint256 timelockDelay_
    ) ERC20(name_, symbol_) TimelockedAccessControl(timelockDelay_) {
        if (issuerWallet_ == address(0) || admin_ == address(0)) revert ZeroAddress();

        assetReference = assetReference_;
        assetClass = assetClass_;
        countryOfOrigin = countryOfOrigin_;
        issuerWallet = issuerWallet_;
        cashbackEligible = !(
            assetClass_ == AssetClass.CURRENCY || assetClass_ == AssetClass.COMMODITY
                || assetClass_ == AssetClass.FUND
        );

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
        _grantRole(CUSTODIAN_ROLE, admin_);
    }

    /// @notice Cunha `amount` de tokens para `to`, desde que o total emitido resultante
    /// não exceda o lastro atestado pelo BackingGateway configurado.
    /// @dev Esta checagem é estrutural: mesmo que MINTER_ROLE seja concedido a um endereço
    /// diferente do BackingGateway "oficial", ainda assim é impossível cunhar além do que o
    /// BackingGateway configurado reporta como atestado — a trava vive neste contrato, não
    /// apenas no controle de acesso de quem chama.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        if (backingGateway == address(0)) revert BackingGatewayNotSet();
        uint256 attested = IBackingGateway(backingGateway).totalAttested(address(this));
        uint256 newSupply = totalSupply() + amount;
        if (newSupply > attested) revert MintExceedsAttestedBacking(newSupply, attested);
        _mint(to, amount);
        emit Minted(to, amount, attested);
    }

    /// @notice Queima `amount` de tokens de `from`. Usado pelo BackingGateway no caminho
    /// de resgate, após a liberação do ativo real ser atestada.
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
        emit Burned(from, amount);
    }

    /// @notice Pausa transferências, mint e burn. PAUSER_ROLE ou CUSTODIAN_ROLE podem
    /// acionar — o custodiante, que enxerga o estado real da custódia, pode travar o
    /// token imediatamente ao detectar um problema, sem esperar o admin.
    function pause() external {
        if (!hasRole(PAUSER_ROLE, msg.sender) && !hasRole(CUSTODIAN_ROLE, msg.sender)) {
            revert NotAuthorizedToPause();
        }
        _pause();
    }

    /// @notice Remove a pausa. Decisão deliberada: apenas PAUSER_ROLE (governança), nunca
    /// CUSTODIAN_ROLE sozinho — travar é uma ação unilateral de emergência, destravar exige
    /// o processo de governança normal.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function proposeSetIssuerWallet(address newIssuerWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (newIssuerWallet == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_ISSUER_WALLET", newIssuerWallet));
        executeAfter = _scheduleAction(actionId);
        emit IssuerWalletChangeProposed(newIssuerWallet, executeAfter);
    }

    function executeSetIssuerWallet(address newIssuerWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_ISSUER_WALLET", newIssuerWallet));
        _consumeAction(actionId);
        address old = issuerWallet;
        issuerWallet = newIssuerWallet;
        emit IssuerWalletChanged(old, newIssuerWallet);
    }

    function proposeSetBackingGateway(address newBackingGateway)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (newBackingGateway == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_BACKING_GATEWAY", newBackingGateway));
        executeAfter = _scheduleAction(actionId);
        emit BackingGatewayChangeProposed(newBackingGateway, executeAfter);
    }

    function executeSetBackingGateway(address newBackingGateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_BACKING_GATEWAY", newBackingGateway));
        _consumeAction(actionId);
        address old = backingGateway;
        backingGateway = newBackingGateway;
        emit BackingGatewayChanged(old, newBackingGateway);
    }

    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }
}

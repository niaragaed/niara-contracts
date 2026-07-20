// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {ICashbackDistributor} from "./interfaces/ICashbackDistributor.sol";

/// @title NiaraSettlement
/// @notice Liquidação atômica entre comprador e vendedor: na mesma transação, transfere o
/// AssetToken do vendedor ao comprador, o pagamento (USDT ou WBTC) do comprador ao vendedor,
/// e retém a taxa do protocolo — na própria moeda de liquidação, sem swap, sem DEX, sem
/// oráculo. Qualquer falha reverte tudo.
/// @dev Nunca custodia saldo das partes: opera inteiramente por `allowance`, movendo apenas
/// o valor exato de cada execução. `settle` é restrita a SETTLEMENT_OPERATOR_ROLE — embora o
/// movimento de fundos dependa só de allowance, permitir que qualquer endereço dispare
/// liquidações entre duas partes que aprovaram o contrato abriria margem para um chamador
/// arbitrário escolher termos desfavoráveis dentro dessas aprovações. O papel deve ser
/// concedido ao motor de casamento de ordens confiável da Niara.
contract NiaraSettlement is TimelockedAccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_OPERATOR_ROLE = keccak256("SETTLEMENT_OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Teto rígido e imutável da taxa: 100 bps (1%). Nem o admin pode superá-lo.
    uint16 public constant MAX_FEE_BPS = 100;

    /// @notice Taxa atual, em bps, cobrada na moeda de liquidação. Padrão: 50 bps (0,5%).
    uint16 public feeBps = 50;

    /// @notice Contrato que recebe a taxa e credita cashback ao emissor quando elegível.
    ICashbackDistributor public cashbackDistributor;

    event Settled(
        address indexed assetToken,
        address indexed paymentToken,
        address indexed buyer,
        address seller,
        uint256 assetAmount,
        uint256 paymentAmount,
        uint256 feeCharged
    );
    event FeeBpsChangeProposed(uint16 newFeeBps, uint256 executeAfter);
    event FeeBpsChanged(uint16 oldFeeBps, uint16 newFeeBps);
    event CashbackDistributorChangeProposed(address indexed newCashbackDistributor, uint256 executeAfter);
    event CashbackDistributorChanged(address indexed oldCashbackDistributor, address indexed newCashbackDistributor);

    error ZeroAddress();
    error BuyerEqualsSeller();
    error ZeroAmount();
    error FeeExceedsCap(uint16 feeBps);
    error PaymentAmountTooSmallForFeePrecision();

    constructor(address admin_, address cashbackDistributor_, uint256 timelockDelay_)
        TimelockedAccessControl(timelockDelay_)
    {
        if (admin_ == address(0) || cashbackDistributor_ == address(0)) revert ZeroAddress();
        cashbackDistributor = ICashbackDistributor(cashbackDistributor_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
    }

    /// @notice Executa a liquidação atômica de uma ordem já casada.
    /// @param assetToken Token do ativo tokenizado sendo negociado.
    /// @param paymentToken Moeda de liquidação (USDT ou WBTC).
    /// @param buyer Parte que recebe o ativo e paga em `paymentToken`.
    /// @param seller Parte que entrega o ativo e recebe em `paymentToken`.
    /// @param assetAmount Quantidade de `assetToken` transferida do vendedor ao comprador.
    /// @param paymentAmount Valor total em `paymentToken` que o comprador paga; a taxa é
    /// descontada deste valor antes de chegar ao vendedor.
    /// @return feeCharged Valor da taxa retido, em `paymentToken`.
    function settle(
        address assetToken,
        address paymentToken,
        address buyer,
        address seller,
        uint256 assetAmount,
        uint256 paymentAmount
    ) external onlyRole(SETTLEMENT_OPERATOR_ROLE) nonReentrant whenNotPaused returns (uint256 feeCharged) {
        if (assetToken == address(0) || paymentToken == address(0)) revert ZeroAddress();
        if (buyer == address(0) || seller == address(0)) revert ZeroAddress();
        if (buyer == seller) revert BuyerEqualsSeller();
        if (assetAmount == 0 || paymentAmount == 0) revert ZeroAmount();

        feeCharged = (paymentAmount * feeBps) / BPS_DENOMINATOR;
        // Se a taxa está ativa (feeBps > 0), quantias mínimas não podem truncar a taxa a
        // zero — isso permitiria negociar sem pagar taxa via valores pequenos o bastante.
        if (feeBps > 0 && feeCharged == 0) revert PaymentAmountTooSmallForFeePrecision();

        uint256 sellerProceeds = paymentAmount - feeCharged;

        IERC20(assetToken).safeTransferFrom(seller, buyer, assetAmount);
        IERC20(paymentToken).safeTransferFrom(buyer, seller, sellerProceeds);
        if (feeCharged > 0) {
            IERC20(paymentToken).safeTransferFrom(buyer, address(cashbackDistributor), feeCharged);
            cashbackDistributor.recordFee(assetToken, paymentToken, feeCharged);
        }

        emit Settled(assetToken, paymentToken, buyer, seller, assetAmount, paymentAmount, feeCharged);
    }

    /// @notice Propõe uma nova taxa (bps). Sujeita ao teto imutável `MAX_FEE_BPS` e ao timelock.
    function proposeSetFeeBps(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 executeAfter) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeExceedsCap(newFeeBps);
        bytes32 actionId = keccak256(abi.encode("SET_FEE_BPS", newFeeBps));
        executeAfter = _scheduleAction(actionId);
        emit FeeBpsChangeProposed(newFeeBps, executeAfter);
    }

    /// @notice Executa uma proposta de mudança de taxa após o atraso do timelock.
    function executeSetFeeBps(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeExceedsCap(newFeeBps);
        bytes32 actionId = keccak256(abi.encode("SET_FEE_BPS", newFeeBps));
        _consumeAction(actionId);
        uint16 old = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsChanged(old, newFeeBps);
    }

    /// @notice Propõe um novo endereço de CashbackDistributor. Sujeito a timelock.
    function proposeSetCashbackDistributor(address newCashbackDistributor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (newCashbackDistributor == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_CASHBACK_DISTRIBUTOR", newCashbackDistributor));
        executeAfter = _scheduleAction(actionId);
        emit CashbackDistributorChangeProposed(newCashbackDistributor, executeAfter);
    }

    /// @notice Executa uma proposta de mudança de CashbackDistributor após o atraso do timelock.
    function executeSetCashbackDistributor(address newCashbackDistributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_CASHBACK_DISTRIBUTOR", newCashbackDistributor));
        _consumeAction(actionId);
        address old = address(cashbackDistributor);
        cashbackDistributor = ICashbackDistributor(newCashbackDistributor);
        emit CashbackDistributorChanged(old, newCashbackDistributor);
    }

    /// @notice Pausa `settle` em caso de emergência.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Remove a pausa.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

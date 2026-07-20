// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {IAssetToken} from "./interfaces/IAssetToken.sol";

/// @title CashbackDistributor
/// @notice Recebe a parcela de cashback (já transferida pelo NiaraSettlement) e credita o
/// emissor do ativo em padrão pull: os valores se acumulam por (ativo, moeda de
/// liquidação) e o emissor saca quando quiser via `withdraw`. O restante da taxa fica
/// acumulado como receita do protocolo, sacável pela tesouraria.
contract CashbackDistributor is TimelockedAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Teto rígido: cashback nunca pode exceder 100% da taxa recebida.
    uint16 public constant MAX_CASHBACK_BPS = 10_000;

    // A DEFINIR — 1% da taxa equivale a 0,005% do volume, provavelmente insuficiente.
    // Ver whitepaper, seção 4.
    /// @notice Parcela da taxa, em bps, repassada ao emissor. Padrão provisório: 1000 bps
    /// (10% da taxa).
    uint16 public cashbackBps = 1_000;

    /// @notice Saldo de cashback acumulado, por ativo e por moeda de liquidação, que o
    /// emissor pode sacar.
    mapping(address assetToken => mapping(address paymentToken => uint256)) public cashbackBalance;

    /// @notice Saldo de receita do protocolo (taxa menos cashback), por moeda de liquidação.
    mapping(address paymentToken => uint256) public protocolBalance;

    event FeeRecorded(
        address indexed assetToken, address indexed paymentToken, uint256 feeAmount, uint256 cashbackAmount, bool eligible
    );
    event CashbackCredited(address indexed assetToken, address indexed paymentToken, address indexed issuer, uint256 amount);
    event CashbackWithdrawn(address indexed assetToken, address indexed paymentToken, address indexed issuer, uint256 amount);
    event ProtocolFeesWithdrawn(address indexed paymentToken, address indexed to, uint256 amount);
    event CashbackBpsChangeProposed(uint16 newCashbackBps, uint256 executeAfter);
    event CashbackBpsChanged(uint16 oldCashbackBps, uint16 newCashbackBps);

    error ZeroAddress();
    error ZeroFeeAmount();
    error CashbackBpsExceedsCap(uint16 cashbackBps);
    error NotIssuerWallet();
    error NothingToWithdraw();
    error InvalidWithdrawAmount();

    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(TREASURY_ROLE, admin_);
    }

    /// @notice Registra `feeAmount` de `paymentToken`, já transferido para este contrato
    /// pelo NiaraSettlement, e credita o emissor de `assetToken` proporcionalmente — apenas
    /// se `assetToken.cashbackEligible()` for verdadeiro. O restante vira receita do
    /// protocolo.
    function recordFee(address assetToken, address paymentToken, uint256 feeAmount) external onlyRole(SETTLEMENT_ROLE) {
        if (feeAmount == 0) revert ZeroFeeAmount();

        bool eligible = IAssetToken(assetToken).cashbackEligible();
        uint256 cashbackAmount = 0;

        if (eligible) {
            cashbackAmount = (feeAmount * cashbackBps) / BPS_DENOMINATOR;
            if (cashbackAmount > 0) {
                address issuer = IAssetToken(assetToken).issuerWallet();
                cashbackBalance[assetToken][paymentToken] += cashbackAmount;
                emit CashbackCredited(assetToken, paymentToken, issuer, cashbackAmount);
            }
        }

        protocolBalance[paymentToken] += (feeAmount - cashbackAmount);
        emit FeeRecorded(assetToken, paymentToken, feeAmount, cashbackAmount, eligible);
    }

    /// @notice Saca o cashback acumulado de `assetToken` em `paymentToken`. Só a carteira
    /// atualmente registrada como `issuerWallet` do ativo pode chamar — se o emissor trocar
    /// de carteira, a nova carteira passa a poder sacar o saldo acumulado.
    function withdraw(address assetToken, address paymentToken) external nonReentrant {
        if (msg.sender != IAssetToken(assetToken).issuerWallet()) revert NotIssuerWallet();

        uint256 amount = cashbackBalance[assetToken][paymentToken];
        if (amount == 0) revert NothingToWithdraw();

        cashbackBalance[assetToken][paymentToken] = 0;
        IERC20(paymentToken).safeTransfer(msg.sender, amount);

        emit CashbackWithdrawn(assetToken, paymentToken, msg.sender, amount);
    }

    /// @notice Saca receita do protocolo acumulada. Restrito à tesouraria.
    function withdrawProtocolFees(address paymentToken, address to, uint256 amount) external nonReentrant onlyRole(TREASURY_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > protocolBalance[paymentToken]) revert InvalidWithdrawAmount();

        protocolBalance[paymentToken] -= amount;
        IERC20(paymentToken).safeTransfer(to, amount);

        emit ProtocolFeesWithdrawn(paymentToken, to, amount);
    }

    /// @notice Propõe uma nova parcela de cashback (bps sobre a taxa). Sujeita ao teto
    /// imutável `MAX_CASHBACK_BPS` e ao timelock.
    function proposeSetCashbackBps(uint16 newCashbackBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (newCashbackBps > MAX_CASHBACK_BPS) revert CashbackBpsExceedsCap(newCashbackBps);
        bytes32 actionId = keccak256(abi.encode("SET_CASHBACK_BPS", newCashbackBps));
        executeAfter = _scheduleAction(actionId);
        emit CashbackBpsChangeProposed(newCashbackBps, executeAfter);
    }

    /// @notice Executa uma proposta de mudança de cashbackBps após o atraso do timelock.
    function executeSetCashbackBps(uint16 newCashbackBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCashbackBps > MAX_CASHBACK_BPS) revert CashbackBpsExceedsCap(newCashbackBps);
        bytes32 actionId = keccak256(abi.encode("SET_CASHBACK_BPS", newCashbackBps));
        _consumeAction(actionId);
        uint16 old = cashbackBps;
        cashbackBps = newCashbackBps;
        emit CashbackBpsChanged(old, newCashbackBps);
    }
}

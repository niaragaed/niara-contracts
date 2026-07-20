// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICashbackDistributor
/// @notice Superfície mínima do CashbackDistributor usada pelo NiaraSettlement para
/// repassar a contabilização da taxa recém-transferida.
interface ICashbackDistributor {
    /// @notice Registra uma taxa já transferida para este contrato e credita o emissor
    /// proporcionalmente, se o ativo for elegível a cashback.
    /// @dev Quem chama esta função é responsável por já ter transferido `feeAmount` de
    /// `paymentToken` para o CashbackDistributor antes da chamada.
    function recordFee(address assetToken, address paymentToken, uint256 feeAmount) external;
}

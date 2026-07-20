// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBackingGateway
/// @notice Superfície mínima do BackingGateway consultada pelo AssetToken para validar,
/// dentro do próprio mint, que a emissão nunca excede o lastro atestado.
interface IBackingGateway {
    function totalAttested(address asset) external view returns (uint256);
}

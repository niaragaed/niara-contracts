// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAssetToken
/// @notice Superfície mínima do AssetToken usada pelos demais contratos do protocolo.
interface IAssetToken {
    function issuerWallet() external view returns (address);
    function cashbackEligible() external view returns (bool);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

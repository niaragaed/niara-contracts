// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAssetToken
/// @notice Minimal AssetToken surface used by the protocol's other contracts.
interface IAssetToken {
    function issuerWallet() external view returns (address);
    function cashbackEligible() external view returns (bool);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

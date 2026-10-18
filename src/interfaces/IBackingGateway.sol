// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBackingGateway
/// @notice Minimal BackingGateway surface read by the AssetToken to validate, inside
/// its own mint, that issuance never exceeds the attested backing.
interface IBackingGateway {
    function totalAttested(address asset) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice BackingGateway mock with a freely adjustable `totalAttested`, used to
/// isolate the AssetToken tests from the real BackingGateway logic.
contract MockBackingGateway {
    mapping(address => uint256) public totalAttested;

    function setTotalAttested(address asset, uint256 amount) external {
        totalAttested[asset] = amount;
    }
}

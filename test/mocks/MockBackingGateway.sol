// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mock de BackingGateway com `totalAttested` ajustável livremente, usado para
/// isolar os testes de AssetToken da lógica real de BackingGateway.
contract MockBackingGateway {
    mapping(address => uint256) public totalAttested;

    function setTotalAttested(address asset, uint256 amount) external {
        totalAttested[asset] = amount;
    }
}

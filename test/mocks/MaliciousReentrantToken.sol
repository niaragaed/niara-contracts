// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Malicious ERC-20 token for tests: when transferred via `transferFrom`, it
/// tries to re-enter a configurable target with arbitrary calldata, simulating a token
/// with a hook (ERC-777 style) used as a reentrancy vector. Used only in tests to
/// prove that `nonReentrant` blocks the attack.
contract MaliciousReentrantToken is ERC20 {
    address public reentrantTarget;
    bytes public reentrantCalldata;
    bool public armed;

    constructor() ERC20("Malicious Reentrant Token", "EVIL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Arms the attack: on the next `transferFrom` call, this contract will call
    /// `reentrantTarget` with `data` before completing the transfer.
    function arm(address target, bytes calldata data) external {
        reentrantTarget = target;
        reentrantCalldata = data;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool success,) = reentrantTarget.call(reentrantCalldata);
            require(success, "reentrant call did not revert as expected");
        }
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool success,) = reentrantTarget.call(reentrantCalldata);
            require(success, "reentrant call did not revert as expected");
        }
        return super.transfer(to, amount);
    }
}

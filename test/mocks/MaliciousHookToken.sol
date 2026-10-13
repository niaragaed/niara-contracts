// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Token with a malicious hook (ERC-777/ERC-1363 style) for cross-function
/// reentrancy tests. When minted, burned or transferred, it calls a configurable target
/// with arbitrary calldata and **records** the result instead of aborting, unlike
/// `MaliciousReentrantToken`, which reverts the whole transaction and therefore does not
/// let us inspect the state the re-entry saw.
/// @dev Implements the `IAssetToken` surface used by the BackingGateway (`mint`/`burn`)
/// without any access control: it is meant to be a hostile asset, not a valid token.
contract MaliciousHookToken is ERC20 {
    address public reentrantTarget;
    bytes public reentrantCalldata;

    bool public armedOnMint;
    bool public armedOnBurn;
    bool public armedOnTransferFrom;
    bool public armedOnTransfer;

    /// @notice True if the hook actually fired the re-entrant call.
    bool public reentered;
    /// @notice Success of the re-entrant call (false if it reverted).
    bool public reentrantSucceeded;
    /// @notice Raw return of the re-entrant call: return data on success, or the error
    /// (selector + arguments) on revert.
    bytes public reentrantReturnData;

    constructor() ERC20("Malicious Hook Token", "EVILHOOK") {}

    /// @notice Arms the re-entry to fire inside `mint`.
    function armOnMint(address target, bytes calldata data) external {
        _arm(target, data);
        armedOnMint = true;
    }

    /// @notice Arms the re-entry to fire inside `burn`.
    function armOnBurn(address target, bytes calldata data) external {
        _arm(target, data);
        armedOnBurn = true;
    }

    /// @notice Arms the re-entry to fire inside `transferFrom`.
    function armOnTransferFrom(address target, bytes calldata data) external {
        _arm(target, data);
        armedOnTransferFrom = true;
    }

    /// @notice Arms the re-entry to fire inside `transfer`.
    function armOnTransfer(address target, bytes calldata data) external {
        _arm(target, data);
        armedOnTransfer = true;
    }

    function mint(address to, uint256 amount) external {
        if (armedOnMint) {
            armedOnMint = false;
            _reenter();
        }
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (armedOnBurn) {
            armedOnBurn = false;
            _reenter();
        }
        _burn(from, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armedOnTransferFrom) {
            armedOnTransferFrom = false;
            _reenter();
        }
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armedOnTransfer) {
            armedOnTransfer = false;
            _reenter();
        }
        return super.transfer(to, amount);
    }

    function _arm(address target, bytes calldata data) internal {
        reentrantTarget = target;
        reentrantCalldata = data;
        reentered = false;
        reentrantSucceeded = false;
        reentrantReturnData = "";
    }

    /// @dev Deliberately does not propagate the failure: the test inspects the recorded result.
    function _reenter() internal {
        reentered = true;
        (bool ok, bytes memory ret) = reentrantTarget.call(reentrantCalldata);
        reentrantSucceeded = ok;
        reentrantReturnData = ret;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test stand-in for a Safe multisig: a contract account that only acts when its
/// owner (standing for the Safe's signer threshold) tells it to. It lets the handover tests
/// prove that a CONTRACT can hold and use the protocol's roles, and that every action it
/// takes is one the multisig signed.
/// @dev Not a Safe: no threshold, no nonce, no modules. Test use only.
contract MockSafe {
    address public immutable owner;

    error NotOwner();
    error CallFailed(bytes returnData);

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Executes `data` on `target` as this contract (what a Safe transaction does once
    /// enough owners signed it). Bubbles up the target's revert reason.
    function exec(address target, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != owner) revert NotOwner();
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

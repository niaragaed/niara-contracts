// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IListingRegistry} from "../interfaces/IListingRegistry.sol";

/// @title ProtocolPausable
/// @notice Gives a contract the protocol's single, shared pause: the one held by the
/// ListingRegistry (`ListingRegistry.pause` / `unpause`, PAUSER_ROLE). EVM mirror of
/// Solana's single `Config.paused` (EXCHANGE-MULTICHAIN-DESIGN.md, section 3.3, "Pause
/// principle"): one call stops `settle`, issuance execution and every payout based on the
/// protocol's own accounting (cashback and protocol-fee withdrawals) together.
/// @dev Principle: a pause blocks payouts based on protocol accounting, never a user
/// reclaiming their own escrowed deposit. Only functions that fit the first category use
/// `whenProtocolNotPaused`. The pause lives in the registry, so pausing or unpausing here is
/// impossible by design: this contract only reads it.
abstract contract ProtocolPausable {
    /// @notice Registry that holds the shared pause (and the listings). Immutable.
    IListingRegistry public immutable listingRegistry;

    /// @dev Same selector as OpenZeppelin's `Pausable.EnforcedPause()`, which the registry
    /// itself raises, so every paused path in the protocol reverts with the same error.
    error EnforcedPause();

    /// @param listingRegistry_ ListingRegistry holding the shared pause. The inheriting
    /// contract checks it is non-zero.
    constructor(address listingRegistry_) {
        listingRegistry = IListingRegistry(listingRegistry_);
    }

    /// @dev Reverts while the protocol (the ListingRegistry) is paused.
    modifier whenProtocolNotPaused() {
        if (listingRegistry.paused()) revert EnforcedPause();
        _;
    }

    /// @notice True while the protocol is paused. Reads the ListingRegistry's pause; there is
    /// no separate pause in this contract.
    /// @return Whether the shared protocol pause is active.
    function paused() public view returns (bool) {
        return listingRegistry.paused();
    }
}

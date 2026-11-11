// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICashbackDistributor} from "./ICashbackDistributor.sol";
import {IListingRegistry} from "./IListingRegistry.sol";

/// @title INiaraSettlement
/// @notice The protocol parameters P2PEscrow reads from NiaraSettlement, so both trading
/// modes share one fee, one fee token and one CashbackDistributor (the EVM counterpart of
/// Solana's single `Config`). All three change only through NiaraSettlement's timelock.
interface INiaraSettlement {
    /// @notice Current protocol fee, in bps (never above `MAX_FEE_BPS`).
    function feeBps() external view returns (uint16);

    /// @notice The token every fee and all cashback are paid in (USDT).
    function feeToken() external view returns (address);

    /// @notice Contract that receives fees and credits cashback.
    function cashbackDistributor() external view returns (ICashbackDistributor);

    /// @notice Registry that gates listings and holds the shared pause.
    function listingRegistry() external view returns (IListingRegistry);
}

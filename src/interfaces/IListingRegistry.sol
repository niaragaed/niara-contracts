// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IListingRegistry
/// @notice Shared listing types and the minimal ListingRegistry surface read by
/// NiaraSettlement. Mirrors the `Listing` account of the Solana program
/// (EXCHANGE-MULTICHAIN-DESIGN.md, section 3.2).
interface IListingRegistry {
    /// @notice Asset class of a listing. Fixes the trading mode (design doc, section 1):
    /// only `Equity` trades on the order book (`NiaraSettlement.settle`); `FixedIncome`,
    /// `Credit` and `Currency` are P2P escrow classes. `Currency` is never
    /// cashback-eligible.
    enum AssetClass {
        Equity,
        FixedIncome,
        Credit,
        Currency
    }

    /// @notice Listing lifecycle. `None` means "no listing". `Delisted` is final.
    enum ListingStatus {
        None,
        Pending,
        Approved,
        Suspended,
        Delisted
    }

    struct Listing {
        address issuer;
        AssetClass assetClass;
        ListingStatus status;
        bool cashbackEligible;
        bytes32 docHash;
        uint64 approvedAt;
    }

    /// @notice Returns the listing of `token` (all fields zero / `None` if there is none).
    function getListing(address token) external view returns (Listing memory);
}

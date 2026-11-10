// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NativeAssetToken} from "./NativeAssetToken.sol";
import {IListingRegistry} from "./interfaces/IListingRegistry.sol";

/// @title AssetTokenFactory
/// @notice Lets an issuer deploy its own ERC-20 instrument from its wallet
/// (issuer = `msg.sender`). The ListingRegistry only accepts listings for tokens
/// deployed here, so the asset side of every listing is a known implementation
/// (`NativeAssetToken`).
contract AssetTokenFactory {
    /// @notice ListingRegistry: the only minter of every token this factory deploys.
    address public immutable registry;

    /// @notice True for every token deployed by this factory.
    mapping(address token => bool) public isFactoryToken;

    event AssetTokenCreated(
        address indexed token,
        address indexed issuer,
        IListingRegistry.AssetClass assetClass,
        bytes32 docHash,
        string name,
        string symbol
    );

    error ZeroAddress();
    error UnsupportedAssetClass(IListingRegistry.AssetClass assetClass);

    /// @param registry_ The ListingRegistry (minter of every token deployed here).
    constructor(address registry_) {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    /// @notice Deploys a new instrument with `msg.sender` as issuer. No supply is minted:
    /// issuance happens later in batches through the ListingRegistry.
    /// @param name Token name.
    /// @param symbol Token symbol.
    /// @param assetClass `Equity`, `FixedIncome` or `Credit` (`Currency` reverts).
    /// @param docHash Hash of the offering document.
    /// @return token Address of the new instrument.
    function createAssetToken(
        string calldata name,
        string calldata symbol,
        IListingRegistry.AssetClass assetClass,
        bytes32 docHash
    ) external returns (address token) {
        if (assetClass == IListingRegistry.AssetClass.Currency) revert UnsupportedAssetClass(assetClass);

        // The only external interaction is the creation itself, whose code is fixed
        // (NativeAssetToken's constructor makes no calls), so recording the address after
        // it is safe: the address only exists once the creation returns.
        token = address(new NativeAssetToken(name, symbol, msg.sender, registry, assetClass, docHash));
        isFactoryToken[token] = true;
        emit AssetTokenCreated(token, msg.sender, assetClass, docHash, name, symbol);
    }
}

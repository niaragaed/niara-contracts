// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IListingRegistry} from "./interfaces/IListingRegistry.sol";

/// @title NativeAssetToken
/// @notice ERC-20 instrument issued natively by its issuer through AssetTokenFactory: the
/// token *is* the instrument (equity, fixed income or credit), not a claim on an asset
/// held by a custodian.
/// @dev Deliberately plain: no fee-on-transfer, no rebasing, no hooks, no pause. Because
/// the registry only lists tokens deployed by the factory, the protocol knows this exact
/// implementation sits on the asset side of every listing (the EVM equivalent of the
/// Solana mint-extension allowlist).
///
/// Supply model: no initial supply and no public mint. The only minter is the
/// ListingRegistry, which mints a batch only after the issuer requested it and the
/// listing authority approved it, so neither the issuer nor Niara can mint alone.
contract NativeAssetToken is ERC20 {
    /// @notice Why a holder burned tokens.
    enum BurnReason {
        Redemption,
        Cancellation
    }

    /// @notice Issuer wallet (the account that deployed the instrument via the factory).
    address public immutable issuer;

    /// @notice The only address allowed to mint: the ListingRegistry.
    address public immutable minter;

    /// @notice Asset class fixed at creation (`Equity`, `FixedIncome` or `Credit`).
    IListingRegistry.AssetClass public immutable assetClass;

    /// @notice Hash of the offering document.
    bytes32 public immutable docHash;

    /// @notice Natively issued instruments are always cashback-eligible (the factory never
    /// issues `Currency`). Read by CashbackDistributor through `IAssetToken`.
    bool public constant cashbackEligible = true;

    event TokensBurned(address indexed holder, uint256 amount, BurnReason reason, bytes32 ref);

    error NotMinter();
    error ZeroAmount();
    error EmptyReference();

    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param issuer_ Issuer wallet (cashback recipient).
    /// @param minter_ The ListingRegistry.
    /// @param assetClass_ Asset class (validated by the factory).
    /// @param docHash_ Hash of the offering document.
    constructor(
        string memory name_,
        string memory symbol_,
        address issuer_,
        address minter_,
        IListingRegistry.AssetClass assetClass_,
        bytes32 docHash_
    ) ERC20(name_, symbol_) {
        issuer = issuer_;
        minter = minter_;
        assetClass = assetClass_;
        docHash = docHash_;
    }

    /// @notice Cashback recipient, read by CashbackDistributor. Always the issuer.
    /// @return The issuer wallet.
    function issuerWallet() external view returns (address) {
        return issuer;
    }

    /// @notice Mints an approved issuance batch. Callable only by the ListingRegistry.
    /// @param to Recipient of the batch.
    /// @param amount Amount to mint.
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }

    /// @notice Burns `amount` of the caller's own tokens, recording why.
    /// @param amount Amount to burn.
    /// @param reason `Redemption` or `Cancellation`.
    /// @param ref Non-zero reference for the off-chain record (e.g. the hash of the document
    /// authorizing the burn, registered in Niara-Register).
    function burnWithReason(uint256 amount, BurnReason reason, bytes32 ref) external {
        if (amount == 0) revert ZeroAmount();
        if (ref == bytes32(0)) revert EmptyReference();
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount, reason, ref);
    }
}

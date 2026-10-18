// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {IBackingGateway} from "./interfaces/IBackingGateway.sol";

/// @title AssetToken
/// @notice ERC-20 representing a tokenized real-world asset, backed 1:1 under regulated
/// custody. It is never minted beyond the backing attested by a BackingGateway (see the
/// invariant in `mint`).
/// @dev The tokenized asset's origin/issuance currency is not defined here: this contract
/// represents the asset itself (e.g. a tokenized stock, ETF, commodity or currency), not a
/// settlement position. It uses 18 decimals (ERC-20 standard), enough for fractions of the
/// underlying asset.
contract AssetToken is ERC20, Pausable, TimelockedAccessControl {
    /// @notice Class of the asset represented by this token.
    enum AssetClass {
        EQUITY,
        ETF,
        COMMODITY,
        FUND,
        CURRENCY
    }

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");

    /// @notice Ticker/ISIN or other reference of the underlying real-world asset.
    string public assetReference;

    /// @notice Asset class (immutable: corporate actions that change the class require
    /// a new AssetToken, not a migration of this one).
    AssetClass public immutable assetClass;

    /// @notice Asset's country of origin (e.g. "US", "BR").
    string public countryOfOrigin;

    /// @notice True for EQUITY and ETF. CURRENCY, COMMODITY and FUND are never
    /// eligible for issuer cashback (immutable, derived from the asset class).
    bool public immutable cashbackEligible;

    /// @notice Wallet of the issuing company, recipient of the cashback. Changeable only
    /// by the admin, subject to the timelock.
    address public issuerWallet;

    /// @notice Address of the BackingGateway authorized to attest backing for this token.
    /// `mint` reads `totalAttested` from this address on every call, so changing this
    /// address is as sensitive as changing the backing criterion itself; that is why it
    /// is also subject to the timelock.
    address public backingGateway;

    event Minted(address indexed to, uint256 amount, uint256 totalAttestedAtMint);
    event Burned(address indexed from, uint256 amount);
    event IssuerWalletChangeProposed(address indexed newIssuerWallet, uint256 executeAfter);
    event IssuerWalletChanged(address indexed oldIssuerWallet, address indexed newIssuerWallet);
    event BackingGatewayChangeProposed(address indexed newBackingGateway, uint256 executeAfter);
    event BackingGatewayChanged(address indexed oldBackingGateway, address indexed newBackingGateway);

    error ZeroAddress();
    error MintExceedsAttestedBacking(uint256 requestedSupply, uint256 attested);
    error BackingGatewayNotSet();
    error NotAuthorizedToPause();

    /// @param name_ Token name (e.g. "Apple Inc. — Niara Tokenized Equity").
    /// @param symbol_ Token symbol (e.g. "nAAPL").
    /// @param assetReference_ Ticker/ISIN of the real-world asset.
    /// @param assetClass_ Asset class.
    /// @param countryOfOrigin_ Asset's country of origin.
    /// @param issuerWallet_ Initial wallet of the issuing company.
    /// @param admin_ Initial holder of DEFAULT_ADMIN_ROLE, PAUSER_ROLE and CUSTODIAN_ROLE
    /// (recommended: a multisig).
    /// @param timelockDelay_ Initial delay (seconds) between proposal and execution of
    /// sensitive changes.
    constructor(
        string memory name_,
        string memory symbol_,
        string memory assetReference_,
        AssetClass assetClass_,
        string memory countryOfOrigin_,
        address issuerWallet_,
        address admin_,
        uint256 timelockDelay_
    ) ERC20(name_, symbol_) TimelockedAccessControl(timelockDelay_) {
        if (issuerWallet_ == address(0) || admin_ == address(0)) revert ZeroAddress();

        assetReference = assetReference_;
        assetClass = assetClass_;
        countryOfOrigin = countryOfOrigin_;
        issuerWallet = issuerWallet_;
        cashbackEligible = !(
            assetClass_ == AssetClass.CURRENCY || assetClass_ == AssetClass.COMMODITY
                || assetClass_ == AssetClass.FUND
        );

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
        _grantRole(CUSTODIAN_ROLE, admin_);
    }

    /// @notice Mints `amount` tokens to `to`, as long as the resulting total supply
    /// does not exceed the backing attested by the configured BackingGateway.
    /// @dev This check is structural: even if MINTER_ROLE is granted to an address other
    /// than the "official" BackingGateway, it is still impossible to mint beyond what the
    /// configured BackingGateway reports as attested. The lock lives in this contract, not
    /// only in the caller's access control.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        if (backingGateway == address(0)) revert BackingGatewayNotSet();
        uint256 attested = IBackingGateway(backingGateway).totalAttested(address(this));
        uint256 newSupply = totalSupply() + amount;
        if (newSupply > attested) revert MintExceedsAttestedBacking(newSupply, attested);
        _mint(to, amount);
        emit Minted(to, amount, attested);
    }

    /// @notice Burns `amount` tokens from `from`. Used by the BackingGateway on the
    /// redemption path, after the release of the real-world asset is attested.
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
        emit Burned(from, amount);
    }

    /// @notice Pauses transfers, mint and burn. PAUSER_ROLE or CUSTODIAN_ROLE can
    /// trigger it: the custodian, who sees the real state of custody, can lock the
    /// token immediately when it detects a problem, without waiting for the admin.
    function pause() external {
        if (!hasRole(PAUSER_ROLE, msg.sender) && !hasRole(CUSTODIAN_ROLE, msg.sender)) {
            revert NotAuthorizedToPause();
        }
        _pause();
    }

    /// @notice Removes the pause. Deliberate decision: only PAUSER_ROLE (governance), never
    /// CUSTODIAN_ROLE alone. Locking is a unilateral emergency action; unlocking requires
    /// the normal governance process.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function proposeSetIssuerWallet(address newIssuerWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (newIssuerWallet == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_ISSUER_WALLET", newIssuerWallet));
        executeAfter = _scheduleAction(actionId);
        emit IssuerWalletChangeProposed(newIssuerWallet, executeAfter);
    }

    /// @notice Executes a proposed issuer wallet change after the timelock.
    /// @dev Revalidates the address here, not only at proposal time: an executed
    /// `address(0)` would lock the cashback destination until a new proposal went through
    /// the whole timelock.
    function executeSetIssuerWallet(address newIssuerWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newIssuerWallet == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_ISSUER_WALLET", newIssuerWallet));
        _consumeAction(actionId);
        address old = issuerWallet;
        issuerWallet = newIssuerWallet;
        emit IssuerWalletChanged(old, newIssuerWallet);
    }

    function proposeSetBackingGateway(address newBackingGateway)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (newBackingGateway == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_BACKING_GATEWAY", newBackingGateway));
        executeAfter = _scheduleAction(actionId);
        emit BackingGatewayChangeProposed(newBackingGateway, executeAfter);
    }

    /// @notice Executes a proposed BackingGateway change after the timelock.
    /// @dev Revalidates the address here, not only at proposal time: an executed
    /// `address(0)` would make every `mint` revert with `BackingGatewayNotSet` until a new
    /// proposal went through the whole timelock.
    function executeSetBackingGateway(address newBackingGateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBackingGateway == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_BACKING_GATEWAY", newBackingGateway));
        _consumeAction(actionId);
        address old = backingGateway;
        backingGateway = newBackingGateway;
        emit BackingGatewayChanged(old, newBackingGateway);
    }

    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }
}

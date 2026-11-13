// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestnetMockToken
/// @notice A TEST token with NO VALUE, deployed only on testnets (Sepolia, Base Sepolia) to
/// stand in for a currency in Niara's testnet deployment: "Niara Mock USDT" (the fee token)
/// and "Niara Mock BRL". It is not USDT, not BRL, not issued by or affiliated with any
/// stablecoin issuer, and represents no claim on anything.
/// @dev Anyone can mint (a faucet), which is exactly why it can never be worth anything:
/// testers fund their own wallets without asking Niara. A per-call cap only keeps balances
/// readable. Plain ERC-20: no fee-on-transfer, no rebasing, no hooks, no pause, no owner.
/// Lives under `script/`, not `src/`: it is deployment tooling, not part of the protocol.
contract TestnetMockToken is ERC20 {
    /// @notice Largest amount one `mint` call can create, in whole tokens.
    uint256 public constant MAX_MINT_WHOLE_TOKENS = 1_000_000;

    uint8 private immutable _tokenDecimals;

    error MintExceedsFaucetCap(uint256 amount, uint256 cap);

    /// @param name_ Token name. Must say it is a test token.
    /// @param symbol_ Token symbol.
    /// @param decimals_ Token decimals (6 for the mock currencies).
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    /// @notice Token decimals fixed at deployment.
    /// @return The number of decimals.
    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    /// @notice Largest amount one `mint` call can create, in the token's smallest unit.
    /// @return The cap.
    function maxMintPerCall() public view returns (uint256) {
        return MAX_MINT_WHOLE_TOKENS * 10 ** _tokenDecimals;
    }

    /// @notice Faucet: mints test tokens to `to`. Open to anyone; the tokens have no value.
    /// @param to Recipient.
    /// @param amount Amount in the smallest unit, at most `maxMintPerCall()`.
    function mint(address to, uint256 amount) external {
        uint256 cap = maxMintPerCall();
        if (amount > cap) revert MintExceedsFaucetCap(amount, cap);
        _mint(to, amount);
    }
}

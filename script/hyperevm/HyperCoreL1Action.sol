// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HyperCoreL1Action
/// @notice What signing a HyperCore "L1 action" involves, rebuilt from Hyperliquid's official
/// Python SDK (`hyperliquid/utils/signing.py`: `action_hash`, `construct_phantom_agent`,
/// `l1_payload`):
///
///   connectionId = keccak256(msgpack(action) ‖ nonce as 8 bytes big-endian ‖ vault flag)
///     where the vault flag is 0x00 without a vault, or 0x01 ‖ the vault's 20 bytes
///   phantom agent = Agent { source: "a" (mainnet) | "b" (testnet), connectionId }
///   signed as EIP-712 typed data: domain { name "Exchange", version "1", chainId 1337,
///   verifyingContract 0x0 }, type Agent(string source,bytes32 connectionId)
///
/// Only the MessagePack this repository needs is implemented: a map with string keys and
/// string, boolean or unsigned-integer values, encoded the way the SDK's `msgpack.packb`
/// encodes a Python dict (keys in insertion order, smallest integer format). The SDK's
/// optional `expiresAfter` is not supported (the big-blocks action does not use it).
///
/// Pure functions, no network access, no keys: signing happens outside, with
/// `cast wallet sign --data` on a Foundry keystore.
library HyperCoreL1Action {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant AGENT_TYPEHASH = keccak256("Agent(string source,bytes32 connectionId)");
    uint256 internal constant L1_CHAIN_ID = 1337;

    error MsgpackStringTooLong(uint256 length);
    error MsgpackMapTooLarge(uint256 entries);

    // ── MessagePack (the subset used here) ─────────────────────────────────────────────

    /// @notice A map header with `entries` entries (fixmap, up to 15).
    function mapHeader(uint256 entries) internal pure returns (bytes memory) {
        if (entries > 15) revert MsgpackMapTooLarge(entries);
        return abi.encodePacked(bytes1(uint8(0x80 + entries)));
    }

    /// @notice A string (fixstr, up to 31 bytes, or str8 up to 255).
    function str(string memory s) internal pure returns (bytes memory) {
        uint256 len = bytes(s).length;
        if (len <= 31) return abi.encodePacked(bytes1(uint8(0xa0 + len)), s);
        if (len <= 255) return abi.encodePacked(bytes1(0xd9), bytes1(uint8(len)), s);
        revert MsgpackStringTooLong(len);
    }

    /// @notice A boolean.
    function boolean(bool b) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(b ? 0xc3 : 0xc2));
    }

    /// @notice A non-negative integer in the smallest format, as msgpack-python packs it.
    function uinteger(uint64 n) internal pure returns (bytes memory) {
        if (n < 0x80) return abi.encodePacked(bytes1(uint8(n)));
        if (n <= type(uint8).max) return abi.encodePacked(bytes1(0xcc), uint8(n));
        if (n <= type(uint16).max) return abi.encodePacked(bytes1(0xcd), uint16(n));
        if (n <= type(uint32).max) return abi.encodePacked(bytes1(0xce), uint32(n));
        return abi.encodePacked(bytes1(0xcf), n);
    }

    // ── The big-blocks action ──────────────────────────────────────────────────────────

    /// @notice msgpack of `{"type": "evmUserModify", "usingBigBlocks": <flag>}`, the action
    /// the SDK's `Exchange.use_big_blocks` signs.
    function evmUserModify(bool usingBigBlocks) internal pure returns (bytes memory) {
        return abi.encodePacked(
            mapHeader(2), str("type"), str("evmUserModify"), str("usingBigBlocks"), boolean(usingBigBlocks)
        );
    }

    // ── Hashing ────────────────────────────────────────────────────────────────────────

    /// @notice The SDK's `action_hash` without `expiresAfter`: the phantom agent's
    /// connectionId.
    /// @param packedAction msgpack of the action.
    /// @param nonce The nonce (a millisecond timestamp in practice).
    /// @param vault The vault address, or `address(0)` for none.
    function connectionId(bytes memory packedAction, uint64 nonce, address vault) internal pure returns (bytes32) {
        bytes memory vaultPart = vault == address(0) ? abi.encodePacked(bytes1(0x00)) : abi.encodePacked(bytes1(0x01), vault);
        return keccak256(abi.encodePacked(packedAction, nonce, vaultPart));
    }

    /// @notice The phantom agent's `source`: "a" on mainnet, "b" on testnet.
    function source(bool mainnet) internal pure returns (string memory) {
        return mainnet ? "a" : "b";
    }

    /// @notice EIP-712 domain separator of L1 actions (Exchange, 1, chain 1337, zero address).
    function domainSeparator() internal pure returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("Exchange"), keccak256("1"), L1_CHAIN_ID, address(0))
        );
    }

    /// @notice The EIP-712 digest a wallet signs for the phantom agent.
    function agentDigest(bytes32 connId, bool mainnet) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(AGENT_TYPEHASH, keccak256(bytes(source(mainnet))), connId));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }
}

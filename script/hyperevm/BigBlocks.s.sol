// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HyperCoreL1Action} from "./HyperCoreL1Action.sol";

/// @title HyperEvmBigBlocks
/// @notice Prepares, and NEVER sends, the HyperCore action that moves an address's HyperEVM
/// transactions to big blocks (30M gas, about one a minute) or back to small blocks (3M gas,
/// one a second): `{"type": "evmUserModify", "usingBigBlocks": true|false}`, the action the
/// official SDK's `Exchange.use_big_blocks` signs. TESTNET ONLY: the phantom agent's source is
/// always "b"; there is no mainnet option.
///
///   forge script script/hyperevm/BigBlocks.s.sol                         # enable
///   forge script script/hyperevm/BigBlocks.s.sol --sig "runDisable()"    # switch back
///
/// It needs no RPC and no key. It writes two files to `hyperevm-signing/` (git-ignored):
///   - `big-blocks-typed-data.json`: the EIP-712 typed data to sign with
///     `cast wallet sign --data --from-file ... --account niara-evm-deployer`;
///   - `big-blocks-request.json`: the request body without its signature, to which the
///     signature is added before POSTing it to https://api.hyperliquid-testnet.xyz/exchange.
/// The README ("HyperEVM big blocks") has the exact commands. The nonce is the current time in
/// milliseconds; Hyperliquid only accepts it for a limited time (submit the same day).
contract HyperEvmBigBlocks is Script {
    string public constant OUT_DIR = "hyperevm-signing";
    string public constant TYPED_DATA_FILE = "hyperevm-signing/big-blocks-typed-data.json";
    string public constant REQUEST_FILE = "hyperevm-signing/big-blocks-request.json";
    string public constant EXCHANGE_URL = "https://api.hyperliquid-testnet.xyz/exchange";

    /// @notice Prepares the action that switches big blocks ON.
    function run() external {
        prepare(true, uint64(vm.unixTime()));
    }

    /// @notice Prepares the action that switches big blocks OFF again.
    function runDisable() external {
        prepare(false, uint64(vm.unixTime()));
    }

    /// @notice Builds the action, its connectionId and the EIP-712 digest, prints them and
    /// writes the two files.
    /// @param usingBigBlocks The value of `usingBigBlocks`.
    /// @param nonce The action's nonce (milliseconds since the epoch).
    /// @return connId The phantom agent's connectionId.
    /// @return digest The EIP-712 digest the deployer's signature must cover.
    function prepare(bool usingBigBlocks, uint64 nonce) public returns (bytes32 connId, bytes32 digest) {
        bytes memory packed = HyperCoreL1Action.evmUserModify(usingBigBlocks);
        connId = HyperCoreL1Action.connectionId(packed, nonce, address(0));
        digest = HyperCoreL1Action.agentDigest(connId, false);

        console2.log("== HyperCore action (Hyperliquid TESTNET), NOT sent ==");
        console2.log(string.concat("action:        ", actionJson(usingBigBlocks)));
        console2.log("nonce (ms):   ", uint256(nonce));
        console2.log("vault:         none");
        console2.log(string.concat("msgpack:       ", vm.toString(packed)));
        console2.log(string.concat("connectionId:  ", vm.toString(connId)));
        console2.log("phantom agent: source \"b\" (testnet)");
        console2.log(string.concat("EIP-712 digest:", " ", vm.toString(digest)));

        vm.createDir(OUT_DIR, true);
        vm.writeFile(TYPED_DATA_FILE, typedDataJson(connId));
        vm.writeFile(REQUEST_FILE, requestJson(usingBigBlocks, nonce));
        console2.log(string.concat("written: ", TYPED_DATA_FILE, " and ", REQUEST_FILE));
        console2.log(string.concat("submit to: ", EXCHANGE_URL));
    }

    /// @notice The action as JSON, keys in the order they are hashed.
    /// @param usingBigBlocks The flag.
    /// @return The JSON object.
    function actionJson(bool usingBigBlocks) public pure returns (string memory) {
        return string.concat(
            '{"type":"evmUserModify","usingBigBlocks":', usingBigBlocks ? "true" : "false", "}"
        );
    }

    /// @notice EIP-712 typed data of the phantom agent, in the format
    /// `cast wallet sign --data --from-file` reads.
    /// @param connId The connectionId.
    /// @return The JSON document.
    function typedDataJson(bytes32 connId) public pure returns (string memory) {
        return string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"Agent":[{"name":"source","type":"string"},{"name":"connectionId","type":"bytes32"}]},',
            '"primaryType":"Agent",',
            '"domain":{"name":"Exchange","version":"1","chainId":1337,',
            '"verifyingContract":"0x0000000000000000000000000000000000000000"},',
            '"message":{"source":"b","connectionId":"',
            vm.toString(connId),
            '"}}'
        );
    }

    /// @notice The request body the SDK's `_post_action` sends, without the signature.
    /// @param usingBigBlocks The flag.
    /// @param nonce The nonce.
    /// @return The JSON document.
    function requestJson(bool usingBigBlocks, uint64 nonce) public pure returns (string memory) {
        return string.concat(
            '{"action":',
            actionJson(usingBigBlocks),
            ',"nonce":',
            vm.toString(uint256(nonce)),
            ',"vaultAddress":null,"expiresAfter":null}'
        );
    }
}

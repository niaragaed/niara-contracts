// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HyperCoreL1Action} from "../../script/hyperevm/HyperCoreL1Action.sol";
import {HyperEvmBigBlocks} from "../../script/hyperevm/BigBlocks.s.sol";

/// @dev External wrappers, so reverts of the library's internal functions can be expected.
contract MsgpackHarness {
    function mapHeader(uint256 entries) external pure returns (bytes memory) {
        return HyperCoreL1Action.mapHeader(entries);
    }

    function str(string memory s) external pure returns (bytes memory) {
        return HyperCoreL1Action.str(s);
    }
}

/// @notice Checks the L1-action hashing and EIP-712 digest against the reference vectors in
/// Hyperliquid's official Python SDK (`tests/signing_test.py`, hyperliquid-python-sdk, master,
/// fetched 2026-11-16): the same action, nonce and vault, signed with the SDK tests' key, must
/// give exactly the SDK's r, s and v, on mainnet ("a") and testnet ("b").
///
/// The SDK has no vector for `evmUserModify` itself. The vectors used cover every piece it is
/// built from: string keys and values (fixstr and str8), a boolean (`isDeposit`), integers of
/// three sizes, the nonce, the no-vault and vault suffixes, and the phantom agent's EIP-712
/// digest on both networks.
///
/// The key below is the SDK tests' published sample key
/// (0x0123456789012345678901234567890123456789012345678901234567890123). It controls nothing
/// and is used only to reproduce the vectors here; no script reads a key.
contract HyperCoreL1ActionTest is Test {
    uint256 internal constant SDK_TEST_KEY = 0x0123456789012345678901234567890123456789012345678901234567890123;

    using HyperCoreL1Action for *;

    function _sig(bytes memory packed, uint64 nonce, address vault, bool mainnet)
        internal
        pure
        returns (uint8 v, uint256 r, uint256 s)
    {
        bytes32 digest = HyperCoreL1Action.agentDigest(HyperCoreL1Action.connectionId(packed, nonce, vault), mainnet);
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(SDK_TEST_KEY, digest);
        return (v_, uint256(r_), uint256(s_));
    }

    function _assertSig(
        bytes memory packed,
        address vault,
        bool mainnet,
        uint256 expectedR,
        uint256 expectedS,
        uint8 expectedV
    ) internal pure {
        (uint8 v, uint256 r, uint256 s) = _sig(packed, 0, vault, mainnet);
        assertEq(r, expectedR, "r");
        assertEq(s, expectedS, "s");
        assertEq(v, expectedV, "v");
    }

    // ── SDK vectors ────────────────────────────────────────────────────────────────────

    /// @notice test_create_sub_account_action: {"type": "createSubAccount", "name": "example"}.
    function test_SdkVector_CreateSubAccount() public pure {
        bytes memory packed = abi.encodePacked(
            HyperCoreL1Action.mapHeader(2),
            HyperCoreL1Action.str("type"),
            HyperCoreL1Action.str("createSubAccount"),
            HyperCoreL1Action.str("name"),
            HyperCoreL1Action.str("example")
        );
        _assertSig(
            packed,
            address(0),
            true,
            0x51096fe3239421d16b671e192f574ae24ae14329099b6db28e479b86cdd6caa7,
            0xb71f7d293af92d3772572afb8b102d167a7cef7473388286bc01f52a5c5b423,
            27
        );
        _assertSig(
            packed,
            address(0),
            false,
            0xa699e3ed5c2b89628c746d3298b5dc1cca604694c2c855da8bb8250ec8014a5b,
            0x53f1b8153a301c72ecc655b1c315d64e1dcea3ee58921fd7507e35818fcc1584,
            28
        );
    }

    /// @notice test_sub_account_transfer_action: a boolean (as in evmUserModify), a 42-char
    /// string (str8) and a small integer.
    function test_SdkVector_SubAccountTransfer_WithABoolean() public pure {
        bytes memory packed = abi.encodePacked(
            HyperCoreL1Action.mapHeader(4),
            HyperCoreL1Action.str("type"),
            HyperCoreL1Action.str("subAccountTransfer"),
            HyperCoreL1Action.str("subAccountUser"),
            HyperCoreL1Action.str("0x1d9470d4b963f552e6f671a81619d395877bf409"),
            HyperCoreL1Action.str("isDeposit"),
            HyperCoreL1Action.boolean(true),
            HyperCoreL1Action.str("usd"),
            HyperCoreL1Action.uinteger(10)
        );
        _assertSig(
            packed,
            address(0),
            true,
            0x43592d7c6c7d816ece2e206f174be61249d651944932b13343f4d13f306ae602,
            0x71a926cb5c9a7c01c3359ec4c4c34c16ff8107d610994d4de0e6430e5cc0f4c9,
            28
        );
        _assertSig(
            packed,
            address(0),
            false,
            0xe26574013395ad55ee2f4e0575310f003c5bb3351b5425482e2969fa51543927,
            0xefb08999196366871f919fd0e138b3a7f30ee33e678df7cfaf203e25f0a4278,
            28
        );
    }

    /// @notice test_schedule_cancel_action, both cases: a one-entry map, and a uint32 value.
    function test_SdkVector_ScheduleCancel() public pure {
        bytes memory bare = abi.encodePacked(
            HyperCoreL1Action.mapHeader(1), HyperCoreL1Action.str("type"), HyperCoreL1Action.str("scheduleCancel")
        );
        _assertSig(
            bare,
            address(0),
            true,
            0x6cdfb286702f5917e76cd9b3b8bf678fcc49aec194c02a73e6d4f16891195df9,
            0x6557ac307fa05d25b8d61f21fb8a938e703b3d9bf575f6717ba21ec61261b2a0,
            27
        );
        _assertSig(
            bare,
            address(0),
            false,
            0xc75bb195c3f6a4e06b7d395acc20bbb224f6d23ccff7c6a26d327304e6efaeed,
            0x342f8ede109a29f2c0723bd5efb9e9100e3bbb493f8fb5164ee3d385908233df,
            28
        );

        bytes memory timed = abi.encodePacked(
            HyperCoreL1Action.mapHeader(2),
            HyperCoreL1Action.str("type"),
            HyperCoreL1Action.str("scheduleCancel"),
            HyperCoreL1Action.str("time"),
            HyperCoreL1Action.uinteger(123456789)
        );
        _assertSig(
            timed,
            address(0),
            true,
            0x609cb20c737945d070716dcc696ba030e9976fcf5edad87afa7d877493109d55,
            0x16c685d63b5c7a04512d73f183b3d7a00da5406ff1f8aad33f8ae2163bab758b,
            28
        );
        _assertSig(
            timed,
            address(0),
            false,
            0x4e4f2dbd4107c69783e251b7e1057d9f2b9d11cee213441ccfa2be63516dc5bc,
            0x706c656b23428c8ba356d68db207e11139ede1670481a9e01ae2dfcdb0e1a678,
            27
        );
    }

    /// @notice test_l1_action_signing_matches and ..._with_vault: {"type": "dummy", "num":
    /// float_to_int_for_hashing(1000)} = 100000000000 (uint64), without and with a vault.
    function test_SdkVector_Dummy_WithoutAndWithVault() public pure {
        bytes memory packed = abi.encodePacked(
            HyperCoreL1Action.mapHeader(2),
            HyperCoreL1Action.str("type"),
            HyperCoreL1Action.str("dummy"),
            HyperCoreL1Action.str("num"),
            HyperCoreL1Action.uinteger(100000000000)
        );
        _assertSig(
            packed,
            address(0),
            true,
            0x53749d5b30552aeb2fca34b530185976545bb22d0b3ce6f62e31be961a59298,
            0x755c40ba9bf05223521753995abb2f73ab3229be8ec921f350cb447e384d8ed8,
            27
        );
        _assertSig(
            packed,
            address(0),
            false,
            0x542af61ef1f429707e3c76c5293c80d01f74ef853e34b76efffcb57e574f9510,
            0x17b8b32f086e8cdede991f1e2c529f5dd5297cbe8128500e00cbaf766204a613,
            28
        );

        address vault = 0x1719884eb866CB12B2287399b15f7dB5E7d775EA;
        _assertSig(
            packed,
            vault,
            true,
            0x3c548db75e479f8012acf3000ca3a6b05606bc2ec0c29c50c515066a326239,
            0x4d402be7396ce74fbba3795769cda45aec00dc3125a984f2a9f23177b190da2c,
            28
        );
        _assertSig(
            packed,
            vault,
            false,
            0xe281d2fb5c6e25ca01601f878e4d69c965bb598b88fac58e475dd1f5e56c362b,
            0x7ddad27e9a238d045c035bc606349d075d5c5cd00a6cd1da23ab5c39d4ef0f60,
            27
        );
    }

    // ── The big-blocks action ──────────────────────────────────────────────────────────

    /// @notice Byte for byte what msgpack-python packs for the SDK's use_big_blocks dict.
    function test_EvmUserModify_Msgpack() public pure {
        assertEq(
            HyperCoreL1Action.evmUserModify(true),
            abi.encodePacked(
                hex"82", hex"a4", "type", hex"ad", "evmUserModify", hex"ae", "usingBigBlocks", hex"c3"
            )
        );
        assertEq(
            HyperCoreL1Action.evmUserModify(false),
            abi.encodePacked(
                hex"82", hex"a4", "type", hex"ad", "evmUserModify", hex"ae", "usingBigBlocks", hex"c2"
            )
        );
    }

    function test_ConnectionId_IsKeccakOfActionNonceAndVaultFlag() public pure {
        bytes memory packed = HyperCoreL1Action.evmUserModify(true);
        uint64 nonce = 1_794_800_000_000;
        assertEq(
            HyperCoreL1Action.connectionId(packed, nonce, address(0)),
            keccak256(abi.encodePacked(packed, bytes8(nonce), hex"00"))
        );
        address vault = address(0xBEEF);
        assertEq(
            HyperCoreL1Action.connectionId(packed, nonce, vault),
            keccak256(abi.encodePacked(packed, bytes8(nonce), hex"01", vault))
        );
    }

    function test_Source_AOnMainnetBOnTestnet() public pure {
        assertEq(HyperCoreL1Action.source(true), "a");
        assertEq(HyperCoreL1Action.source(false), "b");
    }

    // ── MessagePack edges ──────────────────────────────────────────────────────────────

    function test_Uinteger_SmallestFormat() public pure {
        assertEq(HyperCoreL1Action.uinteger(0), hex"00");
        assertEq(HyperCoreL1Action.uinteger(127), hex"7f");
        assertEq(HyperCoreL1Action.uinteger(128), hex"cc80");
        assertEq(HyperCoreL1Action.uinteger(256), hex"cd0100");
        assertEq(HyperCoreL1Action.uinteger(65536), hex"ce00010000");
        assertEq(HyperCoreL1Action.uinteger(type(uint64).max), hex"cfffffffffffffffff");
    }

    function test_Str_Formats() public {
        assertEq(HyperCoreL1Action.str(""), hex"a0");
        bytes memory s32 = new bytes(32);
        assertEq(HyperCoreL1Action.str(string(s32)), abi.encodePacked(hex"d920", s32));
        MsgpackHarness h = new MsgpackHarness();
        bytes memory s256 = new bytes(256);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreL1Action.MsgpackStringTooLong.selector, 256));
        h.str(string(s256));
    }

    function test_MapHeader_FixmapOnly() public {
        assertEq(HyperCoreL1Action.mapHeader(0), hex"80");
        assertEq(HyperCoreL1Action.mapHeader(15), hex"8f");
        MsgpackHarness h = new MsgpackHarness();
        vm.expectRevert(abi.encodeWithSelector(HyperCoreL1Action.MsgpackMapTooLarge.selector, 16));
        h.mapHeader(16);
    }
}

/// @notice The helper script: what it prints and writes, and that the typed-data file decodes
/// to the digest the library computes (`vm.eip712HashTypedData` parses EIP-712 JSON the way
/// `cast wallet sign --data` does).
contract HyperEvmBigBlocksScriptTest is Test {
    HyperEvmBigBlocks internal helper;
    uint64 internal constant NONCE = 1_794_800_000_000;

    function setUp() public {
        helper = new HyperEvmBigBlocks();
    }

    function test_TypedDataFile_HashesToTheTestnetAgentDigest() public view {
        bytes32 connId = HyperCoreL1Action.connectionId(HyperCoreL1Action.evmUserModify(true), NONCE, address(0));
        assertEq(
            vm.eip712HashTypedData(helper.typedDataJson(connId)), HyperCoreL1Action.agentDigest(connId, false)
        );
    }

    /// @notice ONE test for everything that writes the two files: tests run in parallel and
    /// would otherwise overwrite each other's output.
    function test_PrepareAndRun_WriteTheTypedDataAndTheRequest() public {
        // Enable, fixed nonce.
        (bytes32 connId, bytes32 digest) = helper.prepare(true, NONCE);
        assertEq(connId, HyperCoreL1Action.connectionId(HyperCoreL1Action.evmUserModify(true), NONCE, address(0)));
        assertEq(digest, HyperCoreL1Action.agentDigest(connId, false));
        string memory typed = vm.readFile(helper.TYPED_DATA_FILE());
        assertEq(vm.eip712HashTypedData(typed), digest);
        assertEq(vm.parseJsonString(typed, ".message.source"), "b");
        assertEq(vm.parseJsonBytes32(typed, ".message.connectionId"), connId);
        string memory request = vm.readFile(helper.REQUEST_FILE());
        assertEq(vm.parseJsonString(request, ".action.type"), "evmUserModify");
        assertTrue(vm.parseJsonBool(request, ".action.usingBigBlocks"));
        assertEq(vm.parseJsonUint(request, ".nonce"), NONCE);

        // Disable: a different action, so a different connectionId.
        (bytes32 offId,) = helper.prepare(false, NONCE);
        assertTrue(offId != connId);
        assertFalse(vm.parseJsonBool(vm.readFile(helper.REQUEST_FILE()), ".action.usingBigBlocks"));

        // run() / runDisable(): the nonce is wall-clock milliseconds (vm.unixTime), not the
        // block time.
        vm.warp(1_000);
        helper.run();
        assertTrue(vm.parseJsonBool(vm.readFile(helper.REQUEST_FILE()), ".action.usingBigBlocks"));
        assertGt(vm.parseJsonUint(vm.readFile(helper.REQUEST_FILE()), ".nonce"), 1_700_000_000_000);
        helper.runDisable();
        assertFalse(vm.parseJsonBool(vm.readFile(helper.REQUEST_FILE()), ".action.usingBigBlocks"));
    }

    function test_ActionJson_KeysInHashOrder() public view {
        assertEq(helper.actionJson(true), '{"type":"evmUserModify","usingBigBlocks":true}');
        assertEq(helper.actionJson(false), '{"type":"evmUserModify","usingBigBlocks":false}');
    }

    function test_RequestJson_MatchesTheSdkBodyWithoutSignature() public view {
        assertEq(
            helper.requestJson(true, NONCE),
            '{"action":{"type":"evmUserModify","usingBigBlocks":true},"nonce":1794800000000,"vaultAddress":null,"expiresAfter":null}'
        );
    }

}

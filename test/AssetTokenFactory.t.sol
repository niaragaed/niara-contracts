// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Unit tests for AssetTokenFactory and NativeAssetToken. The minter here is a
/// stand-in address; the real minter (ListingRegistry) is covered in ListingRegistry.t.sol.
contract AssetTokenFactoryTest is Test {
    AssetTokenFactory public factory;

    address public registry = makeAddr("registry");
    address public issuer = makeAddr("issuer");
    address public holder = makeAddr("holder");

    bytes32 public constant DOC_HASH = keccak256("offering-document-v1");

    function setUp() public {
        factory = new AssetTokenFactory(registry);
    }

    function _create(IListingRegistry.AssetClass assetClass) internal returns (NativeAssetToken) {
        vm.prank(issuer);
        return NativeAssetToken(factory.createAssetToken("Acme Equity", "ACME", assetClass, DOC_HASH));
    }

    // ── Factory ────────────────────────────────────────────────────────────────────────

    function test_Constructor_SetsRegistry() public view {
        assertEq(factory.registry(), registry);
    }

    function test_Constructor_RevertsForZeroRegistry() public {
        vm.expectRevert(AssetTokenFactory.ZeroAddress.selector);
        new AssetTokenFactory(address(0));
    }

    function test_CreateAssetToken_RecordsIssuerClassDocHashAndMinter() public {
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Equity);

        assertTrue(factory.isFactoryToken(address(token)));
        assertEq(token.issuer(), issuer);
        assertEq(token.issuerWallet(), issuer);
        assertEq(token.minter(), registry);
        assertEq(uint8(token.assetClass()), uint8(IListingRegistry.AssetClass.Equity));
        assertEq(token.docHash(), DOC_HASH);
        assertTrue(token.cashbackEligible());
        assertEq(token.name(), "Acme Equity");
        assertEq(token.symbol(), "ACME");
        assertEq(token.decimals(), 18);
    }

    function test_CreateAssetToken_HasNoInitialSupply() public {
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Equity);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(issuer), 0);
    }

    function test_CreateAssetToken_AcceptsFixedIncomeAndCredit() public {
        NativeAssetToken bond = _create(IListingRegistry.AssetClass.FixedIncome);
        NativeAssetToken loan = _create(IListingRegistry.AssetClass.Credit);
        assertEq(uint8(bond.assetClass()), uint8(IListingRegistry.AssetClass.FixedIncome));
        assertEq(uint8(loan.assetClass()), uint8(IListingRegistry.AssetClass.Credit));
        assertTrue(factory.isFactoryToken(address(bond)));
        assertTrue(factory.isFactoryToken(address(loan)));
    }

    function test_CreateAssetToken_RevertsForCurrency() public {
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetTokenFactory.UnsupportedAssetClass.selector, IListingRegistry.AssetClass.Currency
            )
        );
        factory.createAssetToken("Fake Dollar", "FUSD", IListingRegistry.AssetClass.Currency, DOC_HASH);
    }

    function test_CreateAssetToken_EmitsEvent() public {
        vm.recordLogs();
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Credit);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("AssetTokenCreated(address,address,uint8,bytes32,string,string)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == topic) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), issuer);
            }
        }
        assertTrue(found, "AssetTokenCreated not emitted");
    }

    function test_IsFactoryToken_FalseForOtherAddresses() public view {
        assertFalse(factory.isFactoryToken(address(0xBEEF)));
        assertFalse(factory.isFactoryToken(address(factory)));
    }

    // ── NativeAssetToken: mint ─────────────────────────────────────────────────────────

    function test_Mint_OnlyMinter() public {
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Equity);

        vm.prank(issuer);
        vm.expectRevert(NativeAssetToken.NotMinter.selector);
        token.mint(holder, 1 ether);

        vm.prank(address(factory));
        vm.expectRevert(NativeAssetToken.NotMinter.selector);
        token.mint(holder, 1 ether);
    }

    function test_Mint_ByMinterMints() public {
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Equity);
        vm.prank(registry);
        token.mint(holder, 100 ether);
        assertEq(token.balanceOf(holder), 100 ether);
        assertEq(token.totalSupply(), 100 ether);
    }

    // ── NativeAssetToken: burnWithReason ───────────────────────────────────────────────

    function test_BurnWithReason_BurnsAndEmits() public {
        NativeAssetToken token = _create(IListingRegistry.AssetClass.FixedIncome);
        vm.prank(registry);
        token.mint(holder, 100 ether);

        bytes32 ref = keccak256("redemption-42");
        vm.expectEmit(true, false, false, true, address(token));
        emit NativeAssetToken.TokensBurned(holder, 40 ether, NativeAssetToken.BurnReason.Redemption, ref);

        vm.prank(holder);
        token.burnWithReason(40 ether, NativeAssetToken.BurnReason.Redemption, ref);

        assertEq(token.balanceOf(holder), 60 ether);
        assertEq(token.totalSupply(), 60 ether);
    }

    function test_BurnWithReason_Cancellation() public {
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Credit);
        vm.prank(registry);
        token.mint(holder, 10 ether);

        vm.expectEmit(true, false, false, true, address(token));
        emit NativeAssetToken.TokensBurned(holder, 10 ether, NativeAssetToken.BurnReason.Cancellation, bytes32(0));

        vm.prank(holder);
        token.burnWithReason(10 ether, NativeAssetToken.BurnReason.Cancellation, bytes32(0));
        assertEq(token.totalSupply(), 0);
    }

    function test_BurnWithReason_RevertsOnZeroAmount() public {
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Equity);
        vm.prank(holder);
        vm.expectRevert(NativeAssetToken.ZeroAmount.selector);
        token.burnWithReason(0, NativeAssetToken.BurnReason.Redemption, bytes32(0));
    }

    function test_BurnWithReason_RevertsBeyondBalance() public {
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Equity);
        vm.prank(registry);
        token.mint(holder, 1 ether);

        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 1 ether, 2 ether)
        );
        token.burnWithReason(2 ether, NativeAssetToken.BurnReason.Redemption, bytes32(0));
    }

    /// @notice Only the caller's own balance can be burned: a third party (even the issuer
    /// or the minter) cannot burn a holder's tokens.
    function test_BurnWithReason_OnlyBurnsCallerBalance() public {
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Equity);
        vm.prank(registry);
        token.mint(holder, 5 ether);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, issuer, 0, 5 ether));
        token.burnWithReason(5 ether, NativeAssetToken.BurnReason.Cancellation, bytes32(0));

        assertEq(token.balanceOf(holder), 5 ether);
    }

    /// @notice Transfers are plain ERC-20: the receiver gets exactly what was sent.
    function testFuzz_Transfer_IsExact(uint256 minted, uint256 sent) public {
        minted = bound(minted, 1, type(uint128).max);
        sent = bound(sent, 0, minted);
        NativeAssetToken token = _create(IListingRegistry.AssetClass.Equity);
        vm.prank(registry);
        token.mint(holder, minted);

        vm.prank(holder);
        assertTrue(token.transfer(issuer, sent));
        assertEq(token.balanceOf(issuer), sent);
        assertEq(token.balanceOf(holder), minted - sent);
        assertEq(token.totalSupply(), minted);
    }
}

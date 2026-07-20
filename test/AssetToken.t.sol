// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {MockBackingGateway} from "./mocks/MockBackingGateway.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// NOTA IMPORTANTE SOBRE OS TESTES: `token.ALGO_ROLE()` é uma chamada externa (staticcall).
// Se ela aparecer na mesma linha, como argumento, de uma chamada logo após um
// vm.prank/vm.expectRevert destinado a OUTRA chamada, ela "rouba" o prank/expectRevert —
// o cheatcode se aplica à primeiríssima chamada externa seguinte, não à chamada que
// visualmente parece ser a testada. Por isso todo bytes32 de papel é resolvido uma única
// vez em variáveis no setUp, fora de qualquer prank, e reutilizado nos testes.
contract AssetTokenTest is Test {
    AssetToken public token;
    MockBackingGateway public gateway;

    address public admin = makeAddr("admin");
    address public issuer = makeAddr("issuer");
    address public minter = makeAddr("minter");
    address public burner = makeAddr("burner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant TIMELOCK_DELAY = 2 days;
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);

    bytes32 public minterRole;
    bytes32 public burnerRole;
    bytes32 public pauserRole;
    bytes32 public custodianRole;

    function setUp() public {
        gateway = new MockBackingGateway();

        token = new AssetToken(
            "Apple Inc. - Niara Tokenized Equity",
            "nAAPL",
            "AAPL",
            AssetToken.AssetClass.EQUITY,
            "US",
            issuer,
            admin,
            TIMELOCK_DELAY
        );

        minterRole = token.MINTER_ROLE();
        burnerRole = token.BURNER_ROLE();
        pauserRole = token.PAUSER_ROLE();
        custodianRole = token.CUSTODIAN_ROLE();

        _setBackingGateway(address(gateway));
        _grantRole(minterRole, minter);
        _grantRole(burnerRole, burner);
    }

    // ── Helpers de governança com timelock ────────────────────────────────────────────

    function _setBackingGateway(address newGateway) internal {
        vm.prank(admin);
        token.proposeSetBackingGateway(newGateway);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        token.executeSetBackingGateway(newGateway);
    }

    function _grantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        token.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        token.executeGrantRole(role, account);
    }

    // ── Metadados e elegibilidade a cashback ──────────────────────────────────────────

    function test_InitialMetadata() public view {
        assertEq(token.name(), "Apple Inc. - Niara Tokenized Equity");
        assertEq(token.symbol(), "nAAPL");
        assertEq(token.assetReference(), "AAPL");
        assertEq(uint8(token.assetClass()), uint8(AssetToken.AssetClass.EQUITY));
        assertEq(token.countryOfOrigin(), "US");
        assertEq(token.issuerWallet(), issuer);
        assertTrue(token.cashbackEligible());
    }

    function test_CashbackEligible_EquityAndETF() public {
        AssetToken etf = new AssetToken(
            "Niara Tokenized ETF", "nETF", "SPY", AssetToken.AssetClass.ETF, "US", issuer, admin, TIMELOCK_DELAY
        );
        assertTrue(etf.cashbackEligible());
    }

    function test_CashbackNotEligible_CurrencyCommodityFund() public {
        AssetToken currency = new AssetToken(
            "Niara Tokenized EUR", "nEUR", "EUR", AssetToken.AssetClass.CURRENCY, "EU", issuer, admin, TIMELOCK_DELAY
        );
        AssetToken commodity = new AssetToken(
            "Niara Tokenized Gold", "nXAU", "XAU", AssetToken.AssetClass.COMMODITY, "US", issuer, admin, TIMELOCK_DELAY
        );
        AssetToken fund = new AssetToken(
            "Niara Tokenized Fund", "nFUND", "FUND1", AssetToken.AssetClass.FUND, "US", issuer, admin, TIMELOCK_DELAY
        );

        assertFalse(currency.cashbackEligible());
        assertFalse(commodity.cashbackEligible());
        assertFalse(fund.cashbackEligible());
    }

    // ── Invariante de lastro no mint ───────────────────────────────────────────────────

    function test_Mint_RevertsWithoutBackingGatewaySet() public {
        AssetToken freshToken = new AssetToken(
            "Test", "TST", "TST", AssetToken.AssetClass.EQUITY, "US", issuer, admin, TIMELOCK_DELAY
        );
        bytes32 freshMinterRole = freshToken.MINTER_ROLE();

        vm.prank(admin);
        freshToken.proposeGrantRole(freshMinterRole, minter);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        freshToken.executeGrantRole(freshMinterRole, minter);

        vm.prank(minter);
        vm.expectRevert(AssetToken.BackingGatewayNotSet.selector);
        freshToken.mint(alice, 1 ether);
    }

    function test_Mint_RevertsWhenNoAttestation() public {
        // totalAttested nunca foi setado (fica em zero) — mint de qualquer quantidade > 0 deve reverter.
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AssetToken.MintExceedsAttestedBacking.selector, 1 ether, 0));
        token.mint(alice, 1 ether);
    }

    function test_Mint_RevertsWhenExceedsAttested() public {
        gateway.setTotalAttested(address(token), 100 ether);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AssetToken.MintExceedsAttestedBacking.selector, 100 ether + 1, 100 ether));
        token.mint(alice, 100 ether + 1);
    }

    function test_Mint_SucceedsUpToAttested() public {
        gateway.setTotalAttested(address(token), 100 ether);

        vm.prank(minter);
        token.mint(alice, 100 ether);

        assertEq(token.totalSupply(), 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_Mint_RevertsOnSecondMintThatExceedsAttested() public {
        gateway.setTotalAttested(address(token), 100 ether);

        vm.startPrank(minter);
        token.mint(alice, 60 ether);
        vm.expectRevert(abi.encodeWithSelector(AssetToken.MintExceedsAttestedBacking.selector, 100 ether + 1, 100 ether));
        token.mint(alice, 40 ether + 1);
        vm.stopPrank();
    }

    function test_Mint_RevertsIfNotMinterRole() public {
        gateway.setTotalAttested(address(token), 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minterRole));
        token.mint(alice, 1 ether);
    }

    // ── Burn ───────────────────────────────────────────────────────────────────────────

    function test_Burn_OnlyBurnerRole() public {
        gateway.setTotalAttested(address(token), 100 ether);
        vm.prank(minter);
        token.mint(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, burnerRole));
        token.burn(alice, 10 ether);

        vm.prank(burner);
        token.burn(alice, 10 ether);
        assertEq(token.balanceOf(alice), 90 ether);
    }

    // ── Pausable ───────────────────────────────────────────────────────────────────────

    function test_Pause_ByPauserRole() public {
        vm.prank(admin);
        token.pause();
        assertTrue(token.paused());
    }

    function test_Pause_ByCustodianRole() public {
        // admin também detém CUSTODIAN_ROLE por padrão neste setUp
        vm.prank(admin);
        token.pause();
        assertTrue(token.paused());
    }

    function test_Pause_RevertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(AssetToken.NotAuthorizedToPause.selector);
        token.pause();
    }

    function test_Unpause_OnlyPauserRole() public {
        vm.prank(admin);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pauserRole));
        token.unpause();

        vm.prank(admin);
        token.unpause();
        assertFalse(token.paused());
    }

    function test_Pause_BlocksMintAndTransfer() public {
        gateway.setTotalAttested(address(token), 100 ether);
        vm.prank(minter);
        token.mint(alice, 50 ether);

        vm.prank(admin);
        token.pause();

        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.mint(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(bob, 1 ether);
    }

    // ── Timelock: issuerWallet ─────────────────────────────────────────────────────────

    function test_SetIssuerWallet_RevertsBeforeDelayElapses() public {
        address newIssuer = makeAddr("newIssuer");
        vm.prank(admin);
        token.proposeSetIssuerWallet(newIssuer);

        bytes32 actionId = keccak256(abi.encode("SET_ISSUER_WALLET", newIssuer));
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAccessControl.TimelockNotElapsed.selector, actionId, executeAfter)
        );
        token.executeSetIssuerWallet(newIssuer);
    }

    function test_SetIssuerWallet_SucceedsAfterDelay() public {
        address newIssuer = makeAddr("newIssuer");
        vm.prank(admin);
        token.proposeSetIssuerWallet(newIssuer);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        token.executeSetIssuerWallet(newIssuer);

        assertEq(token.issuerWallet(), newIssuer);
    }

    function test_SetIssuerWallet_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        token.proposeSetIssuerWallet(alice);
    }

    function test_SetIssuerWallet_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AssetToken.ZeroAddress.selector);
        token.proposeSetIssuerWallet(address(0));
    }

    // ── Papéis: grantRole/revokeRole diretos desabilitados ────────────────────────────

    function test_DirectGrantRole_AlwaysReverts() public {
        vm.prank(admin);
        vm.expectRevert(TimelockedAccessControl.RoleChangeRequiresTimelock.selector);
        token.grantRole(minterRole, alice);
    }

    function test_DirectRevokeRole_AlwaysReverts() public {
        vm.prank(admin);
        vm.expectRevert(TimelockedAccessControl.RoleChangeRequiresTimelock.selector);
        token.revokeRole(minterRole, minter);
    }

    function test_GrantRole_ViaTimelock() public {
        vm.prank(admin);
        token.proposeGrantRole(minterRole, alice);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        token.executeGrantRole(minterRole, alice);

        assertTrue(token.hasRole(minterRole, alice));
    }

    function test_RevokeRole_ViaTimelock() public {
        vm.prank(admin);
        token.proposeRevokeRole(minterRole, minter);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        token.executeRevokeRole(minterRole, minter);

        assertFalse(token.hasRole(minterRole, minter));
    }
}

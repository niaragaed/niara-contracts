// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract BackingGatewayTest is Test {
    BackingGateway public gateway;
    AssetToken public token;

    address public admin = makeAddr("admin");
    address public issuer = makeAddr("issuer");
    address public operator = makeAddr("operator");
    address public custodian = makeAddr("custodian");
    address public alice = makeAddr("alice");

    uint256 public constant TIMELOCK_DELAY = 2 days;

    bytes32 public operatorRole;
    bytes32 public custodianRole;
    bytes32 public pauserRole;
    bytes32 public tokenMinterRole;
    bytes32 public tokenBurnerRole;

    function setUp() public {
        gateway = new BackingGateway(admin, TIMELOCK_DELAY);
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

        operatorRole = gateway.OPERATOR_ROLE();
        custodianRole = gateway.CUSTODIAN_ROLE();
        pauserRole = gateway.PAUSER_ROLE();
        tokenMinterRole = token.MINTER_ROLE();
        tokenBurnerRole = token.BURNER_ROLE();

        _gatewayGrantRole(operatorRole, operator);
        _gatewayGrantRole(custodianRole, custodian);

        _tokenGrantRole(tokenMinterRole, address(gateway));
        _tokenGrantRole(tokenBurnerRole, address(gateway));
        _tokenSetBackingGateway(address(gateway));
    }

    // ── Helpers de governança com timelock ────────────────────────────────────────────

    function _gatewayGrantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        gateway.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        gateway.executeGrantRole(role, account);
    }

    function _tokenGrantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        token.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        token.executeGrantRole(role, account);
    }

    function _tokenSetBackingGateway(address newGateway) internal {
        vm.prank(admin);
        token.proposeSetBackingGateway(newGateway);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        token.executeSetBackingGateway(newGateway);
    }

    function _requestBacking(uint256 quantity) internal returns (uint256 requestId) {
        vm.prank(operator);
        requestId = gateway.requestBacking(address(token), quantity);
    }

    // ── Lastro: request → attest → mint ───────────────────────────────────────────────

    function test_RequestBacking_OnlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, operatorRole));
        gateway.requestBacking(address(token), 100 ether);
    }

    function test_RequestBacking_CreatesPendingRequest() public {
        uint256 requestId = _requestBacking(100 ether);

        (address asset, address requester, uint256 quantityRequested, uint256 quantityAcquired,, BackingGateway.RequestStatus status,) =
            gateway.backingRequests(requestId);

        assertEq(asset, address(token));
        assertEq(requester, operator);
        assertEq(quantityRequested, 100 ether);
        assertEq(quantityAcquired, 0);
        assertEq(uint8(status), uint8(BackingGateway.RequestStatus.PENDING));
    }

    function test_RequestBacking_RevertsForZeroQuantity() public {
        vm.prank(operator);
        vm.expectRevert(BackingGateway.ZeroQuantity.selector);
        gateway.requestBacking(address(token), 0);
    }

    function test_AttestBacking_OnlyCustodian() public {
        uint256 requestId = _requestBacking(100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, custodianRole));
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether);
    }

    function test_AttestBacking_RevertsIfQuantityAcquiredExceedsRequested() public {
        uint256 requestId = _requestBacking(100 ether);

        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(BackingGateway.QuantityAcquiredExceedsRequested.selector, 100 ether + 1, 100 ether)
        );
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether + 1);
    }

    function test_AttestBacking_RevertsForZeroQuantity() public {
        uint256 requestId = _requestBacking(100 ether);

        vm.prank(custodian);
        vm.expectRevert(BackingGateway.ZeroQuantity.selector);
        gateway.attestBacking(requestId, keccak256("proof"), 0);
    }

    function test_AttestBacking_RevertsIfNotPending() public {
        uint256 requestId = _requestBacking(100 ether);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether);

        vm.prank(custodian);
        vm.expectRevert(abi.encodeWithSelector(BackingGateway.RequestNotPending.selector, requestId));
        gateway.attestBacking(requestId, keccak256("proof2"), 1 ether);
    }

    function test_AttestBacking_IncreasesTotalAttested() public {
        uint256 requestId = _requestBacking(100 ether);

        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 80 ether);

        assertEq(gateway.totalAttested(address(token)), 80 ether);
    }

    function test_MintAttested_OnlyOperator() public {
        uint256 requestId = _requestBacking(100 ether);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, operatorRole));
        gateway.mintAttested(requestId, alice);
    }

    function test_MintAttested_RevertsIfNotSettled() public {
        uint256 requestId = _requestBacking(100 ether);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BackingGateway.RequestNotSettled.selector, requestId));
        gateway.mintAttested(requestId, alice);
    }

    function test_MintAttested_MintsExactAttestedQuantity() public {
        uint256 requestId = _requestBacking(100 ether);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 80 ether);

        vm.prank(operator);
        gateway.mintAttested(requestId, alice);

        assertEq(token.balanceOf(alice), 80 ether);
        assertEq(token.totalSupply(), 80 ether);
    }

    function test_MintAttested_RevertsIfAlreadyMinted() public {
        uint256 requestId = _requestBacking(100 ether);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether);
        vm.prank(operator);
        gateway.mintAttested(requestId, alice);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BackingGateway.AlreadyMinted.selector, requestId));
        gateway.mintAttested(requestId, alice);
    }

    /// @notice Invariante central: mesmo que MINTER_ROLE seja concedido a um endereço fora
    /// do fluxo do BackingGateway, ainda assim é impossível cunhar além do que o gateway
    /// atestou — a checagem vive dentro do próprio AssetToken.mint.
    function test_Invariant_MintBeyondAttestedIsImpossibleRegardlessOfCaller() public {
        uint256 requestId = _requestBacking(100 ether);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 50 ether);

        // Concede MINTER_ROLE diretamente a Alice, fora do fluxo do gateway.
        _tokenGrantRole(tokenMinterRole, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AssetToken.MintExceedsAttestedBacking.selector, 50 ether + 1, 50 ether));
        token.mint(alice, 50 ether + 1);

        // Até o teto exatamente atestado, o mint funciona normalmente.
        vm.prank(alice);
        token.mint(alice, 50 ether);
        assertEq(token.totalSupply(), 50 ether);
    }

    function test_CancelBackingRequest_OnlyIfPending() public {
        uint256 requestId = _requestBacking(100 ether);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BackingGateway.RequestNotPending.selector, requestId));
        gateway.cancelBackingRequest(requestId);
    }

    function test_CancelBackingRequest_Succeeds() public {
        uint256 requestId = _requestBacking(100 ether);

        vm.prank(operator);
        gateway.cancelBackingRequest(requestId);

        (,,,,, BackingGateway.RequestStatus status,) = gateway.backingRequests(requestId);
        assertEq(uint8(status), uint8(BackingGateway.RequestStatus.CANCELLED));
    }

    // ── Resgate: request → attest (queima) ────────────────────────────────────────────

    function _mintTokensTo(address to, uint256 amount) internal returns (uint256 requestId) {
        requestId = _requestBacking(amount);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), amount);
        vm.prank(operator);
        gateway.mintAttested(requestId, to);
    }

    function test_RedemptionRequest_PullsTokensIntoCustody() public {
        _mintTokensTo(alice, 100 ether);

        vm.prank(alice);
        token.approve(address(gateway), 40 ether);

        vm.prank(alice);
        uint256 requestId = gateway.redemptionRequest(address(token), 40 ether);

        assertEq(token.balanceOf(address(gateway)), 40 ether);
        assertEq(token.balanceOf(alice), 60 ether);

        (,, uint256 quantity,, BackingGateway.RequestStatus status) = gateway.redemptionRequests(requestId);
        assertEq(quantity, 40 ether);
        assertEq(uint8(status), uint8(BackingGateway.RequestStatus.PENDING));
    }

    function test_RedemptionRequest_RevertsWithoutAllowance() public {
        _mintTokensTo(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gateway), 0, 40 ether)
        );
        gateway.redemptionRequest(address(token), 40 ether);
    }

    function test_RedemptionAttest_OnlyCustodian() public {
        _mintTokensTo(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(gateway), 40 ether);
        vm.prank(alice);
        uint256 requestId = gateway.redemptionRequest(address(token), 40 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, custodianRole));
        gateway.redemptionAttest(requestId, keccak256("proof"));
    }

    function test_RedemptionAttest_BurnsAndReducesTotalAttested() public {
        _mintTokensTo(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(gateway), 40 ether);
        vm.prank(alice);
        uint256 requestId = gateway.redemptionRequest(address(token), 40 ether);

        uint256 attestedBefore = gateway.totalAttested(address(token));

        vm.prank(custodian);
        gateway.redemptionAttest(requestId, keccak256("proof"));

        assertEq(token.totalSupply(), 60 ether);
        assertEq(token.balanceOf(address(gateway)), 0);
        assertEq(gateway.totalAttested(address(token)), attestedBefore - 40 ether);
    }

    function test_RedemptionAttest_RevertsIfNotPending() public {
        _mintTokensTo(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(gateway), 40 ether);
        vm.prank(alice);
        uint256 requestId = gateway.redemptionRequest(address(token), 40 ether);
        vm.prank(custodian);
        gateway.redemptionAttest(requestId, keccak256("proof"));

        vm.prank(custodian);
        vm.expectRevert(abi.encodeWithSelector(BackingGateway.RequestNotPending.selector, requestId));
        gateway.redemptionAttest(requestId, keccak256("proof2"));
    }

    function test_CancelRedemptionRequest_ReturnsTokens() public {
        _mintTokensTo(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(gateway), 40 ether);
        vm.prank(alice);
        uint256 requestId = gateway.redemptionRequest(address(token), 40 ether);

        vm.prank(custodian);
        gateway.cancelRedemptionRequest(requestId);

        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function test_CancelRedemptionRequest_OnlyCustodian() public {
        _mintTokensTo(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(gateway), 40 ether);
        vm.prank(alice);
        uint256 requestId = gateway.redemptionRequest(address(token), 40 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, custodianRole));
        gateway.cancelRedemptionRequest(requestId);
    }

    // ── Pausable ───────────────────────────────────────────────────────────────────────

    function test_Pause_BlocksRequestBacking() public {
        vm.prank(admin);
        gateway.pause();

        vm.prank(operator);
        vm.expectRevert();
        gateway.requestBacking(address(token), 100 ether);
    }

    function test_Pause_OnlyPauserRole() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pauserRole));
        gateway.pause();
    }

    function test_Unpause_OnlyPauserRole() public {
        vm.prank(admin);
        gateway.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pauserRole));
        gateway.unpause();
    }

    /// @notice Ponta a ponta: pausar bloqueia as quatro operações protegidas por
    /// `whenNotPaused` (requestBacking, attestBacking, mintAttested, redemptionRequest);
    /// despausar restaura o funcionamento normal de cada uma delas.
    function test_PauseUnpause_EndToEnd_BlocksThenRestoresOperations() public {
        uint256 requestId = _requestBacking(100 ether);

        vm.prank(admin);
        gateway.pause();
        assertTrue(gateway.paused());

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.requestBacking(address(token), 1 ether);

        vm.prank(custodian);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether);

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.mintAttested(requestId, alice);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.redemptionRequest(address(token), 1 ether);

        vm.prank(admin);
        gateway.unpause();
        assertFalse(gateway.paused());

        // As mesmas operações voltam a funcionar normalmente após o unpause.
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether);
        vm.prank(operator);
        gateway.mintAttested(requestId, alice);
        assertEq(token.balanceOf(alice), 100 ether);

        vm.prank(alice);
        token.approve(address(gateway), 40 ether);
        vm.prank(alice);
        uint256 redemptionId = gateway.redemptionRequest(address(token), 40 ether);
        assertEq(token.balanceOf(address(gateway)), 40 ether);

        vm.prank(custodian);
        gateway.redemptionAttest(redemptionId, keccak256("proof2"));
        assertEq(token.balanceOf(alice), 60 ether);
    }

    // ── Guardas de endereço/quantidade zero ────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(BackingGateway.ZeroAddress.selector);
        new BackingGateway(address(0), TIMELOCK_DELAY);
    }

    function test_RequestBacking_RevertsForZeroAssetAddress() public {
        vm.prank(operator);
        vm.expectRevert(BackingGateway.ZeroAddress.selector);
        gateway.requestBacking(address(0), 100 ether);
    }

    function test_MintAttested_RevertsForZeroRecipient() public {
        uint256 requestId = _requestBacking(100 ether);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether);

        vm.prank(operator);
        vm.expectRevert(BackingGateway.ZeroAddress.selector);
        gateway.mintAttested(requestId, address(0));
    }

    function test_RedemptionRequest_RevertsForZeroAssetAddress() public {
        vm.prank(alice);
        vm.expectRevert(BackingGateway.ZeroAddress.selector);
        gateway.redemptionRequest(address(0), 1 ether);
    }

    function test_RedemptionRequest_RevertsForZeroQuantity() public {
        vm.prank(alice);
        vm.expectRevert(BackingGateway.ZeroQuantity.selector);
        gateway.redemptionRequest(address(token), 0);
    }

    function test_CancelRedemptionRequest_RevertsIfNotPending() public {
        _mintTokensTo(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(gateway), 40 ether);
        vm.prank(alice);
        uint256 requestId = gateway.redemptionRequest(address(token), 40 ether);

        vm.prank(custodian);
        gateway.cancelRedemptionRequest(requestId);

        vm.prank(custodian);
        vm.expectRevert(abi.encodeWithSelector(BackingGateway.RequestNotPending.selector, requestId));
        gateway.cancelRedemptionRequest(requestId);
    }
}

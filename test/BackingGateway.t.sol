// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MaliciousHookToken} from "./mocks/MaliciousHookToken.sol";

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

    // ── Timelocked governance helpers ─────────────────────────────────────────────────

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

    // ── Backing: request → attest → mint ──────────────────────────────────────────────

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

    /// @notice Core invariant: even if MINTER_ROLE is granted to an address outside the
    /// BackingGateway flow, it is still impossible to mint beyond what the gateway
    /// attested, because the check lives inside AssetToken.mint itself.
    function test_Invariant_MintBeyondAttestedIsImpossibleRegardlessOfCaller() public {
        uint256 requestId = _requestBacking(100 ether);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 50 ether);

        // Grants MINTER_ROLE directly to Alice, outside the gateway flow.
        _tokenGrantRole(tokenMinterRole, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AssetToken.MintExceedsAttestedBacking.selector, 50 ether + 1, 50 ether));
        token.mint(alice, 50 ether + 1);

        // Up to exactly the attested cap, minting works normally.
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

    /// @notice End to end: pausing blocks the four operations guarded by
    /// `whenNotPaused` (requestBacking, attestBacking, mintAttested, redemptionRequest);
    /// unpausing restores each of them to normal.
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

        // The same operations work normally again after unpause.
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

    // ── Zero address/quantity guards ──────────────────────────────────────────────────

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

    // ── Cross-function reentrancy (checks-effects-interactions) ───────────────────────

    /// @dev Extracts the selector from raw return data (e.g. the error of a reverted call).
    function _selectorOf(bytes memory data) internal pure returns (bytes4 sel) {
        require(data.length >= 4, "return data has no selector");
        assembly {
            sel := mload(add(data, 32))
        }
    }

    /// @dev Prepares a hostile asset, already attested and ready for `mintAttested`.
    function _armedBackingRequest(MaliciousHookToken evil, uint256 quantity)
        internal
        returns (uint256 requestId)
    {
        vm.prank(operator);
        requestId = gateway.requestBacking(address(evil), quantity);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), quantity);
    }

    function test_MintAttested_ReentrancyDuringMintSeesRequestAlreadyMinted() public {
        MaliciousHookToken evil = new MaliciousHookToken();
        uint256 requestId = _armedBackingRequest(evil, 100 ether);

        // During `mint`, the hook reads its own request back from the gateway.
        evil.armOnMint(address(gateway), abi.encodeWithSignature("backingRequests(uint256)", requestId));

        vm.prank(operator);
        gateway.mintAttested(requestId, alice);

        assertTrue(evil.reentered());
        assertTrue(evil.reentrantSucceeded());

        (,,,,, uint8 status, bool minted) = abi.decode(
            evil.reentrantReturnData(), (address, address, uint256, uint256, bytes32, uint8, bool)
        );
        // The effect was already committed when the external call happened.
        assertTrue(minted);
        assertEq(status, uint8(BackingGateway.RequestStatus.SETTLED));
        assertEq(evil.balanceOf(alice), 100 ether);
    }

    function test_MintAttested_ReentrantMintAttestedRevertsViaGuard() public {
        MaliciousHookToken evil = new MaliciousHookToken();
        uint256 requestId = _armedBackingRequest(evil, 100 ether);

        // Grants OPERATOR_ROLE to the hostile token itself to isolate the guarantee under test
        // (the reentrancy guard) from the access-control check.
        _gatewayGrantRole(operatorRole, address(evil));

        evil.armOnMint(
            address(gateway), abi.encodeWithSignature("mintAttested(uint256,address)", requestId, alice)
        );

        vm.prank(operator);
        gateway.mintAttested(requestId, alice);

        assertTrue(evil.reentered());
        assertFalse(evil.reentrantSucceeded());
        // `nonReentrant` is the first modifier: the re-entry dies at the guard, not at the role check.
        assertEq(_selectorOf(evil.reentrantReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        // The legitimate mint happened exactly once.
        assertEq(evil.balanceOf(alice), 100 ether);
    }

    /// @dev Takes a hostile asset to a PENDING redemption request with custodied tokens.
    function _pendingEvilRedemption(MaliciousHookToken evil, uint256 backed, uint256 redeemed)
        internal
        returns (uint256 redemptionId)
    {
        uint256 backingId = _armedBackingRequest(evil, backed);
        vm.prank(operator);
        gateway.mintAttested(backingId, alice);

        vm.prank(alice);
        evil.approve(address(gateway), redeemed);
        vm.prank(alice);
        redemptionId = gateway.redemptionRequest(address(evil), redeemed);
    }

    function test_RedemptionAttest_ReentrancyDuringBurnSeesRequestAlreadySettled() public {
        MaliciousHookToken evil = new MaliciousHookToken();
        uint256 redemptionId = _pendingEvilRedemption(evil, 100 ether, 40 ether);

        evil.armOnBurn(address(gateway), abi.encodeWithSignature("redemptionRequests(uint256)", redemptionId));

        vm.prank(custodian);
        gateway.redemptionAttest(redemptionId, keccak256("released"));

        assertTrue(evil.reentered());
        assertTrue(evil.reentrantSucceeded());

        (,,,, uint8 status) =
            abi.decode(evil.reentrantReturnData(), (address, address, uint256, bytes32, uint8));
        // Final status and the `totalAttested` decrease were already committed before the burn.
        assertEq(status, uint8(BackingGateway.RequestStatus.SETTLED));
        assertEq(gateway.totalAttested(address(evil)), 60 ether);
        assertEq(evil.balanceOf(address(gateway)), 0);
    }

    function test_RedemptionAttest_ReentrantCancelRevertsViaGuard() public {
        MaliciousHookToken evil = new MaliciousHookToken();
        uint256 redemptionId = _pendingEvilRedemption(evil, 100 ether, 40 ether);

        // Deliberately without granting CUSTODIAN_ROLE to the hostile token: since `nonReentrant`
        // is the first modifier, the expected error is the guard's, not the access-control one.

        evil.armOnBurn(
            address(gateway), abi.encodeWithSignature("cancelRedemptionRequest(uint256)", redemptionId)
        );

        uint256 aliceBalanceBefore = evil.balanceOf(alice);

        vm.prank(custodian);
        gateway.redemptionAttest(redemptionId, keccak256("released"));

        assertTrue(evil.reentered());
        assertFalse(evil.reentrantSucceeded());
        assertEq(_selectorOf(evil.reentrantReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertTrue(
            _selectorOf(evil.reentrantReturnData()) != IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        // The re-entrant cancellation returned nothing: the tokens were burned.
        assertEq(evil.balanceOf(alice), aliceBalanceBefore);
        assertEq(evil.balanceOf(address(gateway)), 0);
        assertEq(gateway.totalAttested(address(evil)), 60 ether);
    }

    function test_CancelRedemptionRequest_ReentrancyDuringTransferSeesRequestAlreadyCancelled() public {
        MaliciousHookToken evil = new MaliciousHookToken();
        uint256 redemptionId = _pendingEvilRedemption(evil, 100 ether, 40 ether);

        // While the tokens are being returned, the hook reads its own request back from the gateway.
        evil.armOnTransfer(address(gateway), abi.encodeWithSignature("redemptionRequests(uint256)", redemptionId));

        vm.prank(custodian);
        gateway.cancelRedemptionRequest(redemptionId);

        assertTrue(evil.reentered());
        assertTrue(evil.reentrantSucceeded());

        (,,,, uint8 status) =
            abi.decode(evil.reentrantReturnData(), (address, address, uint256, bytes32, uint8));
        // The cancellation was already committed when the external return happened.
        assertEq(status, uint8(BackingGateway.RequestStatus.CANCELLED));
        // The return itself completed normally.
        assertEq(evil.balanceOf(alice), 100 ether);
        assertEq(evil.balanceOf(address(gateway)), 0);
        assertEq(gateway.totalAttested(address(evil)), 100 ether);
    }

    function test_CancelRedemptionRequest_ReentrantRedemptionAttestRevertsViaGuard() public {
        MaliciousHookToken evil = new MaliciousHookToken();
        uint256 redemptionId = _pendingEvilRedemption(evil, 100 ether, 40 ether);

        // Deliberately without granting CUSTODIAN_ROLE to the hostile token: since `nonReentrant`
        // is the first modifier, the expected error is the guard's, not the access-control one.
        evil.armOnTransfer(
            address(gateway),
            abi.encodeWithSignature("redemptionAttest(uint256,bytes32)", redemptionId, keccak256("forjado"))
        );

        vm.prank(custodian);
        gateway.cancelRedemptionRequest(redemptionId);

        assertTrue(evil.reentered());
        assertFalse(evil.reentrantSucceeded());
        assertEq(_selectorOf(evil.reentrantReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertTrue(
            _selectorOf(evil.reentrantReturnData()) != IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        // The re-entrant attestation burned nothing and did not touch the backing: only the cancellation counted.
        assertEq(evil.balanceOf(alice), 100 ether);
        assertEq(evil.balanceOf(address(gateway)), 0);
        assertEq(gateway.totalAttested(address(evil)), 100 ether);
    }

    /// @notice Direct checks-effects-interactions regression: `RedemptionRequestCancelled`
    /// must be emitted before the `Transfer` of the returned tokens. The status was already
    /// written before the transfer even in the old order; it is the log order this change locks in.
    function test_CancelRedemptionRequest_EmitsCancelledBeforeExternalTransfer() public {
        _mintTokensTo(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(gateway), 40 ether);
        vm.prank(alice);
        uint256 requestId = gateway.redemptionRequest(address(token), 40 ether);

        vm.recordLogs();
        vm.prank(custodian);
        gateway.cancelRedemptionRequest(requestId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 cancelledTopic = keccak256("RedemptionRequestCancelled(uint256,address,uint256)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");

        uint256 cancelledIndex = type(uint256).max;
        uint256 transferIndex = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == cancelledTopic && cancelledIndex == type(uint256).max) cancelledIndex = i;
            if (logs[i].topics[0] == transferTopic && transferIndex == type(uint256).max) transferIndex = i;
        }

        assertTrue(cancelledIndex != type(uint256).max, "RedemptionRequestCancelled not emitted");
        assertTrue(transferIndex != type(uint256).max, "Transfer not emitted");
        assertLt(cancelledIndex, transferIndex);
        assertEq(cancelledIndex, 0);
    }

    /// @notice Checks-effects-interactions regression in `mintAttested`: `BackingMinted`
    /// must be emitted before the AssetToken's mint `Transfer`.
    function test_MintAttested_EmitsBackingMintedBeforeExternalTransfer() public {
        uint256 requestId = _requestBacking(100 ether);
        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof"), 100 ether);

        vm.recordLogs();
        vm.prank(operator);
        gateway.mintAttested(requestId, alice);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 mintedTopic = keccak256("BackingMinted(uint256,address,address,uint256)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");

        uint256 mintedIndex = type(uint256).max;
        uint256 transferIndex = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == mintedTopic && mintedIndex == type(uint256).max) mintedIndex = i;
            if (logs[i].topics[0] == transferTopic && transferIndex == type(uint256).max) transferIndex = i;
        }

        assertTrue(mintedIndex != type(uint256).max, "BackingMinted not emitted");
        assertTrue(transferIndex != type(uint256).max, "Transfer not emitted");
        assertLt(mintedIndex, transferIndex);
        assertEq(mintedIndex, 0);
    }

    /// @notice Checks-effects-interactions regression in `redemptionAttest`:
    /// `RedemptionAttested` must be emitted before the burn `Transfer`.
    function test_RedemptionAttest_EmitsRedemptionAttestedBeforeExternalTransfer() public {
        _mintTokensTo(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(gateway), 40 ether);
        vm.prank(alice);
        uint256 requestId = gateway.redemptionRequest(address(token), 40 ether);

        vm.recordLogs();
        vm.prank(custodian);
        gateway.redemptionAttest(requestId, keccak256("released"));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 attestedTopic = keccak256("RedemptionAttested(uint256,address,bytes32,uint256)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");

        uint256 attestedIndex = type(uint256).max;
        uint256 transferIndex = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == attestedTopic && attestedIndex == type(uint256).max) attestedIndex = i;
            if (logs[i].topics[0] == transferTopic && transferIndex == type(uint256).max) transferIndex = i;
        }

        assertTrue(attestedIndex != type(uint256).max, "RedemptionAttested not emitted");
        assertTrue(transferIndex != type(uint256).max, "Transfer not emitted");
        assertLt(attestedIndex, transferIndex);
        assertEq(attestedIndex, 0);
    }
}

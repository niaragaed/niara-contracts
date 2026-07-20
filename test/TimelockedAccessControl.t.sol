// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockHarness} from "./mocks/TimelockHarness.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TimelockedAccessControlTest is Test {
    TimelockHarness public harness;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");

    uint256 public constant TIMELOCK_DELAY = 2 days;
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);

    function setUp() public {
        harness = new TimelockHarness(admin, TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForDelayBelowMin() public {
        uint256 tooLow = harness.MIN_TIMELOCK_DELAY() - 1;
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.InvalidTimelockDelay.selector, tooLow));
        new TimelockHarness(admin, tooLow);
    }

    function test_Constructor_RevertsForDelayAboveMax() public {
        uint256 tooHigh = harness.MAX_TIMELOCK_DELAY() + 1;
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.InvalidTimelockDelay.selector, tooHigh));
        new TimelockHarness(admin, tooHigh);
    }

    function test_SetTimelockDelay_RevertsForOutOfBoundsProposal() public {
        uint256 tooHigh = harness.MAX_TIMELOCK_DELAY() + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.InvalidTimelockDelay.selector, tooHigh));
        harness.proposeSetTimelockDelay(tooHigh);
    }

    function test_SetTimelockDelay_SucceedsAfterDelay() public {
        uint256 newDelay = 5 days;
        vm.prank(admin);
        harness.proposeSetTimelockDelay(newDelay);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        harness.executeSetTimelockDelay(newDelay);

        assertEq(harness.timelockDelay(), newDelay);
    }

    function test_ProposeAction_RevertsIfAlreadyPending() public {
        uint256 newDelay = 5 days;
        vm.prank(admin);
        harness.proposeSetTimelockDelay(newDelay);

        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", newDelay));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionAlreadyPending.selector, actionId));
        harness.proposeSetTimelockDelay(newDelay);
    }

    function test_ExecuteAction_RevertsIfNeverProposed() public {
        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", uint256(5 days)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionNotPending.selector, actionId));
        harness.executeSetTimelockDelay(5 days);
    }

    function test_ExecuteAction_RevertsBeforeDelayElapses() public {
        uint256 newDelay = 5 days;
        vm.prank(admin);
        harness.proposeSetTimelockDelay(newDelay);

        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", newDelay));
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;

        vm.warp(executeAfter - 1);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockedAccessControl.TimelockNotElapsed.selector, actionId, executeAfter)
        );
        harness.executeSetTimelockDelay(newDelay);
    }

    function test_CancelAction_OnlyAdmin() public {
        vm.prank(admin);
        harness.proposeSetTimelockDelay(5 days);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        harness.cancelAction(keccak256(abi.encode("SET_TIMELOCK_DELAY", uint256(5 days))));
    }

    function test_CancelAction_AllowsReproposing() public {
        uint256 newDelay = 5 days;
        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", newDelay));

        vm.prank(admin);
        harness.proposeSetTimelockDelay(newDelay);

        vm.prank(admin);
        harness.cancelAction(actionId);

        // Depois de cancelada, a mesma proposta pode ser refeita sem reverter.
        vm.prank(admin);
        harness.proposeSetTimelockDelay(newDelay);
    }

    function test_CancelAction_RevertsIfNotPending() public {
        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", uint256(5 days)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionNotPending.selector, actionId));
        harness.cancelAction(actionId);
    }

    function test_GrantRole_DirectCallAlwaysReverts() public {
        vm.prank(admin);
        vm.expectRevert(TimelockedAccessControl.RoleChangeRequiresTimelock.selector);
        harness.grantRole(DEFAULT_ADMIN_ROLE, alice);
    }

    function test_RevokeRole_DirectCallAlwaysReverts() public {
        vm.prank(admin);
        vm.expectRevert(TimelockedAccessControl.RoleChangeRequiresTimelock.selector);
        harness.revokeRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function test_RenounceRole_DoesNotRequireTimelock() public {
        // renounceRole segue liberado sem timelock: abrir mão do próprio papel é seguro e
        // pode precisar ser imediato numa emergência.
        vm.prank(admin);
        harness.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        assertFalse(harness.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }
}

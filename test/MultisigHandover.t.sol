// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DeployNiara} from "../script/Deploy.s.sol";
import {NiaraScriptBase} from "../script/NiaraScriptBase.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {MockSafe} from "./mocks/MockSafe.sol";

/// @notice Rehearses the mandatory pre-mainnet migration of the EVM roles to a multisig
/// (spec §9.6): `DEFAULT_ADMIN_ROLE` on the four v1 contracts that have roles,
/// `PAUSER_ROLE` on the ListingRegistry and `TREASURY_ROLE` on the CashbackDistributor and
/// P2PEscrow, moved from the deployer key to a Safe, on a deployment made by
/// `script/Deploy.s.sol`.
///
/// EVM has no on-chain acceptance step (Solana's `accept_admin`): a timelocked grant makes
/// the Safe a role holder without it signing anything. The procedure tested here supplies
/// the acceptance instead: the deployer only GRANTS, and the old key is removed by the
/// SAFE ITSELF (`proposeRevokeRole` / `executeRevokeRole` signed by the Safe). So the
/// deployer can never lose its roles to an address that cannot sign: if the Safe address
/// is wrong, nothing the deployer holds is ever revoked.
contract MultisigHandoverTest is Test {
    DeployNiara internal script;
    NiaraScriptBase.Deployment internal d;
    MockSafe internal safe;

    address internal deployer = makeAddr("deployer");
    address internal listingAuthority = makeAddr("listingAuthority");
    address internal operator = makeAddr("operator");
    /// @dev Stands for the Safe's owners reaching their threshold.
    address internal safeOwners = makeAddr("safeOwners");

    uint256 internal constant DELAY = 1 hours;

    bytes32 internal adminRole;
    bytes32 internal pauserRole;
    bytes32 internal treasuryRole;
    bytes32 internal escrowTreasuryRole;

    /// @dev One role on one contract.
    struct Grant {
        TimelockedAccessControl target;
        bytes32 role;
    }

    function setUp() public {
        vm.chainId(11155111);
        script = new DeployNiara();
        DeployNiara.Config memory cfg = DeployNiara.Config({
            deployer: deployer,
            listingAuthority: listingAuthority,
            operator: operator,
            timelockDelay: DELAY,
            cashbackBps: 2_000
        });
        d = script.deployAndPropose(cfg);
        vm.warp(block.timestamp + DELAY);
        script.executeWiringOn(cfg, d);

        safe = new MockSafe(safeOwners);
        adminRole = d.registry.DEFAULT_ADMIN_ROLE();
        pauserRole = d.registry.PAUSER_ROLE();
        treasuryRole = d.distributor.TREASURY_ROLE();
        escrowTreasuryRole = d.escrow.TREASURY_ROLE();
    }

    /// @dev Every role the migration moves: admin on the four contracts, the shared pause,
    /// and the two treasury roles.
    function _grants() internal view returns (Grant[7] memory g) {
        g[0] = Grant(TimelockedAccessControl(address(d.registry)), adminRole);
        g[1] = Grant(TimelockedAccessControl(address(d.settlement)), adminRole);
        g[2] = Grant(TimelockedAccessControl(address(d.distributor)), adminRole);
        g[3] = Grant(TimelockedAccessControl(address(d.escrow)), adminRole);
        g[4] = Grant(TimelockedAccessControl(address(d.registry)), pauserRole);
        g[5] = Grant(TimelockedAccessControl(address(d.distributor)), treasuryRole);
        g[6] = Grant(TimelockedAccessControl(address(d.escrow)), escrowTreasuryRole);
    }

    /// @dev Step 1, signed by the deployer: propose granting every role to `newHolder`, wait,
    /// execute. The deployer keeps all its roles.
    function _deployerGrantsTo(address newHolder) internal {
        Grant[7] memory g = _grants();
        for (uint256 i = 0; i < g.length; i++) {
            vm.prank(deployer);
            g[i].target.proposeGrantRole(g[i].role, newHolder);
        }
        vm.warp(block.timestamp + DELAY);
        for (uint256 i = 0; i < g.length; i++) {
            vm.prank(deployer);
            g[i].target.executeGrantRole(g[i].role, newHolder);
        }
    }

    /// @dev Step 2, signed by the Safe: propose revoking every role from the deployer, wait,
    /// execute. Only a holder that can actually sign gets this far.
    function _safeRevokesDeployer() internal {
        Grant[7] memory g = _grants();
        for (uint256 i = 0; i < g.length; i++) {
            vm.prank(safeOwners);
            safe.exec(address(g[i].target), abi.encodeCall(TimelockedAccessControl.proposeRevokeRole, (g[i].role, deployer)));
        }
        vm.warp(block.timestamp + DELAY);
        for (uint256 i = 0; i < g.length; i++) {
            vm.prank(safeOwners);
            safe.exec(address(g[i].target), abi.encodeCall(TimelockedAccessControl.executeRevokeRole, (g[i].role, deployer)));
        }
    }

    // ── The full handover ──────────────────────────────────────────────────────────────

    function test_Handover_MovesEveryAdminPauseAndTreasuryRoleToTheSafe() public {
        _deployerGrantsTo(address(safe));
        _safeRevokesDeployer();

        Grant[7] memory g = _grants();
        for (uint256 i = 0; i < g.length; i++) {
            assertTrue(g[i].target.hasRole(g[i].role, address(safe)), "safe lacks a role");
            assertFalse(g[i].target.hasRole(g[i].role, deployer), "deployer kept a role");
        }
    }

    /// @notice After the handover the deployer key can do nothing an admin can: it cannot
    /// propose a role change, pause, or withdraw protocol fees.
    function test_Handover_TheOldKeyHasNoPowerLeft() public {
        _deployerGrantsTo(address(safe));
        _safeRevokesDeployer();
        // Resolved before the prank: reading the constant is itself an external call and would
        // consume both the prank and the expected revert (see test/AssetToken.t.sol).
        bytes32 operatorRole = d.settlement.SETTLEMENT_OPERATOR_ROLE();

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, adminRole)
        );
        d.settlement.proposeGrantRole(operatorRole, deployer);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, pauserRole)
        );
        d.registry.pause();

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, adminRole)
        );
        d.distributor.proposeSetCashbackBps(0);
    }

    /// @notice The Safe can use every role it received: pause and unpause the protocol,
    /// change the cashback rate and the fee through the timelock, and act as treasury.
    function test_Handover_TheSafeCanUseEveryRole() public {
        _deployerGrantsTo(address(safe));
        _safeRevokesDeployer();

        vm.startPrank(safeOwners);
        safe.exec(address(d.registry), abi.encodeWithSignature("pause()"));
        assertTrue(d.registry.paused());
        safe.exec(address(d.registry), abi.encodeWithSignature("unpause()"));
        assertFalse(d.registry.paused());

        safe.exec(address(d.distributor), abi.encodeCall(d.distributor.proposeSetCashbackBps, (1_500)));
        safe.exec(address(d.settlement), abi.encodeCall(d.settlement.proposeSetFeeBps, (30)));
        vm.warp(block.timestamp + DELAY);
        safe.exec(address(d.distributor), abi.encodeCall(d.distributor.executeSetCashbackBps, (1_500)));
        safe.exec(address(d.settlement), abi.encodeCall(d.settlement.executeSetFeeBps, (30)));
        vm.stopPrank();

        assertEq(d.distributor.cashbackBps(), 1_500);
        assertEq(d.settlement.feeBps(), 30);

        // Treasury on the escrow: sweep a stray transfer.
        d.mockUsdt.mint(address(d.escrow), 7e6);
        vm.prank(safeOwners);
        safe.exec(address(d.escrow), abi.encodeCall(d.escrow.sweepExcess, (address(d.mockUsdt), address(safe))));
        assertEq(d.mockUsdt.balanceOf(address(safe)), 7e6);
    }

    /// @notice A multisig admin replaces a leaked operational key without that key's
    /// cooperation: the operator and the listing authority are rotated through the timelock.
    function test_Handover_TheSafeRotatesTheOperatorAndTheListingAuthority() public {
        _deployerGrantsTo(address(safe));
        _safeRevokesDeployer();

        address newOperator = makeAddr("newOperator");
        address newAuthority = makeAddr("newAuthority");
        bytes32 operatorRole = d.settlement.SETTLEMENT_OPERATOR_ROLE();
        bytes32 authorityRole = d.registry.LISTING_AUTHORITY_ROLE();

        vm.startPrank(safeOwners);
        safe.exec(address(d.settlement), abi.encodeCall(TimelockedAccessControl.proposeGrantRole, (operatorRole, newOperator)));
        safe.exec(address(d.settlement), abi.encodeCall(TimelockedAccessControl.proposeRevokeRole, (operatorRole, operator)));
        safe.exec(address(d.registry), abi.encodeCall(TimelockedAccessControl.proposeGrantRole, (authorityRole, newAuthority)));
        safe.exec(address(d.registry), abi.encodeCall(TimelockedAccessControl.proposeRevokeRole, (authorityRole, listingAuthority)));
        vm.warp(block.timestamp + DELAY);
        safe.exec(address(d.settlement), abi.encodeCall(TimelockedAccessControl.executeGrantRole, (operatorRole, newOperator)));
        safe.exec(address(d.settlement), abi.encodeCall(TimelockedAccessControl.executeRevokeRole, (operatorRole, operator)));
        safe.exec(address(d.registry), abi.encodeCall(TimelockedAccessControl.executeGrantRole, (authorityRole, newAuthority)));
        safe.exec(address(d.registry), abi.encodeCall(TimelockedAccessControl.executeRevokeRole, (authorityRole, listingAuthority)));
        vm.stopPrank();

        assertTrue(d.settlement.hasRole(operatorRole, newOperator));
        assertFalse(d.settlement.hasRole(operatorRole, operator));
        assertTrue(d.registry.hasRole(authorityRole, newAuthority));
        assertFalse(d.registry.hasRole(authorityRole, listingAuthority));
    }

    // ── What makes the procedure safe ──────────────────────────────────────────────────

    /// @notice Granting never removes anything: until the Safe signs the revocations, the
    /// deployer and the Safe both hold every role.
    function test_Handover_TheGrantAloneRemovesNothing() public {
        _deployerGrantsTo(address(safe));

        Grant[7] memory g = _grants();
        for (uint256 i = 0; i < g.length; i++) {
            assertTrue(g[i].target.hasRole(g[i].role, address(safe)));
            assertTrue(g[i].target.hasRole(g[i].role, deployer));
        }
    }

    /// @notice The acceptance step EVM lacks on-chain: if the roles went to an address that
    /// cannot sign (a typo), nothing can ever revoke the deployer's roles through that
    /// address, so the deployer keeps control and removes the mistaken grant itself.
    function test_Handover_AWrongSafeAddressNeverLosesTheAdmin() public {
        address typo = makeAddr("typoNobodyControls");
        _deployerGrantsTo(typo);

        Grant[7] memory g = _grants();
        for (uint256 i = 0; i < g.length; i++) {
            assertTrue(g[i].target.hasRole(g[i].role, deployer), "deployer must keep every role");
        }

        // The deployer undoes the mistake through the timelock.
        for (uint256 i = 0; i < g.length; i++) {
            vm.prank(deployer);
            g[i].target.proposeRevokeRole(g[i].role, typo);
        }
        vm.warp(block.timestamp + DELAY);
        for (uint256 i = 0; i < g.length; i++) {
            vm.prank(deployer);
            g[i].target.executeRevokeRole(g[i].role, typo);
            assertFalse(g[i].target.hasRole(g[i].role, typo));
        }
    }

    /// @notice There is no shortcut: the Safe cannot be made admin before the timelock, and
    /// once admin it cannot remove the old key before the timelock either.
    function test_Handover_EveryStepWaitsForTheTimelock() public {
        vm.prank(deployer);
        d.registry.proposeGrantRole(adminRole, address(safe));
        vm.prank(deployer);
        vm.expectRevert();
        d.registry.executeGrantRole(adminRole, address(safe));
        assertFalse(d.registry.hasRole(adminRole, address(safe)));

        vm.warp(block.timestamp + DELAY);
        vm.prank(deployer);
        d.registry.executeGrantRole(adminRole, address(safe));

        vm.startPrank(safeOwners);
        safe.exec(address(d.registry), abi.encodeCall(TimelockedAccessControl.proposeRevokeRole, (adminRole, deployer)));
        vm.expectRevert();
        safe.exec(address(d.registry), abi.encodeCall(TimelockedAccessControl.executeRevokeRole, (adminRole, deployer)));
        vm.stopPrank();
        assertTrue(d.registry.hasRole(adminRole, deployer));
    }

    /// @notice While both hold the admin role, the old key can cancel a revocation the Safe
    /// proposed (`cancelAction`): the handover is only final once the Safe executes it.
    /// The rehearsal must therefore complete each revocation, not just propose it.
    function test_Handover_TheOldKeyCanCancelAPendingRevocationUntilItExecutes() public {
        _deployerGrantsTo(address(safe));

        vm.prank(safeOwners);
        safe.exec(address(d.registry), abi.encodeCall(TimelockedAccessControl.proposeRevokeRole, (adminRole, deployer)));
        bytes32 actionId = keccak256(abi.encode("REVOKE_ROLE", adminRole, deployer));
        vm.prank(deployer);
        d.registry.cancelAction(actionId);

        vm.warp(block.timestamp + DELAY);
        vm.prank(safeOwners);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionNotPending.selector, actionId));
        safe.exec(address(d.registry), abi.encodeCall(TimelockedAccessControl.executeRevokeRole, (adminRole, deployer)));
        assertTrue(d.registry.hasRole(adminRole, deployer));
    }

    function test_MockSafe_OnlyItsOwnersCanMakeItAct() public {
        vm.expectRevert(MockSafe.NotOwner.selector);
        safe.exec(address(d.registry), abi.encodeWithSignature("pause()"));
    }
}

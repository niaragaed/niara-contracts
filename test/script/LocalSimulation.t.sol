// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployNiara} from "../../script/Deploy.s.sol";
import {DemoNiaraFlows} from "../../script/Demo.s.sol";
import {LocalSimulation} from "../../script/LocalSimulation.s.sol";
import {NiaraScriptBase} from "../../script/NiaraScriptBase.sol";

/// @notice The rehearsal script only runs against a local Anvil, and the scripts' entry
/// points read their configuration from the environment as documented in `.env.example`.
contract LocalSimulationTest is Test {
    /// @notice With no Anvil behind it (here: no node at all) the rehearsal refuses to run,
    /// before simulating anything. A public node answers `anvil_nodeInfo` with "method not
    /// found", which lands in the same branch.
    function test_Run_RefusesWithoutALocalAnvil() public {
        vm.chainId(11155111);
        LocalSimulation simulation = new LocalSimulation();
        vm.expectRevert(LocalSimulation.NotALocalAnvil.selector);
        simulation.run();
    }

    function test_AnvilRoles_AreSixDistinctWallets() public {
        LocalSimulation simulation = new LocalSimulation();
        DemoNiaraFlows.Roles memory roles = simulation.anvilRoles();
        new DemoNiaraFlows().requireDistinctRoles(roles);
        assertEq(roles.deployer, 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    }

    /// @notice The environment path of both scripts, in ONE test: `vm.setEnv` changes the
    /// whole process, so no other test reads or writes these variables.
    function test_EnvironmentReaders_MatchTheDocumentedVariables() public {
        vm.chainId(84532);
        DeployNiara deploy = new DeployNiara();
        DemoNiaraFlows demo = new DemoNiaraFlows();
        DemoNiaraFlows.Roles memory expected = new LocalSimulation().anvilRoles();

        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(expected.deployer));
        vm.setEnv("LISTING_AUTHORITY_ADDRESS", vm.toString(expected.listingAuthority));
        vm.setEnv("OPERATOR_ADDRESS", vm.toString(expected.operator));
        vm.setEnv("DEMO_ISSUER_ADDRESS", vm.toString(expected.issuer));
        vm.setEnv("DEMO_INVESTOR_A_ADDRESS", vm.toString(expected.investorA));
        vm.setEnv("DEMO_INVESTOR_B_ADDRESS", vm.toString(expected.investorB));
        vm.setEnv("TIMELOCK_DELAY", "7200");
        vm.setEnv("CASHBACK_BPS", "1500");

        DeployNiara.Config memory cfg = deploy.readConfig();
        assertEq(cfg.deployer, expected.deployer);
        assertEq(cfg.listingAuthority, expected.listingAuthority);
        assertEq(cfg.operator, expected.operator);
        assertEq(cfg.timelockDelay, 7200);
        assertEq(cfg.cashbackBps, 1500);

        DemoNiaraFlows.Roles memory roles = demo.readRoles();
        assertEq(roles.deployer, expected.deployer);
        assertEq(roles.listingAuthority, expected.listingAuthority);
        assertEq(roles.operator, expected.operator);
        assertEq(roles.issuer, expected.issuer);
        assertEq(roles.investorA, expected.investorA);
        assertEq(roles.investorB, expected.investorB);

        // A cashback share above 100% of the fee is refused when the configuration is read.
        vm.setEnv("CASHBACK_BPS", "10001");
        vm.expectRevert(abi.encodeWithSelector(DeployNiara.CashbackBpsOutOfRange.selector, uint256(10_001)));
        deploy.readConfig();
        vm.setEnv("CASHBACK_BPS", "2000");

        // Deployed addresses are read from the variables of the CURRENT chain only.
        NiaraScriptBase.Deployment memory d = deploy.deployAndPropose(deploy.readConfig());
        vm.setEnv("DEPLOYED_SETTLEMENT_ADDRESS_84532", vm.toString(address(d.settlement)));
        vm.setEnv("DEPLOYED_ESCROW_ADDRESS_84532", vm.toString(address(d.escrow)));
        vm.setEnv("DEPLOYED_MOCK_BRL_ADDRESS_84532", vm.toString(address(d.mockBrl)));

        NiaraScriptBase.Deployment memory read = demo.readDeployment();
        assertEq(address(read.settlement), address(d.settlement));
        assertEq(address(read.escrow), address(d.escrow));
        assertEq(address(read.mockBrl), address(d.mockBrl));
        assertEq(address(read.mockUsdt), address(d.mockUsdt));
        assertEq(address(read.registry), address(d.registry));
        assertEq(address(read.distributor), address(d.distributor));
        assertEq(address(read.factory), address(d.factory));
    }
}

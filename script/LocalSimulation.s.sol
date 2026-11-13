// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DeployNiara} from "./Deploy.s.sol";
import {DemoNiaraFlows} from "./Demo.s.sol";
import {NiaraScriptBase} from "./NiaraScriptBase.sol";

/// @title LocalSimulation
/// @notice A rehearsal, never a deployment: chains deploy phase 1, the timelock wait, deploy
/// phase 2 and the three demo flows in ONE dry run against a local Anvil node.
///
///   anvil --chain-id 11155111        (or --chain-id 84532 for the Base Sepolia path)
///   forge script script/LocalSimulation.s.sol --rpc-url http://127.0.0.1:8545 --skip-simulation
///
/// It exists because a dry run keeps no state: phase 2 and the demo need the contracts of
/// phase 1, and without broadcasting anything the only way to run them is in the same
/// execution. The one-hour timelock is crossed with a simulated clock jump (`vm.warp`),
/// which is exactly why this script can never be broadcast: on a real chain phase 2 would
/// revert, the wait cannot be skipped. `--skip-simulation` is needed for the same reason
/// (forge's second pass replays each transaction on the node, whose clock did not move).
///
/// @dev Refuses to run unless the node answers `anvil_nodeInfo`, i.e. is an Anvil: pointing
/// it at Sepolia or Base Sepolia reverts `NotALocalAnvil` before anything is simulated. The
/// chain guard of the real scripts still applies, so Anvil must be started with one of the
/// two supported chain ids. The six role wallets are Anvil's well-known development
/// accounts (public keys, worthless everywhere), named here by address only.
contract LocalSimulation is Script {
    error NotALocalAnvil();

    /// @notice Runs the whole rehearsal and prints what happened.
    function run() external {
        _requireAnvil();

        DemoNiaraFlows.Roles memory roles = anvilRoles();
        DeployNiara deploy = new DeployNiara();
        DemoNiaraFlows demo = new DemoNiaraFlows();

        DeployNiara.Config memory cfg = DeployNiara.Config({
            deployer: roles.deployer,
            listingAuthority: roles.listingAuthority,
            operator: roles.operator,
            timelockDelay: deploy.DEFAULT_TIMELOCK_DELAY(),
            cashbackBps: deploy.DEFAULT_CASHBACK_BPS()
        });

        console2.log("== LOCAL SIMULATION on Anvil, chain id", block.chainid, "==");
        console2.log("== Deploy phase 1: deploy and propose ==");
        NiaraScriptBase.Deployment memory d = deploy.deployAndPropose(cfg);
        uint256 executeAfter = deploy.wiringExecutableAt(cfg, d);
        console2.log("Wiring executable from timestamp:", executeAfter);

        // The real wait is one hour of chain time. Only a simulation can jump it.
        vm.warp(executeAfter);

        console2.log("== Deploy phase 2: execute the wiring, list the currencies, verify ==");
        deploy.executeWiringOn(cfg, d);
        console2.log("Fee (bps):", uint256(d.settlement.feeBps()));
        console2.log("Cashback share of the fee (bps):", uint256(d.distributor.cashbackBps()));

        console2.log("== Demo ==");
        demo.fundGas(roles, demo.DEFAULT_GAS_FUNDING());
        demo.runAll(roles, d);
    }

    /// @notice Anvil's first six development accounts, one per role.
    /// @return roles The roles.
    function anvilRoles() public pure returns (DemoNiaraFlows.Roles memory roles) {
        roles.deployer = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        roles.listingAuthority = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        roles.operator = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
        roles.issuer = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
        roles.investorA = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
        roles.investorB = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    }

    /// @dev `anvil_nodeInfo` only exists on Anvil; any other node returns an error and the
    /// cheatcode reverts.
    function _requireAnvil() internal {
        try vm.rpc("anvil_nodeInfo", "[]") returns (bytes memory) {}
        catch {
            revert NotALocalAnvil();
        }
    }
}

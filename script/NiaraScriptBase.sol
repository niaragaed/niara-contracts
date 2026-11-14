// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {P2PEscrow} from "../src/P2PEscrow.sol";
import {TestnetMockToken} from "./tokens/TestnetMockToken.sol";

/// @title NiaraScriptBase
/// @notice What `Deploy.s.sol` and `Demo.s.sol` share: the chain guard, the deployed
/// addresses and how they are read back.
///
/// Chain guard: the scripts run only on Ethereum Sepolia (11155111) and Base Sepolia
/// (84532). Any other chain id, mainnets included, reverts `UnsupportedChain` before
/// anything is read or sent. A local simulation runs against an Anvil started with one of
/// those two chain ids (`anvil --chain-id 11155111`).
///
/// No secrets: the scripts never read a private key or a mnemonic. Every signer is named by
/// its ADDRESS (environment variables, not secret) and signs through a Foundry keystore
/// passed on the command line (`--account <name>`), see the README.
abstract contract NiaraScriptBase is Script {
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @notice Everything phase 1 deploys.
    struct Deployment {
        TestnetMockToken mockUsdt;
        TestnetMockToken mockBrl;
        ListingRegistry registry;
        AssetTokenFactory factory;
        CashbackDistributor distributor;
        NiaraSettlement settlement;
        P2PEscrow escrow;
    }

    error UnsupportedChain(uint256 chainId);
    error NotAContract(string what, address account);
    error DeploymentMismatch(string what);

    /// @dev Reverts unless the current chain is Sepolia or Base Sepolia.
    function _requireSupportedChain() internal view {
        if (block.chainid != SEPOLIA_CHAIN_ID && block.chainid != BASE_SEPOLIA_CHAIN_ID) {
            revert UnsupportedChain(block.chainid);
        }
    }

    /// @notice Human name of the current chain, for the logs.
    /// @return The chain name.
    function chainName() public view returns (string memory) {
        return block.chainid == SEPOLIA_CHAIN_ID ? "Ethereum Sepolia" : "Base Sepolia";
    }

    /// @notice Name of the environment variable holding a deployed address ON THE CURRENT
    /// CHAIN: the base name plus `_<chainid>`, so the two deployments can sit in one `.env`
    /// and a script can never pick up the other chain's addresses.
    /// @param baseName E.g. `DEPLOYED_SETTLEMENT_ADDRESS`.
    /// @return E.g. `DEPLOYED_SETTLEMENT_ADDRESS_11155111`.
    function deployedVar(string memory baseName) public view returns (string memory) {
        return string.concat(baseName, "_", vm.toString(block.chainid));
    }

    /// @notice Reads the phase 1 addresses of the current chain from the environment
    /// (`DEPLOYED_SETTLEMENT_ADDRESS_<chainid>`, `DEPLOYED_ESCROW_ADDRESS_<chainid>`,
    /// `DEPLOYED_MOCK_BRL_ADDRESS_<chainid>`) and derives the rest on-chain.
    /// @return d The deployment.
    function readDeployment() public view returns (Deployment memory d) {
        return resolveDeployment(
            vm.envAddress(deployedVar("DEPLOYED_SETTLEMENT_ADDRESS")),
            vm.envAddress(deployedVar("DEPLOYED_ESCROW_ADDRESS")),
            vm.envAddress(deployedVar("DEPLOYED_MOCK_BRL_ADDRESS"))
        );
    }

    /// @notice Builds the deployment from the three addresses that cannot be derived, reading
    /// the others from the contracts themselves (so they cannot be mistyped), and checks that
    /// the pieces belong together.
    /// @param settlement NiaraSettlement.
    /// @param escrow P2PEscrow.
    /// @param mockBrl The mock BRL test token.
    /// @return d The deployment.
    function resolveDeployment(address settlement, address escrow, address mockBrl)
        public
        view
        returns (Deployment memory d)
    {
        if (settlement.code.length == 0) revert NotAContract("NiaraSettlement", settlement);
        if (escrow.code.length == 0) revert NotAContract("P2PEscrow", escrow);
        if (mockBrl.code.length == 0) revert NotAContract("mock BRL", mockBrl);

        d.settlement = NiaraSettlement(settlement);
        d.escrow = P2PEscrow(escrow);
        d.mockBrl = TestnetMockToken(mockBrl);
        d.registry = ListingRegistry(address(d.settlement.listingRegistry()));
        d.factory = d.registry.factory();
        d.distributor = CashbackDistributor(address(d.settlement.cashbackDistributor()));
        d.mockUsdt = TestnetMockToken(d.settlement.feeToken());

        if (address(d.escrow.settlement()) != settlement) revert DeploymentMismatch("escrow.settlement");
        if (address(d.escrow.listingRegistry()) != address(d.registry)) revert DeploymentMismatch("escrow.registry");
        if (address(d.distributor.listingRegistry()) != address(d.registry)) {
            revert DeploymentMismatch("distributor.registry");
        }
        if (address(d.mockBrl) == address(d.mockUsdt)) revert DeploymentMismatch("mock BRL is the fee token");
        // The registry's settlement link is zero until deploy phase 2 executes it; after
        // that it must be this NiaraSettlement.
        address linked = address(d.registry.settlement());
        if (linked != address(0) && linked != settlement) revert DeploymentMismatch("registry.settlement");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
/// Chain guard: the scripts run only on five EVM testnets, the same ones Niara Register is
/// deployed on: Ethereum Sepolia (11155111), Base Sepolia (84532), Robinhood Chain testnet
/// (46630), HyperEVM testnet (998) and Tempo testnet "Moderato" (42431). Any other chain id,
/// every mainnet included, reverts `UnsupportedChain` before anything is read or sent. A
/// local simulation runs against an Anvil started with one of those chain ids
/// (`anvil --chain-id 11155111`).
///
/// Tempo has no native gas token: fees are paid in a USD stablecoin (pathUSD by default) and
/// `eth_getBalance` returns a fixed placeholder, so nothing here ever moves native value on
/// it (`hasNativeGasToken`).
///
/// No secrets: the scripts never read a private key or a mnemonic. Every signer is named by
/// its ADDRESS (environment variables, not secret) and signs through a Foundry keystore
/// passed on the command line (`--account <name>`), see the README.
abstract contract NiaraScriptBase is Script {
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;
    uint256 public constant HYPEREVM_TESTNET_CHAIN_ID = 998;
    uint256 public constant TEMPO_TESTNET_CHAIN_ID = 42431;

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

    /// @notice Tempo's default fee token (pathUSD, 6 decimals). Tempo prices gas in
    /// attodollars (1e-18 USD), so a fee in pathUSD base units is gas * price / 1e12.
    address public constant TEMPO_PATH_USD = 0x20C0000000000000000000000000000000000000;
    uint256 public constant TEMPO_ATTODOLLARS_PER_FEE_UNIT = 1e12;

    /// @notice What one wallet must be able to pay in a phase that broadcasts.
    struct GasNeed {
        /// @dev Role name, for the report.
        string role;
        address wallet;
        /// @dev Gas the wallet's transactions use, in forge's own (local, Ethereum-priced)
        /// estimate: forge sets each gas limit to its estimate times the chain's
        /// `--gas-estimate-multiplier`, and a node only accepts a transaction whose sender
        /// holds gas limit * max fee per gas (+ value).
        uint256 gas;
        /// @dev Native value the wallet sends (the demo's gas top-ups).
        uint256 value;
        /// @dev Native value the wallet receives before it signs (a top-up from the deployer).
        uint256 incoming;
    }

    error UnsupportedChain(uint256 chainId);
    error NotAContract(string what, address account);
    error DeploymentMismatch(string what);
    error InsufficientGasFunds(string phase, string shortfalls);

    /// @notice Whether the scripts may run on `chainId`: true for the five supported testnets
    /// only.
    /// @param chainId The chain id to check.
    /// @return True for Sepolia, Base Sepolia, Robinhood Chain testnet, HyperEVM testnet and
    /// Tempo testnet.
    function isSupportedChain(uint256 chainId) public pure returns (bool) {
        return chainId == SEPOLIA_CHAIN_ID || chainId == BASE_SEPOLIA_CHAIN_ID
            || chainId == ROBINHOOD_TESTNET_CHAIN_ID || chainId == HYPEREVM_TESTNET_CHAIN_ID
            || chainId == TEMPO_TESTNET_CHAIN_ID;
    }

    /// @notice Whether `chainId` has a native gas token that can be sent with a plain value
    /// transfer. False only on Tempo, where gas is paid in a USD stablecoin (pathUSD).
    /// @param chainId The chain id to check.
    /// @return False on Tempo testnet, true everywhere else.
    function hasNativeGasToken(uint256 chainId) public pure returns (bool) {
        return chainId != TEMPO_TESTNET_CHAIN_ID;
    }

    /// @dev Reverts unless the current chain is one of the five supported testnets.
    function _requireSupportedChain() internal view {
        if (!isSupportedChain(block.chainid)) revert UnsupportedChain(block.chainid);
    }

    /// @notice Human name of the current chain, for the logs. Reverts `UnsupportedChain` on
    /// any chain the scripts do not support.
    /// @return The chain name.
    function chainName() public view returns (string memory) {
        if (block.chainid == SEPOLIA_CHAIN_ID) return "Ethereum Sepolia";
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return "Base Sepolia";
        if (block.chainid == ROBINHOOD_TESTNET_CHAIN_ID) return "Robinhood Chain testnet";
        if (block.chainid == HYPEREVM_TESTNET_CHAIN_ID) return "HyperEVM testnet";
        if (block.chainid == TEMPO_TESTNET_CHAIN_ID) return "Tempo testnet";
        revert UnsupportedChain(block.chainid);
    }

    /// @notice Name of the environment variable holding a deployed address ON THE CURRENT
    /// CHAIN: the base name plus `_<chainid>`, so the deployments can sit in one `.env` and a
    /// script can never pick up another chain's addresses.
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

    // ── Gas preflight ──────────────────────────────────────────────────────────────────

    /// @notice The `--gas-estimate-multiplier` a broadcast on `chainId` uses by default (the
    /// figures in the README's "Network quirks"): 200 on Robinhood (its L1 data charge), 700
    /// on Tempo (its repriced storage and contract creation), 800 on Sepolia (repriced
    /// contract creation), forge's own 130 elsewhere.
    /// @param chainId The chain id.
    /// @return The multiplier, in percent.
    function defaultGasEstimateMultiplier(uint256 chainId) public pure returns (uint256) {
        if (chainId == ROBINHOOD_TESTNET_CHAIN_ID) return 200;
        if (chainId == TEMPO_TESTNET_CHAIN_ID) return 700;
        if (chainId == SEPOLIA_CHAIN_ID) return 800;
        return 130;
    }

    /// @notice The gas multiplier the preflight assumes on the CURRENT chain:
    /// `GAS_ESTIMATE_MULTIPLIER_<chainid>` if set, else `defaultGasEstimateMultiplier`. It must
    /// equal the `--gas-estimate-multiplier` passed to the broadcast (forge's default is 130).
    /// @return The multiplier, in percent.
    function gasEstimateMultiplier() public view returns (uint256) {
        return vm.envOr(deployedVar("GAS_ESTIMATE_MULTIPLIER"), defaultGasEstimateMultiplier(block.chainid));
    }

    /// @notice Max fee per gas forge signs with on the current chain: base fee + gas price,
    /// i.e. 2 * base fee + priority fee (`tx.gasprice` is base fee + priority fee inside a
    /// forge script). In attodollars on Tempo.
    /// @return The max fee per gas.
    function maxFeePerGas() public view returns (uint256) {
        return block.basefee + tx.gasprice;
    }

    /// @notice The token gas is paid in on the current chain: the native token
    /// (`address(0)`), or on Tempo `TEMPO_FEE_TOKEN` if set, else pathUSD.
    /// @return The fee token, `address(0)` for the native token.
    function gasFeeToken() public view returns (address) {
        if (hasNativeGasToken(block.chainid)) return address(0);
        return vm.envOr("TEMPO_FEE_TOKEN", TEMPO_PATH_USD);
    }

    /// @notice What `wallet` holds to pay gas with: its native balance, or its fee-token
    /// balance on Tempo (where `eth_getBalance` is a placeholder).
    /// @param wallet The wallet.
    /// @return The balance, in wei or fee-token base units.
    function gasFeeBalanceOf(address wallet) public view returns (uint256) {
        address token = gasFeeToken();
        if (token == address(0)) return wallet.balance;
        return IERC20(token).balanceOf(wallet);
    }

    /// @notice Most that `gas` (forge's estimate) can cost on the current chain: gas *
    /// multiplier / 100 * `feePerGas`, converted to pathUSD base units (rounded up) on Tempo.
    /// @param gas Forge's gas estimate.
    /// @param feePerGas Max fee per gas.
    /// @return The cost, in wei or fee-token base units.
    function gasCost(uint256 gas, uint256 feePerGas) public view returns (uint256) {
        uint256 cost = gas * gasEstimateMultiplier() / 100 * feePerGas;
        if (hasNativeGasToken(block.chainid)) return cost;
        return (cost + TEMPO_ATTODOLLARS_PER_FEE_UNIT - 1) / TEMPO_ATTODOLLARS_PER_FEE_UNIT;
    }

    /// @notice How much one wallet is missing for its part of a phase.
    /// @param need The wallet's need.
    /// @param feePerGas Max fee per gas.
    /// @return required Gas cost plus native value sent.
    /// @return available Balance plus native value received first (native chains only).
    /// @return missing `required - available`, or zero.
    function gasShortfall(GasNeed memory need, uint256 feePerGas)
        public
        view
        returns (uint256 required, uint256 available, uint256 missing)
    {
        required = gasCost(need.gas, feePerGas) + need.value;
        available = gasFeeBalanceOf(need.wallet) + need.incoming;
        if (available < required) missing = required - available;
    }

    /// @notice Checks every wallet that signs in `phase` against what its transactions can
    /// cost, logs one line per wallet and, if any is short, either reverts
    /// `InsufficientGasFunds` listing every short wallet with the amount missing (`enforce`) or
    /// only warns.
    /// @param phase Name of the phase, for the report.
    /// @param needs One entry per signing wallet.
    /// @param feePerGas Max fee per gas.
    /// @param enforce Revert when a wallet is short.
    /// @return shortWallets How many wallets are short.
    function checkGasFunds(string memory phase, GasNeed[] memory needs, uint256 feePerGas, bool enforce)
        public
        view
        returns (uint256 shortWallets)
    {
        string memory unit = gasFeeToken() == address(0) ? "wei" : "fee-token base units";
        string memory report;
        console2.log("== Gas preflight:", phase, "==");
        console2.log("Max fee per gas:", feePerGas, "| gas estimate multiplier (%):", gasEstimateMultiplier());
        for (uint256 i = 0; i < needs.length; i++) {
            (uint256 required, uint256 available, uint256 missing) = gasShortfall(needs[i], feePerGas);
            string memory line = string.concat(
                needs[i].role,
                " ",
                vm.toString(needs[i].wallet),
                ": needs ",
                vm.toString(required),
                ", has ",
                vm.toString(available),
                " ",
                unit
            );
            if (missing == 0) {
                console2.log(string.concat("  ok    ", line));
                continue;
            }
            shortWallets++;
            string memory shortLine = string.concat(line, ", missing ", vm.toString(missing));
            console2.log(string.concat("  SHORT ", shortLine));
            report = bytes(report).length == 0 ? shortLine : string.concat(report, "; ", shortLine);
        }
        if (shortWallets > 0 && enforce) revert InsufficientGasFunds(phase, report);
    }

    /// @dev The preflight every broadcasting entry point runs before its first transaction:
    /// refuses to broadcast (or resume) when a signing wallet is short; a dry run only
    /// reports it, so the figures can still be inspected.
    function _preflight(string memory phase, GasNeed[] memory needs) internal view {
        bool broadcasting = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        checkGasFunds(phase, needs, maxFeePerGas(), broadcasting);
    }
}

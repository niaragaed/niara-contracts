// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {NiaraScriptBase} from "./NiaraScriptBase.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {P2PEscrow} from "../src/P2PEscrow.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {TestnetMockToken} from "./tokens/TestnetMockToken.sol";

/// @title DeployNiara
/// @notice TWO-PHASE deployment of the v1 exchange (native issuance, order book and P2P
/// escrow) to Ethereum Sepolia (11155111) or Base Sepolia (84532), and to nothing else: any
/// other chain id reverts `UnsupportedChain`.
///
/// The two phases exist because of the protocol's real timelock
/// (`TimelockedAccessControl.MIN_TIMELOCK_DELAY` = 1 hour). Roles and the cashback rate
/// change only through propose -> wait -> execute, and there is no shortcut, not even on a
/// testnet (see CLAUDE.md).
///
/// PHASE 1, `run()`: deploys the two mock test tokens, the ListingRegistry (which creates
/// the AssetTokenFactory), the CashbackDistributor, NiaraSettlement and P2PEscrow, and
/// PROPOSES the wiring:
///   - SETTLEMENT_ROLE on the distributor  -> NiaraSettlement
///   - ESCROW_ROLE on the distributor      -> P2PEscrow
///   - SETTLEMENT_OPERATOR_ROLE            -> the settlement operator
///   - cashback rate                       -> `CASHBACK_BPS` (2000 bps = 20% of the fee)
/// Nothing can trade yet: without those roles `settle` and `acceptDeal` revert.
///
/// PHASE 2, `executeWiring()`: once the timelock has really elapsed on-chain, EXECUTES those
/// proposals, lists the two mock currencies (signed by the listing authority) and verifies
/// the result. Safe to run again if it stopped halfway: steps already done are skipped.
///
/// `verify()`: read-only check of a finished deployment.
///
/// Parameters: the fee is 50 bps, the contract's default and its hard cap (`MAX_FEE_BPS`);
/// the script only checks it. The cashback share is `CASHBACK_BPS` (default 2000). The
/// deployer is the admin of every contract: on a testnet that is one key, and it must be
/// stated as such; in production the admin is a multisig, which proposes and executes
/// through its own interface rather than through this script.
///
/// Signers: named by address in the environment (`DEPLOYER_ADDRESS`, optionally
/// `LISTING_AUTHORITY_ADDRESS` and `OPERATOR_ADDRESS`, which default to the deployer) and
/// signed with Foundry keystores (`--account`). This script never reads a private key.
contract DeployNiara is NiaraScriptBase {
    /// @notice The protocol fee this deployment is meant to charge. It is the contract's
    /// default; the script fails if the deployed value differs.
    uint16 public constant FEE_BPS = 50;

    /// @notice Cashback share of the fee set by this deployment unless `CASHBACK_BPS` says
    /// otherwise: 2000 bps = 20% of the fee.
    uint16 public constant DEFAULT_CASHBACK_BPS = 2_000;

    uint256 public constant DEFAULT_TIMELOCK_DELAY = 1 hours;

    string public constant MOCK_USDT_NAME = "Niara Mock USDT (TESTNET ONLY - NO VALUE)";
    string public constant MOCK_USDT_SYMBOL = "mockUSDT";
    string public constant MOCK_BRL_NAME = "Niara Mock BRL (TESTNET ONLY - NO VALUE)";
    string public constant MOCK_BRL_SYMBOL = "mockBRL";
    uint8 public constant MOCK_DECIMALS = 6;

    struct Config {
        /// @dev Signs both phases and becomes the admin (DEFAULT_ADMIN_ROLE, PAUSER_ROLE,
        /// TREASURY_ROLE) of every contract.
        address deployer;
        /// @dev LISTING_AUTHORITY_ROLE on the registry; signs the currency listings in phase 2.
        address listingAuthority;
        /// @dev SETTLEMENT_OPERATOR_ROLE on NiaraSettlement.
        address operator;
        uint256 timelockDelay;
        uint16 cashbackBps;
    }

    error ZeroConfigAddress(string what);
    error CashbackBpsOutOfRange(uint256 cashbackBps);
    error UnexpectedFee(uint16 deployedFeeBps);
    error TimelockStillRunning(uint256 executeAfter, uint256 nowTimestamp);
    error ListingAuthorityMismatch(address configured);
    error WiringIncomplete(string what);

    // ── Entry points ───────────────────────────────────────────────────────────────────

    /// @notice PHASE 1: deploy everything and propose the wiring.
    /// @return d The deployed contracts.
    function run() external returns (Deployment memory d) {
        Config memory cfg = readConfig();
        _logConfig(cfg);
        d = deployAndPropose(cfg);
        _logDeployment(d);
        _logNextStep(cfg, d);
    }

    /// @notice PHASE 2: execute the wiring proposed by `run()`. Only succeeds once the
    /// timelock delay has really passed since phase 1.
    function executeWiring() external {
        Config memory cfg = readConfig();
        Deployment memory d = readDeployment();
        executeWiringOn(cfg, d);
        console2.log("Wiring complete and verified on", chainName());
    }

    /// @notice Read-only: checks that the deployment in the environment is fully wired.
    /// Reverts with the first thing that is missing.
    function verify() external view {
        Config memory cfg = readConfig();
        verifyWiring(cfg, readDeployment());
        console2.log("Deployment verified on", chainName());
    }

    // ── Configuration ──────────────────────────────────────────────────────────────────

    /// @notice Reads the configuration from the environment. Only addresses and numbers:
    /// nothing here is secret.
    /// @return cfg The configuration.
    function readConfig() public view returns (Config memory cfg) {
        cfg.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        cfg.listingAuthority = vm.envOr("LISTING_AUTHORITY_ADDRESS", cfg.deployer);
        cfg.operator = vm.envOr("OPERATOR_ADDRESS", cfg.deployer);
        cfg.timelockDelay = vm.envOr("TIMELOCK_DELAY", DEFAULT_TIMELOCK_DELAY);
        uint256 cashbackBps = vm.envOr("CASHBACK_BPS", uint256(DEFAULT_CASHBACK_BPS));
        if (cashbackBps > 10_000) revert CashbackBpsOutOfRange(cashbackBps);
        cfg.cashbackBps = uint16(cashbackBps);
    }

    function _validate(Config memory cfg) internal pure {
        if (cfg.deployer == address(0)) revert ZeroConfigAddress("deployer");
        if (cfg.listingAuthority == address(0)) revert ZeroConfigAddress("listing authority");
        if (cfg.operator == address(0)) revert ZeroConfigAddress("operator");
        if (cfg.cashbackBps > 10_000) revert CashbackBpsOutOfRange(cfg.cashbackBps);
    }

    // ── Phase 1 ────────────────────────────────────────────────────────────────────────

    /// @notice Deploys the contracts and proposes the wiring, all signed by `cfg.deployer`.
    /// @param cfg The configuration.
    /// @return d The deployed contracts.
    function deployAndPropose(Config memory cfg) public returns (Deployment memory d) {
        _requireSupportedChain();
        _validate(cfg);

        vm.startBroadcast(cfg.deployer);

        d.mockUsdt = new TestnetMockToken(MOCK_USDT_NAME, MOCK_USDT_SYMBOL, MOCK_DECIMALS);
        d.mockBrl = new TestnetMockToken(MOCK_BRL_NAME, MOCK_BRL_SYMBOL, MOCK_DECIMALS);
        // The registry deploys the AssetTokenFactory in its constructor and holds the
        // protocol's single, shared pause.
        d.registry = new ListingRegistry(cfg.deployer, cfg.listingAuthority, cfg.timelockDelay);
        d.factory = d.registry.factory();
        d.distributor = new CashbackDistributor(cfg.deployer, address(d.registry), cfg.timelockDelay);
        // The mock USDT is the fee token: the only payment `settle` accepts, and one leg of
        // every P2P deal.
        d.settlement = new NiaraSettlement(
            cfg.deployer, address(d.distributor), address(d.registry), address(d.mockUsdt), cfg.timelockDelay
        );
        d.escrow = new P2PEscrow(cfg.deployer, address(d.settlement), address(d.registry), cfg.timelockDelay);

        // The fee is not set here: 50 bps is the contract's default and its hard cap.
        if (d.settlement.feeBps() != FEE_BPS) revert UnexpectedFee(d.settlement.feeBps());

        d.distributor.proposeGrantRole(d.distributor.SETTLEMENT_ROLE(), address(d.settlement));
        d.distributor.proposeGrantRole(d.distributor.ESCROW_ROLE(), address(d.escrow));
        d.settlement.proposeGrantRole(d.settlement.SETTLEMENT_OPERATOR_ROLE(), cfg.operator);
        if (d.distributor.cashbackBps() != cfg.cashbackBps) d.distributor.proposeSetCashbackBps(cfg.cashbackBps);

        vm.stopBroadcast();
    }

    // ── Phase 2 ────────────────────────────────────────────────────────────────────────

    /// @notice Executes the proposed wiring (signed by `cfg.deployer`), lists the two mock
    /// currencies (signed by `cfg.listingAuthority`) and verifies everything. Steps that
    /// are already done are skipped, so a run that stopped halfway can simply be repeated.
    /// @param cfg The same configuration phase 1 used.
    /// @param d The phase 1 deployment.
    function executeWiringOn(Config memory cfg, Deployment memory d) public {
        _requireSupportedChain();
        _validate(cfg);
        // The currencies are listed by the listing authority fixed in phase 1: a different
        // address here means the environment changed between the phases.
        if (!d.registry.hasRole(d.registry.LISTING_AUTHORITY_ROLE(), cfg.listingAuthority)) {
            revert ListingAuthorityMismatch(cfg.listingAuthority);
        }
        uint256 executeAfter = wiringExecutableAt(cfg, d);
        if (block.timestamp < executeAfter) revert TimelockStillRunning(executeAfter, block.timestamp);

        bytes32 settlementRole = d.distributor.SETTLEMENT_ROLE();
        bytes32 escrowRole = d.distributor.ESCROW_ROLE();
        bytes32 operatorRole = d.settlement.SETTLEMENT_OPERATOR_ROLE();

        vm.startBroadcast(cfg.deployer);
        if (!d.distributor.hasRole(settlementRole, address(d.settlement))) {
            d.distributor.executeGrantRole(settlementRole, address(d.settlement));
        }
        if (!d.distributor.hasRole(escrowRole, address(d.escrow))) {
            d.distributor.executeGrantRole(escrowRole, address(d.escrow));
        }
        if (!d.settlement.hasRole(operatorRole, cfg.operator)) {
            d.settlement.executeGrantRole(operatorRole, cfg.operator);
        }
        if (d.distributor.cashbackBps() != cfg.cashbackBps) d.distributor.executeSetCashbackBps(cfg.cashbackBps);
        vm.stopBroadcast();

        // Listing a currency is not timelocked (it is an operational listing decision), but
        // it is done here, after the wiring, so nothing is tradable before the cashback rate
        // and the roles are in place.
        vm.startBroadcast(cfg.listingAuthority);
        if (_notListed(d, address(d.mockUsdt))) d.registry.listCurrency(address(d.mockUsdt));
        if (_notListed(d, address(d.mockBrl))) d.registry.listCurrency(address(d.mockBrl));
        vm.stopBroadcast();

        verifyWiring(cfg, d);
    }

    /// @notice Earliest timestamp at which every pending proposal of phase 1 can execute
    /// (0 if none is pending).
    /// @param cfg The phase 1 configuration.
    /// @param d The phase 1 deployment.
    /// @return executeAfter The latest `executeAfter` among the pending proposals.
    function wiringExecutableAt(Config memory cfg, Deployment memory d) public view returns (uint256 executeAfter) {
        bytes32[4] memory actions = [
            keccak256(abi.encode("GRANT_ROLE", d.distributor.SETTLEMENT_ROLE(), address(d.settlement))),
            keccak256(abi.encode("GRANT_ROLE", d.distributor.ESCROW_ROLE(), address(d.escrow))),
            keccak256(abi.encode("SET_CASHBACK_BPS", cfg.cashbackBps)),
            keccak256(abi.encode("GRANT_ROLE", d.settlement.SETTLEMENT_OPERATOR_ROLE(), cfg.operator))
        ];
        for (uint256 i = 0; i < 3; i++) {
            uint256 at = d.distributor.pendingActions(actions[i]);
            if (at > executeAfter) executeAfter = at;
        }
        uint256 operatorAt = d.settlement.pendingActions(actions[3]);
        if (operatorAt > executeAfter) executeAfter = operatorAt;
    }

    /// @notice Checks that the deployment is fully wired and configured. Reverts
    /// `WiringIncomplete` naming the first thing that is not as expected.
    /// @param cfg The configuration.
    /// @param d The deployment.
    function verifyWiring(Config memory cfg, Deployment memory d) public view {
        if (d.settlement.feeBps() != FEE_BPS) revert WiringIncomplete("fee is not 50 bps");
        if (d.settlement.MAX_FEE_BPS() != FEE_BPS) revert WiringIncomplete("fee cap is not 50 bps");
        if (d.distributor.cashbackBps() != cfg.cashbackBps) revert WiringIncomplete("cashback rate");
        if (!d.distributor.hasRole(d.distributor.SETTLEMENT_ROLE(), address(d.settlement))) {
            revert WiringIncomplete("SETTLEMENT_ROLE -> NiaraSettlement");
        }
        if (!d.distributor.hasRole(d.distributor.ESCROW_ROLE(), address(d.escrow))) {
            revert WiringIncomplete("ESCROW_ROLE -> P2PEscrow");
        }
        if (!d.settlement.hasRole(d.settlement.SETTLEMENT_OPERATOR_ROLE(), cfg.operator)) {
            revert WiringIncomplete("SETTLEMENT_OPERATOR_ROLE -> operator");
        }
        if (!d.registry.hasRole(d.registry.LISTING_AUTHORITY_ROLE(), cfg.listingAuthority)) {
            revert WiringIncomplete("LISTING_AUTHORITY_ROLE -> listing authority");
        }
        if (!_approvedCurrency(d, address(d.mockUsdt))) revert WiringIncomplete("mock USDT not an Approved Currency");
        if (!_approvedCurrency(d, address(d.mockBrl))) revert WiringIncomplete("mock BRL not an Approved Currency");
        if (d.settlement.feeToken() != address(d.mockUsdt)) revert WiringIncomplete("fee token");
        if (d.registry.paused()) revert WiringIncomplete("protocol is paused");
    }

    function _notListed(Deployment memory d, address token) internal view returns (bool) {
        return d.registry.getListing(token).status == IListingRegistry.ListingStatus.None;
    }

    function _approvedCurrency(Deployment memory d, address token) internal view returns (bool) {
        IListingRegistry.Listing memory listing = d.registry.getListing(token);
        return listing.status == IListingRegistry.ListingStatus.Approved
            && listing.assetClass == IListingRegistry.AssetClass.Currency;
    }

    // ── Logs ───────────────────────────────────────────────────────────────────────────

    function _logConfig(Config memory cfg) internal view {
        console2.log("Chain:", chainName(), block.chainid);
        console2.log("Deployer and admin of every contract:", cfg.deployer);
        console2.log("Listing authority:", cfg.listingAuthority);
        console2.log("Settlement operator:", cfg.operator);
        console2.log("Timelock delay (seconds):", cfg.timelockDelay);
        console2.log("Fee (bps):", uint256(FEE_BPS));
        console2.log("Cashback share of the fee (bps):", uint256(cfg.cashbackBps));
    }

    function _logDeployment(Deployment memory d) internal view {
        console2.log("");
        console2.log("== Deployed (copy the three DEPLOYED_ lines into your local .env) ==");
        console2.log(_envLine("DEPLOYED_SETTLEMENT_ADDRESS", address(d.settlement)));
        console2.log(_envLine("DEPLOYED_ESCROW_ADDRESS", address(d.escrow)));
        console2.log(_envLine("DEPLOYED_MOCK_BRL_ADDRESS", address(d.mockBrl)));
        console2.log("ListingRegistry:    ", address(d.registry));
        console2.log("AssetTokenFactory:  ", address(d.factory));
        console2.log("CashbackDistributor:", address(d.distributor));
        console2.log("NiaraSettlement:    ", address(d.settlement));
        console2.log("P2PEscrow:          ", address(d.escrow));
        console2.log("Mock USDT (test):   ", address(d.mockUsdt));
        console2.log("Mock BRL (test):    ", address(d.mockBrl));
    }

    function _envLine(string memory baseName, address value) internal view returns (string memory) {
        return string.concat(deployedVar(baseName), "=", vm.toString(value));
    }

    function _logNextStep(Config memory cfg, Deployment memory d) internal view {
        console2.log("");
        console2.log("== Next step ==");
        console2.log("Wiring proposed. Phase 2 can execute from this timestamp on:", wiringExecutableAt(cfg, d));
        console2.log('forge script script/Deploy.s.sol --sig "executeWiring()" --rpc-url <alias> --account <keystore>');
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";
import {MockWBTC} from "../test/mocks/MockWBTC.sol";

/// @title DeployNiara
/// @notice TWO-PHASE deploy script. It reflects the protocol's real timelock
/// requirement (`TimelockedAccessControl.MIN_TIMELOCK_DELAY` = 1h): there is no shortcut
/// to skip that wait, not even on testnet (see CLAUDE.md, "Role changes... go through the timelock").
///
/// PHASE 1, `run()`: deploys the four contracts + USDT/WBTC mocks and SCHEDULES (propose)
/// all the sensitive wiring between them (roles and `backingGateway`). Always safe to
/// broadcast: it does not depend on any time having passed.
///
/// PHASE 2, `executeWiring()`: CONSUMES (execute) the phase 1 proposals. It can only be
/// broadcast successfully after `TIMELOCK_DELAY` seconds have really passed on-chain
/// since phase 1; there is no way to simulate that wait against a real network.
/// It reads the addresses deployed in phase 1 from `DEPLOYED_*` environment variables.
///
/// All parameters come from environment variables: no sensitive or network-specific
/// value is hardcoded in this file.
contract DeployNiara is Script {
    uint256 internal constant DEFAULT_TIMELOCK_DELAY = 1 hours;

    /// @dev Grouped in a struct to avoid "stack too deep" in `run()`: a single memory
    /// pointer instead of a dozen simultaneous stack variables.
    struct Config {
        address admin;
        address operator;
        address custodian;
        address issuerWallet;
        uint256 timelockDelay;
        string assetName;
        string assetSymbol;
        string assetReference;
        string assetCountry;
    }

    function run()
        external
        returns (
            MockUSDT usdt,
            MockWBTC wbtc,
            CashbackDistributor distributor,
            NiaraSettlement settlement,
            BackingGateway gateway,
            AssetToken assetToken
        )
    {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        Config memory cfg = _readConfig(deployerPrivateKey);
        _logConfig(deployerPrivateKey, cfg);

        vm.startBroadcast(deployerPrivateKey);
        (usdt, wbtc, distributor, settlement, gateway, assetToken) = _deployAll(cfg);
        _proposeWiring(distributor, settlement, gateway, assetToken, cfg);
        vm.stopBroadcast();

        _logDeployedAddresses(usdt, wbtc, distributor, settlement, gateway, assetToken);
        _logWiringInstructions(cfg.timelockDelay);
    }

    /// @notice PHASE 2: executes the wiring scheduled in `run()`. Only broadcast after
    /// `TIMELOCK_DELAY` seconds have really passed since phase 1.
    function executeWiring() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address operator = vm.envOr("OPERATOR_ADDRESS", deployer);
        address custodian = vm.envOr("CUSTODIAN_ADDRESS", deployer);

        CashbackDistributor distributor = CashbackDistributor(vm.envAddress("DEPLOYED_DISTRIBUTOR_ADDRESS"));
        NiaraSettlement settlement = NiaraSettlement(vm.envAddress("DEPLOYED_SETTLEMENT_ADDRESS"));
        BackingGateway gateway = BackingGateway(vm.envAddress("DEPLOYED_GATEWAY_ADDRESS"));
        AssetToken assetToken = AssetToken(vm.envAddress("DEPLOYED_ASSET_TOKEN_ADDRESS"));

        vm.startBroadcast(deployerPrivateKey);

        distributor.executeGrantRole(distributor.SETTLEMENT_ROLE(), address(settlement));
        settlement.executeGrantRole(settlement.SETTLEMENT_OPERATOR_ROLE(), operator);
        gateway.executeGrantRole(gateway.OPERATOR_ROLE(), operator);
        gateway.executeGrantRole(gateway.CUSTODIAN_ROLE(), custodian);
        assetToken.executeGrantRole(assetToken.MINTER_ROLE(), address(gateway));
        assetToken.executeGrantRole(assetToken.BURNER_ROLE(), address(gateway));
        assetToken.executeSetBackingGateway(address(gateway));

        vm.stopBroadcast();

        console2.log("Wiring complete: roles granted and backingGateway configured.");
    }

    // ── Fase 1: helpers ─────────────────────────────────────────────────────────────────

    function _readConfig(uint256 deployerPrivateKey) internal view returns (Config memory cfg) {
        address deployer = vm.addr(deployerPrivateKey);
        cfg.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        cfg.operator = vm.envOr("OPERATOR_ADDRESS", deployer);
        cfg.custodian = vm.envOr("CUSTODIAN_ADDRESS", deployer);
        cfg.issuerWallet = vm.envOr("ISSUER_WALLET_ADDRESS", deployer);
        cfg.timelockDelay = vm.envOr("TIMELOCK_DELAY", DEFAULT_TIMELOCK_DELAY);
        cfg.assetName = vm.envOr("ASSET_NAME", string("Niara Demo Equity"));
        cfg.assetSymbol = vm.envOr("ASSET_SYMBOL", string("nDEMO"));
        cfg.assetReference = vm.envOr("ASSET_REFERENCE", string("DEMO"));
        cfg.assetCountry = vm.envOr("ASSET_COUNTRY", string("US"));
    }

    function _deployAll(Config memory cfg)
        internal
        returns (
            MockUSDT usdt,
            MockWBTC wbtc,
            CashbackDistributor distributor,
            NiaraSettlement settlement,
            BackingGateway gateway,
            AssetToken assetToken
        )
    {
        usdt = new MockUSDT();
        wbtc = new MockWBTC();

        distributor = new CashbackDistributor(cfg.admin, cfg.timelockDelay);
        settlement = new NiaraSettlement(cfg.admin, address(distributor), cfg.timelockDelay);
        gateway = new BackingGateway(cfg.admin, cfg.timelockDelay);
        // AssetClass fixed to EQUITY: the demo script (Demo.s.sol) needs a cashback-eligible
        // asset to exercise the "cashback credited" step.
        assetToken = new AssetToken(
            cfg.assetName,
            cfg.assetSymbol,
            cfg.assetReference,
            AssetToken.AssetClass.EQUITY,
            cfg.assetCountry,
            cfg.issuerWallet,
            cfg.admin,
            cfg.timelockDelay
        );
    }

    /// @dev Schedules (propose) all the sensitive wiring. `cfg.admin` must sign these
    /// calls, so ADMIN_ADDRESS must match the PRIVATE_KEY address, unless phase 2 is
    /// broadcast by another wallet that also signs as `admin`.
    function _proposeWiring(
        CashbackDistributor distributor,
        NiaraSettlement settlement,
        BackingGateway gateway,
        AssetToken assetToken,
        Config memory cfg
    ) internal {
        distributor.proposeGrantRole(distributor.SETTLEMENT_ROLE(), address(settlement));
        settlement.proposeGrantRole(settlement.SETTLEMENT_OPERATOR_ROLE(), cfg.operator);
        gateway.proposeGrantRole(gateway.OPERATOR_ROLE(), cfg.operator);
        gateway.proposeGrantRole(gateway.CUSTODIAN_ROLE(), cfg.custodian);
        assetToken.proposeGrantRole(assetToken.MINTER_ROLE(), address(gateway));
        assetToken.proposeGrantRole(assetToken.BURNER_ROLE(), address(gateway));
        assetToken.proposeSetBackingGateway(address(gateway));
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logConfig(uint256 deployerPrivateKey, Config memory cfg) internal pure {
        console2.log("Deployer:", vm.addr(deployerPrivateKey));
        console2.log("Admin:", cfg.admin);
        console2.log("Operator:", cfg.operator);
        console2.log("Custodian:", cfg.custodian);
        console2.log("Issuer wallet:", cfg.issuerWallet);
        console2.log("Timelock delay (seconds):", cfg.timelockDelay);
    }

    function _logDeployedAddresses(
        MockUSDT usdt,
        MockWBTC wbtc,
        CashbackDistributor distributor,
        NiaraSettlement settlement,
        BackingGateway gateway,
        AssetToken assetToken
    ) internal pure {
        console2.log("");
        console2.log("== Deployed addresses (copy into your local .env before phase 2) ==");
        console2.log(string.concat("DEPLOYED_USDT_ADDRESS=", vm.toString(address(usdt))));
        console2.log(string.concat("DEPLOYED_WBTC_ADDRESS=", vm.toString(address(wbtc))));
        console2.log(string.concat("DEPLOYED_DISTRIBUTOR_ADDRESS=", vm.toString(address(distributor))));
        console2.log(string.concat("DEPLOYED_SETTLEMENT_ADDRESS=", vm.toString(address(settlement))));
        console2.log(string.concat("DEPLOYED_GATEWAY_ADDRESS=", vm.toString(address(gateway))));
        console2.log(string.concat("DEPLOYED_ASSET_TOKEN_ADDRESS=", vm.toString(address(assetToken))));
        console2.log("");
    }

    function _logWiringInstructions(uint256 timelockDelay) internal pure {
        console2.log("== Next step ==");
        console2.log(
            string.concat(
                "Roles and backingGateway scheduled (propose). Wait ",
                vm.toString(timelockDelay),
                 " seconds and run phase 2:"
            )
        );
        console2.log('forge script script/Deploy.s.sol --sig "executeWiring()" --rpc-url sepolia --broadcast');
    }
}

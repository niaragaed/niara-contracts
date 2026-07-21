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
/// @notice Script de deploy em DUAS FASES — reflete a exigência real de timelock do
/// protocolo (`TimelockedAccessControl.MIN_TIMELOCK_DELAY` = 1h): não há atalho para pular
/// essa espera, nem em testnet (ver CLAUDE.md, "Mudanças em papéis... passam pelo timelock").
///
/// FASE 1 — `run()`: implanta os quatro contratos + mocks de USDT/WBTC e AGENDA (propose)
/// toda a fiação sensível entre eles (papéis e `backingGateway`). Sempre seguro de
/// transmitir — não depende de nenhum tempo ter decorrido.
///
/// FASE 2 — `executeWiring()`: CONSOME (execute) as propostas da fase 1. Só pode ser
/// transmitida com sucesso depois que `TIMELOCK_DELAY` segundos realmente decorrerem
/// on-chain a partir da fase 1 — não há como simular essa espera contra uma rede real.
/// Lê os endereços implantados na fase 1 de variáveis de ambiente `DEPLOYED_*`.
///
/// Todos os parâmetros vêm de variáveis de ambiente — nenhum valor sensível ou específico
/// de rede fica hardcoded neste arquivo.
contract DeployNiara is Script {
    uint256 internal constant DEFAULT_TIMELOCK_DELAY = 1 hours;

    /// @dev Agrupada em struct para evitar "stack too deep" em `run()` — um único ponteiro
    /// de memória em vez de uma dezena de variáveis simultâneas na stack.
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

    /// @notice FASE 2 — executa a fiação agendada em `run()`. Só transmita depois que
    /// `TIMELOCK_DELAY` segundos tiverem realmente decorrido desde a fase 1.
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

        console2.log("Fiacao concluida: papeis concedidos e backingGateway configurado.");
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
        // AssetClass fixada em EQUITY: o script de demonstração (Demo.s.sol) depende de um
        // ativo elegível a cashback para exercitar o passo "cashback creditado".
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

    /// @dev Agenda (propose) toda a fiação sensível. `cfg.admin` precisa assinar estas
    /// chamadas — por isso ADMIN_ADDRESS deve corresponder ao endereço de PRIVATE_KEY, a
    /// menos que a fase 2 seja transmitida por outra carteira que também assine por `admin`.
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
        console2.log("Timelock delay (segundos):", cfg.timelockDelay);
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
        console2.log("== Enderecos implantados (copie para o .env local antes da fase 2) ==");
        console2.log(string.concat("DEPLOYED_USDT_ADDRESS=", vm.toString(address(usdt))));
        console2.log(string.concat("DEPLOYED_WBTC_ADDRESS=", vm.toString(address(wbtc))));
        console2.log(string.concat("DEPLOYED_DISTRIBUTOR_ADDRESS=", vm.toString(address(distributor))));
        console2.log(string.concat("DEPLOYED_SETTLEMENT_ADDRESS=", vm.toString(address(settlement))));
        console2.log(string.concat("DEPLOYED_GATEWAY_ADDRESS=", vm.toString(address(gateway))));
        console2.log(string.concat("DEPLOYED_ASSET_TOKEN_ADDRESS=", vm.toString(address(assetToken))));
        console2.log("");
    }

    function _logWiringInstructions(uint256 timelockDelay) internal pure {
        console2.log("== Proximo passo ==");
        console2.log(
            string.concat(
                "Papeis e backingGateway agendados (propose). Espere ",
                vm.toString(timelockDelay),
                " segundos e rode a fase 2:"
            )
        );
        console2.log('forge script script/Deploy.s.sol --sig "executeWiring()" --rpc-url sepolia --broadcast');
    }
}

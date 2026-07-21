// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";

/// @title DemoNiaraFlow
/// @notice Executa, em transações reais e rastreáveis na testnet, o fluxo completo do
/// protocolo: requestBacking -> attestBacking -> mintAttested -> settle -> cashback
/// creditado -> withdraw. Requer que `DeployNiara.executeWiring()` já tenha sido concluída
/// (papéis concedidos e `backingGateway` configurado).
/// @dev A liquidação exige duas partes distintas (buyer != seller, checagem estrutural em
/// NiaraSettlement.settle). Para não depender de uma segunda chave privada fornecida pelo
/// usuário, o "comprador" de demonstração é uma conta derivada deterministicamente
/// (`makeAddrAndKey`) e recebe um pouco de ETH de teste do deployer só para pagar o gás do
/// próprio `approve` — nunca detém valor além disso. O emissor (`issuerWallet`) precisa ser
/// o próprio deployer (padrão do Deploy.s.sol) para que o passo de `withdraw` funcione aqui,
/// já que este script só possui a chave privada do deployer.
contract DemoNiaraFlow is Script {
    struct Contracts {
        BackingGateway gateway;
        AssetToken assetToken;
        NiaraSettlement settlement;
        CashbackDistributor distributor;
        MockUSDT usdt;
    }

    struct DemoConfig {
        address issuerWallet;
        address seller;
        uint256 backingQuantity;
        uint256 settleAssetAmount;
        uint256 settlePaymentAmount;
        uint256 buyerGasFunding;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        Contracts memory c = _readContracts();
        DemoConfig memory cfg = _readDemoConfig(deployer);
        (address buyer, uint256 buyerPrivateKey) = makeAddrAndKey("niara-demo-buyer");
        console2.log("Comprador de demonstracao (derivado):", buyer);

        _runBackingFlow(c, cfg, deployerPrivateKey);
        _fundBuyer(c, cfg, deployerPrivateKey, buyer);
        _runSettleFlow(c, cfg, deployerPrivateKey, buyer, buyerPrivateKey);
        _runCashbackFlow(c, deployerPrivateKey);

        console2.log("");
        console2.log("Fluxo de demonstracao concluido com sucesso.");
    }

    function _readContracts() internal view returns (Contracts memory c) {
        c.gateway = BackingGateway(vm.envAddress("DEPLOYED_GATEWAY_ADDRESS"));
        c.assetToken = AssetToken(vm.envAddress("DEPLOYED_ASSET_TOKEN_ADDRESS"));
        c.settlement = NiaraSettlement(vm.envAddress("DEPLOYED_SETTLEMENT_ADDRESS"));
        c.distributor = CashbackDistributor(vm.envAddress("DEPLOYED_DISTRIBUTOR_ADDRESS"));
        c.usdt = MockUSDT(vm.envAddress("DEPLOYED_USDT_ADDRESS"));
    }

    function _readDemoConfig(address deployer) internal view returns (DemoConfig memory cfg) {
        cfg.issuerWallet = vm.envOr("ISSUER_WALLET_ADDRESS", deployer);
        // O próprio deployer atua como vendedor (recebe o mint) — só o comprador precisa de
        // uma conta separada, pela checagem buyer != seller.
        cfg.seller = deployer;
        cfg.backingQuantity = vm.envOr("DEMO_BACKING_QUANTITY", uint256(1_000 ether));
        cfg.settleAssetAmount = vm.envOr("DEMO_SETTLE_ASSET_AMOUNT", uint256(100 ether));
        cfg.settlePaymentAmount = vm.envOr("DEMO_SETTLE_PAYMENT_AMOUNT", uint256(10_000e6));
        cfg.buyerGasFunding = vm.envOr("DEMO_BUYER_GAS_FUNDING_WEI", uint256(0.01 ether));
    }

    function _runBackingFlow(Contracts memory c, DemoConfig memory cfg, uint256 deployerPrivateKey) internal {
        vm.startBroadcast(deployerPrivateKey);

        uint256 requestId = c.gateway.requestBacking(address(c.assetToken), cfg.backingQuantity);
        console2.log("1) requestBacking -> requestId", requestId);

        c.gateway.attestBacking(
            requestId, keccak256(abi.encode("niara-demo-backing-proof", requestId)), cfg.backingQuantity
        );
        console2.log("2) attestBacking OK -> quantidade atestada", cfg.backingQuantity);

        c.gateway.mintAttested(requestId, cfg.seller);
        console2.log("3) mintAttested -> tokens emitidos para o vendedor", cfg.seller);

        vm.stopBroadcast();
    }

    function _fundBuyer(Contracts memory c, DemoConfig memory cfg, uint256 deployerPrivateKey, address buyer)
        internal
    {
        vm.startBroadcast(deployerPrivateKey);
        if (buyer.balance < cfg.buyerGasFunding) {
            (bool ok,) = buyer.call{value: cfg.buyerGasFunding}("");
            require(ok, "funding do comprador falhou");
        }
        // MockUSDT.mint e publico (sem controle de acesso, uso exclusivo de teste) — o
        // deployer pode financiar o comprador diretamente, sem precisar da chave dele.
        c.usdt.mint(buyer, cfg.settlePaymentAmount);
        vm.stopBroadcast();
        console2.log("4) Comprador financiado: ETH para gas + USDT de demonstracao");
    }

    function _runSettleFlow(
        Contracts memory c,
        DemoConfig memory cfg,
        uint256 deployerPrivateKey,
        address buyer,
        uint256 buyerPrivateKey
    ) internal {
        vm.startBroadcast(deployerPrivateKey);
        c.assetToken.approve(address(c.settlement), cfg.settleAssetAmount);
        vm.stopBroadcast();
        console2.log("5) Vendedor aprovou o AssetToken para a liquidacao");

        vm.startBroadcast(buyerPrivateKey);
        c.usdt.approve(address(c.settlement), cfg.settlePaymentAmount);
        vm.stopBroadcast();
        console2.log("6) Comprador aprovou o USDT para a liquidacao");

        vm.startBroadcast(deployerPrivateKey);
        uint256 feeCharged = c.settlement.settle(
            address(c.assetToken), address(c.usdt), buyer, cfg.seller, cfg.settleAssetAmount, cfg.settlePaymentAmount
        );
        vm.stopBroadcast();
        console2.log("7) settle executado -> taxa cobrada", feeCharged);
    }

    function _runCashbackFlow(Contracts memory c, uint256 deployerPrivateKey) internal {
        uint256 cashbackBalance = c.distributor.cashbackBalance(address(c.assetToken), address(c.usdt));
        console2.log("8) Cashback creditado ao emissor (saldo antes do saque):", cashbackBalance);

        vm.startBroadcast(deployerPrivateKey);
        c.distributor.withdraw(address(c.assetToken), address(c.usdt));
        vm.stopBroadcast();
        console2.log("9) withdraw executado -> emissor sacou o cashback");
    }
}

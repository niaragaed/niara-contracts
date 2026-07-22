// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";

/// @title PresentationDemo
/// @notice Versão da demonstração para APRESENTAÇÃO PÚBLICA: cada papel do protocolo —
/// vendedor, comprador, empresa emissora (recebe o cashback), custodiante e operador — é uma
/// carteira DISTINTA das demais, para deixar explícito que o cashback vai para um terceiro
/// alheio à negociação (a empresa emissora não é nem o comprador nem o vendedor).
///
/// @dev REUTILIZA os contratos JÁ implantados por `script/Deploy.s.sol` (endereços
/// `DEPLOYED_*` no `.env`) — não implanta nada novo. Só REATRIBUI, via timelock, os papéis de
/// operador/custodiante/emissora para carteiras distintas das usadas no deploy original (que
/// continuam válidas — esta reatribuição é aditiva, não revoga nada). `MINTER_ROLE`/
/// `BURNER_ROLE`/`backingGateway` já estão corretos desde o deploy original e não precisam
/// mudar.
///
/// Mesma estrutura em duas fases dos demais scripts, por causa do timelock real
/// (`MIN_TIMELOCK_DELAY` = 1h, sem atalho possível — ver CLAUDE.md):
///
///   FASE 1 — `run()`: deriva as 5 carteiras de papel, agenda (propose) a reatribuição e
///   financia cada carteira derivada com um pouco de ETH de teste (só para o próprio gás).
///
///   FASE 2 — `executeWiring()`: executa (consome) a reatribuição agendada, depois que o
///   atraso realmente decorrer on-chain.
///
///   DEMO — `runDemo()`: fluxo completo, cada etapa assinada pela carteira do papel
///   correspondente (não pelo deployer): requestBacking/mintAttested/settle pelo operador,
///   attestBacking pelo custodiante, approve pelo vendedor e pelo comprador, withdraw pela
///   empresa emissora.
///
/// As 5 carteiras são derivadas deterministicamente por rótulo (`makeAddrAndKey`) — não
/// dependem de nenhuma chave privada além da do deployer (`PRIVATE_KEY`), que as financia.
contract PresentationDemo is Script {
    uint256 internal constant ROLE_GAS_FUNDING_WEI = 0.003 ether;

    /// @dev Agrupada em struct para evitar "stack too deep" — um único ponteiro de memória
    /// em vez de uma dezena de variáveis simultâneas na stack.
    struct Actors {
        address admin;
        address operator;
        uint256 operatorKey;
        address custodian;
        uint256 custodianKey;
        address issuerWallet;
        uint256 issuerKey;
        address seller;
        uint256 sellerKey;
        address buyer;
        uint256 buyerKey;
    }

    struct Contracts {
        MockUSDT usdt;
        CashbackDistributor distributor;
        NiaraSettlement settlement;
        BackingGateway gateway;
        AssetToken assetToken;
    }

    // ── Fase 1 ──────────────────────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        Actors memory actors = _deriveActors(deployerPrivateKey);
        Contracts memory c = _readContracts();

        _logActors(actors);

        vm.startBroadcast(deployerPrivateKey);
        _proposeRewiring(c, actors);
        _fundActorsForGas(actors);
        vm.stopBroadcast();

        _logNextSteps();
    }

    function _readContracts() internal view returns (Contracts memory c) {
        c.usdt = MockUSDT(vm.envAddress("DEPLOYED_USDT_ADDRESS"));
        c.distributor = CashbackDistributor(vm.envAddress("DEPLOYED_DISTRIBUTOR_ADDRESS"));
        c.settlement = NiaraSettlement(vm.envAddress("DEPLOYED_SETTLEMENT_ADDRESS"));
        c.gateway = BackingGateway(vm.envAddress("DEPLOYED_GATEWAY_ADDRESS"));
        c.assetToken = AssetToken(vm.envAddress("DEPLOYED_ASSET_TOKEN_ADDRESS"));
    }

    /// @dev Agenda (propose) a troca de operador/custodiante/emissora nos contratos JÁ
    /// implantados. `issuerWallet` é substituído (não aditivo); os papéis via AccessControl
    /// são concedidos além dos já existentes (aditivo — o deployer original continua com os
    /// papéis dele, isso não é uma migração, é uma reatribuição para fins de demonstração).
    function _proposeRewiring(Contracts memory c, Actors memory actors) internal {
        c.gateway.proposeGrantRole(c.gateway.OPERATOR_ROLE(), actors.operator);
        c.gateway.proposeGrantRole(c.gateway.CUSTODIAN_ROLE(), actors.custodian);
        c.settlement.proposeGrantRole(c.settlement.SETTLEMENT_OPERATOR_ROLE(), actors.operator);
        c.assetToken.proposeSetIssuerWallet(actors.issuerWallet);
    }

    /// @dev As carteiras de papel precisam de um pouco de ETH para assinar suas próprias
    /// transações em `executeWiring`/`runDemo` — só o deployer tem saldo de partida.
    function _fundActorsForGas(Actors memory actors) internal {
        _fundIfNeeded(actors.operator);
        _fundIfNeeded(actors.custodian);
        _fundIfNeeded(actors.issuerWallet);
        _fundIfNeeded(actors.seller);
        _fundIfNeeded(actors.buyer);
    }

    function _fundIfNeeded(address to) internal {
        if (to.balance < ROLE_GAS_FUNDING_WEI) {
            (bool ok,) = to.call{value: ROLE_GAS_FUNDING_WEI}("");
            require(ok, "funding de carteira de apresentacao falhou");
        }
    }

    // ── Fase 2 ──────────────────────────────────────────────────────────────────────────

    /// @notice Executa a reatribuição agendada em `run()`. Só transmita depois que
    /// `TIMELOCK_DELAY` (do deploy original) segundos tiverem realmente decorrido desde a
    /// fase 1 deste script.
    function executeWiring() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        Actors memory actors = _deriveActors(deployerPrivateKey);
        Contracts memory c = _readContracts();

        vm.startBroadcast(deployerPrivateKey);

        c.gateway.executeGrantRole(c.gateway.OPERATOR_ROLE(), actors.operator);
        c.gateway.executeGrantRole(c.gateway.CUSTODIAN_ROLE(), actors.custodian);
        c.settlement.executeGrantRole(c.settlement.SETTLEMENT_OPERATOR_ROLE(), actors.operator);
        c.assetToken.executeSetIssuerWallet(actors.issuerWallet);

        vm.stopBroadcast();

        console2.log("Reatribuicao concluida: papeis de apresentacao ativos nos contratos existentes.");
    }

    // ── Demo: cada etapa assinada pela carteira do papel correspondente ────────────────

    function runDemo() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        Actors memory actors = _deriveActors(deployerPrivateKey);
        Contracts memory c = _readContracts();

        uint256 backingQuantity = vm.envOr("DEMO_BACKING_QUANTITY", uint256(1_000 ether));
        uint256 settleAssetAmount = vm.envOr("DEMO_SETTLE_ASSET_AMOUNT", uint256(100 ether));
        uint256 settlePaymentAmount = vm.envOr("DEMO_SETTLE_PAYMENT_AMOUNT", uint256(10_000e6));

        _runBackingFlow(c, actors, backingQuantity);
        _fundBuyerWithUsdt(c, actors.buyer, settlePaymentAmount);
        _runSettleFlow(c, actors, settleAssetAmount, settlePaymentAmount);
        _runCashbackFlow(c, actors);

        console2.log("");
        console2.log("Fluxo de apresentacao concluido com sucesso.");
    }

    function _runBackingFlow(Contracts memory c, Actors memory actors, uint256 quantity) internal {
        vm.startBroadcast(actors.operatorKey);
        uint256 requestId = c.gateway.requestBacking(address(c.assetToken), quantity);
        console2.log("1) requestBacking (operador) -> requestId", requestId);
        vm.stopBroadcast();

        vm.startBroadcast(actors.custodianKey);
        c.gateway.attestBacking(requestId, keccak256(abi.encode("niara-presentation-proof", requestId)), quantity);
        console2.log("2) attestBacking (custodiante) OK -> quantidade atestada", quantity);
        vm.stopBroadcast();

        vm.startBroadcast(actors.operatorKey);
        c.gateway.mintAttested(requestId, actors.seller);
        console2.log("3) mintAttested (operador) -> tokens emitidos para o vendedor", actors.seller);
        vm.stopBroadcast();
    }

    function _fundBuyerWithUsdt(Contracts memory c, address buyer, uint256 amount) internal {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        // MockUSDT.mint e publico (sem controle de acesso, uso exclusivo de teste) — o
        // deployer financia o comprador diretamente, sem precisar da chave dele.
        c.usdt.mint(buyer, amount);
        vm.stopBroadcast();
        console2.log("4) Comprador financiado com USDT de demonstracao");
    }

    function _runSettleFlow(Contracts memory c, Actors memory actors, uint256 assetAmount, uint256 paymentAmount)
        internal
    {
        vm.startBroadcast(actors.sellerKey);
        c.assetToken.approve(address(c.settlement), assetAmount);
        vm.stopBroadcast();
        console2.log("5) Vendedor aprovou o AssetToken para a liquidacao");

        vm.startBroadcast(actors.buyerKey);
        c.usdt.approve(address(c.settlement), paymentAmount);
        vm.stopBroadcast();
        console2.log("6) Comprador aprovou o USDT para a liquidacao");

        vm.startBroadcast(actors.operatorKey);
        uint256 feeCharged = c.settlement.settle(
            address(c.assetToken), address(c.usdt), actors.buyer, actors.seller, assetAmount, paymentAmount
        );
        vm.stopBroadcast();
        console2.log("7) settle (operador) executado -> taxa cobrada", feeCharged);
    }

    function _runCashbackFlow(Contracts memory c, Actors memory actors) internal {
        uint256 cashbackBalance = c.distributor.cashbackBalance(address(c.assetToken), address(c.usdt));
        console2.log("8) Cashback creditado a empresa emissora (saldo antes do saque):", cashbackBalance);

        vm.startBroadcast(actors.issuerKey);
        c.distributor.withdraw(address(c.assetToken), address(c.usdt));
        vm.stopBroadcast();
        console2.log("9) withdraw (empresa emissora) executado -> cashback sacado");
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────

    function _deriveActors(uint256 deployerPrivateKey) internal returns (Actors memory a) {
        a.admin = vm.addr(deployerPrivateKey);
        (a.operator, a.operatorKey) = makeAddrAndKey("niara-presentation-operator");
        (a.custodian, a.custodianKey) = makeAddrAndKey("niara-presentation-custodian");
        (a.issuerWallet, a.issuerKey) = makeAddrAndKey("niara-presentation-issuer");
        (a.seller, a.sellerKey) = makeAddrAndKey("niara-presentation-seller");
        (a.buyer, a.buyerKey) = makeAddrAndKey("niara-presentation-buyer");
    }

    function _logActors(Actors memory a) internal pure {
        console2.log("== Papeis da apresentacao (carteiras distintas) ==");
        console2.log("Admin (deployer / governanca):", a.admin);
        console2.log("Operador (requestBacking, mintAttested, settle):", a.operator);
        console2.log("Custodiante (attestBacking):", a.custodian);
        console2.log("Empresa emissora (issuerWallet, recebe o cashback):", a.issuerWallet);
        console2.log("Vendedor (entrega o AssetToken na liquidacao):", a.seller);
        console2.log("Comprador (paga na liquidacao):", a.buyer);
        console2.log("");
    }

    function _logNextSteps() internal pure {
        console2.log("== Proximo passo ==");
        console2.log("Reatribuicao agendada (propose). Espere o timelock decorrer e rode a fase 2:");
        console2.log('forge script script/PresentationDemo.s.sol --sig "executeWiring()" --rpc-url sepolia --broadcast');
        console2.log("Depois disso, rode a demo:");
        console2.log('forge script script/PresentationDemo.s.sol --sig "runDemo()" --rpc-url sepolia --broadcast');
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetToken} from "../../src/AssetToken.sol";
import {BackingGateway} from "../../src/BackingGateway.sol";
import {NiaraSettlement} from "../../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../../src/CashbackDistributor.sol";
import {MockUSDT} from "../mocks/MockUSDT.sol";
import {MockWBTC} from "../mocks/MockWBTC.sol";

/// @notice Ator de fuzzing stateful: expõe uma ação por função pública (request, attest,
/// mint, redeem, settle, saques, pausas) para que o motor de invariantes do Foundry explore
/// sequências aleatórias desses passos entre múltiplos atores.
/// @dev Na maior parte das chamadas os parâmetros são limitados (`bound`) a estados válidos,
/// maximizando sequências produtivas (mint real, settle real etc.) — mas uma fração de cada
/// chamada (`_chaos`, ~1 em 5) ignora essas guardas de propósito e tenta o caminho inválido
/// (endereço zero, quantidade zero, estado errado, valores fora do saldo/aprovação real).
/// Não envolvemos as chamadas externas em try/catch: com `fail_on_revert = false` (ver
/// foundry.toml), um revert genuíno é tolerado pelo runner de invariantes e desfaz, de forma
/// atômica, qualquer efeito colateral desta chamada (inclusive as variáveis "ghost" abaixo) —
/// não há necessidade de capturá-lo manualmente, e capturá-lo apenas escondia esses caminhos
/// de revert da exploração do fuzzer.
/// Variáveis "ghost" (`ghost_sum*`) acumulam totais que não existem como estado no protocolo
/// real, usadas pelas invariantes para verificar contabilidade ao longo do tempo (não apenas
/// o saldo atual).
contract Handler is Test {
    // Variáveis de estado normais (não `immutable`) de propósito: um construtor com muitas
    // `immutable` simultâneas nesta contagem faz o codegen do Solidity estourar a stack
    // ("stack too deep") na etapa final de finalização do construtor.
    AssetToken public assetEquity;
    AssetToken public assetCommodity;
    BackingGateway public gateway;
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    MockUSDT public usdt;
    MockWBTC public wbtc;

    address[] public actors;
    address public operator;
    address public custodian;
    address public settlementOperator;
    address public admin;

    uint256[] public backingRequestIds;
    uint256[] public redemptionRequestIds;

    /// @notice Soma histórica de taxas registradas no CashbackDistributor, por moeda de
    /// liquidação (nunca decresce).
    mapping(address paymentToken => uint256) public ghost_sumFeesRecorded;

    /// @notice Soma histórica de cashback creditado (não o saldo atual — saques não
    /// reduzem este valor), por moeda de liquidação.
    mapping(address paymentToken => uint256) public ghost_sumCashbackCredited;

    /// @dev Agrupada em struct (em vez de ~12 parâmetros soltos) para evitar "stack too
    /// deep" na finalização do construtor — um único ponteiro de memória em vez de uma
    /// dezena de variáveis simultâneas na stack.
    struct Config {
        AssetToken assetEquity;
        AssetToken assetCommodity;
        BackingGateway gateway;
        NiaraSettlement settlement;
        CashbackDistributor distributor;
        MockUSDT usdt;
        MockWBTC wbtc;
        address[] actors;
        address operator;
        address custodian;
        address settlementOperator;
        address admin;
    }

    constructor(Config memory config) {
        assetEquity = config.assetEquity;
        assetCommodity = config.assetCommodity;
        gateway = config.gateway;
        settlement = config.settlement;
        distributor = config.distributor;
        usdt = config.usdt;
        wbtc = config.wbtc;
        actors = config.actors;
        operator = config.operator;
        custodian = config.custodian;
        settlementOperator = config.settlementOperator;
        admin = config.admin;
    }

    // ── Helpers de seleção ─────────────────────────────────────────────────────────────

    function _pickAsset(uint256 seed) internal view returns (AssetToken) {
        return seed % 2 == 0 ? assetEquity : assetCommodity;
    }

    function _pickPaymentToken(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? address(usdt) : address(wbtc);
    }

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _distinctActor(uint256 seed, address other) internal view returns (address) {
        uint256 idx = seed % actors.length;
        address candidate = actors[idx];
        if (candidate == other) {
            candidate = actors[(idx + 1) % actors.length];
        }
        return candidate;
    }

    /// @dev ~1 em 5 chamadas toma o caminho "caótico" (inválido de propósito) em vez do
    /// caminho limitado a estados válidos.
    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    // ── Lastro (emissão) ────────────────────────────────────────────────────────────────

    function requestBacking(uint256 assetSeed, uint256 quantitySeed) external {
        address asset = _chaos(assetSeed) ? address(0) : address(_pickAsset(assetSeed));
        uint256 quantity = _chaos(quantitySeed) ? 0 : bound(quantitySeed, 1, 1_000_000 ether);

        vm.prank(operator);
        uint256 requestId = gateway.requestBacking(asset, quantity);
        backingRequestIds.push(requestId);
    }

    function attestBacking(uint256 idxSeed, uint256 acquiredSeed) external {
        if (backingRequestIds.length == 0) return;
        uint256 requestId = backingRequestIds[idxSeed % backingRequestIds.length];
        (,, uint256 quantityRequested,,, BackingGateway.RequestStatus status,) = gateway.backingRequests(requestId);

        // Na maior parte das vezes só ataca pedidos PENDING — uma fração ignora essa
        // checagem de propósito para alcançar RequestNotPending.
        if (status != BackingGateway.RequestStatus.PENDING && !_chaos(idxSeed)) return;

        uint256 quantityAcquired = _chaos(acquiredSeed)
            ? acquiredSeed % 2_000_000 ether // pode exceder quantityRequested, ou ser zero.
            : bound(acquiredSeed, 1, quantityRequested == 0 ? 1 : quantityRequested);

        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256(abi.encode("backing-proof", requestId, acquiredSeed)), quantityAcquired);
    }

    function mintAttested(uint256 idxSeed, uint256 toSeed) external {
        if (backingRequestIds.length == 0) return;
        uint256 requestId = backingRequestIds[idxSeed % backingRequestIds.length];
        (,,,,, BackingGateway.RequestStatus status, bool minted) = gateway.backingRequests(requestId);

        bool eligible = status == BackingGateway.RequestStatus.SETTLED && !minted;
        if (!eligible && !_chaos(idxSeed)) return;

        address to = _chaos(toSeed) ? address(0) : _actorAt(toSeed);

        vm.prank(operator);
        gateway.mintAttested(requestId, to);
    }

    function cancelBackingRequest(uint256 idxSeed) external {
        if (backingRequestIds.length == 0) return;
        uint256 requestId = backingRequestIds[idxSeed % backingRequestIds.length];
        (,,,,, BackingGateway.RequestStatus status,) = gateway.backingRequests(requestId);

        if (status != BackingGateway.RequestStatus.PENDING && !_chaos(idxSeed)) return;

        vm.prank(operator);
        gateway.cancelBackingRequest(requestId);
    }

    // ── Resgate (queima) ────────────────────────────────────────────────────────────────

    function redemptionRequest(uint256 actorSeed, uint256 assetSeed, uint256 quantitySeed) external {
        address actor = _actorAt(actorSeed);
        address asset = _chaos(assetSeed) ? address(0) : address(_pickAsset(assetSeed));
        uint256 balance = asset == address(0) ? 0 : AssetToken(asset).balanceOf(actor);

        uint256 quantity;
        if (_chaos(quantitySeed)) {
            quantity = quantitySeed % 2; // às vezes 0 (ZeroQuantity), às vezes 1 mesmo sem saldo.
        } else if (balance == 0) {
            return;
        } else {
            quantity = bound(quantitySeed, 1, balance);
        }

        if (asset != address(0) && quantity > 0) {
            vm.prank(actor);
            AssetToken(asset).approve(address(gateway), quantity);
        }

        vm.prank(actor);
        uint256 requestId = gateway.redemptionRequest(asset, quantity);
        redemptionRequestIds.push(requestId);
    }

    function redemptionAttest(uint256 idxSeed) external {
        if (redemptionRequestIds.length == 0) return;
        uint256 requestId = redemptionRequestIds[idxSeed % redemptionRequestIds.length];
        (,,,, BackingGateway.RequestStatus status) = gateway.redemptionRequests(requestId);

        if (status != BackingGateway.RequestStatus.PENDING && !_chaos(idxSeed)) return;

        vm.prank(custodian);
        gateway.redemptionAttest(requestId, keccak256(abi.encode("redemption-proof", requestId)));
    }

    function cancelRedemptionRequest(uint256 idxSeed) external {
        if (redemptionRequestIds.length == 0) return;
        uint256 requestId = redemptionRequestIds[idxSeed % redemptionRequestIds.length];
        (,,,, BackingGateway.RequestStatus status) = gateway.redemptionRequests(requestId);

        if (status != BackingGateway.RequestStatus.PENDING && !_chaos(idxSeed)) return;

        vm.prank(custodian);
        gateway.cancelRedemptionRequest(requestId);
    }

    // ── Liquidação atômica ──────────────────────────────────────────────────────────────

    function settle(
        uint256 buyerSeed,
        uint256 sellerSeed,
        uint256 assetSeed,
        uint256 paymentSeed,
        uint256 assetAmountSeed,
        uint256 paymentAmountSeed
    ) external {
        address buyer = _actorAt(buyerSeed);
        address seller = _chaos(sellerSeed) ? buyer : _distinctActor(sellerSeed, buyer);
        AssetToken asset = _pickAsset(assetSeed);
        address paymentToken = _pickPaymentToken(paymentSeed);

        uint256 assetAmount = _pickAssetAmount(asset, seller, assetAmountSeed);
        if (assetAmount == 0) return;
        uint256 paymentAmount = _pickPaymentAmount(paymentToken, buyer, paymentAmountSeed);

        vm.prank(seller);
        asset.approve(address(settlement), assetAmount);
        vm.prank(buyer);
        IERC20(paymentToken).approve(address(settlement), paymentAmount);

        uint256 cashbackBefore = distributor.cashbackBalance(address(asset), paymentToken);
        vm.prank(settlementOperator);
        uint256 feeCharged = settlement.settle(address(asset), paymentToken, buyer, seller, assetAmount, paymentAmount);
        _recordSettleGhosts(asset, paymentToken, feeCharged, cashbackBefore);
    }

    function _pickAssetAmount(AssetToken asset, address seller, uint256 seed) internal view returns (uint256) {
        if (_chaos(seed)) return seed % 2_000_000 ether; // pode exceder saldo/aprovação real, ou ser zero.
        uint256 sellerBalance = asset.balanceOf(seller);
        if (sellerBalance == 0) return 0;
        return bound(seed, 1, sellerBalance);
    }

    function _pickPaymentAmount(address paymentToken, address buyer, uint256 seed) internal returns (uint256) {
        // Garante liquidez suficiente ao comprador na maior parte das vezes, para não
        // desperdiçar a chamada fuzzed em um no-op por falta de saldo — o mock permite mint
        // livre, só usado em teste.
        if (paymentToken == address(usdt)) {
            usdt.mint(buyer, 1_000_000e6);
        } else {
            wbtc.mint(buyer, 1_000e8);
        }

        if (_chaos(seed)) return seed % 2_000_000e8; // pode exceder o saldo recém-financiado, ou ser zero.
        uint256 buyerBalance = IERC20(paymentToken).balanceOf(buyer);
        return bound(seed, 1, buyerBalance);
    }

    function _recordSettleGhosts(AssetToken asset, address paymentToken, uint256 feeCharged, uint256 cashbackBefore)
        internal
    {
        ghost_sumFeesRecorded[paymentToken] += feeCharged;
        uint256 cashbackAfter = distributor.cashbackBalance(address(asset), paymentToken);
        ghost_sumCashbackCredited[paymentToken] += (cashbackAfter - cashbackBefore);
    }

    // ── Saques ──────────────────────────────────────────────────────────────────────────

    function withdrawCashback(uint256 assetSeed, uint256 paymentSeed) external {
        AssetToken asset = _pickAsset(assetSeed);
        address paymentToken = _pickPaymentToken(paymentSeed);
        address issuer = asset.issuerWallet();

        // Sem guarda de saldo disponível de propósito: na maior parte das vezes não há
        // nada a sacar ainda, exercitando NothingToWithdraw organicamente.
        vm.prank(issuer);
        distributor.withdraw(address(asset), paymentToken);
    }

    function withdrawProtocolFees(uint256 paymentSeed, uint256 amountSeed) external {
        address paymentToken = _pickPaymentToken(paymentSeed);
        uint256 available = distributor.protocolBalance(paymentToken);

        uint256 amount;
        if (_chaos(amountSeed) || available == 0) {
            amount = amountSeed % 1_000_000e8; // pode exceder o disponível, incl. zero.
        } else {
            amount = bound(amountSeed, 1, available);
        }

        vm.prank(admin);
        distributor.withdrawProtocolFees(paymentToken, admin, amount);
    }

    // ── Pausas (emergência) ─────────────────────────────────────────────────────────────

    function toggleGatewayPause() external {
        // `vm.prank` só vale para a PRÓXIMA chamada externa — não pode ser consumido pela
        // leitura de `paused()` antes da chamada que de fato precisa do prank (mesma
        // armadilha documentada no topo de test/AssetToken.t.sol).
        bool isPaused = gateway.paused();
        vm.prank(admin);
        if (isPaused) {
            gateway.unpause();
        } else {
            gateway.pause();
        }
    }

    function toggleSettlementPause() external {
        bool isPaused = settlement.paused();
        vm.prank(admin);
        if (isPaused) {
            settlement.unpause();
        } else {
            settlement.pause();
        }
    }

    function toggleAssetPause(uint256 assetSeed) external {
        AssetToken asset = _pickAsset(assetSeed);
        bool isPaused = asset.paused();
        vm.prank(admin);
        if (isPaused) {
            asset.unpause();
        } else {
            asset.pause();
        }
    }
}

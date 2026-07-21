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
/// mint, redeem, settle, saques, pausas) com parâmetros limitados (`bound`) a estados
/// válidos, para que o motor de invariantes do Foundry explore sequências aleatórias
/// desses passos entre múltiplos atores. Chamadas que não fazem sentido no estado atual
/// (ex.: atestar um pedido que já não está PENDING) são no-ops silenciosos — não usamos
/// `vm.assume`/revert para não distorcer a taxa de rejeição do fuzzer.
/// @dev Variáveis "ghost" (`ghost_sum*`) acumulam totais que não existem como estado no
/// protocolo real, usadas pelas invariantes para verificar contabilidade ao longo do tempo
/// (não apenas o saldo atual).
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

    // ── Lastro (emissão) ────────────────────────────────────────────────────────────────

    function requestBacking(uint256 assetSeed, uint256 quantitySeed) external {
        AssetToken asset = _pickAsset(assetSeed);
        uint256 quantity = bound(quantitySeed, 1, 1_000_000 ether);

        vm.prank(operator);
        try gateway.requestBacking(address(asset), quantity) returns (uint256 requestId) {
            backingRequestIds.push(requestId);
        } catch {}
    }

    function attestBacking(uint256 idxSeed, uint256 acquiredSeed) external {
        if (backingRequestIds.length == 0) return;
        uint256 requestId = backingRequestIds[idxSeed % backingRequestIds.length];

        (,, uint256 quantityRequested,,, BackingGateway.RequestStatus status,) = gateway.backingRequests(requestId);
        if (status != BackingGateway.RequestStatus.PENDING) return;

        uint256 quantityAcquired = bound(acquiredSeed, 1, quantityRequested);

        vm.prank(custodian);
        try gateway.attestBacking(requestId, keccak256(abi.encode("backing-proof", requestId)), quantityAcquired) {}
        catch {}
    }

    function mintAttested(uint256 idxSeed, uint256 toSeed) external {
        if (backingRequestIds.length == 0) return;
        uint256 requestId = backingRequestIds[idxSeed % backingRequestIds.length];

        (,,,,, BackingGateway.RequestStatus status, bool minted) = gateway.backingRequests(requestId);
        if (status != BackingGateway.RequestStatus.SETTLED || minted) return;

        address to = _actorAt(toSeed);

        vm.prank(operator);
        try gateway.mintAttested(requestId, to) {} catch {}
    }

    function cancelBackingRequest(uint256 idxSeed) external {
        if (backingRequestIds.length == 0) return;
        uint256 requestId = backingRequestIds[idxSeed % backingRequestIds.length];

        (,,,,, BackingGateway.RequestStatus status,) = gateway.backingRequests(requestId);
        if (status != BackingGateway.RequestStatus.PENDING) return;

        vm.prank(operator);
        try gateway.cancelBackingRequest(requestId) {} catch {}
    }

    // ── Resgate (queima) ────────────────────────────────────────────────────────────────

    function redemptionRequest(uint256 actorSeed, uint256 assetSeed, uint256 quantitySeed) external {
        address actor = _actorAt(actorSeed);
        AssetToken asset = _pickAsset(assetSeed);

        uint256 balance = asset.balanceOf(actor);
        if (balance == 0) return;
        uint256 quantity = bound(quantitySeed, 1, balance);

        vm.prank(actor);
        asset.approve(address(gateway), quantity);

        vm.prank(actor);
        try gateway.redemptionRequest(address(asset), quantity) returns (uint256 requestId) {
            redemptionRequestIds.push(requestId);
        } catch {}
    }

    function redemptionAttest(uint256 idxSeed) external {
        if (redemptionRequestIds.length == 0) return;
        uint256 requestId = redemptionRequestIds[idxSeed % redemptionRequestIds.length];

        (,,,, BackingGateway.RequestStatus status) = gateway.redemptionRequests(requestId);
        if (status != BackingGateway.RequestStatus.PENDING) return;

        vm.prank(custodian);
        try gateway.redemptionAttest(requestId, keccak256(abi.encode("redemption-proof", requestId))) {} catch {}
    }

    function cancelRedemptionRequest(uint256 idxSeed) external {
        if (redemptionRequestIds.length == 0) return;
        uint256 requestId = redemptionRequestIds[idxSeed % redemptionRequestIds.length];

        (,,,, BackingGateway.RequestStatus status) = gateway.redemptionRequests(requestId);
        if (status != BackingGateway.RequestStatus.PENDING) return;

        vm.prank(custodian);
        try gateway.cancelRedemptionRequest(requestId) {} catch {}
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
        address seller = _distinctActor(sellerSeed, buyer);
        AssetToken asset = _pickAsset(assetSeed);
        address paymentToken = _pickPaymentToken(paymentSeed);

        uint256 assetAmount = _boundAssetAmount(asset, seller, assetAmountSeed);
        if (assetAmount == 0) return;
        uint256 paymentAmount = _fundAndBoundPayment(paymentToken, buyer, paymentAmountSeed);

        vm.prank(seller);
        asset.approve(address(settlement), assetAmount);
        vm.prank(buyer);
        IERC20(paymentToken).approve(address(settlement), paymentAmount);

        uint256 cashbackBefore = distributor.cashbackBalance(address(asset), paymentToken);

        vm.prank(settlementOperator);
        try settlement.settle(address(asset), paymentToken, buyer, seller, assetAmount, paymentAmount) returns (
            uint256 feeCharged
        ) {
            _recordSettleGhosts(asset, paymentToken, feeCharged, cashbackBefore);
        } catch {}
    }

    function _boundAssetAmount(AssetToken asset, address seller, uint256 seed) internal view returns (uint256) {
        uint256 sellerBalance = asset.balanceOf(seller);
        if (sellerBalance == 0) return 0;
        return bound(seed, 1, sellerBalance);
    }

    function _fundAndBoundPayment(address paymentToken, address buyer, uint256 seed) internal returns (uint256) {
        // Garante liquidez suficiente ao comprador para não desperdiçar a chamada fuzzed
        // em um no-op por falta de saldo — o mock permite mint livre, só usado em teste.
        if (paymentToken == address(usdt)) {
            usdt.mint(buyer, 1_000_000e6);
        } else {
            wbtc.mint(buyer, 1_000e8);
        }
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

        vm.prank(issuer);
        try distributor.withdraw(address(asset), paymentToken) {} catch {}
    }

    function withdrawProtocolFees(uint256 paymentSeed, uint256 amountSeed) external {
        address paymentToken = _pickPaymentToken(paymentSeed);
        uint256 available = distributor.protocolBalance(paymentToken);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);

        vm.prank(admin);
        try distributor.withdrawProtocolFees(paymentToken, admin, amount) {} catch {}
    }

    // ── Pausas (emergência) ─────────────────────────────────────────────────────────────

    function toggleGatewayPause() external {
        vm.prank(admin);
        if (gateway.paused()) {
            try gateway.unpause() {} catch {}
        } else {
            try gateway.pause() {} catch {}
        }
    }

    function toggleSettlementPause() external {
        vm.prank(admin);
        if (settlement.paused()) {
            try settlement.unpause() {} catch {}
        } else {
            try settlement.pause() {} catch {}
        }
    }

    function toggleAssetPause(uint256 assetSeed) external {
        AssetToken asset = _pickAsset(assetSeed);
        vm.prank(admin);
        if (asset.paused()) {
            try asset.unpause() {} catch {}
        } else {
            try asset.pause() {} catch {}
        }
    }
}

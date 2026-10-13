// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";

/// @title DemoNiaraFlow
/// @notice Runs the protocol's full flow as real, traceable testnet transactions:
/// requestBacking -> attestBacking -> mintAttested -> settle -> cashback credited ->
/// withdraw. Requires `DeployNiara.executeWiring()` to have completed (roles granted
/// and `backingGateway` configured).
/// @dev Settlement requires two distinct parties (buyer != seller, a structural check in
/// NiaraSettlement.settle). To avoid depending on a second private key supplied by the
/// user, the demo "buyer" is a deterministically derived account (`makeAddrAndKey`) that
/// receives a little test ETH from the deployer just to pay the gas of its own
/// `approve`; it never holds any other value. The issuer (`issuerWallet`) must be the
/// deployer itself (the Deploy.s.sol default) for the `withdraw` step to work here,
/// since this script only has the deployer's private key.
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
        console2.log("Demo buyer (derived):", buyer);

        _runBackingFlow(c, cfg, deployerPrivateKey);
        _fundBuyer(c, cfg, deployerPrivateKey, buyer);
        _runSettleFlow(c, cfg, deployerPrivateKey, buyer, buyerPrivateKey);
        _runCashbackFlow(c, deployerPrivateKey);

        console2.log("");
        console2.log("Demo flow completed successfully.");
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
        // The deployer acts as the seller (receives the mint); only the buyer needs a
        // separate account, because of the buyer != seller check.
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
        console2.log("2) attestBacking OK -> attested quantity", cfg.backingQuantity);

        c.gateway.mintAttested(requestId, cfg.seller);
        console2.log("3) mintAttested -> tokens minted to the seller", cfg.seller);

        vm.stopBroadcast();
    }

    function _fundBuyer(Contracts memory c, DemoConfig memory cfg, uint256 deployerPrivateKey, address buyer)
        internal
    {
        vm.startBroadcast(deployerPrivateKey);
        if (buyer.balance < cfg.buyerGasFunding) {
            (bool ok,) = buyer.call{value: cfg.buyerGasFunding}("");
            require(ok, "buyer funding failed");
        }
        // MockUSDT.mint is public (no access control, test use only), so the deployer can
        // fund the buyer directly without needing the buyer's key.
        c.usdt.mint(buyer, cfg.settlePaymentAmount);
        vm.stopBroadcast();
        console2.log("4) Buyer funded: ETH for gas + demo USDT");
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
        console2.log("5) Seller approved the AssetToken for settlement");

        vm.startBroadcast(buyerPrivateKey);
        c.usdt.approve(address(c.settlement), cfg.settlePaymentAmount);
        vm.stopBroadcast();
        console2.log("6) Buyer approved USDT for settlement");

        vm.startBroadcast(deployerPrivateKey);
        uint256 feeCharged = c.settlement.settle(
            address(c.assetToken), address(c.usdt), buyer, cfg.seller, cfg.settleAssetAmount, cfg.settlePaymentAmount
        );
        vm.stopBroadcast();
        console2.log("7) settle executed -> fee charged", feeCharged);
    }

    function _runCashbackFlow(Contracts memory c, uint256 deployerPrivateKey) internal {
        uint256 cashbackBalance = c.distributor.cashbackBalance(address(c.assetToken), address(c.usdt));
        console2.log("8) Cashback credited to the issuer (balance before withdrawal):", cashbackBalance);

        vm.startBroadcast(deployerPrivateKey);
        c.distributor.withdraw(address(c.assetToken), address(c.usdt));
        vm.stopBroadcast();
        console2.log("9) withdraw executed -> issuer withdrew the cashback");
    }
}

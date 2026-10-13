// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";

/// @title PresentationDemo
/// @notice Demo version for PUBLIC PRESENTATION: each protocol role (seller, buyer,
/// issuing company that receives the cashback, custodian and operator) is a wallet
/// DISTINCT from the others, to make explicit that the cashback goes to a third party
/// outside the trade (the issuing company is neither the buyer nor the seller).
///
/// @dev REUSES the contracts ALREADY deployed by `script/Deploy.s.sol` (`DEPLOYED_*`
/// addresses in `.env`); it deploys nothing new. It only REASSIGNS, through the timelock,
/// the operator/custodian/issuer roles to wallets distinct from those used in the original
/// deploy (which remain valid: this reassignment is additive and revokes nothing).
/// `MINTER_ROLE`/`BURNER_ROLE`/`backingGateway` are already correct since the original
/// deploy and do not need to change.
///
/// Same two-phase structure as the other scripts, because of the real timelock
/// (`MIN_TIMELOCK_DELAY` = 1h, no shortcut possible; see CLAUDE.md):
///
///   PHASE 1, `run()`: derives the 5 role wallets, schedules (propose) the reassignment and
///   funds each derived wallet with a little test ETH (only for its own gas).
///
///   PHASE 2, `executeWiring()`: executes (consumes) the scheduled reassignment, once the
///   delay has really passed on-chain.
///
///   DEMO, `runDemo()`: full flow, each step signed by the wallet of the corresponding role
///   (not by the deployer): requestBacking/mintAttested/settle by the operator,
///   attestBacking by the custodian, approve by the seller and the buyer, withdraw by the
///   issuing company.
///
/// The 5 wallets are derived deterministically from a label (`makeAddrAndKey`); they
/// depend on no private key other than the deployer's (`PRIVATE_KEY`), which funds them.
contract PresentationDemo is Script {
    uint256 internal constant ROLE_GAS_FUNDING_WEI = 0.003 ether;

    /// @dev Grouped in a struct to avoid "stack too deep": a single memory pointer
    /// instead of a dozen simultaneous stack variables.
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

    /// @dev Schedules (propose) the change of operator/custodian/issuer in the ALREADY
    /// deployed contracts. `issuerWallet` is replaced (not additive); the AccessControl roles
    /// are granted on top of the existing ones (additive: the original deployer keeps its
    /// roles; this is not a migration, it is a reassignment for demo purposes).
    function _proposeRewiring(Contracts memory c, Actors memory actors) internal {
        c.gateway.proposeGrantRole(c.gateway.OPERATOR_ROLE(), actors.operator);
        c.gateway.proposeGrantRole(c.gateway.CUSTODIAN_ROLE(), actors.custodian);
        c.settlement.proposeGrantRole(c.settlement.SETTLEMENT_OPERATOR_ROLE(), actors.operator);
        c.assetToken.proposeSetIssuerWallet(actors.issuerWallet);
    }

    /// @dev The role wallets need a little ETH to sign their own transactions in
    /// `executeWiring`/`runDemo`; only the deployer has a starting balance.
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
            require(ok, "presentation wallet funding failed");
        }
    }

    // ── Fase 2 ──────────────────────────────────────────────────────────────────────────

    /// @notice Executes the reassignment scheduled in `run()`. Only broadcast after
    /// `TIMELOCK_DELAY` (from the original deploy) seconds have really passed since
    /// phase 1 of this script.
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

        console2.log("Reassignment complete: presentation roles active on the existing contracts.");
    }

    // ── Demo: each step signed by the wallet of the corresponding role ──────────────────

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
        console2.log("Presentation flow completed successfully.");
    }

    function _runBackingFlow(Contracts memory c, Actors memory actors, uint256 quantity) internal {
        vm.startBroadcast(actors.operatorKey);
        uint256 requestId = c.gateway.requestBacking(address(c.assetToken), quantity);
        console2.log("1) requestBacking (operator) -> requestId", requestId);
        vm.stopBroadcast();

        vm.startBroadcast(actors.custodianKey);
        c.gateway.attestBacking(requestId, keccak256(abi.encode("niara-presentation-proof", requestId)), quantity);
        console2.log("2) attestBacking (custodian) OK -> attested quantity", quantity);
        vm.stopBroadcast();

        vm.startBroadcast(actors.operatorKey);
        c.gateway.mintAttested(requestId, actors.seller);
        console2.log("3) mintAttested (operator) -> tokens minted to the seller", actors.seller);
        vm.stopBroadcast();
    }

    function _fundBuyerWithUsdt(Contracts memory c, address buyer, uint256 amount) internal {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        // MockUSDT.mint is public (no access control, test use only), so the deployer
        // funds the buyer directly without needing the buyer's key.
        c.usdt.mint(buyer, amount);
        vm.stopBroadcast();
        console2.log("4) Buyer funded with demo USDT");
    }

    function _runSettleFlow(Contracts memory c, Actors memory actors, uint256 assetAmount, uint256 paymentAmount)
        internal
    {
        vm.startBroadcast(actors.sellerKey);
        c.assetToken.approve(address(c.settlement), assetAmount);
        vm.stopBroadcast();
        console2.log("5) Seller approved the AssetToken for settlement");

        vm.startBroadcast(actors.buyerKey);
        c.usdt.approve(address(c.settlement), paymentAmount);
        vm.stopBroadcast();
        console2.log("6) Buyer approved USDT for settlement");

        vm.startBroadcast(actors.operatorKey);
        uint256 feeCharged = c.settlement.settle(
            address(c.assetToken), address(c.usdt), actors.buyer, actors.seller, assetAmount, paymentAmount
        );
        vm.stopBroadcast();
        console2.log("7) settle (operator) executed -> fee charged", feeCharged);
    }

    function _runCashbackFlow(Contracts memory c, Actors memory actors) internal {
        uint256 cashbackBalance = c.distributor.cashbackBalance(address(c.assetToken), address(c.usdt));
        console2.log("8) Cashback credited to the issuing company (balance before withdrawal):", cashbackBalance);

        vm.startBroadcast(actors.issuerKey);
        c.distributor.withdraw(address(c.assetToken), address(c.usdt));
        vm.stopBroadcast();
        console2.log("9) withdraw (issuing company) executed -> cashback withdrawn");
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
        console2.log("== Presentation roles (distinct wallets) ==");
        console2.log("Admin (deployer / governance):", a.admin);
        console2.log("Operator (requestBacking, mintAttested, settle):", a.operator);
        console2.log("Custodian (attestBacking):", a.custodian);
        console2.log("Issuing company (issuerWallet, receives the cashback):", a.issuerWallet);
        console2.log("Seller (delivers the AssetToken at settlement):", a.seller);
        console2.log("Buyer (pays at settlement):", a.buyer);
        console2.log("");
    }

    function _logNextSteps() internal pure {
        console2.log("== Next step ==");
        console2.log("Reassignment scheduled (propose). Wait for the timelock and run phase 2:");
        console2.log('forge script script/PresentationDemo.s.sol --sig "executeWiring()" --rpc-url sepolia --broadcast');
        console2.log("After that, run the demo:");
        console2.log('forge script script/PresentationDemo.s.sol --sig "runDemo()" --rpc-url sepolia --broadcast');
    }
}

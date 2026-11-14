// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NiaraScriptBase} from "./NiaraScriptBase.sol";
import {P2PEscrow} from "../src/P2PEscrow.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";

/// @title DemoNiaraFlows
/// @notice Runs the v1 exchange end to end as real, traceable testnet transactions, on a
/// deployment made by `Deploy.s.sol` (both phases complete). Three flows, one per trading
/// mode and asset class:
///
///   1. EQUITY, order book: the issuer creates a share and submits its listing, the
///      listing authority quotes the listing fee and the issuer pays it in mock USDT (which
///      approves the listing, spec §3.13), the issuer requests an issuance batch, the
///      listing authority approves it (the registry mints), the operator settles a matched
///      order between the two investors, and the issuer withdraws its cashback.
///   2. FIXED INCOME, P2P deal: the issuer creates a bond, pays its quoted listing fee and
///      issues a batch; investor A opens a deal selling bonds to investor B (escrowing the
///      bonds), B accepts paying mock USDT, and the issuer withdraws its cashback.
///   3. CURRENCY, P2P deal: investor B opens a deal buying mock BRL from investor A with
///      mock USDT (escrowing the USDT), A accepts delivering the BRL. A receives the USDT
///      and pays the fee; a currency deal never accrues cashback.
///
/// Every step is signed by the wallet of its role, and the SIX ROLES ARE DISTINCT WALLETS
/// (the script refuses to run otherwise): deployer/admin, listing authority, settlement
/// operator, issuing company, investor A and investor B. That makes the separation of
/// powers visible on the explorer: neither the issuer nor Niara mints alone, the operator
/// only settles, and the cashback goes to a third party that is neither buyer nor seller.
/// The deployer takes no part in the flows; it only tops up the other wallets' gas.
///
/// Everything moved is a TEST token with no value: the instruments created here are named
/// "(TEST)", and the currencies are the deployment's mock USDT and mock BRL.
///
/// Signers are named by address in the environment and sign through Foundry keystores
/// (`--account`, once per wallet). This script never reads a private key.
///
/// @dev Each run creates new instruments, so it can be repeated. The instruments' addresses
/// come from the public factory's nonce: if someone else created a token through the factory
/// between the dry run and the broadcast, the addresses baked into the later transactions
/// would be wrong and those transactions would revert (nothing is lost; run it again).
contract DemoNiaraFlows is NiaraScriptBase {
    uint256 public constant DEFAULT_GAS_FUNDING = 0.02 ether;

    // Flow 1: equity.
    uint256 public constant EQUITY_BATCH = 1_000 ether;
    uint256 public constant EQUITY_TRADE = 100 ether;
    uint256 public constant EQUITY_PRICE = 10_000e6;
    // Flow 2: fixed income.
    uint256 public constant BOND_BATCH = 500 ether;
    uint256 public constant BOND_TRADE = 50 ether;
    uint256 public constant BOND_PRICE = 5_000e6;
    // Flow 3: currency (5.50 mock BRL per mock USDT).
    uint256 public constant FX_BRL_AMOUNT = 5_500e6;
    uint256 public constant FX_USDT_AMOUNT = 1_000e6;

    uint64 public constant DEAL_LIFETIME = 1 days;

    // Listing fee (spec §3.13), quoted for flows 1 and 2: a 1,000,000 mock USDT valuation at
    // 10 bps (the 0.1% pricing floor) is a 1,000 mock USDT fee, paid by the issuer.
    uint256 public constant LISTING_VALUATION = 1_000_000e6;
    uint16 public constant LISTING_FEE_BPS = 10;
    uint64 public constant QUOTE_LIFETIME = 7 days;

    struct Roles {
        /// @dev Admin of the deployment. Only funds the other wallets' gas.
        address deployer;
        address listingAuthority;
        address operator;
        /// @dev The issuing company: creates the instruments, requests issuance, receives
        /// the cashback.
        address issuer;
        address investorA;
        address investorB;
    }

    /// @dev What one flow changed, for the logs and the checks.
    struct Outcome {
        address instrument;
        uint256 fee;
        uint256 cashback;
        /// @dev Listing fee the issuer paid for the instrument; zero for the currency flow.
        uint256 listingFee;
    }

    error RolesNotDistinct(string first, string second);
    error ZeroRoleAddress(string what);
    error DemoNotReady(string what);
    error DemoCheckFailed(string what);

    // ── Entry points ───────────────────────────────────────────────────────────────────

    /// @notice Gas top-up, then the three flows.
    function run() external {
        Roles memory roles = readRoles();
        Deployment memory d = readDeployment();
        fundGas(roles, vm.envOr("DEMO_GAS_FUNDING_WEI", DEFAULT_GAS_FUNDING));
        runAll(roles, d);
    }

    /// @notice Flow 1 only (equity, order book).
    function runEquityFlow() external {
        equityFlow(readRoles(), readDeployment());
    }

    /// @notice Flow 2 only (fixed income, P2P deal).
    function runFixedIncomeFlow() external {
        fixedIncomeFlow(readRoles(), readDeployment());
    }

    /// @notice Flow 3 only (currency, P2P deal).
    function runCurrencyFlow() external {
        currencyFlow(readRoles(), readDeployment());
    }

    /// @notice Only the gas top-up of the five role wallets by the deployer.
    function runFundGas() external {
        fundGas(readRoles(), vm.envOr("DEMO_GAS_FUNDING_WEI", DEFAULT_GAS_FUNDING));
    }

    // ── Roles ──────────────────────────────────────────────────────────────────────────

    /// @notice Reads the six role addresses from the environment. All are required.
    /// @return roles The roles.
    function readRoles() public view returns (Roles memory roles) {
        roles.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        roles.listingAuthority = vm.envAddress("LISTING_AUTHORITY_ADDRESS");
        roles.operator = vm.envAddress("OPERATOR_ADDRESS");
        roles.issuer = vm.envAddress("DEMO_ISSUER_ADDRESS");
        roles.investorA = vm.envAddress("DEMO_INVESTOR_A_ADDRESS");
        roles.investorB = vm.envAddress("DEMO_INVESTOR_B_ADDRESS");
    }

    /// @notice Reverts unless the six roles are six different, non-zero addresses.
    /// @param roles The roles.
    function requireDistinctRoles(Roles memory roles) public pure {
        address[6] memory wallets = [
            roles.deployer, roles.listingAuthority, roles.operator, roles.issuer, roles.investorA, roles.investorB
        ];
        string[6] memory names =
            ["deployer", "listing authority", "operator", "issuer", "investor A", "investor B"];
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] == address(0)) revert ZeroRoleAddress(names[i]);
            for (uint256 j = i + 1; j < wallets.length; j++) {
                if (wallets[i] == wallets[j]) revert RolesNotDistinct(names[i], names[j]);
            }
        }
    }

    /// @notice Reverts unless the deployment can trade and the role wallets hold the roles
    /// the flows need (deploy phase 2 complete, protocol not paused).
    /// @param roles The roles.
    /// @param d The deployment.
    function requireReady(Roles memory roles, Deployment memory d) public view {
        _requireSupportedChain();
        requireDistinctRoles(roles);
        if (d.registry.paused()) revert DemoNotReady("protocol is paused");
        if (!d.registry.hasRole(d.registry.LISTING_AUTHORITY_ROLE(), roles.listingAuthority)) {
            revert DemoNotReady("listing authority lacks LISTING_AUTHORITY_ROLE");
        }
        if (!d.settlement.hasRole(d.settlement.SETTLEMENT_OPERATOR_ROLE(), roles.operator)) {
            revert DemoNotReady("operator lacks SETTLEMENT_OPERATOR_ROLE (deploy phase 2 not run?)");
        }
        if (!d.distributor.hasRole(d.distributor.SETTLEMENT_ROLE(), address(d.settlement))) {
            revert DemoNotReady("NiaraSettlement lacks SETTLEMENT_ROLE (deploy phase 2 not run?)");
        }
        if (!d.distributor.hasRole(d.distributor.ESCROW_ROLE(), address(d.escrow))) {
            revert DemoNotReady("P2PEscrow lacks ESCROW_ROLE (deploy phase 2 not run?)");
        }
        if (address(d.registry.settlement()) != address(d.settlement)) {
            revert DemoNotReady("registry not linked to NiaraSettlement (deploy phase 2 not run?)");
        }
        if (!d.distributor.hasRole(d.distributor.LISTING_REGISTRY_ROLE(), address(d.registry))) {
            revert DemoNotReady("ListingRegistry lacks LISTING_REGISTRY_ROLE (deploy phase 2 not run?)");
        }
        if (!_approvedCurrency(d, address(d.mockUsdt))) revert DemoNotReady("mock USDT is not an Approved Currency");
        if (!_approvedCurrency(d, address(d.mockBrl))) revert DemoNotReady("mock BRL is not an Approved Currency");
    }

    // ── Gas top-up ─────────────────────────────────────────────────────────────────────

    /// @notice The deployer tops up each of the five role wallets to `target` wei of test
    /// ETH, so they can pay their own gas. Wallets already at or above `target` get
    /// nothing; `target == 0` disables it (fund the wallets yourself).
    /// @param roles The roles.
    /// @param target Balance each role wallet should have at least.
    function fundGas(Roles memory roles, uint256 target) public {
        _requireSupportedChain();
        requireDistinctRoles(roles);
        if (target == 0) return;
        address[5] memory wallets =
            [roles.listingAuthority, roles.operator, roles.issuer, roles.investorA, roles.investorB];

        vm.startBroadcast(roles.deployer);
        for (uint256 i = 0; i < wallets.length; i++) {
            uint256 balance = wallets[i].balance;
            if (balance >= target) continue;
            (bool ok,) = wallets[i].call{value: target - balance}("");
            if (!ok) revert DemoCheckFailed("gas top-up transfer failed");
        }
        vm.stopBroadcast();
    }

    // ── The three flows ────────────────────────────────────────────────────────────────

    /// @notice Runs the three flows in order.
    /// @param roles The roles.
    /// @param d The deployment.
    function runAll(Roles memory roles, Deployment memory d) public {
        console2.log("Niara demo on", chainName(), "- test tokens only, no value");
        _logRoles(roles);
        equityFlow(roles, d);
        fixedIncomeFlow(roles, d);
        currencyFlow(roles, d);
        console2.log("");
        console2.log("All three flows completed and checked.");
    }

    /// @notice FLOW 1, equity on the order book: listing fee -> issuance batch -> settle ->
    /// cashback withdrawal. Investor B is the seller (it receives the issued batch), investor A the
    /// buyer.
    /// @param roles The roles.
    /// @param d The deployment.
    /// @return out The share created, the fee charged and the cashback withdrawn.
    function equityFlow(Roles memory roles, Deployment memory d) public returns (Outcome memory out) {
        requireReady(roles, d);
        console2.log("");
        console2.log("== Flow 1: EQUITY, order book (listing fee -> issuance batch -> settle -> cashback) ==");

        (out.instrument, out.listingFee) = _issueInstrument(
            roles,
            d,
            "Niara Demo Equity (TEST)",
            "tEQTY",
            IListingRegistry.AssetClass.Equity,
            roles.investorB,
            EQUITY_BATCH
        );
        IERC20 share = IERC20(out.instrument);
        IERC20 usdt = IERC20(address(d.mockUsdt));
        (out.fee, out.cashback) = _expectedFee(d, EQUITY_PRICE, true);
        uint256 sellerUsdtBefore = usdt.balanceOf(roles.investorB);
        uint256 issuerUsdtBefore = usdt.balanceOf(roles.issuer);

        vm.startBroadcast(roles.investorB);
        share.approve(address(d.settlement), EQUITY_TRADE);
        vm.stopBroadcast();
        console2.log("1.6 seller (investor B) approved the shares for NiaraSettlement");

        vm.startBroadcast(roles.investorA);
        d.mockUsdt.mint(roles.investorA, EQUITY_PRICE);
        usdt.approve(address(d.settlement), EQUITY_PRICE);
        vm.stopBroadcast();
        console2.log("1.7 buyer (investor A) took mock USDT from the faucet and approved it");

        // The match id is the off-chain match UUID; here it is derived from the new share,
        // so every run uses a fresh one (a match settles at most once).
        bytes16 matchId = bytes16(keccak256(abi.encode("niara-demo-match", block.chainid, out.instrument)));
        vm.startBroadcast(roles.operator);
        uint256 feeCharged = d.settlement.settle(
            matchId, out.instrument, address(usdt), roles.investorA, roles.investorB, EQUITY_TRADE, EQUITY_PRICE
        );
        vm.stopBroadcast();
        console2.log("1.8 operator settled the match -> fee (mock USDT, 6 decimals):", feeCharged);

        vm.startBroadcast(roles.issuer);
        d.distributor.withdraw(out.instrument, address(usdt));
        vm.stopBroadcast();
        console2.log("1.9 issuer withdrew its cashback (mock USDT, 6 decimals):", out.cashback);

        if (feeCharged != out.fee) revert DemoCheckFailed("equity: fee");
        if (share.balanceOf(roles.investorA) != EQUITY_TRADE) revert DemoCheckFailed("equity: buyer shares");
        if (share.balanceOf(roles.investorB) != EQUITY_BATCH - EQUITY_TRADE) {
            revert DemoCheckFailed("equity: seller shares");
        }
        if (usdt.balanceOf(roles.investorB) != sellerUsdtBefore + EQUITY_PRICE - out.fee) {
            revert DemoCheckFailed("equity: seller proceeds");
        }
        if (usdt.balanceOf(roles.issuer) != issuerUsdtBefore + out.cashback) {
            revert DemoCheckFailed("equity: issuer cashback");
        }
        if (d.distributor.cashbackBalance(out.instrument, address(usdt)) != 0) {
            revert DemoCheckFailed("equity: cashback left behind");
        }
        if (!d.settlement.settledMatches(matchId)) revert DemoCheckFailed("equity: match not marked settled");
    }

    /// @notice FLOW 2, fixed income as a P2P deal: the issuer pays the bond's listing fee;
    /// investor A (holder of the issued batch) opens a deal selling bonds to investor B and
    /// escrows them; B accepts paying mock
    /// USDT; A, who receives the USDT, pays the fee; the issuer withdraws its cashback.
    /// @param roles The roles.
    /// @param d The deployment.
    /// @return out The bond created, the fee charged and the cashback withdrawn.
    function fixedIncomeFlow(Roles memory roles, Deployment memory d) public returns (Outcome memory out) {
        requireReady(roles, d);
        console2.log("");
        console2.log("== Flow 2: FIXED INCOME, P2P deal (listing fee -> escrow -> accept -> cashback) ==");

        (out.instrument, out.listingFee) = _issueInstrument(
            roles,
            d,
            "Niara Demo Bond 2030 (TEST)",
            "tBOND",
            IListingRegistry.AssetClass.FixedIncome,
            roles.investorA,
            BOND_BATCH
        );
        IERC20 bond = IERC20(out.instrument);
        IERC20 usdt = IERC20(address(d.mockUsdt));
        (out.fee, out.cashback) = _expectedFee(d, BOND_PRICE, true);
        uint256 sellerUsdtBefore = usdt.balanceOf(roles.investorA);
        uint256 issuerUsdtBefore = usdt.balanceOf(roles.issuer);

        P2PEscrow.DealTerms memory terms = P2PEscrow.DealTerms({
            counterparty: roles.investorB,
            assetToken: out.instrument,
            paymentToken: address(usdt),
            proposerSide: P2PEscrow.DealSide.Sell,
            assetAmount: BOND_TRADE,
            paymentAmount: BOND_PRICE
        });
        bytes16 dealId = _freshDealId(d, roles.investorA, "niara-demo-bond-deal");
        uint64 expiresAt = uint64(block.timestamp) + DEAL_LIFETIME;

        vm.startBroadcast(roles.investorA);
        bond.approve(address(d.escrow), BOND_TRADE);
        bytes32 dealKey = d.escrow.openDeal(dealId, terms, expiresAt);
        vm.stopBroadcast();
        console2.log("2.6 investor A opened the deal and escrowed the bonds; deal key:");
        console2.logBytes32(dealKey);

        vm.startBroadcast(roles.investorB);
        d.mockUsdt.mint(roles.investorB, BOND_PRICE);
        usdt.approve(address(d.escrow), BOND_PRICE);
        d.escrow.acceptDeal(dealKey);
        vm.stopBroadcast();
        console2.log("2.7 investor B accepted, paying mock USDT -> fee (6 decimals):", out.fee);

        vm.startBroadcast(roles.issuer);
        d.distributor.withdraw(out.instrument, address(usdt));
        vm.stopBroadcast();
        console2.log("2.8 issuer withdrew its cashback (mock USDT, 6 decimals):", out.cashback);

        if (d.escrow.getDeal(dealKey).status != P2PEscrow.DealStatus.Executed) {
            revert DemoCheckFailed("bond: deal not executed");
        }
        if (bond.balanceOf(roles.investorB) != BOND_TRADE) revert DemoCheckFailed("bond: buyer bonds");
        if (bond.balanceOf(roles.investorA) != BOND_BATCH - BOND_TRADE) revert DemoCheckFailed("bond: seller bonds");
        if (usdt.balanceOf(roles.investorA) != sellerUsdtBefore + BOND_PRICE - out.fee) {
            revert DemoCheckFailed("bond: seller proceeds");
        }
        if (usdt.balanceOf(roles.issuer) != issuerUsdtBefore + out.cashback) {
            revert DemoCheckFailed("bond: issuer cashback");
        }
        if (d.escrow.totalEscrowed(out.instrument) != 0) revert DemoCheckFailed("bond: escrow not released");
    }

    /// @notice FLOW 3, currency as a P2P deal: investor B opens a deal BUYING mock BRL from
    /// investor A with mock USDT and escrows the USDT; A accepts delivering the BRL. A
    /// receives the USDT, so A pays the fee; B receives its BRL in full. No cashback: a
    /// `Currency` listing never accrues any.
    /// @param roles The roles.
    /// @param d The deployment.
    /// @return out The mock BRL, the fee charged and a zero cashback.
    function currencyFlow(Roles memory roles, Deployment memory d) public returns (Outcome memory out) {
        requireReady(roles, d);
        console2.log("");
        console2.log("== Flow 3: CURRENCY, P2P deal (mock BRL <-> mock USDT, no cashback) ==");

        out.instrument = address(d.mockBrl);
        IERC20 brl = IERC20(address(d.mockBrl));
        IERC20 usdt = IERC20(address(d.mockUsdt));
        (out.fee, out.cashback) = _expectedFee(d, FX_USDT_AMOUNT, false);
        uint256 aUsdtBefore = usdt.balanceOf(roles.investorA);
        uint256 bBrlBefore = brl.balanceOf(roles.investorB);
        uint256 protocolBefore = d.distributor.protocolBalance(address(usdt));

        P2PEscrow.DealTerms memory terms = P2PEscrow.DealTerms({
            counterparty: roles.investorA,
            assetToken: address(brl),
            paymentToken: address(usdt),
            proposerSide: P2PEscrow.DealSide.Buy,
            assetAmount: FX_BRL_AMOUNT,
            paymentAmount: FX_USDT_AMOUNT
        });
        bytes16 dealId = _freshDealId(d, roles.investorB, "niara-demo-fx-deal");
        uint64 expiresAt = uint64(block.timestamp) + DEAL_LIFETIME;

        vm.startBroadcast(roles.investorB);
        d.mockUsdt.mint(roles.investorB, FX_USDT_AMOUNT);
        usdt.approve(address(d.escrow), FX_USDT_AMOUNT);
        bytes32 dealKey = d.escrow.openDeal(dealId, terms, expiresAt);
        vm.stopBroadcast();
        console2.log("3.1 investor B opened the deal and escrowed the mock USDT; deal key:");
        console2.logBytes32(dealKey);

        vm.startBroadcast(roles.investorA);
        d.mockBrl.mint(roles.investorA, FX_BRL_AMOUNT);
        brl.approve(address(d.escrow), FX_BRL_AMOUNT);
        d.escrow.acceptDeal(dealKey);
        vm.stopBroadcast();
        console2.log("3.2 investor A accepted, delivering mock BRL -> fee (mock USDT, 6 decimals):", out.fee);

        if (d.escrow.getDeal(dealKey).status != P2PEscrow.DealStatus.Executed) {
            revert DemoCheckFailed("fx: deal not executed");
        }
        if (brl.balanceOf(roles.investorB) != bBrlBefore + FX_BRL_AMOUNT) revert DemoCheckFailed("fx: BRL leg");
        if (usdt.balanceOf(roles.investorA) != aUsdtBefore + FX_USDT_AMOUNT - out.fee) {
            revert DemoCheckFailed("fx: USDT leg minus fee");
        }
        if (d.distributor.cashbackBalance(address(brl), address(usdt)) != 0) {
            revert DemoCheckFailed("fx: a currency accrued cashback");
        }
        if (d.distributor.protocolBalance(address(usdt)) != protocolBefore + out.fee) {
            revert DemoCheckFailed("fx: protocol fee");
        }
        if (d.escrow.totalEscrowed(address(usdt)) != 0) revert DemoCheckFailed("fx: escrow not released");
    }

    // ── Shared steps ───────────────────────────────────────────────────────────────────

    /// @dev Steps 1 to 5 of flows 1 and 2: the issuer creates the instrument through the
    /// factory and submits its listing; the listing authority quotes the listing fee; the
    /// issuer pays it in mock USDT, which approves the listing (spec §3.13); the issuer
    /// requests an issuance batch; the listing authority approves it and the registry mints.
    /// Neither the issuer nor Niara can mint alone.
    function _issueInstrument(
        Roles memory roles,
        Deployment memory d,
        string memory name,
        string memory symbol,
        IListingRegistry.AssetClass assetClass,
        address recipient,
        uint256 amount
    ) internal returns (address instrument, uint256 listingFee) {
        // The hashes stand in for the offering document and the corporate act authorizing
        // the batch (registered in Niara-Register in the real flow).
        bytes32 docHash = keccak256(abi.encode("niara-demo-offering-document", name));
        bytes32 batchDocHash = keccak256(abi.encode("niara-demo-issuance-act", name));

        vm.startBroadcast(roles.issuer);
        instrument = d.factory.createAssetToken(name, symbol, assetClass, docHash);
        d.registry.submitListing(instrument);
        vm.stopBroadcast();
        console2.log(string.concat(".1 issuer created and submitted: ", name), instrument);

        listingFee = _payListingFee(roles, d, instrument);

        vm.startBroadcast(roles.issuer);
        uint256 batchNo = d.registry.requestIssuance(instrument, amount, recipient, batchDocHash);
        vm.stopBroadcast();
        console2.log(".4 issuer requested issuance batch no.", batchNo);

        vm.startBroadcast(roles.listingAuthority);
        d.registry.approveIssuance(instrument, batchNo);
        vm.stopBroadcast();
        console2.log(".5 listing authority approved the batch; the registry minted it to", recipient);

        if (IERC20(instrument).balanceOf(recipient) != amount) revert DemoCheckFailed("issuance: recipient balance");
        if (IERC20(instrument).totalSupply() != amount) revert DemoCheckFailed("issuance: total supply");
        if (NativeAssetToken(instrument).issuer() != roles.issuer) revert DemoCheckFailed("issuance: issuer");
    }

    /// @dev Steps 2 and 3: the listing authority quotes the listing fee; the issuer takes
    /// exactly that from the mock USDT faucet and pays it, which approves the listing. The
    /// fee goes to the CashbackDistributor as protocol revenue, with no cashback share.
    function _payListingFee(Roles memory roles, Deployment memory d, address instrument)
        internal
        returns (uint256 listingFee)
    {
        IERC20 usdt = IERC20(address(d.mockUsdt));
        listingFee = (LISTING_VALUATION * LISTING_FEE_BPS + 9_999) / 10_000;
        uint256 issuerUsdtBefore = usdt.balanceOf(roles.issuer);
        uint256 distributorUsdtBefore = usdt.balanceOf(address(d.distributor));
        uint256 protocolBefore = d.distributor.protocolBalance(address(usdt));

        vm.startBroadcast(roles.listingAuthority);
        d.registry.quoteListing(
            instrument, LISTING_VALUATION, LISTING_FEE_BPS, uint64(block.timestamp) + QUOTE_LIFETIME
        );
        vm.stopBroadcast();
        console2.log(".2 listing authority quoted the listing fee (mock USDT, 6 decimals):", listingFee);

        vm.startBroadcast(roles.issuer);
        d.mockUsdt.mint(roles.issuer, listingFee);
        usdt.approve(address(d.registry), listingFee);
        d.registry.payListingFee(instrument);
        vm.stopBroadcast();
        console2.log(".3 issuer took mock USDT from the faucet and paid it; the listing is approved");

        ListingRegistry.ListingFeeQuote memory quote = d.registry.getListingFeeQuote(instrument);
        if (quote.listingFee != listingFee || quote.listingFeePaid != listingFee) {
            revert DemoCheckFailed("listing fee: quote");
        }
        if (!d.registry.isApproved(instrument)) revert DemoCheckFailed("listing fee: listing not approved");
        if (usdt.balanceOf(roles.issuer) != issuerUsdtBefore) revert DemoCheckFailed("listing fee: issuer paid");
        if (usdt.balanceOf(address(d.distributor)) != distributorUsdtBefore + listingFee) {
            revert DemoCheckFailed("listing fee: distributor balance");
        }
        if (d.distributor.protocolBalance(address(usdt)) != protocolBefore + listingFee) {
            revert DemoCheckFailed("listing fee: protocol revenue");
        }
        if (d.distributor.cashbackBalance(instrument, address(usdt)) != 0) {
            revert DemoCheckFailed("listing fee: credited cashback");
        }
    }

    /// @dev The fee the protocol must charge on `usdtAmount` at the current rates
    /// (`ceil(usdtAmount * feeBps / 10_000)`) and the issuer's share of it (rounded down;
    /// zero for a currency). The deals of this script open and execute in the same run, so
    /// the current rates are the ones the deal carries.
    function _expectedFee(Deployment memory d, uint256 usdtAmount, bool cashbackEligible)
        internal
        view
        returns (uint256 fee, uint256 cashback)
    {
        fee = (usdtAmount * d.settlement.feeBps() + 9_999) / 10_000;
        if (cashbackEligible) cashback = (fee * d.distributor.cashbackBps()) / 10_000;
    }

    /// @dev A deal id this proposer has never used (ids can never be reopened), found by
    /// asking the escrow, so the script can be run any number of times.
    function _freshDealId(Deployment memory d, address proposer, string memory label)
        internal
        view
        returns (bytes16 dealId)
    {
        for (uint256 i = 0; i < 10_000; i++) {
            dealId = bytes16(keccak256(abi.encode(label, block.chainid, i)));
            if (d.escrow.getDeal(d.escrow.dealKeyOf(proposer, dealId)).status == P2PEscrow.DealStatus.None) {
                return dealId;
            }
        }
        revert DemoCheckFailed("no free deal id");
    }

    function _approvedCurrency(Deployment memory d, address token) internal view returns (bool) {
        IListingRegistry.Listing memory listing = d.registry.getListing(token);
        return listing.status == IListingRegistry.ListingStatus.Approved
            && listing.assetClass == IListingRegistry.AssetClass.Currency;
    }

    function _logRoles(Roles memory roles) internal pure {
        console2.log("Deployer / admin (gas top-up only):", roles.deployer);
        console2.log("Listing authority:                 ", roles.listingAuthority);
        console2.log("Settlement operator:               ", roles.operator);
        console2.log("Issuing company:                   ", roles.issuer);
        console2.log("Investor A:                        ", roles.investorA);
        console2.log("Investor B:                        ", roles.investorB);
    }
}

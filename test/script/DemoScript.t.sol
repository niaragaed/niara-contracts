// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployNiara} from "../../script/Deploy.s.sol";
import {DemoNiaraFlows} from "../../script/Demo.s.sol";
import {NiaraScriptBase} from "../../script/NiaraScriptBase.sol";
import {NativeAssetToken} from "../../src/NativeAssetToken.sol";
import {ListingRegistry} from "../../src/ListingRegistry.sol";
import {NiaraSettlement} from "../../src/NiaraSettlement.sol";
import {IListingRegistry} from "../../src/interfaces/IListingRegistry.sol";

/// @notice Runs `script/Demo.s.sol` in-process on top of a deployment made by
/// `script/Deploy.s.sol` (both phases). Inside a test `vm.startBroadcast(address)` behaves
/// like a prank, so each step runs as the wallet of its role and fails if that wallet lacks
/// the role on-chain: this checks the script's logic and its figures, it sends nothing.
contract DemoScriptTest is Test {
    DeployNiara internal deployScript;
    DemoNiaraFlows internal demo;
    DeployNiara.Config internal cfg;
    NiaraScriptBase.Deployment internal d;
    DemoNiaraFlows.Roles internal roles;

    IERC20 internal usdt;
    IERC20 internal brl;

    function setUp() public {
        vm.chainId(11155111);
        deployScript = new DeployNiara();
        demo = new DemoNiaraFlows();

        roles = DemoNiaraFlows.Roles({
            deployer: makeAddr("deployer"),
            listingAuthority: makeAddr("listingAuthority"),
            operator: makeAddr("operator"),
            issuer: makeAddr("issuer"),
            investorA: makeAddr("investorA"),
            investorB: makeAddr("investorB")
        });
        cfg = DeployNiara.Config({
            deployer: roles.deployer,
            listingAuthority: roles.listingAuthority,
            operator: roles.operator,
            timelockDelay: 1 hours,
            cashbackBps: 2_000
        });

        d = deployScript.deployAndPropose(cfg);
        vm.warp(block.timestamp + cfg.timelockDelay);
        deployScript.executeWiringOn(cfg, d);

        usdt = IERC20(address(d.mockUsdt));
        brl = IERC20(address(d.mockBrl));
    }

    // ── Flow 1: equity ─────────────────────────────────────────────────────────────────

    /// @notice 100 shares for 10,000 mock USDT at 50 bps: fee 50, of which 20% (10) is the
    /// issuer's cashback and 40 stays with the protocol, on top of the 1,000 mock USDT
    /// listing fee (all protocol revenue).
    function test_EquityFlow_IssuesSettlesAndPaysCashback() public {
        DemoNiaraFlows.Outcome memory out = demo.equityFlow(roles, d);

        assertEq(out.fee, 50e6);
        assertEq(out.cashback, 10e6);
        assertEq(out.listingFee, 1_000e6);

        IERC20 share = IERC20(out.instrument);
        assertEq(share.totalSupply(), 1_000 ether);
        assertEq(share.balanceOf(roles.investorA), 100 ether);
        assertEq(share.balanceOf(roles.investorB), 900 ether);

        assertEq(usdt.balanceOf(roles.investorA), 0);
        assertEq(usdt.balanceOf(roles.investorB), 9_950e6);
        assertEq(usdt.balanceOf(roles.issuer), 10e6);
        assertEq(usdt.balanceOf(address(d.distributor)), 1_040e6);
        assertEq(d.distributor.protocolBalance(address(usdt)), 1_040e6);
        assertEq(d.distributor.cashbackBalance(out.instrument, address(usdt)), 0);
    }

    /// @notice The share is approved by the listing fee (spec §3.13): 1,000,000 mock USDT
    /// valuation at 10 bps, quoted by the listing authority and paid by the issuer.
    function test_EquityFlow_PaysTheQuotedListingFee() public {
        DemoNiaraFlows.Outcome memory out = demo.equityFlow(roles, d);

        ListingRegistry.ListingFeeQuote memory quote = d.registry.getListingFeeQuote(out.instrument);
        assertEq(quote.valuation, 1_000_000e6);
        assertEq(quote.listingFeeBps, 10);
        assertEq(quote.listingFee, 1_000e6);
        assertEq(quote.listingFeePaid, 1_000e6);
        assertEq(quote.listingFeeToken, address(usdt));
        assertEq(d.distributor.listingFeesCollected(address(usdt)), 1_000e6);
    }

    function test_EquityFlow_CreatesAnApprovedEquityListingNamedAsATest() public {
        DemoNiaraFlows.Outcome memory out = demo.equityFlow(roles, d);
        NativeAssetToken share = NativeAssetToken(out.instrument);

        assertEq(share.name(), "Niara Demo Equity (TEST)");
        assertEq(share.symbol(), "tEQTY");
        assertEq(share.issuer(), roles.issuer);
        assertTrue(d.factory.isFactoryToken(out.instrument));

        IListingRegistry.Listing memory listing = d.registry.getListing(out.instrument);
        assertEq(uint8(listing.status), uint8(IListingRegistry.ListingStatus.Approved));
        assertEq(uint8(listing.assetClass), uint8(IListingRegistry.AssetClass.Equity));
        assertEq(listing.issuer, roles.issuer);
        assertEq(d.registry.nextBatchNo(out.instrument), 2);
    }

    // ── Flow 2: fixed income ───────────────────────────────────────────────────────────

    /// @notice 50 bonds for 5,000 mock USDT: fee 25, cashback 5, protocol 20 (plus the bond's
    /// 1,000 mock USDT listing fee). The seller (investor A, the proposer) receives the USDT
    /// and pays the fee.
    function test_FixedIncomeFlow_DealExecutesAndPaysCashback() public {
        DemoNiaraFlows.Outcome memory out = demo.fixedIncomeFlow(roles, d);

        assertEq(out.fee, 25e6);
        assertEq(out.cashback, 5e6);
        assertEq(out.listingFee, 1_000e6);

        IERC20 bond = IERC20(out.instrument);
        assertEq(bond.totalSupply(), 500 ether);
        assertEq(bond.balanceOf(roles.investorB), 50 ether);
        assertEq(bond.balanceOf(roles.investorA), 450 ether);
        assertEq(bond.balanceOf(address(d.escrow)), 0);
        assertEq(d.escrow.totalEscrowed(out.instrument), 0);

        assertEq(usdt.balanceOf(roles.investorA), 4_975e6);
        assertEq(usdt.balanceOf(roles.investorB), 0);
        assertEq(usdt.balanceOf(roles.issuer), 5e6);
        assertEq(d.distributor.protocolBalance(address(usdt)), 1_020e6);
    }

    function test_FixedIncomeFlow_CreatesAnApprovedFixedIncomeListingNamedAsATest() public {
        DemoNiaraFlows.Outcome memory out = demo.fixedIncomeFlow(roles, d);
        NativeAssetToken bond = NativeAssetToken(out.instrument);

        assertEq(bond.name(), "Niara Demo Bond 2030 (TEST)");
        assertEq(bond.symbol(), "tBOND");
        IListingRegistry.Listing memory listing = d.registry.getListing(out.instrument);
        assertEq(uint8(listing.status), uint8(IListingRegistry.ListingStatus.Approved));
        assertEq(uint8(listing.assetClass), uint8(IListingRegistry.AssetClass.FixedIncome));
    }

    // ── Flow 3: currency ───────────────────────────────────────────────────────────────

    /// @notice 5,500 mock BRL for 1,000 mock USDT: investor A receives the USDT and pays the
    /// fee (5); investor B gets its BRL in full; no cashback, the whole fee is the protocol's.
    function test_CurrencyFlow_UsdtReceiverPaysTheFeeAndNoCashbackAccrues() public {
        DemoNiaraFlows.Outcome memory out = demo.currencyFlow(roles, d);

        assertEq(out.instrument, address(brl));
        assertEq(out.fee, 5e6);
        assertEq(out.cashback, 0);
        assertEq(out.listingFee, 0, "a currency pays no listing fee");

        assertEq(brl.balanceOf(roles.investorB), 5_500e6);
        assertEq(brl.balanceOf(roles.investorA), 0);
        assertEq(usdt.balanceOf(roles.investorA), 995e6);
        assertEq(usdt.balanceOf(roles.investorB), 0);
        assertEq(usdt.balanceOf(address(d.escrow)), 0);
        assertEq(brl.balanceOf(address(d.escrow)), 0);

        assertEq(d.distributor.cashbackBalance(address(brl), address(usdt)), 0);
        assertEq(d.distributor.protocolBalance(address(usdt)), 5e6);
        assertEq(usdt.balanceOf(roles.issuer), 0);
    }

    // ── All three ──────────────────────────────────────────────────────────────────────

    /// @notice The three flows together: fees 50 + 25 + 5 = 80 mock USDT, of which 15 went to
    /// the issuer as cashback and 65 is protocol revenue, plus two listing fees of 1,000
    /// (protocol revenue, no cashback): 2,065 in the distributor.
    function test_RunAll_TotalsAcrossTheThreeFlows() public {
        demo.runAll(roles, d);

        assertEq(usdt.balanceOf(roles.issuer), 15e6);
        assertEq(d.distributor.protocolBalance(address(usdt)), 2_065e6);
        assertEq(d.distributor.listingFeesCollected(address(usdt)), 2_000e6);
        assertEq(usdt.balanceOf(address(d.distributor)), 2_065e6);
        assertEq(brl.balanceOf(address(d.distributor)), 0);
        assertEq(usdt.balanceOf(address(d.escrow)), 0);
        // Investor A: bought shares (-10,000 from the faucet), sold bonds (+4,975), sold BRL (+995).
        assertEq(usdt.balanceOf(roles.investorA), 4_975e6 + 995e6);
        // Investor B: sold shares (+9,950); paid for bonds and BRL with faucet USDT.
        assertEq(usdt.balanceOf(roles.investorB), 9_950e6);
        assertEq(brl.balanceOf(roles.investorB), 5_500e6);
    }

    /// @notice The deployer (admin) takes no part in the flows: it holds no trading role and
    /// ends with no token.
    function test_RunAll_TheDeployerTakesNoPart() public {
        demo.runAll(roles, d);
        assertEq(usdt.balanceOf(roles.deployer), 0);
        assertEq(brl.balanceOf(roles.deployer), 0);
        assertFalse(d.settlement.hasRole(d.settlement.SETTLEMENT_OPERATOR_ROLE(), roles.deployer));
        assertFalse(d.registry.hasRole(d.registry.LISTING_AUTHORITY_ROLE(), roles.deployer));
    }

    /// @notice The demo can be repeated: new instruments, a new match id and new deal ids
    /// each time.
    function test_RunAll_CanBeRepeated() public {
        demo.runAll(roles, d);
        demo.runAll(roles, d);

        assertEq(usdt.balanceOf(roles.issuer), 30e6);
        assertEq(d.distributor.protocolBalance(address(usdt)), 4_130e6);
        assertEq(d.distributor.listingFeesCollected(address(usdt)), 4_000e6);
    }

    function test_RunAll_OnBaseSepolia() public {
        vm.chainId(84532);
        demo.runAll(roles, d);
        assertEq(usdt.balanceOf(roles.issuer), 15e6);
    }

    /// @notice The three flows pass the chain guard on each of the five testnets (one run per
    /// chain id on the same in-process deployment: the cashback adds up, 15 mock USDT a run).
    function test_RunAll_OnEverySupportedTestnet() public {
        uint256[5] memory chains = [uint256(11155111), 84532, 46630, 998, 42431];
        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            demo.runAll(roles, d);
            assertEq(usdt.balanceOf(roles.issuer), 15e6 * (i + 1));
        }
    }

    /// @notice The flows charge whatever rates the deployment has: after a timelocked change
    /// of the cashback share to 1000 bps, the issuer gets 10% of each fee instead of 20%.
    function test_Flows_FollowTheDeployedCashbackRate() public {
        vm.prank(roles.deployer);
        d.distributor.proposeSetCashbackBps(1_000);
        vm.warp(block.timestamp + cfg.timelockDelay);
        vm.prank(roles.deployer);
        d.distributor.executeSetCashbackBps(1_000);

        DemoNiaraFlows.Outcome memory out = demo.equityFlow(roles, d);
        assertEq(out.fee, 50e6);
        assertEq(out.cashback, 5e6);
        assertEq(usdt.balanceOf(roles.issuer), 5e6);
    }

    // ── Distinct role wallets ──────────────────────────────────────────────────────────

    function test_RequireDistinctRoles_AcceptsSixDifferentWallets() public view {
        demo.requireDistinctRoles(roles);
    }

    function test_RequireDistinctRoles_RevertsWhenTheIssuerIsAnInvestor() public {
        roles.issuer = roles.investorA;
        vm.expectRevert(abi.encodeWithSelector(DemoNiaraFlows.RolesNotDistinct.selector, "issuer", "investor A"));
        demo.requireDistinctRoles(roles);
    }

    function test_RequireDistinctRoles_RevertsWhenTheDeployerIsTheOperator() public {
        roles.operator = roles.deployer;
        vm.expectRevert(abi.encodeWithSelector(DemoNiaraFlows.RolesNotDistinct.selector, "deployer", "operator"));
        demo.requireDistinctRoles(roles);
    }

    function test_RequireDistinctRoles_RevertsWhenTheTwoInvestorsAreTheSame() public {
        roles.investorB = roles.investorA;
        vm.expectRevert(
            abi.encodeWithSelector(DemoNiaraFlows.RolesNotDistinct.selector, "investor A", "investor B")
        );
        demo.requireDistinctRoles(roles);
    }

    function test_RequireDistinctRoles_RevertsForAZeroAddress() public {
        roles.listingAuthority = address(0);
        vm.expectRevert(abi.encodeWithSelector(DemoNiaraFlows.ZeroRoleAddress.selector, "listing authority"));
        demo.requireDistinctRoles(roles);
    }

    /// @notice Every flow refuses to start with shared wallets, before sending anything.
    function test_Flows_RevertWhenRolesAreNotDistinct() public {
        roles.operator = roles.listingAuthority;
        bytes memory err =
            abi.encodeWithSelector(DemoNiaraFlows.RolesNotDistinct.selector, "listing authority", "operator");
        vm.expectRevert(err);
        demo.equityFlow(roles, d);
        vm.expectRevert(err);
        demo.fixedIncomeFlow(roles, d);
        vm.expectRevert(err);
        demo.currencyFlow(roles, d);
        vm.expectRevert(err);
        demo.fundGas(roles, 1 ether);
    }

    // ── Readiness and chain guard ──────────────────────────────────────────────────────

    /// @notice On a deployment whose phase 2 has not run, the demo stops with a message
    /// instead of failing somewhere in the middle.
    function test_RequireReady_RevertsBeforeDeployPhase2() public {
        NiaraScriptBase.Deployment memory fresh = deployScript.deployAndPropose(cfg);
        vm.expectRevert(
            abi.encodeWithSelector(
                DemoNiaraFlows.DemoNotReady.selector, "operator lacks SETTLEMENT_OPERATOR_ROLE (deploy phase 2 not run?)"
            )
        );
        demo.equityFlow(roles, fresh);
    }

    function test_RequireReady_RevertsWhilePaused() public {
        vm.prank(roles.deployer);
        d.registry.pause();
        vm.expectRevert(abi.encodeWithSelector(DemoNiaraFlows.DemoNotReady.selector, "protocol is paused"));
        demo.currencyFlow(roles, d);
    }

    function test_RequireReady_RevertsForAWalletThatIsNotTheListingAuthority() public {
        roles.listingAuthority = makeAddr("notTheAuthority");
        vm.expectRevert(
            abi.encodeWithSelector(
                DemoNiaraFlows.DemoNotReady.selector, "listing authority lacks LISTING_AUTHORITY_ROLE"
            )
        );
        demo.fixedIncomeFlow(roles, d);
    }

    function test_RequireReady_RevertsWhenACurrencyIsSuspended() public {
        vm.prank(roles.listingAuthority);
        d.registry.suspendListing(address(brl));
        vm.expectRevert(
            abi.encodeWithSelector(DemoNiaraFlows.DemoNotReady.selector, "mock BRL is not an Approved Currency")
        );
        demo.currencyFlow(roles, d);
    }

    /// @notice Without the registry's link to this NiaraSettlement no listing fee can be paid
    /// here: the demo says so up front.
    function test_RequireReady_RevertsWhenTheRegistryIsLinkedElsewhere() public {
        NiaraSettlement other = new NiaraSettlement(
            roles.deployer, address(d.distributor), address(d.registry), address(usdt), cfg.timelockDelay
        );
        vm.prank(roles.deployer);
        d.registry.proposeSetSettlement(address(other));
        vm.warp(block.timestamp + cfg.timelockDelay);
        vm.prank(roles.deployer);
        d.registry.executeSetSettlement(address(other));

        vm.expectRevert(
            abi.encodeWithSelector(
                DemoNiaraFlows.DemoNotReady.selector, "registry not linked to NiaraSettlement (deploy phase 2 not run?)"
            )
        );
        demo.equityFlow(roles, d);
    }

    function test_RequireReady_RevertsWhenTheRegistryCannotRecordListingFees() public {
        bytes32 role = d.distributor.LISTING_REGISTRY_ROLE();
        vm.prank(roles.deployer);
        d.distributor.proposeRevokeRole(role, address(d.registry));
        vm.warp(block.timestamp + cfg.timelockDelay);
        vm.prank(roles.deployer);
        d.distributor.executeRevokeRole(role, address(d.registry));

        vm.expectRevert(
            abi.encodeWithSelector(
                DemoNiaraFlows.DemoNotReady.selector,
                "ListingRegistry lacks LISTING_REGISTRY_ROLE (deploy phase 2 not run?)"
            )
        );
        demo.fixedIncomeFlow(roles, d);
    }

    function test_RequireReady_PassesOnAFinishedDeployment() public view {
        demo.requireReady(roles, d);
    }

    function test_ChainGuard_FlowsRevertOutsideTheFiveTestnets() public {
        uint256[6] memory others = [uint256(1), 8453, 999, 42161, 4217, 31337];
        for (uint256 i = 0; i < others.length; i++) {
            vm.chainId(others[i]);
            bytes memory err = abi.encodeWithSelector(NiaraScriptBase.UnsupportedChain.selector, others[i]);
            vm.expectRevert(err);
            demo.equityFlow(roles, d);
            vm.expectRevert(err);
            demo.fixedIncomeFlow(roles, d);
            vm.expectRevert(err);
            demo.currencyFlow(roles, d);
            vm.expectRevert(err);
            demo.fundGas(roles, 1 ether);
            vm.expectRevert(err);
            demo.runAll(roles, d);
        }
    }

    // ── Gas top-up ─────────────────────────────────────────────────────────────────────

    function test_FundGas_TopsUpEachRoleWalletToTheTarget() public {
        vm.deal(roles.deployer, 10 ether);
        vm.deal(roles.issuer, 0.004 ether);

        demo.fundGas(roles, 0.02 ether);

        assertEq(roles.listingAuthority.balance, 0.02 ether);
        assertEq(roles.operator.balance, 0.02 ether);
        assertEq(roles.issuer.balance, 0.02 ether);
        assertEq(roles.investorA.balance, 0.02 ether);
        assertEq(roles.investorB.balance, 0.02 ether);
        // Four full top-ups and one partial (the issuer already had 0.004).
        assertEq(roles.deployer.balance, 10 ether - (4 * 0.02 ether) - 0.016 ether);
    }

    function test_FundGas_SendsNothingToWalletsAlreadyFunded() public {
        vm.deal(roles.deployer, 10 ether);
        address[5] memory wallets =
            [roles.listingAuthority, roles.operator, roles.issuer, roles.investorA, roles.investorB];
        for (uint256 i = 0; i < wallets.length; i++) {
            vm.deal(wallets[i], 1 ether);
        }

        demo.fundGas(roles, 0.02 ether);

        assertEq(roles.deployer.balance, 10 ether);
        assertEq(roles.operator.balance, 1 ether);
    }

    /// @notice Tempo has no native gas token (fees are paid in pathUSD): the top-up sends
    /// nothing there, whatever the target.
    function test_FundGas_SendsNothingOnTempo() public {
        vm.chainId(42431);
        vm.deal(roles.deployer, 10 ether);
        demo.fundGas(roles, 0.02 ether);
        assertEq(roles.deployer.balance, 10 ether);
        assertEq(roles.issuer.balance, 0);
        assertEq(roles.investorB.balance, 0);
    }

    /// @notice Tops up with the chain's own native token on HyperEVM and Robinhood too.
    function test_FundGas_TopsUpOnTheOtherNewTestnets() public {
        uint256[2] memory chains = [uint256(998), 46630];
        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            vm.deal(roles.deployer, 1 ether);
            vm.deal(roles.operator, 0);
            demo.fundGas(roles, 0.001 ether);
            assertEq(roles.operator.balance, 0.001 ether);
        }
    }

    /// @notice The top-up amount is read per chain: `DEMO_GAS_FUNDING_WEI_<chainid>`, then
    /// `DEMO_GAS_FUNDING_WEI`, then the default; always 0 on Tempo. ONE test, because
    /// `vm.setEnv` changes the whole process (and `forge test` loads the local `.env`, so every
    /// variable read here is set here first). No other test reads these variables.
    function test_GasFundingTarget_PerChainThenGlobalThenDefault_ZeroOnTempo() public {
        vm.setEnv("DEMO_GAS_FUNDING_WEI", "300000000000000");
        vm.setEnv("DEMO_GAS_FUNDING_WEI_84532", "40000000000000");
        vm.setEnv("DEMO_GAS_FUNDING_WEI_998", "2000000000000000");
        // An empty per-chain variable counts as unset: the global value applies.
        vm.setEnv("DEMO_GAS_FUNDING_WEI_11155111", "");
        vm.setEnv("DEMO_GAS_FUNDING_WEI_42431", "5000000000000000");

        vm.chainId(84532);
        assertEq(demo.gasFundingTarget(), 40_000_000_000_000);
        vm.chainId(998);
        assertEq(demo.gasFundingTarget(), 2_000_000_000_000_000);
        vm.chainId(11155111);
        assertEq(demo.gasFundingTarget(), 300_000_000_000_000);
        // Tempo: zero even with a per-chain value set.
        vm.chainId(42431);
        assertEq(demo.gasFundingTarget(), 0);

        // Neither variable usable: the default.
        vm.setEnv("DEMO_GAS_FUNDING_WEI", "");
        vm.chainId(11155111);
        assertEq(demo.gasFundingTarget(), demo.DEFAULT_GAS_FUNDING());
    }

    function test_FundGas_ZeroTargetDoesNothing() public {
        vm.deal(roles.deployer, 10 ether);
        demo.fundGas(roles, 0);
        assertEq(roles.deployer.balance, 10 ether);
        assertEq(roles.issuer.balance, 0);
    }

    // ── Gas preflight ──────────────────────────────────────────────────────────────────

    /// @notice All three flows: each wallet's budget is the sum of its part in each flow; the
    /// deployer signs nothing without a top-up.
    function test_DemoGasNeeds_SumsTheSelectedFlows() public view {
        NiaraScriptBase.GasNeed[] memory needs = demo.demoGasNeeds(roles, true, true, true, 0);
        assertEq(needs.length, 6);
        assertEq(needs[0].wallet, roles.deployer);
        assertEq(needs[0].gas, 0);
        assertEq(needs[1].wallet, roles.listingAuthority);
        assertEq(needs[1].gas, demo.EQUITY_LISTING_GAS() + demo.BOND_LISTING_GAS());
        assertEq(needs[2].wallet, roles.operator);
        assertEq(needs[2].gas, demo.EQUITY_OPERATOR_GAS());
        assertEq(needs[3].wallet, roles.issuer);
        assertEq(needs[3].gas, demo.EQUITY_ISSUER_GAS() + demo.BOND_ISSUER_GAS());
        assertEq(needs[4].wallet, roles.investorA);
        assertEq(needs[4].gas, demo.EQUITY_INVESTOR_A_GAS() + demo.BOND_INVESTOR_A_GAS() + demo.FX_INVESTOR_A_GAS());
        assertEq(needs[5].wallet, roles.investorB);
        assertEq(needs[5].gas, demo.EQUITY_INVESTOR_B_GAS() + demo.BOND_INVESTOR_B_GAS() + demo.FX_INVESTOR_B_GAS());
    }

    /// @notice A single flow counts only the wallets that sign in it.
    function test_DemoGasNeeds_CurrencyFlowOnlyNeedsTheInvestors() public view {
        NiaraScriptBase.GasNeed[] memory needs = demo.demoGasNeeds(roles, false, false, true, 0);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(needs[i].gas, 0);
        }
        assertEq(needs[4].gas, demo.FX_INVESTOR_A_GAS());
        assertEq(needs[5].gas, demo.FX_INVESTOR_B_GAS());
    }

    /// @notice The top-up mirrors `fundGas`: the deployer pays one transfer and the value for
    /// each wallet below the target, and that wallet counts the value as received.
    function test_DemoGasNeeds_TopUpMovesValueFromTheDeployer() public {
        vm.deal(roles.issuer, 0.004 ether);
        vm.deal(roles.operator, 1 ether);

        NiaraScriptBase.GasNeed[] memory needs = demo.demoGasNeeds(roles, false, false, false, 0.02 ether);
        // Four wallets below the target (the operator is above it).
        assertEq(needs[0].gas, 4 * demo.FUND_TRANSFER_GAS());
        assertEq(needs[0].value, 3 * 0.02 ether + 0.016 ether);
        assertEq(needs[1].incoming, 0.02 ether);
        assertEq(needs[2].incoming, 0);
        assertEq(needs[3].incoming, 0.016 ether);
        assertEq(needs[4].incoming, 0.02 ether);
        assertEq(needs[5].incoming, 0.02 ether);
    }

    /// @notice No top-up on Tempo, whatever the target: every wallet pays from its own
    /// fee-token balance.
    function test_DemoGasNeeds_NoTopUpOnTempo() public {
        vm.chainId(42431);
        NiaraScriptBase.GasNeed[] memory needs = demo.demoGasNeeds(roles, true, true, true, 0.02 ether);
        assertEq(needs[0].gas, 0);
        assertEq(needs[0].value, 0);
        for (uint256 i = 1; i < needs.length; i++) {
            assertEq(needs[i].incoming, 0);
        }
    }

    /// @notice With the top-up the role wallets are covered (the deployer funds them), and
    /// the deployer alone is reported short when it cannot pay for it.
    function test_DemoGasNeeds_PreflightFlagsOnlyTheUnderfundedDeployer() public {
        // Base Sepolia's figures: multiplier 130, ~0.01 gwei max fee, 0.0002 ETH top-up.
        vm.chainId(84532);
        uint256 fee = 0.01 gwei;
        NiaraScriptBase.GasNeed[] memory needs = demo.demoGasNeeds(roles, true, true, true, 0.0002 ether);
        assertEq(demo.checkGasFunds("demo", needs, fee, false), 1);

        vm.deal(roles.deployer, 1 ether);
        assertEq(demo.checkGasFunds("demo", needs, fee, true), 0);
    }

    /// @notice The budgets cover forge's own estimates in the Base Sepolia demo (2026-11-16),
    /// i.e. each wallet's gas limits divided by the 1.3 multiplier, flows 1 + 2 + 3.
    function test_DemoBudgets_CoverTheMeasuredBaseSepoliaEstimates() public view {
        NiaraScriptBase.GasNeed[] memory needs = demo.demoGasNeeds(roles, true, true, true, 0);
        assertGe(needs[1].gas * 130, 569_620 * 100); // listing authority
        assertGe(needs[2].gas * 130, 282_365 * 100); // operator
        assertGe(needs[3].gas * 130, 3_398_327 * 100); // issuer
        assertGe(needs[4].gas * 130, 1_009_036 * 100); // investor A
        assertGe(needs[5].gas * 130, 1_049_512 * 100); // investor B
    }

    function test_Constants_DemoAmounts() public view {
        assertEq(demo.DEFAULT_GAS_FUNDING(), 0.02 ether);
        assertEq(demo.EQUITY_BATCH(), 1_000 ether);
        assertEq(demo.EQUITY_TRADE(), 100 ether);
        assertEq(demo.EQUITY_PRICE(), 10_000e6);
        assertEq(demo.BOND_BATCH(), 500 ether);
        assertEq(demo.BOND_TRADE(), 50 ether);
        assertEq(demo.BOND_PRICE(), 5_000e6);
        assertEq(demo.FX_BRL_AMOUNT(), 5_500e6);
        assertEq(demo.FX_USDT_AMOUNT(), 1_000e6);
        assertEq(demo.DEAL_LIFETIME(), 1 days);
        assertEq(demo.LISTING_VALUATION(), 1_000_000e6);
        assertEq(demo.LISTING_FEE_BPS(), 10);
        assertEq(demo.QUOTE_LIFETIME(), 7 days);
    }
}

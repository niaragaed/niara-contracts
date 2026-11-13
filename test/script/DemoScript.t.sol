// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployNiara} from "../../script/Deploy.s.sol";
import {DemoNiaraFlows} from "../../script/Demo.s.sol";
import {NiaraScriptBase} from "../../script/NiaraScriptBase.sol";
import {NativeAssetToken} from "../../src/NativeAssetToken.sol";
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
    /// issuer's cashback and 40 stays with the protocol.
    function test_EquityFlow_IssuesSettlesAndPaysCashback() public {
        DemoNiaraFlows.Outcome memory out = demo.equityFlow(roles, d);

        assertEq(out.fee, 50e6);
        assertEq(out.cashback, 10e6);

        IERC20 share = IERC20(out.instrument);
        assertEq(share.totalSupply(), 1_000 ether);
        assertEq(share.balanceOf(roles.investorA), 100 ether);
        assertEq(share.balanceOf(roles.investorB), 900 ether);

        assertEq(usdt.balanceOf(roles.investorA), 0);
        assertEq(usdt.balanceOf(roles.investorB), 9_950e6);
        assertEq(usdt.balanceOf(roles.issuer), 10e6);
        assertEq(usdt.balanceOf(address(d.distributor)), 40e6);
        assertEq(d.distributor.protocolBalance(address(usdt)), 40e6);
        assertEq(d.distributor.cashbackBalance(out.instrument, address(usdt)), 0);
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

    /// @notice 50 bonds for 5,000 mock USDT: fee 25, cashback 5, protocol 20. The seller
    /// (investor A, the proposer) receives the USDT and pays the fee.
    function test_FixedIncomeFlow_DealExecutesAndPaysCashback() public {
        DemoNiaraFlows.Outcome memory out = demo.fixedIncomeFlow(roles, d);

        assertEq(out.fee, 25e6);
        assertEq(out.cashback, 5e6);

        IERC20 bond = IERC20(out.instrument);
        assertEq(bond.totalSupply(), 500 ether);
        assertEq(bond.balanceOf(roles.investorB), 50 ether);
        assertEq(bond.balanceOf(roles.investorA), 450 ether);
        assertEq(bond.balanceOf(address(d.escrow)), 0);
        assertEq(d.escrow.totalEscrowed(out.instrument), 0);

        assertEq(usdt.balanceOf(roles.investorA), 4_975e6);
        assertEq(usdt.balanceOf(roles.investorB), 0);
        assertEq(usdt.balanceOf(roles.issuer), 5e6);
        assertEq(d.distributor.protocolBalance(address(usdt)), 20e6);
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
    /// the issuer as cashback and 65 is protocol revenue, all of it in the distributor.
    function test_RunAll_TotalsAcrossTheThreeFlows() public {
        demo.runAll(roles, d);

        assertEq(usdt.balanceOf(roles.issuer), 15e6);
        assertEq(d.distributor.protocolBalance(address(usdt)), 65e6);
        assertEq(usdt.balanceOf(address(d.distributor)), 65e6);
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
        assertEq(d.distributor.protocolBalance(address(usdt)), 130e6);
    }

    function test_RunAll_OnBaseSepolia() public {
        vm.chainId(84532);
        demo.runAll(roles, d);
        assertEq(usdt.balanceOf(roles.issuer), 15e6);
    }

    /// @notice The flows charge whatever rates the deployment has: with the cashback at the
    /// contract default (1000 bps) the issuer gets 10% of each fee.
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

    function test_RequireReady_PassesOnAFinishedDeployment() public view {
        demo.requireReady(roles, d);
    }

    function test_ChainGuard_FlowsRevertOutsideTheTwoTestnets() public {
        uint256[3] memory others = [uint256(1), 8453, 31337];
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

    function test_FundGas_ZeroTargetDoesNothing() public {
        vm.deal(roles.deployer, 10 ether);
        demo.fundGas(roles, 0);
        assertEq(roles.deployer.balance, 10 ether);
        assertEq(roles.issuer.balance, 0);
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
    }
}

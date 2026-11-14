// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployNiara} from "../../script/Deploy.s.sol";
import {NiaraScriptBase} from "../../script/NiaraScriptBase.sol";
import {TestnetMockToken} from "../../script/tokens/TestnetMockToken.sol";
import {P2PEscrow} from "../../src/P2PEscrow.sol";
import {NiaraSettlement} from "../../src/NiaraSettlement.sol";
import {ListingRegistry} from "../../src/ListingRegistry.sol";
import {IListingRegistry} from "../../src/interfaces/IListingRegistry.sol";

/// @notice Runs `script/Deploy.s.sol` in-process, with the chain id set to each supported
/// testnet. Inside a test `vm.startBroadcast(address)` behaves like a prank, so every
/// transaction of the script is executed as the configured signer against a fresh EVM: this
/// is a regression test of the script's logic (what it deploys, proposes, executes and
/// refuses), not a deployment.
contract DeployScriptTest is Test {
    DeployNiara internal script;

    address internal deployer = makeAddr("deployer");
    address internal listingAuthority = makeAddr("listingAuthority");
    address internal operator = makeAddr("operator");

    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant BASE_SEPOLIA = 84532;

    function setUp() public {
        script = new DeployNiara();
        vm.chainId(SEPOLIA);
    }

    function _config() internal view returns (DeployNiara.Config memory cfg) {
        cfg.deployer = deployer;
        cfg.listingAuthority = listingAuthority;
        cfg.operator = operator;
        cfg.timelockDelay = 1 hours;
        cfg.cashbackBps = 2_000;
    }

    function _phase1() internal returns (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) {
        cfg = _config();
        d = script.deployAndPropose(cfg);
    }

    function _bothPhases() internal returns (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) {
        (cfg, d) = _phase1();
        vm.warp(block.timestamp + cfg.timelockDelay);
        script.executeWiringOn(cfg, d);
    }

    // ── Constants ──────────────────────────────────────────────────────────────────────

    function test_Constants_FeeCashbackAndChains() public view {
        assertEq(script.FEE_BPS(), 50);
        assertEq(script.DEFAULT_CASHBACK_BPS(), 2_000);
        assertEq(script.DEFAULT_TIMELOCK_DELAY(), 1 hours);
        assertEq(script.SEPOLIA_CHAIN_ID(), 11155111);
        assertEq(script.BASE_SEPOLIA_CHAIN_ID(), 84532);
        assertEq(script.WIRING_PROPOSALS(), 5);
    }

    // ── Phase 1 ────────────────────────────────────────────────────────────────────────

    function test_Phase1_DeploysEveryContractWiredToEachOther() public {
        (, NiaraScriptBase.Deployment memory d) = _phase1();

        assertGt(address(d.registry).code.length, 0);
        assertGt(address(d.factory).code.length, 0);
        assertGt(address(d.distributor).code.length, 0);
        assertGt(address(d.settlement).code.length, 0);
        assertGt(address(d.escrow).code.length, 0);

        assertEq(address(d.registry.factory()), address(d.factory));
        assertEq(address(d.distributor.listingRegistry()), address(d.registry));
        assertEq(address(d.settlement.listingRegistry()), address(d.registry));
        assertEq(address(d.settlement.cashbackDistributor()), address(d.distributor));
        assertEq(d.settlement.feeToken(), address(d.mockUsdt));
        assertEq(address(d.escrow.settlement()), address(d.settlement));
        assertEq(address(d.escrow.listingRegistry()), address(d.registry));
    }

    function test_Phase1_DeployerIsAdminAndListingAuthorityIsSet() public {
        (, NiaraScriptBase.Deployment memory d) = _phase1();
        bytes32 adminRole = d.registry.DEFAULT_ADMIN_ROLE();

        assertTrue(d.registry.hasRole(adminRole, deployer));
        assertTrue(d.registry.hasRole(d.registry.PAUSER_ROLE(), deployer));
        assertTrue(d.distributor.hasRole(adminRole, deployer));
        assertTrue(d.distributor.hasRole(d.distributor.TREASURY_ROLE(), deployer));
        assertTrue(d.settlement.hasRole(adminRole, deployer));
        assertTrue(d.escrow.hasRole(adminRole, deployer));
        assertTrue(d.escrow.hasRole(d.escrow.TREASURY_ROLE(), deployer));

        bytes32 authorityRole = d.registry.LISTING_AUTHORITY_ROLE();
        assertTrue(d.registry.hasRole(authorityRole, listingAuthority));
        assertFalse(d.registry.hasRole(authorityRole, deployer));
    }

    function test_Phase1_TimelockDelayIsTheConfiguredOne() public {
        DeployNiara.Config memory cfg = _config();
        cfg.timelockDelay = 3 hours;
        NiaraScriptBase.Deployment memory d = script.deployAndPropose(cfg);

        assertEq(d.registry.timelockDelay(), 3 hours);
        assertEq(d.distributor.timelockDelay(), 3 hours);
        assertEq(d.settlement.timelockDelay(), 3 hours);
        assertEq(d.escrow.timelockDelay(), 3 hours);
    }

    /// @notice The fee is 50 bps (the contract default and its cap); phase 1 does not touch
    /// it. The cashback rate is 2000 bps from the first block: it is a constructor argument
    /// of the CashbackDistributor, with nothing proposed for it.
    function test_Phase1_FeeIs50BpsAndCashbackIs2000BpsFromConstruction() public {
        (, NiaraScriptBase.Deployment memory d) = _phase1();
        assertEq(d.settlement.feeBps(), 50);
        assertEq(d.settlement.MAX_FEE_BPS(), 50);
        assertEq(d.distributor.cashbackBps(), 2_000);
        assertEq(d.distributor.pendingActions(keccak256(abi.encode("SET_CASHBACK_BPS", uint16(2_000)))), 0);
    }

    /// @notice Whatever rate is configured (`CASHBACK_BPS`) is the one the distributor is
    /// constructed with, including both ends of the range.
    function test_Phase1_ConstructsTheDistributorWithTheConfiguredCashbackRate() public {
        uint16[3] memory rates = [uint16(0), 1_500, 10_000];
        for (uint256 i = 0; i < rates.length; i++) {
            DeployNiara.Config memory cfg = _config();
            cfg.cashbackBps = rates[i];
            NiaraScriptBase.Deployment memory d = script.deployAndPropose(cfg);
            assertEq(d.distributor.cashbackBps(), rates[i]);
        }
    }

    /// @notice Phase 1 grants nothing: every sensitive change is only scheduled.
    function test_Phase1_ProposesTheWiringAndGrantsNothing() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _phase1();
        bytes32 settlementRole = d.distributor.SETTLEMENT_ROLE();
        bytes32 escrowRole = d.distributor.ESCROW_ROLE();
        bytes32 listingRegistryRole = d.distributor.LISTING_REGISTRY_ROLE();
        bytes32 operatorRole = d.settlement.SETTLEMENT_OPERATOR_ROLE();

        assertFalse(d.distributor.hasRole(settlementRole, address(d.settlement)));
        assertFalse(d.distributor.hasRole(escrowRole, address(d.escrow)));
        assertFalse(d.distributor.hasRole(listingRegistryRole, address(d.registry)));
        assertFalse(d.settlement.hasRole(operatorRole, operator));
        assertEq(address(d.registry.settlement()), address(0), "the settlement link is only proposed");

        uint256 expected = block.timestamp + cfg.timelockDelay;
        assertEq(
            d.distributor.pendingActions(keccak256(abi.encode("GRANT_ROLE", settlementRole, address(d.settlement)))),
            expected
        );
        assertEq(
            d.distributor.pendingActions(keccak256(abi.encode("GRANT_ROLE", escrowRole, address(d.escrow)))), expected
        );
        assertEq(
            d.distributor.pendingActions(
                keccak256(abi.encode("GRANT_ROLE", listingRegistryRole, address(d.registry)))
            ),
            expected
        );
        assertEq(d.settlement.pendingActions(keccak256(abi.encode("GRANT_ROLE", operatorRole, operator))), expected);
        assertEq(
            d.registry.pendingActions(keccak256(abi.encode("SET_SETTLEMENT", address(d.settlement)))), expected
        );
        assertEq(script.wiringExecutableAt(cfg, d), expected);
    }

    /// @notice Before phase 2 no listing fee can be quoted, so no issuer listing can be
    /// approved: the registry is not yet linked to the settlement.
    function test_Phase1_NoListingFeeBeforePhase2() public {
        (, NiaraScriptBase.Deployment memory d) = _phase1();
        address issuer = makeAddr("issuer");
        vm.prank(issuer);
        address token = d.factory.createAssetToken("Acme", "ACME", IListingRegistry.AssetClass.Equity, keccak256("doc"));
        vm.prank(issuer);
        d.registry.submitListing(token);

        vm.prank(listingAuthority);
        vm.expectRevert(ListingRegistry.SettlementNotSet.selector);
        d.registry.quoteListing(token, 1, 1, uint64(block.timestamp + 1));
    }

    /// @notice Nothing is tradable after phase 1: no listing exists yet.
    function test_Phase1_ListsNothing() public {
        (, NiaraScriptBase.Deployment memory d) = _phase1();
        assertEq(uint8(d.registry.getListing(address(d.mockUsdt)).status), uint8(IListingRegistry.ListingStatus.None));
        assertEq(uint8(d.registry.getListing(address(d.mockBrl)).status), uint8(IListingRegistry.ListingStatus.None));
    }

    /// @notice The two tokens say what they are: test tokens with no value.
    function test_Phase1_MockTokensAreClearlyNamedTestTokens() public {
        (, NiaraScriptBase.Deployment memory d) = _phase1();
        assertEq(d.mockUsdt.name(), "Niara Mock USDT (TESTNET ONLY - NO VALUE)");
        assertEq(d.mockUsdt.symbol(), "mockUSDT");
        assertEq(d.mockUsdt.decimals(), 6);
        assertEq(d.mockBrl.name(), "Niara Mock BRL (TESTNET ONLY - NO VALUE)");
        assertEq(d.mockBrl.symbol(), "mockBRL");
        assertEq(d.mockBrl.decimals(), 6);
        assertEq(d.mockUsdt.totalSupply(), 0);
    }

    function test_Phase1_RevertsForZeroDeployer() public {
        DeployNiara.Config memory cfg = _config();
        cfg.deployer = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployNiara.ZeroConfigAddress.selector, "deployer"));
        script.deployAndPropose(cfg);
    }

    function test_Phase1_RevertsForZeroListingAuthority() public {
        DeployNiara.Config memory cfg = _config();
        cfg.listingAuthority = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployNiara.ZeroConfigAddress.selector, "listing authority"));
        script.deployAndPropose(cfg);
    }

    function test_Phase1_RevertsForZeroOperator() public {
        DeployNiara.Config memory cfg = _config();
        cfg.operator = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployNiara.ZeroConfigAddress.selector, "operator"));
        script.deployAndPropose(cfg);
    }

    function test_Phase1_RevertsForCashbackAbove100Percent() public {
        DeployNiara.Config memory cfg = _config();
        cfg.cashbackBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(DeployNiara.CashbackBpsOutOfRange.selector, uint256(10_001)));
        script.deployAndPropose(cfg);
    }

    // ── Chain guard ────────────────────────────────────────────────────────────────────

    function test_ChainGuard_Phase1RevertsOutsideTheTwoTestnets() public {
        uint256[5] memory others = [uint256(1), 8453, 31337, 17000, 421614];
        for (uint256 i = 0; i < others.length; i++) {
            vm.chainId(others[i]);
            vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.UnsupportedChain.selector, others[i]));
            script.deployAndPropose(_config());
        }
    }

    function test_ChainGuard_Phase2RevertsOutsideTheTwoTestnets() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _phase1();
        vm.warp(block.timestamp + cfg.timelockDelay);

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.UnsupportedChain.selector, uint256(1)));
        script.executeWiringOn(cfg, d);

        vm.chainId(31337);
        vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.UnsupportedChain.selector, uint256(31337)));
        script.executeWiringOn(cfg, d);
    }

    function test_ChainGuard_BothPhasesRunOnBaseSepolia() public {
        vm.chainId(BASE_SEPOLIA);
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();
        script.verifyWiring(cfg, d);
        assertEq(script.chainName(), "Base Sepolia");
    }

    function test_ChainName_Sepolia() public view {
        assertEq(script.chainName(), "Ethereum Sepolia");
    }

    /// @notice Deployed-address variables carry the chain id, so one chain's addresses can
    /// never be picked up on the other.
    function test_DeployedVar_IsSuffixedWithTheChainId() public {
        assertEq(script.deployedVar("DEPLOYED_ESCROW_ADDRESS"), "DEPLOYED_ESCROW_ADDRESS_11155111");
        vm.chainId(BASE_SEPOLIA);
        assertEq(script.deployedVar("DEPLOYED_ESCROW_ADDRESS"), "DEPLOYED_ESCROW_ADDRESS_84532");
    }

    // ── Phase 2 ────────────────────────────────────────────────────────────────────────

    /// @notice There is no shortcut around the timelock: phase 2 refuses to run early.
    function test_Phase2_RevertsWhileTheTimelockIsRunning() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _phase1();
        uint256 executeAfter = block.timestamp + cfg.timelockDelay;

        vm.expectRevert(
            abi.encodeWithSelector(DeployNiara.TimelockStillRunning.selector, executeAfter, block.timestamp)
        );
        script.executeWiringOn(cfg, d);

        vm.warp(executeAfter - 1);
        vm.expectRevert(abi.encodeWithSelector(DeployNiara.TimelockStillRunning.selector, executeAfter, executeAfter - 1));
        script.executeWiringOn(cfg, d);
    }

    function test_Phase2_ExecutesTheWiringExactlyAtTheDeadline() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();

        assertTrue(d.distributor.hasRole(d.distributor.SETTLEMENT_ROLE(), address(d.settlement)));
        assertTrue(d.distributor.hasRole(d.distributor.ESCROW_ROLE(), address(d.escrow)));
        assertTrue(d.distributor.hasRole(d.distributor.LISTING_REGISTRY_ROLE(), address(d.registry)));
        assertTrue(d.settlement.hasRole(d.settlement.SETTLEMENT_OPERATOR_ROLE(), operator));
        assertEq(address(d.registry.settlement()), address(d.settlement));
        assertEq(script.wiringExecutableAt(cfg, d), 0);
    }

    /// @notice Phase 2 neither sets nor changes a rate: cashback stays at the constructed
    /// 2000 bps and the fee at 50 bps.
    function test_Phase2_LeavesCashbackAt2000BpsAndFeeAt50() public {
        (, NiaraScriptBase.Deployment memory d) = _bothPhases();
        assertEq(d.distributor.cashbackBps(), 2_000);
        assertEq(d.settlement.feeBps(), 50);
    }

    function test_Phase2_ListsBothMockCurrencies() public {
        (, NiaraScriptBase.Deployment memory d) = _bothPhases();

        IListingRegistry.Listing memory usdtListing = d.registry.getListing(address(d.mockUsdt));
        assertEq(uint8(usdtListing.status), uint8(IListingRegistry.ListingStatus.Approved));
        assertEq(uint8(usdtListing.assetClass), uint8(IListingRegistry.AssetClass.Currency));
        assertFalse(usdtListing.cashbackEligible);

        IListingRegistry.Listing memory brlListing = d.registry.getListing(address(d.mockBrl));
        assertEq(uint8(brlListing.status), uint8(IListingRegistry.ListingStatus.Approved));
        assertEq(uint8(brlListing.assetClass), uint8(IListingRegistry.AssetClass.Currency));
    }

    /// @notice Only the roles the wiring is about are granted: the deployer does not become
    /// the operator, and the operator gets nothing else.
    function test_Phase2_GrantsNothingBeyondTheWiring() public {
        (, NiaraScriptBase.Deployment memory d) = _bothPhases();
        assertFalse(d.settlement.hasRole(d.settlement.SETTLEMENT_OPERATOR_ROLE(), deployer));
        assertFalse(d.distributor.hasRole(d.distributor.SETTLEMENT_ROLE(), operator));
        assertFalse(d.distributor.hasRole(d.distributor.ESCROW_ROLE(), address(d.settlement)));
        assertFalse(d.distributor.hasRole(d.distributor.SETTLEMENT_ROLE(), address(d.escrow)));
        assertFalse(d.registry.hasRole(d.registry.LISTING_AUTHORITY_ROLE(), operator));
    }

    /// @notice Running phase 2 again changes nothing and does not revert.
    function test_Phase2_IsIdempotent() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();
        script.executeWiringOn(cfg, d);
        script.verifyWiring(cfg, d);
        assertEq(d.distributor.cashbackBps(), 2_000);
    }

    /// @notice A phase 2 that stopped halfway (here: one grant and one listing already
    /// done) is completed by running it again.
    function test_Phase2_ResumesAfterAPartialRun() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _phase1();
        vm.warp(block.timestamp + cfg.timelockDelay);

        bytes32 escrowRole = d.distributor.ESCROW_ROLE();
        vm.prank(deployer);
        d.distributor.executeGrantRole(escrowRole, address(d.escrow));
        vm.prank(listingAuthority);
        d.registry.listCurrency(address(d.mockBrl));

        script.executeWiringOn(cfg, d);
        script.verifyWiring(cfg, d);
    }

    /// @notice Same with the two listing-fee steps already done by hand.
    function test_Phase2_ResumesWhenTheListingFeeWiringIsAlreadyDone() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _phase1();
        vm.warp(block.timestamp + cfg.timelockDelay);

        bytes32 listingRegistryRole = d.distributor.LISTING_REGISTRY_ROLE();
        vm.startPrank(deployer);
        d.distributor.executeGrantRole(listingRegistryRole, address(d.registry));
        d.registry.executeSetSettlement(address(d.settlement));
        vm.stopPrank();

        script.executeWiringOn(cfg, d);
        script.verifyWiring(cfg, d);
    }

    /// @notice The deployment never uses the timelock for the cashback rate, but the timelock
    /// still governs it afterwards: an immediate change is impossible, and a proposed one
    /// applies only after the delay.
    function test_AfterDeployment_CashbackChangesOnlyThroughTheTimelock() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();

        vm.prank(deployer);
        d.distributor.proposeSetCashbackBps(3_000);
        vm.prank(deployer);
        vm.expectRevert();
        d.distributor.executeSetCashbackBps(3_000);
        assertEq(d.distributor.cashbackBps(), 2_000);

        vm.warp(block.timestamp + cfg.timelockDelay);
        vm.prank(deployer);
        d.distributor.executeSetCashbackBps(3_000);
        assertEq(d.distributor.cashbackBps(), 3_000);
    }

    /// @notice Phase 2 does not change the rate, so a `CASHBACK_BPS` that differs from the
    /// one phase 1 deployed with is reported instead of silently ignored.
    function test_Phase2_RevertsWhenTheConfiguredCashbackIsNotTheDeployedOne() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _phase1();
        vm.warp(block.timestamp + cfg.timelockDelay);
        cfg.cashbackBps = 1_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployNiara.WiringIncomplete.selector, "cashback rate is not the configured CASHBACK_BPS"
            )
        );
        script.executeWiringOn(cfg, d);
        assertEq(d.distributor.cashbackBps(), 2_000);
    }

    /// @notice One key for every role (the defaults when only DEPLOYER_ADDRESS is set).
    function test_BothPhases_WithTheDeployerHoldingEveryRole() public {
        DeployNiara.Config memory cfg = _config();
        cfg.listingAuthority = deployer;
        cfg.operator = deployer;
        NiaraScriptBase.Deployment memory d = script.deployAndPropose(cfg);
        vm.warp(block.timestamp + cfg.timelockDelay);
        script.executeWiringOn(cfg, d);

        assertTrue(d.settlement.hasRole(d.settlement.SETTLEMENT_OPERATOR_ROLE(), deployer));
        assertTrue(d.registry.hasRole(d.registry.LISTING_AUTHORITY_ROLE(), deployer));
    }

    /// @notice The environment must not change between the phases: a listing authority that
    /// is not the one fixed in phase 1 is refused before anything is sent.
    function test_Phase2_RevertsForAListingAuthorityThatIsNotTheDeployedOne() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _phase1();
        vm.warp(block.timestamp + cfg.timelockDelay);
        cfg.listingAuthority = makeAddr("someoneElse");

        vm.expectRevert(abi.encodeWithSelector(DeployNiara.ListingAuthorityMismatch.selector, cfg.listingAuthority));
        script.executeWiringOn(cfg, d);
    }

    /// @notice A different operator in phase 2 has no pending proposal: the contract's own
    /// timelock refuses it.
    function test_Phase2_RevertsForAnOperatorThatWasNotProposed() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _phase1();
        vm.warp(block.timestamp + cfg.timelockDelay);
        cfg.operator = makeAddr("anotherOperator");

        vm.expectRevert();
        script.executeWiringOn(cfg, d);
        assertFalse(d.settlement.hasRole(d.settlement.SETTLEMENT_OPERATOR_ROLE(), cfg.operator));
    }

    // ── verifyWiring ───────────────────────────────────────────────────────────────────

    function test_VerifyWiring_RevertsBeforePhase2() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _phase1();
        vm.expectRevert(
            abi.encodeWithSelector(DeployNiara.WiringIncomplete.selector, "SETTLEMENT_ROLE -> NiaraSettlement")
        );
        script.verifyWiring(cfg, d);
    }

    function test_VerifyWiring_RevertsWhenTheCashbackRateIsNotTheConfiguredOne() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();
        cfg.cashbackBps = 2_500;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployNiara.WiringIncomplete.selector, "cashback rate is not the configured CASHBACK_BPS"
            )
        );
        script.verifyWiring(cfg, d);
    }

    function test_VerifyWiring_PassesAfterPhase2() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();
        script.verifyWiring(cfg, d);
    }

    function test_VerifyWiring_RevertsWhenTheProtocolIsPaused() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();
        vm.prank(deployer);
        d.registry.pause();
        vm.expectRevert(abi.encodeWithSelector(DeployNiara.WiringIncomplete.selector, "protocol is paused"));
        script.verifyWiring(cfg, d);
    }

    function test_VerifyWiring_RevertsWhenACurrencyIsSuspended() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();
        vm.prank(listingAuthority);
        d.registry.suspendListing(address(d.mockBrl));
        vm.expectRevert(
            abi.encodeWithSelector(DeployNiara.WiringIncomplete.selector, "mock BRL not an Approved Currency")
        );
        script.verifyWiring(cfg, d);
    }

    function test_VerifyWiring_RevertsWithoutTheListingRegistryRole() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();
        bytes32 role = d.distributor.LISTING_REGISTRY_ROLE();
        vm.prank(deployer);
        d.distributor.proposeRevokeRole(role, address(d.registry));
        vm.warp(block.timestamp + cfg.timelockDelay);
        vm.prank(deployer);
        d.distributor.executeRevokeRole(role, address(d.registry));

        vm.expectRevert(
            abi.encodeWithSelector(DeployNiara.WiringIncomplete.selector, "LISTING_REGISTRY_ROLE -> ListingRegistry")
        );
        script.verifyWiring(cfg, d);
    }

    function test_VerifyWiring_RevertsWhenTheRegistryIsLinkedToAnotherSettlement() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();
        NiaraSettlement other = new NiaraSettlement(
            deployer, address(d.distributor), address(d.registry), address(d.mockUsdt), cfg.timelockDelay
        );
        vm.prank(deployer);
        d.registry.proposeSetSettlement(address(other));
        vm.warp(block.timestamp + cfg.timelockDelay);
        vm.prank(deployer);
        d.registry.executeSetSettlement(address(other));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployNiara.WiringIncomplete.selector, "ListingRegistry.settlement -> NiaraSettlement"
            )
        );
        script.verifyWiring(cfg, d);
        // And the deployment can no longer be read back from that settlement's address.
        vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.DeploymentMismatch.selector, "registry.settlement"));
        script.resolveDeployment(address(d.settlement), address(d.escrow), address(d.mockBrl));
    }

    function test_VerifyWiring_RevertsForTheWrongOperator() public {
        (DeployNiara.Config memory cfg, NiaraScriptBase.Deployment memory d) = _bothPhases();
        cfg.operator = makeAddr("anotherOperator");
        vm.expectRevert(
            abi.encodeWithSelector(DeployNiara.WiringIncomplete.selector, "SETTLEMENT_OPERATOR_ROLE -> operator")
        );
        script.verifyWiring(cfg, d);
    }

    // ── resolveDeployment ──────────────────────────────────────────────────────────────

    function test_ResolveDeployment_DerivesEverythingFromThreeAddresses() public {
        (, NiaraScriptBase.Deployment memory d) = _phase1();
        NiaraScriptBase.Deployment memory r =
            script.resolveDeployment(address(d.settlement), address(d.escrow), address(d.mockBrl));

        assertEq(address(r.registry), address(d.registry));
        assertEq(address(r.factory), address(d.factory));
        assertEq(address(r.distributor), address(d.distributor));
        assertEq(address(r.mockUsdt), address(d.mockUsdt));
        assertEq(address(r.mockBrl), address(d.mockBrl));
        assertEq(address(r.settlement), address(d.settlement));
        assertEq(address(r.escrow), address(d.escrow));
    }

    function test_ResolveDeployment_RevertsForAnAddressWithoutCode() public {
        (, NiaraScriptBase.Deployment memory d) = _phase1();
        address empty = makeAddr("empty");

        vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.NotAContract.selector, "NiaraSettlement", empty));
        script.resolveDeployment(empty, address(d.escrow), address(d.mockBrl));
        vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.NotAContract.selector, "P2PEscrow", empty));
        script.resolveDeployment(address(d.settlement), empty, address(d.mockBrl));
        vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.NotAContract.selector, "mock BRL", empty));
        script.resolveDeployment(address(d.settlement), address(d.escrow), empty);
    }

    /// @notice An escrow from another deployment is refused, not silently mixed in.
    function test_ResolveDeployment_RevertsForAnEscrowOfAnotherDeployment() public {
        (, NiaraScriptBase.Deployment memory first) = _phase1();
        (, NiaraScriptBase.Deployment memory second) = _phase1();

        vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.DeploymentMismatch.selector, "escrow.settlement"));
        script.resolveDeployment(address(first.settlement), address(second.escrow), address(first.mockBrl));
    }

    function test_ResolveDeployment_RevertsWhenTheMockBrlIsTheFeeToken() public {
        (, NiaraScriptBase.Deployment memory d) = _phase1();
        vm.expectRevert(
            abi.encodeWithSelector(NiaraScriptBase.DeploymentMismatch.selector, "mock BRL is the fee token")
        );
        script.resolveDeployment(address(d.settlement), address(d.escrow), address(d.mockUsdt));
    }

    // ── TestnetMockToken ───────────────────────────────────────────────────────────────

    function test_MockToken_AnyoneCanMintUpToTheFaucetCap() public {
        TestnetMockToken token = new TestnetMockToken("Niara Mock USDT (TESTNET ONLY - NO VALUE)", "mockUSDT", 6);
        assertEq(token.MAX_MINT_WHOLE_TOKENS(), 1_000_000);
        assertEq(token.maxMintPerCall(), 1_000_000e6);

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        token.mint(anyone, 1_000_000e6);
        assertEq(token.balanceOf(anyone), 1_000_000e6);
        assertEq(token.totalSupply(), 1_000_000e6);
    }

    function test_MockToken_MintAboveTheFaucetCapReverts() public {
        TestnetMockToken token = new TestnetMockToken("Niara Mock BRL (TESTNET ONLY - NO VALUE)", "mockBRL", 6);
        vm.expectRevert(
            abi.encodeWithSelector(TestnetMockToken.MintExceedsFaucetCap.selector, 1_000_000e6 + 1, 1_000_000e6)
        );
        token.mint(address(this), 1_000_000e6 + 1);
    }

    function test_MockToken_CapFollowsTheDecimals() public {
        TestnetMockToken token = new TestnetMockToken("Test", "T18", 18);
        assertEq(token.decimals(), 18);
        assertEq(token.maxMintPerCall(), 1_000_000 ether);
    }

    /// @notice A plain ERC-20: transfers deliver exactly what was sent (no fee, no hook).
    function test_MockToken_TransfersAreExact() public {
        TestnetMockToken token = new TestnetMockToken("Test", "T", 6);
        address to = makeAddr("to");
        token.mint(address(this), 100e6);
        token.transfer(to, 40e6);
        assertEq(token.balanceOf(to), 40e6);
        assertEq(token.balanceOf(address(this)), 60e6);
    }
}

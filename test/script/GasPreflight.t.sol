// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployNiara} from "../../script/Deploy.s.sol";
import {NiaraScriptBase} from "../../script/NiaraScriptBase.sol";
import {TestnetMockToken} from "../../script/tokens/TestnetMockToken.sol";

/// @notice The gas preflight the broadcasting entry points run (`NiaraScriptBase`), and the
/// needs the deploy phases declare. The demo's needs are tested in `DemoScript.t.sol`.
contract GasPreflightTest is Test {
    DeployNiara internal script;

    address internal deployer = makeAddr("deployer");
    address internal listingAuthority = makeAddr("listingAuthority");
    address internal operator = makeAddr("operator");

    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant ROBINHOOD_TESTNET = 46630;
    uint256 internal constant HYPEREVM_TESTNET = 998;
    uint256 internal constant TEMPO_TESTNET = 42431;

    function setUp() public {
        script = new DeployNiara();
        vm.chainId(BASE_SEPOLIA);
    }

    function _config() internal view returns (DeployNiara.Config memory cfg) {
        cfg.deployer = deployer;
        cfg.listingAuthority = listingAuthority;
        cfg.operator = operator;
        cfg.timelockDelay = 1 hours;
        cfg.cashbackBps = 2_000;
    }

    /// @dev Puts a fee token with real balances at Tempo's pathUSD address.
    function _pathUsd() internal returns (TestnetMockToken token) {
        deployCodeTo("TestnetMockToken.sol:TestnetMockToken", abi.encode("pathUSD", "pathUSD", uint8(6)), script.TEMPO_PATH_USD());
        token = TestnetMockToken(script.TEMPO_PATH_USD());
    }

    // ── Chain parameters ───────────────────────────────────────────────────────────────

    function test_DefaultGasEstimateMultiplier_PerChain() public view {
        assertEq(script.defaultGasEstimateMultiplier(BASE_SEPOLIA), 130);
        assertEq(script.defaultGasEstimateMultiplier(HYPEREVM_TESTNET), 130);
        assertEq(script.defaultGasEstimateMultiplier(ROBINHOOD_TESTNET), 200);
        assertEq(script.defaultGasEstimateMultiplier(TEMPO_TESTNET), 700);
        assertEq(script.defaultGasEstimateMultiplier(SEPOLIA), 800);
    }

    /// @notice `GAS_ESTIMATE_MULTIPLIER_<chainid>` overrides the default. Set for chain 31337
    /// only, which no other test computes a cost on (`vm.setEnv` changes the whole process).
    function test_GasEstimateMultiplier_PerChainOverride() public {
        vm.chainId(31337);
        vm.setEnv("GAS_ESTIMATE_MULTIPLIER_31337", "");
        assertEq(script.gasEstimateMultiplier(), 130);
        vm.setEnv("GAS_ESTIMATE_MULTIPLIER_31337", "250");
        assertEq(script.gasEstimateMultiplier(), 250);
    }

    /// @notice Inside a forge script `tx.gasprice` is base fee + priority fee, so this is
    /// 2 * base fee + priority fee: what forge signs as the max fee per gas.
    function test_MaxFeePerGas_IsBaseFeePlusGasPrice() public {
        vm.fee(5_000_000);
        vm.txGasPrice(6_000_000);
        assertEq(script.maxFeePerGas(), 11_000_000);
    }

    function test_GasFeeToken_NativeEverywhereButTempo() public {
        uint256[4] memory chains = [SEPOLIA, BASE_SEPOLIA, ROBINHOOD_TESTNET, HYPEREVM_TESTNET];
        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            assertEq(script.gasFeeToken(), address(0));
        }
        vm.chainId(TEMPO_TESTNET);
        assertEq(script.gasFeeToken(), script.TEMPO_PATH_USD());
    }

    function test_GasFeeBalanceOf_NativeBalance() public {
        vm.deal(deployer, 3 ether);
        assertEq(script.gasFeeBalanceOf(deployer), 3 ether);
    }

    /// @notice On Tempo the native balance means nothing: the fee-token balance counts.
    function test_GasFeeBalanceOf_FeeTokenOnTempo() public {
        TestnetMockToken pathUsd = _pathUsd();
        pathUsd.mint(deployer, 25e6);
        vm.deal(deployer, 3 ether);
        vm.chainId(TEMPO_TESTNET);
        assertEq(script.gasFeeBalanceOf(deployer), 25e6);
    }

    function test_GasCost_AppliesTheMultiplier() public view {
        uint256 m = script.gasEstimateMultiplier();
        assertEq(script.gasCost(1_000_000, 10_000_000), 1_000_000 * m / 100 * 10_000_000);
        assertEq(script.gasCost(0, 10_000_000), 0);
    }

    /// @notice Tempo prices gas in attodollars: the cost is converted to pathUSD base units
    /// (6 decimals, 1e12 attodollars each), rounded up.
    function test_GasCost_ConvertsToPathUsdOnTempo() public {
        vm.chainId(TEMPO_TESTNET);
        uint256 m = script.gasEstimateMultiplier();
        assertEq(script.gasCost(1_000_000, 1_200_000_000), 1_000_000 * m / 100 * 1_200_000_000 / 1e12);
        // 1 gas at 1 attodollar still costs one base unit.
        assertEq(script.gasCost(1, 1), 1);
    }

    /// @notice A transaction with an explicit gas limit is sent with that limit as it is, so
    /// its cost ignores the multiplier. Chain 31339 is set to 900 here, a chain no other test
    /// computes a cost on (`vm.setEnv` changes the whole process).
    function test_GasLimitCost_IgnoresTheMultiplier() public {
        vm.chainId(31339);
        vm.setEnv("GAS_ESTIMATE_MULTIPLIER_31339", "900");
        assertEq(script.gasLimitCost(1_000_000, 10_000_000), 1_000_000 * 10_000_000);
        assertEq(script.gasCost(1_000_000, 10_000_000), 9 * 1_000_000 * 10_000_000);
        assertEq(script.gasLimitCost(0, 10_000_000), 0);
    }

    /// @notice On Tempo the cost of a fixed limit is converted to pathUSD base units, rounded up.
    function test_GasLimitCost_ConvertsToPathUsdOnTempo() public {
        vm.chainId(TEMPO_TESTNET);
        assertEq(script.gasLimitCost(1_000_000, 1_200_000_000), 1_200);
        assertEq(script.gasLimitCost(1, 1), 1);
    }

    // ── Shortfall and report ───────────────────────────────────────────────────────────

    function test_GasShortfall_CountsValueSentAndValueReceived() public {
        uint256 fee = 1 gwei;
        uint256 cost = script.gasCost(100_000, fee);
        vm.deal(deployer, cost);

        NiaraScriptBase.GasNeed memory need = NiaraScriptBase.GasNeed("deployer", deployer, 100_000, 0, 0, 0);
        (uint256 required, uint256 available, uint256 missing) = script.gasShortfall(need, fee);
        assertEq(required, cost);
        assertEq(available, cost);
        assertEq(missing, 0);

        // Sending value on top of the gas makes it short by exactly that value.
        need.value = 7;
        (,, missing) = script.gasShortfall(need, fee);
        assertEq(missing, 7);

        // A top-up received first covers it.
        need.incoming = 7;
        (, available, missing) = script.gasShortfall(need, fee);
        assertEq(available, cost + 7);
        assertEq(missing, 0);
    }

    /// @notice Fixed gas limits (`fixedGas`) are counted on top of the estimated gas, without
    /// the multiplier.
    function test_GasShortfall_CountsFixedGasWithoutTheMultiplier() public {
        uint256 fee = 1 gwei;
        NiaraScriptBase.GasNeed memory need = NiaraScriptBase.GasNeed("issuer", deployer, 100_000, 0, 0, 50_000);
        uint256 expected = script.gasCost(100_000, fee) + 50_000 * fee;
        vm.deal(deployer, expected - 1);
        (uint256 required,, uint256 missing) = script.gasShortfall(need, fee);
        assertEq(required, expected);
        assertEq(missing, 1);

        // Only fixed limits: exactly limit * fee.
        need.gas = 0;
        (required,,) = script.gasShortfall(need, fee);
        assertEq(required, 50_000 * fee);
    }

    function test_CheckGasFunds_PassesWhenEveryWalletIsCovered() public {
        uint256 fee = 1 gwei;
        vm.deal(deployer, script.gasCost(100_000, fee));
        vm.deal(operator, 1 ether);
        NiaraScriptBase.GasNeed[] memory needs = new NiaraScriptBase.GasNeed[](2);
        needs[0] = NiaraScriptBase.GasNeed("deployer", deployer, 100_000, 0, 0, 0);
        needs[1] = NiaraScriptBase.GasNeed("operator", operator, 50_000, 0, 0, 0);
        assertEq(script.checkGasFunds("phase", needs, fee, true), 0);
    }

    /// @notice Refuses to start, naming EVERY short wallet with what it has, needs and misses.
    function test_CheckGasFunds_RevertsListingEveryShortWallet() public {
        uint256 fee = 1 gwei;
        uint256 deployerNeed = script.gasCost(100_000, fee);
        uint256 listingNeed = script.gasCost(40_000, fee);
        vm.deal(deployer, 1000);
        vm.deal(operator, 1 ether);
        vm.deal(listingAuthority, 0);

        NiaraScriptBase.GasNeed[] memory needs = new NiaraScriptBase.GasNeed[](3);
        needs[0] = NiaraScriptBase.GasNeed("deployer", deployer, 100_000, 0, 0, 0);
        needs[1] = NiaraScriptBase.GasNeed("operator", operator, 50_000, 0, 0, 0);
        needs[2] = NiaraScriptBase.GasNeed("listing authority", listingAuthority, 40_000, 0, 0, 0);

        string memory expected = string.concat(
            "deployer ",
            vm.toString(deployer),
            ": needs ",
            vm.toString(deployerNeed),
            ", has 1000 wei, missing ",
            vm.toString(deployerNeed - 1000),
            "; listing authority ",
            vm.toString(listingAuthority),
            ": needs ",
            vm.toString(listingNeed),
            ", has 0 wei, missing ",
            vm.toString(listingNeed)
        );
        vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.InsufficientGasFunds.selector, "deploy phase 2", expected));
        script.checkGasFunds("deploy phase 2", needs, fee, true);
    }

    /// @notice Not enforcing (a dry run) only reports how many wallets are short.
    function test_CheckGasFunds_WarnsWithoutReverting() public {
        NiaraScriptBase.GasNeed[] memory needs = new NiaraScriptBase.GasNeed[](2);
        needs[0] = NiaraScriptBase.GasNeed("deployer", deployer, 100_000, 0, 0, 0);
        needs[1] = NiaraScriptBase.GasNeed("operator", operator, 50_000, 0, 0, 0);
        assertEq(script.checkGasFunds("phase", needs, 1 gwei, false), 2);
    }

    /// @notice On Tempo the check reads the fee token, in its base units.
    function test_CheckGasFunds_UsesTheFeeTokenOnTempo() public {
        TestnetMockToken pathUsd = _pathUsd();
        vm.chainId(TEMPO_TESTNET);
        uint256 fee = 1_200_000_000;
        uint256 need = script.gasCost(13_000_000, fee);
        vm.deal(deployer, 100 ether); // native balance is ignored on Tempo

        NiaraScriptBase.GasNeed[] memory needs = new NiaraScriptBase.GasNeed[](1);
        needs[0] = NiaraScriptBase.GasNeed("deployer", deployer, 13_000_000, 0, 0, 0);
        string memory expected = string.concat(
            "deployer ",
            vm.toString(deployer),
            ": needs ",
            vm.toString(need),
            ", has 0 fee-token base units, missing ",
            vm.toString(need)
        );
        vm.expectRevert(abi.encodeWithSelector(NiaraScriptBase.InsufficientGasFunds.selector, "deploy phase 1", expected));
        script.checkGasFunds("deploy phase 1", needs, fee, true);

        pathUsd.mint(deployer, need);
        assertEq(script.checkGasFunds("deploy phase 1", needs, fee, true), 0);
    }

    // ── What the deploy phases need ────────────────────────────────────────────────────

    function test_Phase1GasNeeds_OnlyTheDeployer() public view {
        NiaraScriptBase.GasNeed[] memory needs = script.phase1GasNeeds(_config());
        assertEq(needs.length, 1);
        assertEq(needs[0].wallet, deployer);
        assertEq(needs[0].gas, script.PHASE1_DEPLOYER_GAS());
        assertEq(needs[0].value, 0);
    }

    /// @notice Before phase 2 the deployer has five executes and the listing authority two
    /// listings; after it, nothing is left (a re-run sends nothing).
    function test_Phase2GasNeeds_CountsOnlyThePendingSteps() public {
        vm.chainId(SEPOLIA);
        DeployNiara.Config memory cfg = _config();
        NiaraScriptBase.Deployment memory d = script.deployAndPropose(cfg);

        NiaraScriptBase.GasNeed[] memory needs = script.phase2GasNeeds(cfg, d);
        assertEq(needs.length, 2);
        assertEq(needs[0].wallet, deployer);
        assertEq(needs[0].gas, 5 * script.WIRING_EXECUTE_GAS());
        assertEq(needs[1].wallet, listingAuthority);
        assertEq(needs[1].gas, 2 * script.LIST_CURRENCY_GAS());

        vm.warp(block.timestamp + cfg.timelockDelay);
        script.executeWiringOn(cfg, d);
        needs = script.phase2GasNeeds(cfg, d);
        assertEq(needs[0].gas, 0);
        assertEq(needs[1].gas, 0);
    }

    function test_Phase2GasNeeds_OneEntryWhenTheDeployerIsTheListingAuthority() public {
        vm.chainId(SEPOLIA);
        DeployNiara.Config memory cfg = _config();
        cfg.listingAuthority = deployer;
        NiaraScriptBase.Deployment memory d = script.deployAndPropose(cfg);

        NiaraScriptBase.GasNeed[] memory needs = script.phase2GasNeeds(cfg, d);
        assertEq(needs.length, 1);
        assertEq(needs[0].wallet, deployer);
        assertEq(needs[0].gas, 5 * script.WIRING_EXECUTE_GAS() + 2 * script.LIST_CURRENCY_GAS());
    }

    /// @notice The budgets cover what the Base Sepolia deployment really used (2026-11-16):
    /// phase 1 12,057,706 gas, the executes up to 53,419 each, the listings 80,464 each.
    function test_DeployBudgets_CoverTheMeasuredBaseSepoliaGas() public view {
        assertGe(script.PHASE1_DEPLOYER_GAS(), 12_057_706);
        assertGe(script.WIRING_EXECUTE_GAS(), 53_419);
        assertGe(script.LIST_CURRENCY_GAS(), 80_464);
    }
}

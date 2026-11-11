// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {BackingGateway} from "../src/BackingGateway.sol";
import {NiaraSettlement} from "../src/NiaraSettlement.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {ListingRegistry} from "../src/ListingRegistry.sol";
import {AssetTokenFactory} from "../src/AssetTokenFactory.sol";
import {NativeAssetToken} from "../src/NativeAssetToken.sol";
import {IListingRegistry} from "../src/interfaces/IListingRegistry.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice End-to-end flows with the real contracts wired together.
/// - Native (v1): issuer deploys its instrument → listing submitted and approved →
///   issuance batch requested and approved → atomic settlement with fee → cashback
///   credited and withdrawn by the issuer → holder burns with a reason.
/// - Backed (kept for the future, not tradable in v1): attested backing → mint →
///   redemption. A backed AssetToken is not a factory token, so it cannot be listed and
///   cannot settle.
contract IntegrationTest is Test {
    AssetToken public assetToken;
    BackingGateway public gateway;
    NiaraSettlement public settlement;
    CashbackDistributor public distributor;
    ListingRegistry public registry;
    MockUSDT public usdt;

    address public admin = makeAddr("admin");
    address public listingAuthority = makeAddr("listingAuthority");
    address public issuer = makeAddr("issuer");
    address public operator = makeAddr("operator");
    address public custodian = makeAddr("custodian");
    address public settlementOperator = makeAddr("settlementOperator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");

    uint256 public constant TIMELOCK_DELAY = 2 days;

    uint128 internal matchCounter;

    /// @dev A fresh match id per settlement (internal: does not consume a pending prank).
    function _nextMatchId() internal returns (bytes16) {
        return bytes16(++matchCounter);
    }

    function setUp() public {
        registry = new ListingRegistry(admin, listingAuthority, TIMELOCK_DELAY);
        distributor = new CashbackDistributor(admin, address(registry), TIMELOCK_DELAY);
        usdt = new MockUSDT();
        settlement =
            new NiaraSettlement(admin, address(distributor), address(registry), address(usdt), TIMELOCK_DELAY);
        gateway = new BackingGateway(admin, TIMELOCK_DELAY);
        assetToken = new AssetToken(
            "Apple Inc. - Niara Tokenized Equity",
            "nAAPL",
            "AAPL",
            AssetToken.AssetClass.EQUITY,
            "US",
            issuer,
            admin,
            TIMELOCK_DELAY
        );

        // Role wiring: every grant goes through the timelock, as in production.
        _grantRoleOn(address(distributor), distributor.SETTLEMENT_ROLE(), address(settlement));
        _grantRoleOn(address(settlement), settlement.SETTLEMENT_OPERATOR_ROLE(), settlementOperator);
        _grantRoleOn(address(gateway), gateway.OPERATOR_ROLE(), operator);
        _grantRoleOn(address(gateway), gateway.CUSTODIAN_ROLE(), custodian);
        _grantRoleOn(address(assetToken), assetToken.MINTER_ROLE(), address(gateway));
        _grantRoleOn(address(assetToken), assetToken.BURNER_ROLE(), address(gateway));

        vm.prank(admin);
        assetToken.proposeSetBackingGateway(address(gateway));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        assetToken.executeSetBackingGateway(address(gateway));

        vm.prank(listingAuthority);
        registry.listCurrency(address(usdt));

        usdt.mint(buyer, 1_000_000e6);
    }

    function _grantRoleOn(address target, bytes32 role, address account) internal {
        vm.prank(admin);
        (bool ok1,) = target.call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, account));
        require(ok1, "propose failed");
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        (bool ok2,) = target.call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, account));
        require(ok2, "execute failed");
    }

    function test_FullLifecycle_NativeIssuanceToSettlementToCashbackToBurn() public {
        // 1. Issuance: the issuer deploys its instrument from its own wallet.
        bytes32 docHash = keccak256("acme-offering-memorandum");
        // Resolve the factory before the prank (the getter would consume it).
        AssetTokenFactory factory = registry.factory();
        vm.prank(issuer);
        NativeAssetToken acme = NativeAssetToken(
            factory.createAssetToken("Acme Corp Shares", "ACME", IListingRegistry.AssetClass.Equity, docHash)
        );

        // 2. Curated listing: submit (issuer) → approve (listing authority).
        vm.prank(issuer);
        registry.submitListing(address(acme));
        vm.prank(listingAuthority);
        registry.approveListing(address(acme));

        // 3. Issuance batch: requested by the issuer, approved by the authority, minted by
        // the registry to the seller.
        vm.prank(issuer);
        uint256 batchNo = registry.requestIssuance(address(acme), 1_000 ether, seller, keccak256("batch-1"));
        vm.prank(listingAuthority);
        registry.approveIssuance(address(acme), batchNo);
        assertEq(acme.balanceOf(seller), 1_000 ether);

        // 4. Atomic settlement: seller delivers 100 ACME, buyer pays 10,000 USDT.
        vm.prank(seller);
        acme.approve(address(settlement), 100 ether);
        vm.prank(buyer);
        usdt.approve(address(settlement), 10_000e6);

        vm.prank(settlementOperator);
        uint256 feeCharged = settlement.settle(_nextMatchId(), address(acme), address(usdt), buyer, seller, 100 ether, 10_000e6);

        uint256 expectedFee = (10_000e6 * settlement.feeBps()) / 10_000;
        assertEq(feeCharged, expectedFee);
        assertEq(acme.balanceOf(buyer), 100 ether);
        assertEq(acme.balanceOf(seller), 900 ether);
        assertEq(usdt.balanceOf(seller), 10_000e6 - expectedFee);
        assertEq(usdt.balanceOf(address(distributor)), expectedFee);

        // 5. Cashback: the issuer withdraws the credited share.
        uint256 expectedCashback = (expectedFee * distributor.cashbackBps()) / 10_000;
        assertEq(distributor.cashbackBalance(address(acme), address(usdt)), expectedCashback);
        vm.prank(issuer);
        distributor.withdraw(address(acme), address(usdt));
        assertEq(usdt.balanceOf(issuer), expectedCashback);

        // 6. Burn: the buyer redeems part of its position, recording the reason.
        vm.prank(buyer);
        acme.burnWithReason(40 ether, NativeAssetToken.BurnReason.Redemption, keccak256("redemption-1"));
        assertEq(acme.balanceOf(buyer), 60 ether);
        assertEq(acme.totalSupply(), 960 ether);

        // 7. Suspension stops trading immediately.
        vm.prank(listingAuthority);
        registry.suspendListing(address(acme));
        vm.prank(seller);
        acme.approve(address(settlement), 1 ether);
        vm.prank(buyer);
        usdt.approve(address(settlement), 100e6);
        vm.prank(settlementOperator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetListingNotApproved.selector, address(acme)));
        settlement.settle(_nextMatchId(), address(acme), address(usdt), buyer, seller, 1 ether, 100e6);
    }

    /// @notice One shared pause (spec §3.3): a single `registry.pause()` stops issuance
    /// execution, settlement and both distributor payouts together; listing actions and
    /// holder burns stay available; a single `unpause()` restores everything.
    function test_SharedPause_StopsIssuanceSettlementAndPayoutsTogether() public {
        AssetTokenFactory factory = registry.factory();
        vm.prank(issuer);
        NativeAssetToken acme = NativeAssetToken(
            factory.createAssetToken("Acme Corp Shares", "ACME", IListingRegistry.AssetClass.Equity, keccak256("doc"))
        );
        vm.prank(issuer);
        registry.submitListing(address(acme));
        vm.prank(listingAuthority);
        registry.approveListing(address(acme));
        vm.prank(issuer);
        uint256 batch1 = registry.requestIssuance(address(acme), 1_000 ether, seller, keccak256("batch-1"));
        vm.prank(listingAuthority);
        registry.approveIssuance(address(acme), batch1);

        vm.prank(seller);
        acme.approve(address(settlement), type(uint256).max);
        vm.prank(buyer);
        usdt.approve(address(settlement), type(uint256).max);
        vm.prank(settlementOperator);
        uint256 fee = settlement.settle(_nextMatchId(), address(acme), address(usdt), buyer, seller, 100 ether, 10_000e6);
        uint256 cashback = distributor.cashbackBalance(address(acme), address(usdt));
        uint256 protocolShare = distributor.protocolBalance(address(usdt));
        assertEq(cashback + protocolShare, fee);

        vm.prank(issuer);
        uint256 batch2 = registry.requestIssuance(address(acme), 10 ether, seller, keccak256("batch-2"));

        // One call pauses the whole protocol.
        vm.prank(admin);
        registry.pause();
        assertTrue(settlement.paused());
        assertTrue(distributor.paused());

        vm.prank(listingAuthority);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.approveIssuance(address(acme), batch2);

        vm.prank(settlementOperator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settlement.settle(_nextMatchId(), address(acme), address(usdt), buyer, seller, 1 ether, 100e6);

        vm.prank(issuer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        distributor.withdraw(address(acme), address(usdt));

        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        distributor.withdrawProtocolFees(address(usdt), admin, protocolShare);

        // Not payouts based on protocol accounting: still allowed while paused.
        vm.prank(buyer);
        acme.burnWithReason(1 ether, NativeAssetToken.BurnReason.Redemption, keccak256("burn-while-paused"));
        vm.prank(issuer);
        registry.requestIssuance(address(acme), 5 ether, seller, keccak256("batch-3"));

        // One call resumes everything; nothing accrued was lost.
        vm.prank(admin);
        registry.unpause();

        vm.prank(listingAuthority);
        registry.approveIssuance(address(acme), batch2);
        vm.prank(settlementOperator);
        settlement.settle(_nextMatchId(), address(acme), address(usdt), buyer, seller, 1 ether, 100e6);
        vm.prank(issuer);
        distributor.withdraw(address(acme), address(usdt));
        assertGe(usdt.balanceOf(issuer), cashback);
        vm.prank(admin);
        distributor.withdrawProtocolFees(address(usdt), admin, protocolShare);
        assertEq(usdt.balanceOf(admin), protocolShare);
    }

    function test_FullLifecycle_BackingToRedemption_NotTradable() public {
        // 1. Backing: request → attestation → mint to the seller.
        vm.prank(operator);
        uint256 requestId = gateway.requestBacking(address(assetToken), 1_000 ether);

        vm.prank(custodian);
        gateway.attestBacking(requestId, keccak256("proof-custody-1"), 1_000 ether);

        vm.prank(operator);
        gateway.mintAttested(requestId, seller);

        assertEq(assetToken.balanceOf(seller), 1_000 ether);
        assertEq(assetToken.totalSupply(), 1_000 ether);

        // 2. Not tradable in v1: a backed AssetToken cannot be listed, so settle rejects it.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ListingRegistry.NotFactoryToken.selector, address(assetToken)));
        registry.submitListing(address(assetToken));

        vm.prank(seller);
        assetToken.approve(address(settlement), 100 ether);
        vm.prank(buyer);
        usdt.approve(address(settlement), 10_000e6);
        vm.prank(settlementOperator);
        vm.expectRevert(abi.encodeWithSelector(NiaraSettlement.AssetListingNotApproved.selector, address(assetToken)));
        settlement.settle(_nextMatchId(), address(assetToken), address(usdt), buyer, seller, 100 ether, 10_000e6);

        // 3. Redemption: the holder returns part of the tokens for the real-world asset.
        vm.prank(seller);
        assetToken.approve(address(gateway), 40 ether);
        vm.prank(seller);
        uint256 redemptionId = gateway.redemptionRequest(address(assetToken), 40 ether);

        uint256 attestedBefore = gateway.totalAttested(address(assetToken));

        vm.prank(custodian);
        gateway.redemptionAttest(redemptionId, keccak256("proof-release-1"));

        assertEq(assetToken.balanceOf(seller), 960 ether);
        assertEq(gateway.totalAttested(address(assetToken)), attestedBefore - 40 ether);
        assertEq(assetToken.totalSupply(), 1_000 ether - 40 ether);

        // Final invariant: at all times, totalSupply <= totalAttested.
        assertLe(assetToken.totalSupply(), gateway.totalAttested(address(assetToken)));
    }
}

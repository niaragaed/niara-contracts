// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ListingRegistry} from "../../src/ListingRegistry.sol";
import {CashbackDistributor} from "../../src/CashbackDistributor.sol";

/// @dev Any test token with an open `mint` (MockUSDT, TestnetMockToken, ...).
interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @notice Helpers for the on-chain listing fee (spec §3.13). Since paying the fee is the only
/// way an issuer listing is first approved, every suite that needs an `Approved` native
/// listing goes through `quoteListing` + `payListingFee`, after wiring the registry to the
/// settlement and granting it LISTING_REGISTRY_ROLE on the distributor, both through the
/// timelock, as in production.
abstract contract ListingFeeHelpers is Test {
    /// @dev 1,000,000 USDT valuation at 10 bps (the 0.1% pricing floor): a 1,000 USDT fee.
    uint256 internal constant HELPER_VALUATION = 1_000_000e6;
    uint16 internal constant HELPER_LISTING_FEE_BPS = 10;

    /// @dev Links `registry` to `settlement` and grants it LISTING_REGISTRY_ROLE on
    /// `distributor`, through both timelocks. `admin` must be the admin of both.
    function _wireListingFee(ListingRegistry registry, CashbackDistributor distributor, address settlement, address admin)
        internal
    {
        // Resolved before any prank: these getters are external calls and would consume it.
        bytes32 role = distributor.LISTING_REGISTRY_ROLE();
        uint256 delay = registry.timelockDelay();
        if (distributor.timelockDelay() > delay) delay = distributor.timelockDelay();
        vm.startPrank(admin);
        registry.proposeSetSettlement(settlement);
        distributor.proposeGrantRole(role, address(registry));
        vm.warp(block.timestamp + delay);
        registry.executeSetSettlement(settlement);
        distributor.executeGrantRole(role, address(registry));
        vm.stopPrank();
    }

    /// @dev Approves a `Pending` listing the only way it can be: the listing authority quotes
    /// the fee and the issuer, funded with exactly that fee, pays it. The issuer's balance of
    /// the fee token ends where it started; the distributor holds `fee` more.
    /// @return fee The listing fee paid.
    function _approveByFee(ListingRegistry registry, address listingAuthority, address token)
        internal
        returns (uint256 fee)
    {
        uint64 expiresAt = uint64(block.timestamp + 1 days);
        vm.prank(listingAuthority);
        registry.quoteListing(token, HELPER_VALUATION, HELPER_LISTING_FEE_BPS, expiresAt);
        ListingRegistry.ListingFeeQuote memory quote = registry.getListingFeeQuote(token);
        fee = quote.listingFee;
        address issuer = registry.getListing(token).issuer;
        IMintableToken(quote.listingFeeToken).mint(issuer, fee);
        vm.prank(issuer);
        IERC20(quote.listingFeeToken).approve(address(registry), fee);
        vm.prank(issuer);
        registry.payListingFee(token);
    }

    /// @dev `_approveByFee`, then the treasury withdraws that fee to `sink`, so the
    /// distributor's balance and `protocolBalance` are back where they were. For suites whose
    /// expected figures only count trading fees.
    function _approveByFeeAndWithdraw(
        ListingRegistry registry,
        CashbackDistributor distributor,
        address listingAuthority,
        address treasury,
        address sink,
        address token
    ) internal returns (uint256 fee) {
        fee = _approveByFee(registry, listingAuthority, token);
        address feeToken = registry.getListingFeeQuote(token).listingFeeToken;
        vm.prank(treasury);
        distributor.withdrawProtocolFees(feeToken, sink, fee);
    }
}

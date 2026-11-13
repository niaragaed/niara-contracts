// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {ProtocolPausable} from "./governance/ProtocolPausable.sol";
import {IAssetToken} from "./interfaces/IAssetToken.sol";

/// @title CashbackDistributor
/// @notice Receives the cashback share (already transferred by NiaraSettlement) and credits
/// the asset's issuer in a pull pattern: amounts accumulate per (asset, settlement
/// currency) and the issuer withdraws whenever it wants via `withdraw`. The rest of the fee
/// accumulates as protocol revenue, withdrawable by the treasury.
///
/// Pause: both withdrawals are payouts based on the protocol's own accounting, so both stop
/// while the protocol's shared pause (held by the ListingRegistry, see ProtocolPausable) is
/// active. `recordFee` is not paused: it only runs inside `settle`, which is.
contract CashbackDistributor is TimelockedAccessControl, ProtocolPausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    /// @notice Held by P2PEscrow: the only caller of `recordDealFee`. Separate from
    /// SETTLEMENT_ROLE so neither contract can use the other's accounting entry point.
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard cap: cashback can never exceed 100% of the fee received.
    uint16 public constant MAX_CASHBACK_BPS = 10_000;

    // TO BE DEFINED: the right share is still a business decision (1% of the fee equals
    // 0.005% of volume, probably not enough). See the whitepaper, section 4.
    /// @notice Share of the fee, in bps, passed on to the issuer. There is no default: it is
    /// set at deployment (constructor), bounded by `MAX_CASHBACK_BPS`, and from then on it
    /// changes only through the timelock (`proposeSetCashbackBps` / `executeSetCashbackBps`).
    uint16 public cashbackBps;

    /// @notice Accumulated cashback balance, per asset and per settlement currency, that
    /// the issuer can withdraw.
    mapping(address assetToken => mapping(address paymentToken => uint256)) public cashbackBalance;

    /// @notice Protocol revenue balance (fee minus cashback), per settlement currency.
    mapping(address paymentToken => uint256) public protocolBalance;

    event FeeRecorded(
        address indexed assetToken, address indexed paymentToken, uint256 feeAmount, uint256 cashbackAmount, bool eligible
    );
    event CashbackCredited(address indexed assetToken, address indexed paymentToken, address indexed issuer, uint256 amount);
    event CashbackWithdrawn(address indexed assetToken, address indexed paymentToken, address indexed issuer, uint256 amount);
    event ProtocolFeesWithdrawn(address indexed paymentToken, address indexed to, uint256 amount);
    event CashbackBpsChangeProposed(uint16 newCashbackBps, uint256 executeAfter);
    event CashbackBpsChanged(uint16 oldCashbackBps, uint16 newCashbackBps);

    error ZeroAddress();
    error ZeroFeeAmount();
    error CashbackBpsExceedsCap(uint16 cashbackBps);
    error NotIssuerWallet();
    error NothingToWithdraw();
    error InvalidWithdrawAmount();
    error CashbackFrozen(address assetToken);

    /// @param admin_ Holder of DEFAULT_ADMIN_ROLE and TREASURY_ROLE.
    /// @param listingRegistry_ ListingRegistry holding the shared protocol pause.
    /// @param timelockDelay_ Delay (seconds) between proposal and execution of sensitive changes.
    /// @param cashbackBps_ Initial share of the fee passed on to the issuer, in bps, at most
    /// `MAX_CASHBACK_BPS`. Later changes go through the timelock.
    constructor(address admin_, address listingRegistry_, uint256 timelockDelay_, uint16 cashbackBps_)
        TimelockedAccessControl(timelockDelay_)
        ProtocolPausable(listingRegistry_)
    {
        if (admin_ == address(0) || listingRegistry_ == address(0)) revert ZeroAddress();
        if (cashbackBps_ > MAX_CASHBACK_BPS) revert CashbackBpsExceedsCap(cashbackBps_);
        cashbackBps = cashbackBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(TREASURY_ROLE, admin_);
    }

    /// @notice Records `feeAmount` of `paymentToken`, already transferred to this contract
    /// by NiaraSettlement, and credits the issuer of `assetToken` proportionally, only
    /// if `assetToken.cashbackEligible()` is true. The rest becomes protocol revenue.
    function recordFee(address assetToken, address paymentToken, uint256 feeAmount) external onlyRole(SETTLEMENT_ROLE) {
        if (feeAmount == 0) revert ZeroFeeAmount();

        bool eligible = IAssetToken(assetToken).cashbackEligible();
        uint256 cashbackAmount = 0;

        if (eligible) {
            cashbackAmount = (feeAmount * cashbackBps) / BPS_DENOMINATOR;
            if (cashbackAmount > 0) {
                address issuer = IAssetToken(assetToken).issuerWallet();
                cashbackBalance[assetToken][paymentToken] += cashbackAmount;
                emit CashbackCredited(assetToken, paymentToken, issuer, cashbackAmount);
            }
        }

        protocolBalance[paymentToken] += (feeAmount - cashbackAmount);
        emit FeeRecorded(assetToken, paymentToken, feeAmount, cashbackAmount, eligible);
    }

    /// @notice Records the fee of a P2P deal: `feeAmount` of `feeToken`, already transferred
    /// to this contract by P2PEscrow. Unlike `recordFee`, the cashback share uses the rate
    /// fixed on the deal at `openDeal` (`dealCashbackBps`), not the current `cashbackBps`:
    /// the fee and its split are part of the terms both parties agreed (spec §3.5).
    /// @dev Eligibility comes from the asset's listing in the registry, not from the token:
    /// a `Currency` asset is a plain ERC-20 with no `cashbackEligible()` and never accrues
    /// cashback. Not paused: it only runs inside `acceptDeal`, which is.
    /// @param assetToken The deal's asset token (the listing the cashback belongs to).
    /// @param feeToken Token the fee was charged in.
    /// @param feeAmount Fee transferred to this contract (non-zero).
    /// @param dealCashbackBps Cashback rate stored on the deal, at most `MAX_CASHBACK_BPS`.
    /// @return cashbackAmount Share of `feeAmount` credited to the issuer.
    function recordDealFee(address assetToken, address feeToken, uint256 feeAmount, uint16 dealCashbackBps)
        external
        onlyRole(ESCROW_ROLE)
        returns (uint256 cashbackAmount)
    {
        if (feeAmount == 0) revert ZeroFeeAmount();
        if (dealCashbackBps > MAX_CASHBACK_BPS) revert CashbackBpsExceedsCap(dealCashbackBps);

        bool eligible = listingRegistry.getListing(assetToken).cashbackEligible;
        if (eligible) {
            cashbackAmount = (feeAmount * dealCashbackBps) / BPS_DENOMINATOR;
            if (cashbackAmount > 0) {
                address issuer = IAssetToken(assetToken).issuerWallet();
                cashbackBalance[assetToken][feeToken] += cashbackAmount;
                emit CashbackCredited(assetToken, feeToken, issuer, cashbackAmount);
            }
        }

        protocolBalance[feeToken] += (feeAmount - cashbackAmount);
        emit FeeRecorded(assetToken, feeToken, feeAmount, cashbackAmount, eligible);
    }

    /// @notice Withdraws the accumulated cashback of `assetToken` in `paymentToken`. Only the
    /// wallet currently registered as the asset's `issuerWallet` can call it: if the issuer
    /// changes wallets, the new wallet can withdraw the accumulated balance. Blocked while
    /// the protocol is paused and while the listing's cashback is frozen
    /// (`ListingRegistry.freezeCashback`, spec §9.5); accrual continues meanwhile.
    function withdraw(address assetToken, address paymentToken) external nonReentrant whenProtocolNotPaused {
        if (msg.sender != IAssetToken(assetToken).issuerWallet()) revert NotIssuerWallet();
        if (listingRegistry.getListing(assetToken).cashbackFrozen) revert CashbackFrozen(assetToken);

        uint256 amount = cashbackBalance[assetToken][paymentToken];
        if (amount == 0) revert NothingToWithdraw();

        // Checks-effects-interactions: the balance is zeroed and `CashbackWithdrawn` is
        // emitted BEFORE the transfer. A payment token with a hook (ERC-777/ERC-1363) that
        // re-enters during `safeTransfer` already sees nothing left to withdraw, and an
        // off-chain indexer never sees the `Transfer` (or a re-entry's events) before the
        // withdrawal that caused them. A failed transfer reverts everything, event included.
        cashbackBalance[assetToken][paymentToken] = 0;
        emit CashbackWithdrawn(assetToken, paymentToken, msg.sender, amount);

        IERC20(paymentToken).safeTransfer(msg.sender, amount);
    }

    /// @notice Withdraws accumulated protocol revenue. Restricted to the treasury. Blocked
    /// while the protocol is paused.
    function withdrawProtocolFees(address paymentToken, address to, uint256 amount)
        external
        nonReentrant
        onlyRole(TREASURY_ROLE)
        whenProtocolNotPaused
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > protocolBalance[paymentToken]) revert InvalidWithdrawAmount();

        // Checks-effects-interactions, as in `withdraw`: the balance is decreased and
        // `ProtocolFeesWithdrawn` is emitted BEFORE the transfer hands control to the token.
        protocolBalance[paymentToken] -= amount;
        emit ProtocolFeesWithdrawn(paymentToken, to, amount);

        IERC20(paymentToken).safeTransfer(to, amount);
    }

    /// @notice Proposes a new cashback share (bps of the fee). Subject to the immutable
    /// cap `MAX_CASHBACK_BPS` and to the timelock.
    function proposeSetCashbackBps(uint16 newCashbackBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (newCashbackBps > MAX_CASHBACK_BPS) revert CashbackBpsExceedsCap(newCashbackBps);
        bytes32 actionId = keccak256(abi.encode("SET_CASHBACK_BPS", newCashbackBps));
        executeAfter = _scheduleAction(actionId);
        emit CashbackBpsChangeProposed(newCashbackBps, executeAfter);
    }

    /// @notice Executes a proposed cashbackBps change after the timelock delay.
    function executeSetCashbackBps(uint16 newCashbackBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCashbackBps > MAX_CASHBACK_BPS) revert CashbackBpsExceedsCap(newCashbackBps);
        bytes32 actionId = keccak256(abi.encode("SET_CASHBACK_BPS", newCashbackBps));
        _consumeAction(actionId);
        uint16 old = cashbackBps;
        cashbackBps = newCashbackBps;
        emit CashbackBpsChanged(old, newCashbackBps);
    }
}

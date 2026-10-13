// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {IAssetToken} from "./interfaces/IAssetToken.sol";

/// @title CashbackDistributor
/// @notice Receives the cashback share (already transferred by NiaraSettlement) and credits
/// the asset's issuer in a pull pattern: amounts accumulate per (asset, settlement
/// currency) and the issuer withdraws whenever it wants via `withdraw`. The rest of the fee
/// accumulates as protocol revenue, withdrawable by the treasury.
contract CashbackDistributor is TimelockedAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard cap: cashback can never exceed 100% of the fee received.
    uint16 public constant MAX_CASHBACK_BPS = 10_000;

    // TO BE DEFINED: 1% of the fee equals 0.005% of volume, probably not enough.
    // See the whitepaper, section 4.
    /// @notice Share of the fee, in bps, passed on to the issuer. Provisional default: 1000 bps
    /// (10% of the fee).
    uint16 public cashbackBps = 1_000;

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

    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
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

    /// @notice Withdraws the accumulated cashback of `assetToken` in `paymentToken`. Only the
    /// wallet currently registered as the asset's `issuerWallet` can call it: if the issuer
    /// changes wallets, the new wallet can withdraw the accumulated balance.
    function withdraw(address assetToken, address paymentToken) external nonReentrant {
        if (msg.sender != IAssetToken(assetToken).issuerWallet()) revert NotIssuerWallet();

        uint256 amount = cashbackBalance[assetToken][paymentToken];
        if (amount == 0) revert NothingToWithdraw();

        cashbackBalance[assetToken][paymentToken] = 0;
        IERC20(paymentToken).safeTransfer(msg.sender, amount);

        emit CashbackWithdrawn(assetToken, paymentToken, msg.sender, amount);
    }

    /// @notice Withdraws accumulated protocol revenue. Restricted to the treasury.
    function withdrawProtocolFees(address paymentToken, address to, uint256 amount) external nonReentrant onlyRole(TREASURY_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > protocolBalance[paymentToken]) revert InvalidWithdrawAmount();

        protocolBalance[paymentToken] -= amount;
        IERC20(paymentToken).safeTransfer(to, amount);

        emit ProtocolFeesWithdrawn(paymentToken, to, amount);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {ICashbackDistributor} from "./interfaces/ICashbackDistributor.sol";

/// @title NiaraSettlement
/// @notice Atomic settlement between buyer and seller: in the same transaction it moves the
/// AssetToken from seller to buyer, the payment (USDT or WBTC) from buyer to seller, and
/// retains the protocol fee, in the settlement currency itself, with no swap, no DEX and
/// no oracle. Any failure reverts everything.
/// @dev Never holds the parties' balances: it works entirely through `allowance`, moving only
/// the exact amount of each execution. `settle` is restricted to SETTLEMENT_OPERATOR_ROLE:
/// although moving funds depends only on allowance, letting any address trigger settlements
/// between two parties that approved the contract would let an arbitrary caller pick
/// unfavorable terms within those approvals. The role should be granted to Niara's
/// trusted order-matching engine.
contract NiaraSettlement is TimelockedAccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_OPERATOR_ROLE = keccak256("SETTLEMENT_OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard, immutable fee cap: 100 bps (1%). Not even the admin can exceed it.
    uint16 public constant MAX_FEE_BPS = 100;

    /// @notice Current fee, in bps, charged in the settlement currency. Default: 50 bps (0.5%).
    uint16 public feeBps = 50;

    /// @notice Contract that receives the fee and credits cashback to the issuer when eligible.
    ICashbackDistributor public cashbackDistributor;

    event Settled(
        address indexed assetToken,
        address indexed paymentToken,
        address indexed buyer,
        address seller,
        uint256 assetAmount,
        uint256 paymentAmount,
        uint256 feeCharged
    );
    event FeeBpsChangeProposed(uint16 newFeeBps, uint256 executeAfter);
    event FeeBpsChanged(uint16 oldFeeBps, uint16 newFeeBps);
    event CashbackDistributorChangeProposed(address indexed newCashbackDistributor, uint256 executeAfter);
    event CashbackDistributorChanged(address indexed oldCashbackDistributor, address indexed newCashbackDistributor);

    error ZeroAddress();
    error BuyerEqualsSeller();
    error ZeroAmount();
    error FeeExceedsCap(uint16 feeBps);
    error PaymentAmountTooSmallForFeePrecision();

    constructor(address admin_, address cashbackDistributor_, uint256 timelockDelay_)
        TimelockedAccessControl(timelockDelay_)
    {
        if (admin_ == address(0) || cashbackDistributor_ == address(0)) revert ZeroAddress();
        cashbackDistributor = ICashbackDistributor(cashbackDistributor_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
    }

    /// @notice Executes the atomic settlement of an already matched order.
    /// @param assetToken Token of the tokenized asset being traded.
    /// @param paymentToken Settlement currency (USDT or WBTC).
    /// @param buyer Party that receives the asset and pays in `paymentToken`.
    /// @param seller Party that delivers the asset and receives `paymentToken`.
    /// @param assetAmount Amount of `assetToken` transferred from seller to buyer.
    /// @param paymentAmount Total amount of `paymentToken` the buyer pays; the fee is
    /// deducted from this amount before it reaches the seller.
    /// @return feeCharged Fee retained, in `paymentToken`.
    function settle(
        address assetToken,
        address paymentToken,
        address buyer,
        address seller,
        uint256 assetAmount,
        uint256 paymentAmount
    ) external nonReentrant onlyRole(SETTLEMENT_OPERATOR_ROLE) whenNotPaused returns (uint256 feeCharged) {
        if (assetToken == address(0) || paymentToken == address(0)) revert ZeroAddress();
        if (buyer == address(0) || seller == address(0)) revert ZeroAddress();
        if (buyer == seller) revert BuyerEqualsSeller();
        if (assetAmount == 0 || paymentAmount == 0) revert ZeroAmount();

        feeCharged = (paymentAmount * feeBps) / BPS_DENOMINATOR;
        // If the fee is active (feeBps > 0), tiny amounts cannot truncate the fee to
        // zero; otherwise one could trade fee-free with small enough amounts.
        if (feeBps > 0 && feeCharged == 0) revert PaymentAmountTooSmallForFeePrecision();

        uint256 sellerProceeds = paymentAmount - feeCharged;

        // Checks-effects-interactions: `Settled` is emitted BEFORE any external call. A
        // payment token with a hook (ERC-777/ERC-1363) that re-enters another function during
        // one of the `safeTransferFrom` calls below already sees this settlement's event
        // emitted, so off-chain indexers never observe a re-entry "before" the operation
        // that caused it. Since `settle` holds no balance and keeps no per-order state, the
        // event is the only effect to order here.
        emit Settled(assetToken, paymentToken, buyer, seller, assetAmount, paymentAmount, feeCharged);

        IERC20(assetToken).safeTransferFrom(seller, buyer, assetAmount);
        IERC20(paymentToken).safeTransferFrom(buyer, seller, sellerProceeds);
        if (feeCharged > 0) {
            IERC20(paymentToken).safeTransferFrom(buyer, address(cashbackDistributor), feeCharged);
            // `recordFee` comes after the transfer out of necessity: the distributor accounts
            // for a fee that must already be in its balance. Any failure here reverts the whole
            // transaction, including the event above.
            cashbackDistributor.recordFee(assetToken, paymentToken, feeCharged);
        }
    }

    /// @notice Proposes a new fee (bps). Subject to the immutable cap `MAX_FEE_BPS` and to the timelock.
    function proposeSetFeeBps(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 executeAfter) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeExceedsCap(newFeeBps);
        bytes32 actionId = keccak256(abi.encode("SET_FEE_BPS", newFeeBps));
        executeAfter = _scheduleAction(actionId);
        emit FeeBpsChangeProposed(newFeeBps, executeAfter);
    }

    /// @notice Executes a proposed fee change after the timelock delay.
    function executeSetFeeBps(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeExceedsCap(newFeeBps);
        bytes32 actionId = keccak256(abi.encode("SET_FEE_BPS", newFeeBps));
        _consumeAction(actionId);
        uint16 old = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsChanged(old, newFeeBps);
    }

    /// @notice Proposes a new CashbackDistributor address. Subject to the timelock.
    function proposeSetCashbackDistributor(address newCashbackDistributor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (newCashbackDistributor == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_CASHBACK_DISTRIBUTOR", newCashbackDistributor));
        executeAfter = _scheduleAction(actionId);
        emit CashbackDistributorChangeProposed(newCashbackDistributor, executeAfter);
    }

    /// @notice Executes a proposed CashbackDistributor change after the timelock delay.
    function executeSetCashbackDistributor(address newCashbackDistributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_CASHBACK_DISTRIBUTOR", newCashbackDistributor));
        _consumeAction(actionId);
        address old = address(cashbackDistributor);
        cashbackDistributor = ICashbackDistributor(newCashbackDistributor);
        emit CashbackDistributorChanged(old, newCashbackDistributor);
    }

    /// @notice Pauses `settle` in an emergency.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Remove a pausa.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

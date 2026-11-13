// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {ProtocolPausable} from "./governance/ProtocolPausable.sol";
import {ICashbackDistributor} from "./interfaces/ICashbackDistributor.sol";
import {IListingRegistry} from "./interfaces/IListingRegistry.sol";

/// @title NiaraSettlement
/// @notice Atomic settlement between buyer and seller: in the same transaction it moves the
/// AssetToken from seller to buyer, the payment (USDT) from buyer to seller, and retains
/// the protocol fee, in USDT, with no swap, no DEX and no oracle. Any failure reverts
/// everything.
///
/// Order-book mode only: the asset must have an `Approved` `Equity` listing and the payment
/// token must be the configured fee token (`feeToken`, USDT) with an `Approved` `Currency`
/// listing in the ListingRegistry (EXCHANGE-MULTICHAIN-DESIGN.md, sections 1 and 3.4). Fees,
/// and therefore all cashback, are always in USDT: the seller is the party receiving USDT,
/// so the seller pays the fee, out of the USDT it receives. Every transfer is checked by balance delta,
/// so a token that delivers less than requested (fee-on-transfer) can never break
/// `paymentAmount == sellerProceeds + feeCharged`.
/// @dev Never holds the parties' balances: it works entirely through `allowance`, moving only
/// the exact amount of each execution. `settle` is restricted to SETTLEMENT_OPERATOR_ROLE:
/// although moving funds depends only on allowance, letting any address trigger settlements
/// between two parties that approved the contract would let an arbitrary caller pick
/// unfavorable terms within those approvals. The role should be granted to Niara's
/// trusted order-matching engine.
///
/// Pause: there is no separate pause here. `settle` stops while the protocol's shared pause
/// (held by the ListingRegistry, see ProtocolPausable) is active.
contract NiaraSettlement is TimelockedAccessControl, ProtocolPausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_OPERATOR_ROLE = keccak256("SETTLEMENT_OPERATOR_ROLE");

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard, immutable fee cap: 50 bps (0.5%). Business rule: Niara charges at most
    /// 0.5%. Not even the admin can exceed it.
    uint16 public constant MAX_FEE_BPS = 50;

    /// @notice Current fee, in bps, charged in `feeToken`. Default: 50 bps (0.5%), the cap:
    /// the timelocked setter can only lower it or bring it back up to the cap.
    uint16 public feeBps = 50;

    /// @notice The only payment token `settle` accepts, and so the token every fee and all
    /// cashback are paid in: USDT (Solana: `Config.fee_mint`). Changed only through the
    /// timelock (`proposeSetFeeToken` / `executeSetFeeToken`), as a migration tool, not
    /// routinely. Balances already credited in the CashbackDistributor are kept per token,
    /// so they stay withdrawable after a switch.
    address public feeToken;

    /// @notice Contract that receives the fee and credits cashback to the issuer when eligible.
    ICashbackDistributor public cashbackDistributor;

    /// @notice Replay guard: true once the match `matchId` (the off-chain match / fill UUID,
    /// `matches.id`) has settled. A match settles at most once, even within the delegated
    /// allowances (Solana: the `["settled", order_id]` SettlementRecord). Never reset.
    mapping(bytes16 matchId => bool) public settledMatches;

    // `listingRegistry` (inherited from ProtocolPausable, immutable) decides which assets and
    // payment tokens can settle, and holds the shared pause. Replacing it means deploying a
    // new NiaraSettlement.

    event Settled(
        bytes16 matchId,
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
    event FeeTokenChangeProposed(address indexed newFeeToken, uint256 executeAfter);
    event FeeTokenChanged(address indexed oldFeeToken, address indexed newFeeToken);

    error ZeroAddress();
    error NotFeeToken(address paymentToken);
    error BuyerEqualsSeller();
    error ZeroAmount();
    error FeeExceedsCap(uint16 feeBps);
    error PaymentAmountTooSmallForFeePrecision();
    error AssetListingNotApproved(address assetToken);
    error AssetNotEquity(address assetToken);
    error PaymentTokenNotApprovedCurrency(address paymentToken);
    error TransferAmountMismatch(address token, uint256 expected, uint256 received);
    error MatchAlreadySettled(bytes16 matchId);
    error ZeroMatchId();

    /// @param admin_ Holder of DEFAULT_ADMIN_ROLE.
    /// @param cashbackDistributor_ CashbackDistributor that receives the fee.
    /// @param listingRegistry_ ListingRegistry that gates which assets and currencies settle,
    /// and holds the shared protocol pause.
    /// @param feeToken_ The USDT token: the only payment token, and the fee currency.
    /// @param timelockDelay_ Delay (seconds) between proposal and execution of sensitive changes.
    constructor(
        address admin_,
        address cashbackDistributor_,
        address listingRegistry_,
        address feeToken_,
        uint256 timelockDelay_
    ) TimelockedAccessControl(timelockDelay_) ProtocolPausable(listingRegistry_) {
        if (
            admin_ == address(0) || cashbackDistributor_ == address(0) || listingRegistry_ == address(0)
                || feeToken_ == address(0)
        ) {
            revert ZeroAddress();
        }
        cashbackDistributor = ICashbackDistributor(cashbackDistributor_);
        feeToken = feeToken_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Executes the atomic settlement of an already matched order.
    /// @param matchId Off-chain match (fill) id, a 16-byte UUID. Each match settles at most
    /// once: settling the same `matchId` again reverts `MatchAlreadySettled`. The all-zero
    /// id is rejected (`ZeroMatchId`): it is what an unset id looks like, never a real UUID.
    /// @param assetToken Token of the tokenized asset being traded.
    /// @param paymentToken Settlement currency; must be `feeToken` (USDT). Passed explicitly
    /// so a fee-token switch can never settle a match priced in the old token.
    /// @param buyer Party that receives the asset and pays in `paymentToken`.
    /// @param seller Party that delivers the asset and receives `paymentToken`, so it pays
    /// the fee (the USDT receiver pays, spec section 3.4).
    /// @param assetAmount Amount of `assetToken` transferred from seller to buyer.
    /// @param paymentAmount Total amount of `paymentToken` the buyer pays; the fee is
    /// deducted from this amount before it reaches the seller.
    /// @return feeCharged Fee retained, in `paymentToken`.
    function settle(
        bytes16 matchId,
        address assetToken,
        address paymentToken,
        address buyer,
        address seller,
        uint256 assetAmount,
        uint256 paymentAmount
    ) external nonReentrant onlyRole(SETTLEMENT_OPERATOR_ROLE) whenProtocolNotPaused returns (uint256 feeCharged) {
        if (matchId == bytes16(0)) revert ZeroMatchId();
        if (settledMatches[matchId]) revert MatchAlreadySettled(matchId);
        if (assetToken == address(0) || paymentToken == address(0)) revert ZeroAddress();
        if (buyer == address(0) || seller == address(0)) revert ZeroAddress();
        if (buyer == seller) revert BuyerEqualsSeller();
        if (assetAmount == 0 || paymentAmount == 0) revert ZeroAmount();
        // Fees are always in USDT, so the order book only pays in USDT (Solana: `NotFeeMint`).
        if (paymentToken != feeToken) revert NotFeeToken(paymentToken);

        // Trading mode is fixed by asset class: only Approved Equity listings settle here
        // (FixedIncome/Credit/Currency trade P2P), and only against an Approved Currency.
        IListingRegistry.Listing memory assetListing = listingRegistry.getListing(assetToken);
        if (assetListing.status != IListingRegistry.ListingStatus.Approved) revert AssetListingNotApproved(assetToken);
        if (assetListing.assetClass != IListingRegistry.AssetClass.Equity) revert AssetNotEquity(assetToken);
        IListingRegistry.Listing memory paymentListing = listingRegistry.getListing(paymentToken);
        if (
            paymentListing.status != IListingRegistry.ListingStatus.Approved
                || paymentListing.assetClass != IListingRegistry.AssetClass.Currency
        ) revert PaymentTokenNotApprovedCurrency(paymentToken);

        feeCharged = (paymentAmount * feeBps) / BPS_DENOMINATOR;
        // If the fee is active (feeBps > 0), tiny amounts cannot truncate the fee to
        // zero; otherwise one could trade fee-free with small enough amounts.
        if (feeBps > 0 && feeCharged == 0) revert PaymentAmountTooSmallForFeePrecision();

        uint256 sellerProceeds = paymentAmount - feeCharged;

        // Checks-effects-interactions: the match is marked settled and `Settled` is emitted
        // BEFORE any external call. A token with a hook (ERC-777/ERC-1363) that re-enters
        // during one of the `safeTransferFrom` calls below already sees this match settled
        // (it can never settle twice, whatever the entry point) and this settlement's event
        // emitted, so off-chain indexers never observe a re-entry "before" the operation that
        // caused it. `settle` holds no balance: the replay flag and the event are the only
        // effects to order here.
        settledMatches[matchId] = true;
        emit Settled(matchId, assetToken, paymentToken, buyer, seller, assetAmount, paymentAmount, feeCharged);

        _safeTransferFromExact(IERC20(assetToken), seller, buyer, assetAmount);
        _safeTransferFromExact(IERC20(paymentToken), buyer, seller, sellerProceeds);
        if (feeCharged > 0) {
            _safeTransferFromExact(IERC20(paymentToken), buyer, address(cashbackDistributor), feeCharged);
            // `recordFee` comes after the transfer out of necessity: the distributor accounts
            // for a fee that must already be in its balance. Any failure here reverts the whole
            // transaction, including the event above.
            cashbackDistributor.recordFee(assetToken, paymentToken, feeCharged);
        }
    }

    /// @dev `safeTransferFrom` plus a balance-delta check on the receiver: reverts unless
    /// `to` received exactly `amount`. Each leg is measured on its own (balance read right
    /// before and right after its transfer), so legs that share a receiver cannot mask each
    /// other. `balanceOf` is a view call (STATICCALL), so the reads cannot emit or change
    /// state and do not affect the checks-effects-interactions order above.
    function _safeTransferFromExact(IERC20 token, address from, address to, uint256 amount) private {
        uint256 balanceBefore = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        uint256 balanceAfter = token.balanceOf(to);
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amount) revert TransferAmountMismatch(address(token), amount, received);
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

    /// @notice Proposes a new fee token (the USDT the order book pays in, and the currency of
    /// every fee and all cashback). Subject to the timelock. A migration tool (e.g. a
    /// redeployed test USDT), not something routine.
    /// @param newFeeToken The new fee token; it still needs an `Approved` `Currency` listing
    /// for `settle` to accept it.
    /// @return executeAfter Earliest timestamp at which the change can be executed.
    function proposeSetFeeToken(address newFeeToken) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 executeAfter) {
        if (newFeeToken == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_FEE_TOKEN", newFeeToken));
        executeAfter = _scheduleAction(actionId);
        emit FeeTokenChangeProposed(newFeeToken, executeAfter);
    }

    /// @notice Executes a proposed fee-token change after the timelock delay.
    /// @param newFeeToken The fee token given to `proposeSetFeeToken`.
    function executeSetFeeToken(address newFeeToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_FEE_TOKEN", newFeeToken));
        _consumeAction(actionId);
        address old = feeToken;
        feeToken = newFeeToken;
        emit FeeTokenChanged(old, newFeeToken);
    }
}

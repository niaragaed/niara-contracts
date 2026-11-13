// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockedAccessControl} from "./governance/TimelockedAccessControl.sol";
import {ProtocolPausable} from "./governance/ProtocolPausable.sol";
import {ICashbackDistributor} from "./interfaces/ICashbackDistributor.sol";
import {IListingRegistry} from "./interfaces/IListingRegistry.sol";
import {INiaraSettlement} from "./interfaces/INiaraSettlement.sol";

/// @title P2PEscrow
/// @notice P2P negotiation mode for `FixedIncome`, `Credit` and `Currency` listings: the EVM
/// mirror of the Solana deals (`open_deal` / `accept_deal` / `cancel_deal` / `expire_deal`,
/// EXCHANGE-MULTICHAIN-DESIGN.md §3.5).
///
/// A deal is bilateral: the proposer names the counterparty and escrows its own side here
/// (the asset when selling, the payment when buying). The counterparty accepts by delivering
/// its side straight from its wallet; one transaction then swaps both legs, charges the fee
/// and credits the cashback. Both parties sign their own transaction, so no operator is
/// involved. Until then the proposer can cancel, and once the deal expires anyone can send
/// the deposit back to the proposer.
///
/// Fees are always in USDT (`NiaraSettlement.feeToken`, spec §3.4): one leg of every deal is
/// in the fee token (the payment for `FixedIncome`/`Credit`, exactly one of the two for
/// `Currency`), and whoever receives that leg pays the fee out of it. The fee and cashback
/// rates are copied onto the deal at `openDeal` and charged at `acceptDeal`: they are part
/// of the agreed terms, so a timelocked change while the deal is open does not affect it.
///
/// Pause principle (spec §3.3): the shared protocol pause, or a listing that is no longer
/// `Approved`, blocks `openDeal` and `acceptDeal` but NEVER `cancelDeal` or `expireDeal`.
/// Those two read neither the registry nor NiaraSettlement: a proposer can always take back
/// its own deposit.
///
/// Custody and accounting: every deposit sits in this one contract, tracked per deal
/// (`Deal`) and per token (`totalEscrowed`). An exit moves exactly the deal's own deposit,
/// never "the balance", so tokens sent straight to the contract can neither block a deal nor
/// be claimed by one. They are the balance above `totalEscrowed`, which the treasury can
/// sweep (`sweepExcess`).
/// @dev Fee, fee token and CashbackDistributor are read from NiaraSettlement, so both trading
/// modes share them and they change only through its timelock. This contract's own timelock
/// (TimelockedAccessControl) governs its roles.
contract P2PEscrow is TimelockedAccessControl, ProtocolPausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Longest life of a deal: `expiresAt` is at most this far ahead at `openDeal`
    /// (Solana: `MAX_DEAL_DURATION_SECS`).
    uint64 public constant MAX_DEAL_DURATION = 30 days;

    /// @notice What the proposer does with the asset: `Sell` escrows `assetAmount` of the
    /// asset token, `Buy` escrows `paymentAmount` of the payment token.
    enum DealSide {
        Sell,
        Buy
    }

    /// @notice Deal lifecycle. `None` means "no such deal". A deal leaves `Open` exactly
    /// once and is never deleted: the status is the replay guard.
    enum DealStatus {
        None,
        Open,
        Executed,
        Cancelled,
        Expired
    }

    /// @notice The terms the two parties agreed off-chain.
    struct DealTerms {
        /// @dev The only address that can accept. Never the proposer, never zero.
        address counterparty;
        /// @dev The `FixedIncome`/`Credit` instrument, or the currency being sold.
        address assetToken;
        /// @dev The currency paid for it.
        address paymentToken;
        DealSide proposerSide;
        uint256 assetAmount;
        uint256 paymentAmount;
    }

    /// @notice One deal. Mirrors Solana's `Deal` account.
    struct Deal {
        bytes16 dealId;
        address proposer;
        address counterparty;
        address assetToken;
        address paymentToken;
        uint256 assetAmount;
        uint256 paymentAmount;
        /// @dev `NiaraSettlement.feeBps` at `openDeal`; the rate charged at `acceptDeal`.
        uint16 feeBps;
        /// @dev `CashbackDistributor.cashbackBps` at `openDeal`; the cashback share applied
        /// at `acceptDeal`.
        uint16 cashbackBps;
        DealSide proposerSide;
        DealStatus status;
        uint64 expiresAt;
        uint64 openedAt;
        /// @dev Block timestamp of accept / cancel / expire; 0 while `Open`.
        uint64 resolvedAt;
    }

    /// @dev Everything `acceptDeal` moves, computed before any state change.
    struct Execution {
        address feeToken;
        address distributor;
        uint256 fee;
        uint256 cashback;
        address escrowedToken;
        uint256 escrowedAmount;
        /// @dev `fee` if the escrowed leg is the fee-token leg, else 0.
        uint256 escrowedFee;
        address deliveredToken;
        uint256 deliveredAmount;
        /// @dev `fee` if the delivered leg is the fee-token leg, else 0.
        uint256 deliveredFee;
    }

    /// @notice NiaraSettlement, read for the current fee, fee token and CashbackDistributor.
    INiaraSettlement public immutable settlement;

    mapping(bytes32 dealKey => Deal) private _deals;

    /// @notice Sum of the deposits of all `Open` deals, per token. The contract's balance of
    /// a token above this amount belongs to no deal (`sweepExcess`).
    mapping(address token => uint256) public totalEscrowed;

    /// @notice The proposer escrowed its side (`assetAmount` if selling, `paymentAmount` if
    /// buying). `feeBps` and `cashbackBps` are the rates fixed for this deal.
    event DealOpened(
        bytes32 indexed dealKey,
        bytes16 dealId,
        address indexed proposer,
        address indexed counterparty,
        address assetToken,
        address paymentToken,
        DealSide proposerSide,
        uint256 assetAmount,
        uint256 paymentAmount,
        uint16 feeBps,
        uint16 cashbackBps,
        uint64 expiresAt
    );
    /// @notice The deal executed. `fee` is in `feeToken` and was deducted from what the
    /// receiver of that leg got; `cashback` is the part of `fee` credited to the asset's
    /// issuer (0 for `Currency` assets).
    event DealExecuted(
        bytes32 indexed dealKey,
        bytes16 dealId,
        address indexed proposer,
        address indexed counterparty,
        address assetToken,
        address paymentToken,
        DealSide proposerSide,
        uint256 assetAmount,
        uint256 paymentAmount,
        address feeToken,
        uint256 fee,
        uint256 cashback
    );
    /// @notice The proposer cancelled an open deal and got its deposit back.
    event DealCancelled(
        bytes32 indexed dealKey, bytes16 dealId, address indexed proposer, address depositToken, uint256 depositAmount
    );
    /// @notice An expired deal was refunded to the proposer (permissionless).
    event DealExpired(
        bytes32 indexed dealKey, bytes16 dealId, address indexed proposer, address depositToken, uint256 depositAmount
    );
    /// @notice Tokens that belonged to no deal were swept by the treasury.
    event ExcessSwept(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroDealId();
    error RegistryMismatch();
    error SelfTrade();
    error InvalidExpiry(uint64 expiresAt);
    error DealAlreadyExists(bytes32 dealKey);
    error SameToken();
    error ListingNotApproved(address assetToken);
    error WrongTradingMode(address assetToken);
    error InvalidPaymentToken(address paymentToken);
    error NotFeeToken();
    error ZeroSellerProceeds();
    error Unauthorized();
    error DealNotOpen(bytes32 dealKey);
    error DealHasExpired(bytes32 dealKey);
    error DealNotExpired(bytes32 dealKey);
    error TransferAmountMismatch(address token, uint256 expected, uint256 received);
    error InvalidRecipient();
    error NothingToSweep(address token);

    /// @param admin_ Holder of DEFAULT_ADMIN_ROLE and TREASURY_ROLE.
    /// @param settlement_ NiaraSettlement: source of the fee, the fee token and the
    /// CashbackDistributor.
    /// @param listingRegistry_ ListingRegistry that gates the listings and holds the shared
    /// pause. Must be the one `settlement_` uses.
    /// @param timelockDelay_ Delay (seconds) between proposal and execution of role changes.
    constructor(address admin_, address settlement_, address listingRegistry_, uint256 timelockDelay_)
        TimelockedAccessControl(timelockDelay_)
        ProtocolPausable(listingRegistry_)
    {
        if (admin_ == address(0) || settlement_ == address(0) || listingRegistry_ == address(0)) {
            revert ZeroAddress();
        }
        if (address(INiaraSettlement(settlement_).listingRegistry()) != listingRegistry_) revert RegistryMismatch();
        settlement = INiaraSettlement(settlement_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(TREASURY_ROLE, admin_);
    }

    // ── Views ───────────────────────────────────────────────────────────────────────────

    /// @notice Key of the deal `dealId` opened by `proposer`. Deal ids are scoped to the
    /// proposer (Solana: the `["deal", proposer, deal_id]` PDA), so nobody can occupy
    /// someone else's id.
    /// @param proposer The deal's proposer.
    /// @param dealId The 16-byte off-chain negotiation id.
    /// @return The key used by `acceptDeal`, `cancelDeal`, `expireDeal` and `getDeal`.
    function dealKeyOf(address proposer, bytes16 dealId) public pure returns (bytes32) {
        return keccak256(abi.encode(proposer, dealId));
    }

    /// @notice Returns a deal (all fields zero / `None` if there is none).
    /// @param dealKey Key from `dealKeyOf` / `DealOpened`.
    /// @return The stored deal.
    function getDeal(bytes32 dealKey) external view returns (Deal memory) {
        return _deals[dealKey];
    }

    // ── Open ────────────────────────────────────────────────────────────────────────────

    /// @notice Opens a deal and escrows the proposer's side (the caller must have approved
    /// this contract for it). Blocked while the protocol is paused and unless both listings
    /// are `Approved`.
    /// @param dealId 16-byte off-chain negotiation id, non-zero, unique per proposer forever.
    /// @param terms Counterparty, tokens, side and amounts.
    /// @param expiresAt Deadline: `now < expiresAt <= now + MAX_DEAL_DURATION`. The deal can
    /// be accepted while `now < expiresAt` and expired from `expiresAt` on.
    /// @return dealKey Key of the new deal.
    function openDeal(bytes16 dealId, DealTerms calldata terms, uint64 expiresAt)
        external
        nonReentrant
        whenProtocolNotPaused
        returns (bytes32 dealKey)
    {
        if (dealId == bytes16(0)) revert ZeroDealId();
        if (terms.assetAmount == 0 || terms.paymentAmount == 0) revert ZeroAmount();
        if (terms.counterparty == address(0)) revert ZeroAddress();
        if (terms.counterparty == msg.sender) revert SelfTrade();
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_DEAL_DURATION) {
            revert InvalidExpiry(expiresAt);
        }
        dealKey = dealKeyOf(msg.sender, dealId);
        if (_deals[dealKey].status != DealStatus.None) revert DealAlreadyExists(dealKey);

        (bool feeOnPaymentLeg,,) = _requireP2PMarket(terms.assetToken, terms.paymentToken);
        // The fee is part of the agreed terms: take the rates now. As in `settle`, the fee
        // rounds up, so whoever receives the USDT leg must still be left with something
        // (`ZeroSellerProceeds`, the name Solana uses for both modes). Checked here only:
        // the rates cannot change afterwards, so a deal that opens can always pay its fee.
        uint16 feeBps_ = settlement.feeBps();
        uint16 cashbackBps_ = settlement.cashbackDistributor().cashbackBps();
        uint256 usdtAmount = feeOnPaymentLeg ? terms.paymentAmount : terms.assetAmount;
        if (usdtAmount - _feeOf(usdtAmount, feeBps_) == 0) revert ZeroSellerProceeds();

        bool selling = terms.proposerSide == DealSide.Sell;
        address depositToken = selling ? terms.assetToken : terms.paymentToken;
        uint256 depositAmount = selling ? terms.assetAmount : terms.paymentAmount;

        // Checks-effects-interactions: the deal is stored, the deposit accounted and
        // `DealOpened` emitted BEFORE the deposit is pulled. A token with a hook
        // (ERC-777/ERC-1363) that takes control during `safeTransferFrom` already sees the
        // deal open and its deposit counted (so it can never be swept as excess), and an
        // off-chain indexer never sees the `Transfer` before the deal that caused it.
        _deals[dealKey] = Deal({
            dealId: dealId,
            proposer: msg.sender,
            counterparty: terms.counterparty,
            assetToken: terms.assetToken,
            paymentToken: terms.paymentToken,
            assetAmount: terms.assetAmount,
            paymentAmount: terms.paymentAmount,
            feeBps: feeBps_,
            cashbackBps: cashbackBps_,
            proposerSide: terms.proposerSide,
            status: DealStatus.Open,
            expiresAt: expiresAt,
            openedAt: uint64(block.timestamp),
            resolvedAt: 0
        });
        totalEscrowed[depositToken] += depositAmount;
        _emitDealOpened(dealKey);

        _transferFromExact(depositToken, msg.sender, address(this), depositAmount);
    }

    // ── Accept ──────────────────────────────────────────────────────────────────────────

    /// @notice The named counterparty accepts: it delivers its side from its own wallet (it
    /// must have approved this contract for it) and receives the escrowed side, atomically.
    /// The receiver of the fee-token leg pays the fee out of it; the other party receives
    /// its leg in full. Only while `now < expiresAt`; blocked while the protocol is paused,
    /// unless both listings are still `Approved`, and if neither leg is the current fee
    /// token (after a fee-token switch a deal in the old token can only be refunded).
    /// @param dealKey Key of the deal (`dealKeyOf` / `DealOpened`).
    function acceptDeal(bytes32 dealKey) external nonReentrant whenProtocolNotPaused {
        Deal storage deal = _deals[dealKey];
        if (msg.sender != deal.counterparty) revert Unauthorized();
        if (deal.status != DealStatus.Open) revert DealNotOpen(dealKey);
        // Live while `now < expiresAt`, expirable from then on: no gap, no overlap.
        if (block.timestamp >= deal.expiresAt) revert DealHasExpired(dealKey);

        Execution memory x = _planExecution(deal);

        // Checks-effects-interactions: the deal leaves `Open` (it can never execute or be
        // refunded again, whatever the entry point), its deposit leaves the escrowed total
        // and `DealExecuted` is emitted BEFORE any transfer. A hook that takes control
        // during the transfers below already sees all of that, and an indexer never sees a
        // `Transfer` of this deal before its `DealExecuted`.
        deal.status = DealStatus.Executed;
        deal.resolvedAt = uint64(block.timestamp);
        totalEscrowed[x.escrowedToken] -= x.escrowedAmount;
        _emitDealExecuted(dealKey, x);

        address proposer = deal.proposer;
        // Escrowed leg: escrow -> counterparty (minus the fee if it is the fee-token leg),
        // and that fee: escrow -> distributor.
        _transferExact(x.escrowedToken, msg.sender, x.escrowedAmount - x.escrowedFee);
        if (x.escrowedFee > 0) _transferExact(x.escrowedToken, x.distributor, x.escrowedFee);
        // Delivered leg: counterparty -> proposer (minus the fee if it is the fee-token
        // leg), and that fee: counterparty -> distributor.
        _transferFromExact(x.deliveredToken, msg.sender, proposer, x.deliveredAmount - x.deliveredFee);
        if (x.deliveredFee > 0) _transferFromExact(x.deliveredToken, msg.sender, x.distributor, x.deliveredFee);
        if (x.fee > 0) {
            // As in `settle`, the accounting call comes after the fee transfer out of
            // necessity: the distributor accounts for a fee that must already be in its
            // balance. It is an internal protocol call and any failure reverts the whole
            // transaction, including the event above.
            ICashbackDistributor(x.distributor).recordDealFee(deal.assetToken, x.feeToken, x.fee, deal.cashbackBps);
        }
    }

    // ── Refunds: never blocked by a pause or by listing status ──────────────────────────

    /// @notice The proposer cancels its open deal and gets the deposit back. Allowed in any
    /// protocol state (paused, listing suspended or delisted) and also after `expiresAt`,
    /// as long as nobody expired the deal first.
    /// @param dealKey Key of the deal.
    function cancelDeal(bytes32 dealKey) external nonReentrant {
        Deal storage deal = _deals[dealKey];
        if (msg.sender != deal.proposer) revert Unauthorized();
        if (deal.status != DealStatus.Open) revert DealNotOpen(dealKey);
        _refund(dealKey, deal, DealStatus.Cancelled);
    }

    /// @notice Refunds an expired deal to its proposer. Anyone can call it once
    /// `now >= expiresAt`; the deposit can only go to the proposer. Allowed in any protocol
    /// state, like `cancelDeal`.
    /// @param dealKey Key of the deal.
    function expireDeal(bytes32 dealKey) external nonReentrant {
        Deal storage deal = _deals[dealKey];
        if (deal.status != DealStatus.Open) revert DealNotOpen(dealKey);
        if (block.timestamp < deal.expiresAt) revert DealNotExpired(dealKey);
        _refund(dealKey, deal, DealStatus.Expired);
    }

    /// @dev Returns exactly the deal's own deposit to the proposer. Reads no other contract
    /// than the deposit token, so nothing in the protocol's state can block it, and uses a
    /// plain `safeTransfer` with no balance-delta check: a refund must not gain a way to
    /// revert.
    function _refund(bytes32 dealKey, Deal storage deal, DealStatus finalStatus) private {
        bool selling = deal.proposerSide == DealSide.Sell;
        address depositToken = selling ? deal.assetToken : deal.paymentToken;
        uint256 depositAmount = selling ? deal.assetAmount : deal.paymentAmount;
        address proposer = deal.proposer;

        // Checks-effects-interactions: the deal leaves `Open` (so it can be neither refunded
        // again nor accepted), its deposit leaves the escrowed total and the event is
        // emitted BEFORE the transfer hands control to the token.
        deal.status = finalStatus;
        deal.resolvedAt = uint64(block.timestamp);
        totalEscrowed[depositToken] -= depositAmount;
        if (finalStatus == DealStatus.Cancelled) {
            emit DealCancelled(dealKey, deal.dealId, proposer, depositToken, depositAmount);
        } else {
            emit DealExpired(dealKey, deal.dealId, proposer, depositToken, depositAmount);
        }

        IERC20(depositToken).safeTransfer(proposer, depositAmount);
    }

    // ── Sweep ───────────────────────────────────────────────────────────────────────────

    /// @notice Moves the balance of `token` that belongs to no open deal (tokens sent
    /// straight to this contract) to `to`. Restricted to the treasury. Deposits are never
    /// touched: only `balance - totalEscrowed[token]` moves. Blocked while the protocol is
    /// paused, like every payout based on the protocol's own accounting.
    /// @param token Token to sweep.
    /// @param to Recipient (not zero, not this contract).
    /// @return amount Amount swept.
    function sweepExcess(address token, address to)
        external
        nonReentrant
        onlyRole(TREASURY_ROLE)
        whenProtocolNotPaused
        returns (uint256 amount)
    {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient();
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 escrowed = totalEscrowed[token];
        if (balance <= escrowed) revert NothingToSweep(token);
        amount = balance - escrowed;

        // Checks-effects-interactions: there is no state to update (the excess is not
        // accounted anywhere), so the event is the only effect to order before the transfer.
        emit ExcessSwept(token, to, amount);

        IERC20(token).safeTransfer(to, amount);
    }

    // ── Internals ───────────────────────────────────────────────────────────────────────

    /// @dev Market checks shared by `openDeal` and `acceptDeal`: two different tokens, an
    /// `Approved` P2P-class asset (`Equity` trades on the order book), an `Approved`
    /// `Currency` payment, and a fee-token leg: the payment for `FixedIncome`/`Credit`,
    /// exactly one of the two for `Currency` (the tokens differ, so never both).
    /// @return feeOnPaymentLeg True if the payment token is the fee token, false if the
    /// asset (a currency sold for another one) is.
    /// @return cashbackEligible The asset listing's cashback eligibility.
    /// @return feeToken_ The current fee token.
    function _requireP2PMarket(address assetToken, address paymentToken)
        private
        view
        returns (bool feeOnPaymentLeg, bool cashbackEligible, address feeToken_)
    {
        if (assetToken == paymentToken) revert SameToken();
        IListingRegistry.Listing memory assetListing = listingRegistry.getListing(assetToken);
        if (assetListing.status != IListingRegistry.ListingStatus.Approved) revert ListingNotApproved(assetToken);
        if (assetListing.assetClass == IListingRegistry.AssetClass.Equity) revert WrongTradingMode(assetToken);
        IListingRegistry.Listing memory paymentListing = listingRegistry.getListing(paymentToken);
        if (
            paymentListing.status != IListingRegistry.ListingStatus.Approved
                || paymentListing.assetClass != IListingRegistry.AssetClass.Currency
        ) revert InvalidPaymentToken(paymentToken);

        feeToken_ = settlement.feeToken();
        if (paymentToken == feeToken_) {
            feeOnPaymentLeg = true;
        } else if (assetListing.assetClass != IListingRegistry.AssetClass.Currency || assetToken != feeToken_) {
            revert NotFeeToken();
        }
        cashbackEligible = assetListing.cashbackEligible;
    }

    /// @dev Re-runs the market checks against the current listings and fee token, and works
    /// out both legs with the rates stored on the deal.
    function _planExecution(Deal storage deal) private view returns (Execution memory x) {
        bool feeOnPaymentLeg;
        bool cashbackEligible;
        (feeOnPaymentLeg, cashbackEligible, x.feeToken) = _requireP2PMarket(deal.assetToken, deal.paymentToken);
        x.distributor = address(settlement.cashbackDistributor());

        x.fee = _feeOf(feeOnPaymentLeg ? deal.paymentAmount : deal.assetAmount, deal.feeBps);
        // Reported in `DealExecuted`; the distributor applies the same formula.
        if (cashbackEligible) x.cashback = (x.fee * deal.cashbackBps) / BPS_DENOMINATOR;

        // The proposer escrowed one leg; the counterparty delivers the other.
        bool selling = deal.proposerSide == DealSide.Sell;
        (x.escrowedToken, x.escrowedAmount) =
            selling ? (deal.assetToken, deal.assetAmount) : (deal.paymentToken, deal.paymentAmount);
        (x.deliveredToken, x.deliveredAmount) =
            selling ? (deal.paymentToken, deal.paymentAmount) : (deal.assetToken, deal.assetAmount);
        if (x.escrowedToken == x.feeToken) {
            x.escrowedFee = x.fee;
        } else {
            x.deliveredFee = x.fee;
        }
    }

    /// @dev Same formula as `NiaraSettlement.settle` and as Solana (spec section 3.4):
    /// `ceil(amount * feeBps / 10_000)`. The fee rounds up, so an active fee is never
    /// truncated to zero.
    function _feeOf(uint256 amount, uint16 feeBps_) private pure returns (uint256) {
        return Math.mulDiv(amount, feeBps_, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }

    function _emitDealOpened(bytes32 dealKey) private {
        Deal storage deal = _deals[dealKey];
        emit DealOpened(
            dealKey,
            deal.dealId,
            deal.proposer,
            deal.counterparty,
            deal.assetToken,
            deal.paymentToken,
            deal.proposerSide,
            deal.assetAmount,
            deal.paymentAmount,
            deal.feeBps,
            deal.cashbackBps,
            deal.expiresAt
        );
    }

    function _emitDealExecuted(bytes32 dealKey, Execution memory x) private {
        Deal storage deal = _deals[dealKey];
        emit DealExecuted(
            dealKey,
            deal.dealId,
            deal.proposer,
            deal.counterparty,
            deal.assetToken,
            deal.paymentToken,
            deal.proposerSide,
            deal.assetAmount,
            deal.paymentAmount,
            x.feeToken,
            x.fee,
            x.cashback
        );
    }

    /// @dev `safeTransferFrom` plus a balance-delta check on the receiver: reverts unless
    /// `to` received exactly `amount`, so a token that delivers less than requested
    /// (fee-on-transfer) can never enter the escrow or short a leg. `balanceOf` is a view
    /// call (STATICCALL): it cannot emit or change state, so it does not affect the
    /// checks-effects-interactions order.
    function _transferFromExact(address token, address from, address to, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransferFrom(from, to, amount);
        _requireReceived(token, to, balanceBefore, amount);
    }

    /// @dev `safeTransfer` out of the escrow with the same balance-delta check.
    function _transferExact(address token, address to, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransfer(to, amount);
        _requireReceived(token, to, balanceBefore, amount);
    }

    function _requireReceived(address token, address to, uint256 balanceBefore, uint256 amount) private view {
        uint256 balanceAfter = IERC20(token).balanceOf(to);
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amount) revert TransferAmountMismatch(token, amount, received);
    }
}

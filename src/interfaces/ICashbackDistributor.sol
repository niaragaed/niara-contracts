// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICashbackDistributor
/// @notice Minimal CashbackDistributor surface used by NiaraSettlement and P2PEscrow to hand
/// off the accounting of the fee they just transferred.
interface ICashbackDistributor {
    /// @notice Current share of the fee, in bps, passed on to the issuer. P2PEscrow copies it
    /// onto each deal at `openDeal`.
    function cashbackBps() external view returns (uint16);

    /// @notice Records a fee already transferred to this contract and credits the issuer
    /// proportionally, if the asset is cashback-eligible.
    /// @dev The caller is responsible for having transferred `feeAmount` of
    /// `paymentToken` to the CashbackDistributor before the call.
    function recordFee(address assetToken, address paymentToken, uint256 feeAmount) external;

    /// @notice Records the fee of a P2P deal, already transferred to this contract, at the
    /// cashback rate fixed on the deal when it was opened.
    /// @dev The caller is responsible for having transferred `feeAmount` of `feeToken` to
    /// the CashbackDistributor before the call.
    /// @return cashbackAmount Share of `feeAmount` credited to the issuer.
    function recordDealFee(address assetToken, address feeToken, uint256 feeAmount, uint16 dealCashbackBps)
        external
        returns (uint256 cashbackAmount);
}

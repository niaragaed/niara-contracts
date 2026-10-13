// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICashbackDistributor
/// @notice Minimal CashbackDistributor surface used by NiaraSettlement to hand off the
/// accounting of the fee it just transferred.
interface ICashbackDistributor {
    /// @notice Records a fee already transferred to this contract and credits the issuer
    /// proportionally, if the asset is cashback-eligible.
    /// @dev The caller is responsible for having transferred `feeAmount` of
    /// `paymentToken` to the CashbackDistributor before the call.
    function recordFee(address assetToken, address paymentToken, uint256 feeAmount) external;
}

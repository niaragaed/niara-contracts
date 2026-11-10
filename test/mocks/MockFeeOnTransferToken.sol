// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only token whose receiver gets less than the amount sent, to prove that
/// NiaraSettlement's balance-delta check rejects it. Two modes:
/// - `feeBps > 0`: a fee-on-transfer token; `feeBps` of each transfer is burned in flight.
/// - `drainReceiver`: after crediting the receiver, burns `amount + 1` from it, so the
///   receiver ends with a LOWER balance than before (covers the "balance decreased" path).
contract MockFeeOnTransferToken is ERC20 {
    uint256 public feeBps;
    bool public drainReceiver;

    constructor(uint256 feeBps_) ERC20("Mock Fee-On-Transfer", "mFOT") {
        feeBps = feeBps_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDrainReceiver(bool on) external {
        drainReceiver = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, address(0), fee);
        if (drainReceiver) super._update(to, address(0), value + 1);
    }
}

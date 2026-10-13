// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../../src/governance/TimelockedAccessControl.sol";

/// @notice Minimal concrete instance of TimelockedAccessControl, used only to test
/// the governance base in isolation from the business rules of the contracts that inherit it.
contract TimelockHarness is TimelockedAccessControl {
    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }
}

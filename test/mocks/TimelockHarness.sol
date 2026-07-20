// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../../src/governance/TimelockedAccessControl.sol";

/// @notice Instância mínima e concreta de TimelockedAccessControl, usada apenas para testar
/// a base de governança isoladamente das regras de negócio dos contratos que a herdam.
contract TimelockHarness is TimelockedAccessControl {
    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }
}

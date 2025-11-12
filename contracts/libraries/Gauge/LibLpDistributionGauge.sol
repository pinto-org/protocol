/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {Implementation} from "contracts/beanstalk/storage/System.sol";

/**
 * @title LibLpDistributionGauge
 * @notice handles the LP distribution gauge.
 * @dev a token can dynamically change the optimal deposited bdv by via adding an implementation.
 */
library LibLpDistributionGauge {
    // LP gauge distribution Update
    // LpDistributionSettings - a settings struct determining how the distribution works
    struct LpDistributionGaugeData {
        uint256 duration;
        LpDistribution[] distributions;
    }

    // token: the token to change the optimal deposited bdv. MUST be a whitelisted token
    // delta - the amount to change the tokens optimal deposited bdv by.
    // Implementation -> an implementation that changes `delta`. an address of (0) implies no change in delta.
    // @dev delta is a int64 as `optimalPercentDepositedBdv` is an uint64.
    struct LpDistribution {
        address token;
        int64 delta;
        Implementation impl;
    }
}

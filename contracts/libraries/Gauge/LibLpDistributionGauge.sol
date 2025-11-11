/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {Implementation} from "contracts/beanstalk/storage/System.sol";

/**
 * @title LibLpDistributionGauge
 */
library LibLpDistributionGauge {
    // LP gauge distribution Update
    // LpDistributionSettings - a settings struct determining how the distribution works
    struct LpDistributionGaugeData {
        uint256 duration;
        LpDistribution[] distributions;
    }

    // token: the token to change the optimal deposited bdv. MUST be a whitelisted token
    // delta - the amount to change
    // Implementation -> an implementation that changes `delta`. an address of (0) implies no change in delta.
    struct LpDistribution {
        address token;
        int256 delta;
        Implementation impl;
    }
}

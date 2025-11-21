/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {Implementation} from "contracts/beanstalk/storage/System.sol";
import {LibAppStorage, AppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibSeedGauge} from "./LibSeedGauge.sol";

/**
 * @title LibLpDistributionGauge
 * @notice handles the LP distribution gauge.
 * @dev a token can dynamically change the optimal deposited bdv by via adding an implementation.
 */
library LibLpDistributionGauge {
    /**
     * @notice LpDistributionGaugeData struct.
     * @param enabled Whether the gauge is enabled.
     * @param distributions The distributions to apply to the tokens.
     */
    struct LpDistributionGaugeData {
        bool enabled;
        LpDistribution[] distributions;
    }

    // token: the token to change the optimal deposited bdv. MUST be a whitelisted token
    // delta - the amount to change the tokens optimal deposited bdv by.
    // target - the target optimal distribution percentage.
    // Implementation -> an implementation that changes `delta`. an address of (0) implies no change in delta.
    // @dev delta is a int64 as `optimalPercentDepositedBdv` is an uint64.
    struct LpDistribution {
        address token;
        int64 delta;
        uint64 target;
        Implementation impl;
    }

    /**
     * @notice Internal function to calculate the new optimal percent deposited bdv.
     */
    function calculateOptimalPercentDepositedBdv(
        address token,
        int64 delta,
        uint64 target
    ) internal view returns (uint64) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint64 currentOptimalPercentDepositedBdv = s
            .sys
            .silo
            .assetSettings[token]
            .optimalPercentDepositedBdv;
        if (delta > 0) {
            // if the new optimal percent deposited bdv is greater than the maximum, set it to the maximum.
            uint64 max = target > currentOptimalPercentDepositedBdv
                ? target
                : uint64(LibSeedGauge.OPTIMAL_DEPOSITED_BDV_PERCENT);
            if (currentOptimalPercentDepositedBdv + uint64(delta) > max) {
                return max;
            }
            return currentOptimalPercentDepositedBdv + uint64(delta);
        } else {
            uint64 min = target < currentOptimalPercentDepositedBdv ? target : 0;
            // if the new optimal percent deposited bdv is less than the minimum, set it to the minimum.
            if (currentOptimalPercentDepositedBdv < min + uint64(-delta)) {
                return min;
            }
            return currentOptimalPercentDepositedBdv - uint64(-delta);
        }
    }
}

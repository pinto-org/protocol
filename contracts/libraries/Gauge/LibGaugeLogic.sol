// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibSeedGauge} from "./LibSeedGauge.sol";
import {LibLpDistributionGauge} from "./LibLpDistributionGauge.sol";

/**
 * @title LibGaugeLogic
 * @notice holds most gauge logic (other than the Seed Gauge).
 */
library LibGaugeLogic {
    /**
     * @notice handles the LP distribution gauge.
     * @param systemData the system data to handle.
     * @param gaugeData the gauge data to handle.
     * @return bytes memory, bytes memory the return data and success status.
     */
    function lpDistributionGauge(
        bytes memory,
        bytes memory systemData,
        bytes memory gaugeData
    ) internal returns (bytes memory, bytes memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LibLpDistributionGauge.LpDistributionGaugeData memory gd = abi.decode(
            gaugeData,
            (LibLpDistributionGauge.LpDistributionGaugeData)
        );

        // this Gauge can be invoked for a number of seasons or indefinitely:
        // 1: if the duration is 0, run indefinitely.
        // 2: otherwise, run for N seasons.
        // note: default state is for the gauge to run in perpetuity.
        // Responsibility is on Deployer to ensure lengths are correct.
        if (gd.duration == 0 || (gd.duration >= s.sys.season.current)) {
            for (uint i = 0; i < gd.distributions.length; i++) {
                LibLpDistributionGauge.LpDistribution memory lpDist = gd.distributions[i];

                // if the token has an implementation, invoke the implementation to calculate the new delta.
                if (lpDist.impl.target != address(0)) {
                    // the function should adhere to `foo(int256,bytes) external returns (int256)`
                    bool success;
                    bytes memory returnData;
                    if (lpDist.impl.encodeType == bytes1(0x00)) {
                        (success, returnData) = lpDist.impl.target.staticcall(
                            abi.encodeWithSelector(
                                lpDist.impl.selector,
                                lpDist.delta,
                                lpDist.impl.data
                            )
                        );
                    }
                    // more encode types can be added here.
                    // if the encoding type is not valid, the delta remains the same.

                    if (success) {
                        lpDist.delta = abi.decode(returnData, (int64));
                    }

                    // if delta is non-zero, calculate the new optimal percent deposited bdv.
                    if (lpDist.delta > 0) {
                        uint64 newOptimalPercentDepositedBdv = calculateOptimalPercentDepositedBdv(
                            lpDist.token,
                            lpDist.delta
                        );
                        s
                            .sys
                            .silo
                            .assetSettings[lpDist.token]
                            .optimalPercentDepositedBdv = newOptimalPercentDepositedBdv;
                    }
                }
            }

            // encode the new gauge data.
            gd.distributions = new LibLpDistributionGauge.LpDistribution[](gd.distributions.length);
            for (uint i = 0; i < gd.distributions.length; i++) {
                gd.distributions[i] = gd.distributions[i];
            }

            return (new bytes(0), abi.encode(gd));
        } else {
            // skip, return unchanged values/gaugeData.
            return (new bytes(0), gaugeData);
        }
    }

    /**
     * @notice Internal function to calculate the new optimal percent deposited bdv.
     */
    function calculateOptimalPercentDepositedBdv(
        address token,
        int64 delta
    ) internal view returns (uint64) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint64 currentOptimalPercentDepositedBdv = s
            .sys
            .silo
            .assetSettings[token]
            .optimalPercentDepositedBdv;
        if (delta > 0) {
            // if the new optimal percent deposited bdv is greater than the maximum, set it to the maximum.
            if (
                currentOptimalPercentDepositedBdv + uint64(delta) >
                uint64(LibSeedGauge.OPTIMAL_DEPOSITED_BDV_PERCENT)
            ) {
                return uint64(LibSeedGauge.OPTIMAL_DEPOSITED_BDV_PERCENT);
            }
            return currentOptimalPercentDepositedBdv + uint64(delta);
        } else {
            // if the new optimal percent deposited bdv is less than the minimum, set it to the minimum.
            if (currentOptimalPercentDepositedBdv < uint64(-delta)) {
                return 0;
            }
            return currentOptimalPercentDepositedBdv - uint64(-delta);
        }
    }
}

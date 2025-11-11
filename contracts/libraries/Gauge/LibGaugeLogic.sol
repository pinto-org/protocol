// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibGauge} from "./LibGauge.sol";
import {LibLpDistributionGauge} from "./LibLpDistributionGauge.sol";

/**
 * @title LibGaugeLogic
 * @notice holds most gauge logic (other than the Seed Gauge).
 */
library LibGaugeLogic {

    /**
     * @notice Stub function for LP distribution calculations
     * @dev This is a placeholder - implement actual logic as needed
     */
    function _calculateOptimalPercentDepositedBdv(
        address token,
        int256 delta
    ) internal pure returns (uint128) {
        // TODO: Implement actual calculation logic
        return 0;
    }

    /**
    * @notice handles the LP distribution gauge.
    * @param value the value to handle.
    * @param systemData the system data to handle.
    * @param gaugeData the gauge data to handle.
    * @return bytes memory, bytes memory the return data and success status.
    */
    function lpDistributionGauge(
        bytes memory value,
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
        // note: default state is for the gauge to run in perpetuitity.
        // delta[] and tokens[] MUST have the same indexes.
        // Responsibility is on Deployer to ensure lengths are correct.
        if ((gd.duration >= s.sys.season.current) || gd.duration == 0) {
            for(uint i = 0; i < gd.distributions.length; i++) {
                LibLpDistributionGauge.LpDistribution memory lpDist = gd.distributions[i];
                if(lpDist.impl.target != address(0)) {
                    // more encode types can be added here.
                    // the function should adhere to `foo(int256,bytes) external returns (int256)`
                    (bool success, bytes memory returnData) = lpDist.impl.target.staticcall(abi.encodeWithSelector(
                        lpDist.impl.selector,
                        lpDist.delta,
                        lpDist.impl.data
                    ));
                    if (success) {
                        lpDist.delta = abi.decode(returnData, (int256));
                    }
                    uint128 newOptimalPercentDepositedBdv;
                    if(lpDist.delta > 0) {
                        newOptimalPercentDepositedBdv = _calculateOptimalPercentDepositedBdv(lpDist.token, lpDist.delta);
                    }
                    // TODO: Implement actual changeOptimalPercentDepositedBdv call
                    // LibGauge.changeOptimalPercentDepositedBdv(lpDist.token, lpDist.delta, newOptimalPercentDepositedBdv);
                } else {
                    // TODO: Implement actual changeOptimalPercentDepositedBdv call
                    // LibGauge.changeOptimalPercentDepositedBdv(lpDist.token, lpDist.delta);
                }
            }

        } else {
            // skip, return unchanged values/gaugeData.
            return (value, gaugeData);
        }
    }

}

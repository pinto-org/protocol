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
     * @param gaugeData the gauge data to handle.
     * @return bytes memory, bytes memory the return data and success status.
     */
    function lpDistributionGauge(
        bytes memory,
        bytes memory,
        bytes memory gaugeData
    ) internal returns (bytes memory, bytes memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LibLpDistributionGauge.LpDistributionGaugeData memory gd = abi.decode(
            gaugeData,
            (LibLpDistributionGauge.LpDistributionGaugeData)
        );

        // if the gauge is not enabled, skip and return unchanged values/gaugeData.
        if (!gd.enabled) {
            return (bytes(""), gaugeData);
        }

        bool targetReached = true;
        for (uint i = 0; i < gd.distributions.length; i++) {
            LibLpDistributionGauge.LpDistribution memory lpDist = gd.distributions[i];
            // if the token has an implementation, invoke the implementation to calculate the new delta.
            if (lpDist.impl.target != address(0)) {
                // the function should adhere to `foo(int64,bytes) external returns (int64)`
                bool success;
                bytes memory returnData;
                if (lpDist.impl.encodeType == bytes1(0x00)) {
                    (success, returnData) = lpDist.impl.target.staticcall(
                        abi.encodeWithSelector(lpDist.impl.selector, lpDist.delta, lpDist.impl.data)
                    );
                }
                // more encode types can be added here.
                // if the encoding type is not valid, the delta remains the same.

                if (success) {
                    lpDist.delta = abi.decode(returnData, (int64));
                }
            }

            // if the token does not have an implementation, we change
            // the optimal deposited bdv by `delta`.

            // if the target is not reached, change the optimal percent deposited bdv if delta is non-zero.
            if (
                s.sys.silo.assetSettings[lpDist.token].optimalPercentDepositedBdv != lpDist.target
            ) {
                targetReached = false;
                if (lpDist.delta != 0) {
                    uint64 newOptimalPercentDepositedBdv = LibLpDistributionGauge
                        .calculateOptimalPercentDepositedBdv(
                            lpDist.token,
                            lpDist.delta,
                            lpDist.target
                        );
                    s
                        .sys
                        .silo
                        .assetSettings[lpDist.token]
                        .optimalPercentDepositedBdv = newOptimalPercentDepositedBdv;
                }
            }
        }

        // if targetReached is true (i.e all targets are reached), disable the gauge.
        if (targetReached) {
            gd.enabled = false;
        }

        return (bytes(""), abi.encode(gd));
    }
}

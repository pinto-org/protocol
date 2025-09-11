// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


/**
 * @title LibGaugeLogic
 * @notice holds most gauge logic (other than the Seed Gauge).
 */
library LibGaugeLogic {

    lpDistrubutionGauge(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) internal returns (bytes memory, bytes memory) {
        LibGaugeHelpers.LpDistrubutionGaugeData memory gd = abi.decode(
            gaugeData,
            (LibGaugeHelpers.LpDistrubutionGaugeData)
        );

        LpDisturbutionSettings settings = LibLpDistrubutionGauge.getSettings(gd);

        // the gauge only runs if: 
        // 1: the duration is 0 (run forever)
        // 2: the duration is >= s.sys.season.current
        // note: default state is for the gauge to run in perpetuitity. 
        // note: delta[] and tokens[] MUST have the same indexes. 
        // Responsibility is on Deployer to ensure lengths are correct.
        if ((settings.duration >= s.sys.season.current) || settings.duration == 0) {
            // run
            int256[] delta;
            if(settings.foo.length > 0) {
                // call stuff to get the delta. 
                // insert logic here to call stuff
                for(uint256 i = 0; i < settings.foo.length; i++) {
                    delta[i] = abi.decode(LibCall.call(settings.foo[i]), (int256));
                }
            } else {
                delta = gd.delta;
            }

            if (gd.tokens.length > 0) {
                for (uint256 i; i < gd.tokens.length; i++) {
                    LibGauge.changeOptimalPercentDepositedBdv(gd.tokens[i], delta[i]);
                }
            }
        } else {
            // skip, return unchanged values/gaugeData.
            return (value, gaugeData);
        }
    }

}

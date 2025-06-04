/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {LibInitGauges} from "../../libraries/LibInitGauges.sol";
import {LibUpdate} from "../../libraries/LibUpdate.sol";
import {LibGauge} from "../../libraries/LibGauge.sol";
import {LibWhitelistedTokens} from "../../libraries/Silo/LibWhitelistedTokens.sol";

/**
 * @title InitPI10
 * @dev Initializes parameters for pinto improvement 10.
 **/
contract InitPI10 {
    uint128 constant MAX_TOTAL_GAUGE_POINTS = 10000e18;

    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Set the max total gauge points to MAX_TOTAL_GAUGE_POINTS
        s.sys.seedGauge.maxTotalGaugePoints = MAX_TOTAL_GAUGE_POINTS;
        emit LibGauge.UpdateMaxTotalGaugePoints(MAX_TOTAL_GAUGE_POINTS);

        s.sys.season.pegCrossSeason = 2558;
        int96[] memory pegCrossStems = new int96[](6);
        pegCrossStems[0] = 8315823284;
        pegCrossStems[1] = 5806287780;
        pegCrossStems[2] = 8192718220;
        pegCrossStems[3] = 6029220433;
        pegCrossStems[4] = 7941276501;
        pegCrossStems[5] = 7573149414;

        address[] memory whitelistedLpTokens = LibWhitelistedTokens.getWhitelistedLpTokens();
        address[] memory whitelistedTokens = LibWhitelistedTokens.getWhitelistedTokens();

        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            s.sys.belowPegCrossStems[whitelistedTokens[i]] = pegCrossStems[i];
        }

        // iterate over all the whitelisted LP tokens
        uint256 totalGaugePoints = 0;
        for (uint256 i = 0; i < whitelistedLpTokens.length; i++) {
            totalGaugePoints += s.sys.silo.assetSettings[whitelistedLpTokens[i]].gaugePoints;
        }
        // set the gauge points to the normalized gauge points
        for (uint256 i = 0; i < whitelistedLpTokens.length; i++) {
            s.sys.silo.assetSettings[whitelistedLpTokens[i]].gaugePoints = uint128(
                (uint256(s.sys.silo.assetSettings[whitelistedLpTokens[i]].gaugePoints) *
                    MAX_TOTAL_GAUGE_POINTS) / totalGaugePoints
            );
            emit LibGauge.GaugePointChange(
                s.sys.season.current,
                whitelistedLpTokens[i],
                s.sys.silo.assetSettings[whitelistedLpTokens[i]].gaugePoints
            );
        }

        LibInitGauges.initConvertUpBonusGauge(); // add the convert up bonus gauge
    }
}

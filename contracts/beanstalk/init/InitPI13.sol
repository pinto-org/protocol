/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {LibInitGauges} from "contracts/libraries/Gauge/LibInitGauges.sol";
import {LibUpdate} from "../../libraries/LibUpdate.sol";
import {LibGauge} from "contracts/libraries/Gauge/LibGauge.sol";
import {LibWhitelistedTokens} from "../../libraries/Silo/LibWhitelistedTokens.sol";
import {LibGaugeHelpers} from "contracts/libraries/Gauge/LibGaugeHelpers.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibWeather} from "../../libraries/Sun/LibWeather.sol";

/**
 * @title InitPI13
 * @dev Initializes parameters for pinto improvement 13.
 **/
contract InitPI13 {
    uint128 constant MAX_TOTAL_GAUGE_POINTS = 10000e18;
    uint16 constant MORNING_DURATION = 600;
    uint128 constant MORNING_CONTROL = uint128(1e18) / 240;

    function init(uint256 bonusStalkPerBdv, uint256 twaDeltaB) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // initialize the gauge point update.
        initMaxGaugePoints();

        // add the convert up bonus gauge
        LibInitGauges.initConvertUpBonusGauge(twaDeltaB);

        // update the gauge with the stalk per bdv bonus.
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
            LibGaugeHelpers.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );

        // initialize morning Auction Control variables.
        s.sys.weather.morningDuration = MORNING_DURATION;
        s.sys.weather.morningControl = MORNING_CONTROL;

        // update the convert up bonus gauge value.
        gv.bonusStalkPerBdv = bonusStalkPerBdv;
        LibGaugeHelpers.updateGaugeValue(GaugeId.CONVERT_UP_BONUS, abi.encode(gv));
    }

    /**
     * @notice Initializes the max total gauge points.
     * @dev this function takes the current gauge points of the whitelisted LP tokens, and normalizes them to the max total gauge points.
     
     */
    function initMaxGaugePoints() internal {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Set the max total gauge points to MAX_TOTAL_GAUGE_POINTS
        s.sys.seedGauge.maxTotalGaugePoints = MAX_TOTAL_GAUGE_POINTS;
        emit LibGauge.UpdateMaxTotalGaugePoints(MAX_TOTAL_GAUGE_POINTS);

        address[] memory whitelistedLpTokens = LibWhitelistedTokens.getWhitelistedLpTokens();

        // iterate over all the whitelisted LP tokens
        uint256 totalGaugePoints = 0;
        for (uint256 i = 0; i < whitelistedLpTokens.length; i++) {
            totalGaugePoints += s.sys.silo.assetSettings[whitelistedLpTokens[i]].gaugePoints;
        }

        // this init scripts assumes that the total gauge points is greater than 0 && there are whitelisted LP tokens.
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
    }
}

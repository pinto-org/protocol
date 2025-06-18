/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {LibInitGauges} from "../../libraries/LibInitGauges.sol";
import {LibUpdate} from "../../libraries/LibUpdate.sol";
import {LibGauge} from "../../libraries/LibGauge.sol";
import {LibWhitelistedTokens} from "../../libraries/Silo/LibWhitelistedTokens.sol";
import {LibGaugeHelpers} from "../../libraries/LibGaugeHelpers.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibWeather} from "../../libraries/Season/LibWeather.sol";

/**
 * @title InitPIConvertBonus
 * @dev Initializes parameters for pinto improvement 10.
 **/
contract InitPIConvertBonus {
    uint128 constant MAX_TOTAL_GAUGE_POINTS = 10000e18;
    uint32 constant PEG_CROSS_SEASON = 2558;
    uint16 constant MORNING_DURATION = 600;
    uint128 constant MORNING_CONTROL = uint128(1e18) / 240;

    function init(uint256 bonusStalkPerBdv) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // initialize the gauge point update.
        initMaxGaugePoints(MAX_TOTAL_GAUGE_POINTS);

        // initialize peg cross season.
        s.sys.season.pegCrossSeason = PEG_CROSS_SEASON;
        emit LibWeather.PegStateUpdated(s.sys.season.pegCrossSeason, s.sys.season.abovePeg);

        // add the convert up bonus gauge
        LibInitGauges.initConvertUpBonusGauge(0);

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

    function initMaxGaugePoints(uint256 /*maxGaugePoints*/) internal {
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

        // Only normalize if totalGaugePoints > 0 to avoid division by zero
        if (totalGaugePoints > 0) {
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
        } else if (whitelistedLpTokens.length > 0) {
            // If all gauge points are 0, distribute equally among whitelisted tokens
            uint256 pointsPerToken = MAX_TOTAL_GAUGE_POINTS / whitelistedLpTokens.length;
            for (uint256 i = 0; i < whitelistedLpTokens.length; i++) {
                s.sys.silo.assetSettings[whitelistedLpTokens[i]].gaugePoints = uint128(
                    pointsPerToken
                );
                emit LibGauge.GaugePointChange(
                    s.sys.season.current,
                    whitelistedLpTokens[i],
                    pointsPerToken
                );
            }
        }
    }
}

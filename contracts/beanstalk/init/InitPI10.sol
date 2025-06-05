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
 * @title InitPI10
 * @dev Initializes parameters for pinto improvement 10.
 **/
contract InitPI10 {
    uint128 constant MAX_TOTAL_GAUGE_POINTS = 10000e18;
    uint32 constant PEG_CROSS_SEASON = 2558;
    uint16 constant MORNING_DURATION = 600;
    uint128 constant MORNING_CONTROL = uint128(1e18) / 240;

    function init(
        uint256 bonusStalkPerBdv,
        uint256 soldOutTemperature,
        uint256 prevSeasonTemperature
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // initialize the gauge point update.
        initMaxGaugePoints(MAX_TOTAL_GAUGE_POINTS);

        // initialize peg cross season.
        s.sys.season.pegCrossSeason = PEG_CROSS_SEASON;
        emit LibWeather.PegStateUpdated(s.sys.season.pegCrossSeason, s.sys.season.abovePeg);

        // add the convert up bonus gauge
        LibInitGauges.initConvertUpBonusGauge();

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

        // update the cultivation factor gauge data to the new version.
        initCultivationFactorGaugeV1_1(soldOutTemperature, prevSeasonTemperature);
    }

    function initMaxGaugePoints(uint128 maxGaugePoints) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Set the max total gauge points to MAX_TOTAL_GAUGE_POINTS
        s.sys.seedGauge.maxTotalGaugePoints = maxGaugePoints;
        emit LibGauge.UpdateMaxTotalGaugePoints(maxGaugePoints);

        address[] memory whitelistedLpTokens = LibWhitelistedTokens.getWhitelistedLpTokens();

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
    }

    function initCultivationFactorGaugeV1_1(
        uint256 soldOutTemperature,
        uint256 prevSeasonTemperature
    ) internal {
        (uint256 minDeltaCf, uint256 maxDeltaCf, uint256 minCf, uint256 maxCf) = abi.decode(
            LibGaugeHelpers.getGaugeData(GaugeId.CULTIVATION_FACTOR),
            (uint256, uint256, uint256, uint256)
        );

        // updates the gauge data to the new version, with the sold out temperature and previous season temperature set to 0.
        LibGaugeHelpers.updateGaugeData(
            GaugeId.CULTIVATION_FACTOR,
            abi.encode(minDeltaCf, maxDeltaCf, minCf, maxCf, 0, 0)
        );
    }
}

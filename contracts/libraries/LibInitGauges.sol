/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import {Gauge, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";
import {IGaugeFacet} from "contracts/beanstalk/facets/sun/GaugeFacet.sol";

/**
 * @title LibInitGauges
 * @dev Helper library for adding and initializing gauges.
 **/
library LibInitGauges {
    //////////// Cultivation Factor ////////////
    // Gauge values
    uint256 internal constant INIT_CULTIVATION_FACTOR = 50e6; // the initial cultivation factor
    // Gauge data
    uint256 internal constant MIN_DELTA_CULTIVATION_FACTOR = 0.5e6; // the minimum value the cultivation factor can be adjusted by
    uint256 internal constant MAX_DELTA_CULTIVATION_FACTOR = 2e6; // the maximum value the cultivation factor can be adjusted by
    uint256 internal constant MIN_CULTIVATION_FACTOR = 1e6; // the minimum value the cultivation factor can be adjusted to
    uint256 internal constant MAX_CULTIVATION_FACTOR = 100e6; // the maximum value the cultivation factor can be adjusted to

    //////////// Convert Down Penalty ////////////
    // Gauge values
    uint256 internal constant INIT_CONVERT_DOWN_PENALTY_RATIO = 0; // The % penalty to be applied to grown stalk when down converting.
    uint256 internal constant INIT_ROLLING_SEASONS_ABOVE_PEG = 0; // Rolling count of seasons with a twap above peg.
    // Gauge data
    uint256 internal constant ROLLING_SEASONS_ABOVE_PEG_CAP = 12; // Max magnitude for rolling seasons above peg count.
    uint256 internal constant ROLLING_SEASONS_ABOVE_PEG_RATE = 1; // Rate at which rolling seasons above peg count changes. If not one, it is not actual count.

    //////////// Convert Up Bonus Gauge ////////////
    // Gauge values
    uint256 internal constant INIT_BONUS_STALK_PER_BDV = 0; // the initial bonus stalk per bdv
    uint256 internal constant INIT_MAX_CONVERT_CAPACITY = 0; // the initial convert capacity
    // Gauge data
    uint256 internal constant DELTA_C = 0.01e18; // the value that the convert bonus factor can be adjusted by
    uint256 internal constant DELTA_T = 0.004e18; // the value that the convert bdv capacity factor can be adjusted by
    uint256 internal constant MIN_CONVERT_BONUS_FACTOR = 0; // the minimum value the convert bonus factor can be adjusted to (0%)
    uint256 internal constant MAX_CONVERT_BONUS_FACTOR = 1e18; // the maximum value the convert bonus factor can be adjusted to (100%)
    uint256 internal constant MIN_CAPACITY_FACTOR = 0.1e18; // the minimum value the convert bdv capacity factor can be adjusted to (10%)
    uint256 internal constant MAX_CAPACITY_FACTOR = 0.5e18; // the maximum value the convert bdv capacity factor can be adjusted to (50%)
    uint256 internal constant TOTAL_SEASON_BDV_CONVERTED_BONUS = 0; // the bdv converted in the current season with a bonus

    //////////// Cultivation Factor Gauge ////////////

    function initCultivationFactor() internal {
        Gauge memory cultivationFactorGauge = Gauge(
            abi.encode(INIT_CULTIVATION_FACTOR),
            address(this),
            IGaugeFacet.cultivationFactor.selector,
            abi.encode(
                MIN_DELTA_CULTIVATION_FACTOR,
                MAX_DELTA_CULTIVATION_FACTOR,
                MIN_CULTIVATION_FACTOR,
                MAX_CULTIVATION_FACTOR,
                uint256(0), // sold out temperature
                uint256(0) // previous season temperature
            )
        );
        LibGaugeHelpers.addGauge(GaugeId.CULTIVATION_FACTOR, cultivationFactorGauge);
    }

    //////////// Convert Down Penalty Gauge ////////////

    function initConvertDownPenalty() internal {
        Gauge memory convertDownPenaltyGauge = Gauge(
            abi.encode(INIT_CONVERT_DOWN_PENALTY_RATIO, INIT_ROLLING_SEASONS_ABOVE_PEG),
            address(this),
            IGaugeFacet.convertDownPenaltyGauge.selector,
            abi.encode(ROLLING_SEASONS_ABOVE_PEG_RATE, ROLLING_SEASONS_ABOVE_PEG_CAP)
        );
        LibGaugeHelpers.addGauge(GaugeId.CONVERT_DOWN_PENALTY, convertDownPenaltyGauge);
    }

    //////////// Convert Up Bonus Gauge ////////////

    function initConvertUpBonusGauge() internal {
        // initialize the gauge as if the system has just started issuing a bonus.
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = LibGaugeHelpers.ConvertBonusGaugeValue(
            MAX_CONVERT_BONUS_FACTOR,
            MIN_CAPACITY_FACTOR,
            INIT_BONUS_STALK_PER_BDV,
            INIT_MAX_CONVERT_CAPACITY
        );

        LibGaugeHelpers.ConvertBonusGaugeData memory gd = LibGaugeHelpers.ConvertBonusGaugeData(
            DELTA_C,
            DELTA_T,
            MIN_CONVERT_BONUS_FACTOR,
            MAX_CONVERT_BONUS_FACTOR,
            MIN_CAPACITY_FACTOR,
            MAX_CAPACITY_FACTOR,
            TOTAL_SEASON_BDV_CONVERTED_BONUS
        );
        Gauge memory convertBonusGauge = Gauge(
            abi.encode(gv),
            address(this),
            IGaugeFacet.convertUpBonusGauge.selector,
            abi.encode(gd)
        );
        LibGaugeHelpers.addGauge(GaugeId.CONVERT_UP_BONUS, convertBonusGauge);
    }
}

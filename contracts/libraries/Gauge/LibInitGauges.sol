/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import {Gauge, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibGaugeHelpers} from "contracts/libraries/Gauge/LibGaugeHelpers.sol";
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
    uint256 internal constant INIT_BEANS_MINTED_ABOVE_PEG = 0; // the initial beans minted above peg
    uint256 internal constant INIT_BEAN_AMOUNT_ABOVE_THRESHOLD = 10_000_000e6; // the initial bean amount above threshold
    uint256 internal constant INIT_RUNNING_THRESHOLD = 0; // initialize running threshold to 0
    uint256 internal constant PERCENT_SUPPLY_THRESHOLD_RATE = 416666666666667; // 1%/24 = 0.01e18/24 ≈ 0.0004166667e18
    uint256 internal constant CONVERT_DOWN_PENALTY_RATE = 1.005e6; // $1.005 convert price.

    //////////// Convert Up Bonus Gauge ////////////
    // Gauge values
    uint256 internal constant INIT_BONUS_STALK_PER_BDV = 0; // the initial bonus stalk per bdv
    uint256 internal constant INIT_CONVERT_CAPACITY_FACTOR = 1e6; // the initial convert capacity factor
    uint256 internal constant INIT_CONVERT_CAPACITY = 0; // the initial convert capacity
    // Gauge data
    uint256 internal constant MIN_SEASON_TARGET = 250e6; // the minimum seasons to reach value target via conversions. 6 decimal precision.
    uint256 internal constant MAX_SEASON_TARGET = 1000e6; // the maximum seasons to reach value target via conversions. 6 decimal precision.
    uint256 internal constant MIN_DELTA_CAPACITY = 0.5e6; // the minimum value that the convert capacity factor can be adjusted by. 6 decimal precision.
    uint256 internal constant MAX_DELTA_CAPACITY = 1.5e6; // the maximum value that the convert capacity factor can be adjusted by. 6 decimal precision.

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
                0,
                0
            )
        );
        LibGaugeHelpers.addGauge(GaugeId.CULTIVATION_FACTOR, cultivationFactorGauge);
    }

    //////////// Convert Down Penalty Gauge ////////////

    function initConvertDownPenalty() internal {
        LibGaugeHelpers.ConvertDownPenaltyValue memory gv = LibGaugeHelpers
            .ConvertDownPenaltyValue({
                penaltyRatio: INIT_CONVERT_DOWN_PENALTY_RATIO,
                rollingSeasonsAbovePeg: INIT_ROLLING_SEASONS_ABOVE_PEG
            });
        LibGaugeHelpers.ConvertDownPenaltyData memory gd = LibGaugeHelpers.ConvertDownPenaltyData({
            rollingSeasonsAbovePegRate: ROLLING_SEASONS_ABOVE_PEG_RATE,
            rollingSeasonsAbovePegCap: ROLLING_SEASONS_ABOVE_PEG_CAP,
            beansMintedAbovePeg: INIT_BEANS_MINTED_ABOVE_PEG,
            beanMintedThreshold: INIT_BEAN_AMOUNT_ABOVE_THRESHOLD,
            runningThreshold: INIT_RUNNING_THRESHOLD,
            percentSupplyThresholdRate: PERCENT_SUPPLY_THRESHOLD_RATE,
            convertDownPenaltyRate: CONVERT_DOWN_PENALTY_RATE,
            thresholdSet: true
        });

        Gauge memory convertDownPenaltyGauge = Gauge(
            abi.encode(gv),
            address(this),
            IGaugeFacet.convertDownPenaltyGauge.selector,
            abi.encode(gd)
        );

        LibGaugeHelpers.addGauge(GaugeId.CONVERT_DOWN_PENALTY, convertDownPenaltyGauge);
    }

    //////////// Convert Up Bonus Gauge ////////////

    function initConvertUpBonusGauge(uint256 twaDeltaB, uint256 minMaxConvertCapacity) internal {
        // initialize the gauge as if the system has just started issuing a bonus.
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = LibGaugeHelpers.ConvertBonusGaugeValue(
            INIT_BONUS_STALK_PER_BDV,
            INIT_CONVERT_CAPACITY,
            INIT_CONVERT_CAPACITY_FACTOR
        );

        LibGaugeHelpers.ConvertBonusGaugeData memory gd = LibGaugeHelpers.ConvertBonusGaugeData(
            MIN_SEASON_TARGET, // minSeasonTarget - minimum seasons to reach value target
            MAX_SEASON_TARGET, // maxSeasonTarget - maximum seasons to reach value target
            minMaxConvertCapacity, // minMaxConvertCapacity - minimum value maxConvertCapacity can be set to
            MIN_DELTA_CAPACITY, // minDeltaCapacity - minimum delta capacity used to change the rate of change in the capacity factor
            MAX_DELTA_CAPACITY, // maxDeltaCapacity - maximum delta capacity used to change the rate of change in the capacity factor
            0, // bdvConvertedThisSeason
            0, // bdvConvertedLastSeason
            twaDeltaB, // maxTwaDeltaB
            0 // lastConvertBonusTaken
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Gauge, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {C} from "contracts/C.sol";
import {Implementation} from "contracts/beanstalk/storage/System.sol";

/**
 * @title LibGaugeHelpers
 * @notice Helper Library for Gauges.
 */
library LibGaugeHelpers {
    // Gauge structs

    // Convert Down Penalty Gauge structs

    /**
     * @notice The value of the Convert Down Penalty Gauge.
     * @param penaltyRatio The % of grown stalk lost on a down convert (1e18 = 100% penalty).
     * @param rollingSeasonsAbovePeg The rolling count of seasons above peg.
     */
    struct ConvertDownPenaltyValue {
        uint256 penaltyRatio;
        uint256 rollingSeasonsAbovePeg;
    }

    /**
     * @notice The data of the Convert Down Penalty Gauge.
     * @param rollingSeasonsAbovePegRate The rate at which the rolling count of seasons above peg increases.
     * @param rollingSeasonsAbovePegCap The cap on the rolling count of seasons above peg.
     * @param beansMintedAbovePeg The amount of beans minted above peg after the system crosses value target.
     * @param beanMintedThreshold The absolute Bean amount that needs to be minted above the threshold before penalty reduction.
     * @param runningThreshold a threshold used to track subsequent threshold, after the initial threshold is set.
     * @param percentSupplyThresholdRate The rate at which the percent supply threshold increases (used to calculate beanMintedThreshold during below-peg seasons).
     * @param convertDownPenaltyRate The rate at which any exchange rate below this value is penalized.
     * @param thresholdSet Flag indicating if the `beanMintedThreshold` is set. `set` in this instance means that the threshold is "locked" until enough beans are minted.
     */
    struct ConvertDownPenaltyData {
        uint256 rollingSeasonsAbovePegRate;
        uint256 rollingSeasonsAbovePegCap;
        uint256 beansMintedAbovePeg;
        uint256 beanMintedThreshold;
        uint256 runningThreshold;
        uint256 percentSupplyThresholdRate;
        uint256 convertDownPenaltyRate;
        bool thresholdSet;
    }

    // Convert Bonus Gauge Constants
    uint256 internal constant MIN_CONVERT_CAPACITY_FACTOR = 1e6;
    uint256 internal constant MAX_CONVERT_CAPACITY_FACTOR = 100e6;
    uint256 internal constant CONVERT_CAPACITY_FILLED = 0.95e6;
    uint256 internal constant CONVERT_CAPACITY_MOSTLY_FILLED = 0.80e6;
    uint256 constant CONVERT_DEMAND_UPPER_BOUND = 1.05e6; // 5% above 1
    uint256 constant CONVERT_DEMAND_LOWER_BOUND = 0.95e6; // 5% below 1

    // Gauge structs

    //// Convert Bonus Gauge ////

    /**
     * @notice Struct for Convert Bonus Gauge Value
     * @dev The value of the Convert Bonus Gauge is a struct that contains the following:
     * - bonusStalkPerBdv: The base bonus stalk per bdv that can be issued as a bonus.
     * - maxConvertCapacity: The maximum amount of bdv that can be converted in a season and get a bonus.
     * - convertCapacityFactor: The Factor used to determine the convert capacity.
     */
    struct ConvertBonusGaugeValue {
        uint256 bonusStalkPerBdv;
        uint256 maxConvertCapacity;
        uint256 convertCapacityFactor;
    }

    /**
     * @notice Struct for Convert Bonus Gauge Data
     * @dev The data of the Convert Bonus Gauge is a struct that contains the following:
     * - minSeasonTarget: The minimum target seasons to return to value target via conversions.
     * - maxSeasonTarget: The maximum target seasons to return to value target via conversions.
     * - minmaxConvertCapacity: The minimum value `maxConvertCapacity` can be set to.
     * - minDeltaCapacity: The minimum delta capacity used to change the rate of change in the capacity factor.
     * - maxDeltaCapacity: The maximum delta capacity used to change the rate of change in the capacity factor.
     * - bdvConvertedThisSeason: The amount of bdv converted that received a bonus this season.
     * - bdvConvertedLastSeason: The amount of bdv converted that received a bonus last season.
     * - maxTwaDeltaB: The maximum recorded negative twaDeltaB while the bonus was active.
     */
    struct ConvertBonusGaugeData {
        uint256 minSeasonTarget;
        uint256 maxSeasonTarget;
        uint256 minMaxConvertCapacity;
        uint256 minDeltaCapacity;
        uint256 maxDeltaCapacity;
        uint256 bdvConvertedThisSeason;
        uint256 bdvConvertedLastSeason;
        uint256 maxTwaDeltaB;
        uint256 lastConvertBonusTaken;
    }

    enum ConvertBonusCapacityUtilization {
        NOT_FILLED,
        MOSTLY_FILLED,
        FILLED
    }

    enum ConvertDemand {
        DECREASING,
        STEADY,
        INCREASING
    }

    // Gauge events

    /**
     * @notice Emitted when a Gauge is engaged (i.e. its value is updated).
     * @param gaugeId The id of the Gauge that was engaged.
     * @param value The value of the Gauge after it was engaged.
     */
    event Engaged(GaugeId gaugeId, bytes value);

    /**
     * @notice Emitted when a Gauge is engaged (i.e. its value is updated).
     * @param gaugeId The id of the Gauge that was engaged.
     * @param data The data of the Gauge after it was engaged.
     */
    event EngagedData(GaugeId gaugeId, bytes data);

    /**
     * @notice Emitted when a Gauge is added.
     * @param gaugeId The id of the Gauge that was added.
     * @param gauge The Gauge that was added.
     */
    event AddedGauge(GaugeId gaugeId, Gauge gauge);

    /**
     * @notice Emitted when a Stateful Gauge is added.
     * @param gaugeId The id of the Stateful Gauge that was added.
     * @param gauge The Stateful Gauge that was added.
     */
    event AddedStatefulGauge(GaugeId gaugeId, Gauge gauge);

    /**
     * @notice Emitted when a Gauge is removed.
     * @param gaugeId The id of the Gauge that was removed.
     */
    event RemovedGauge(GaugeId gaugeId);

    /**
     * @notice Emitted when a Gauge is updated.
     * @param gaugeId The id of the Gauge that was updated.
     * @param gauge The Gauge that was updated.
     */
    event UpdatedGauge(GaugeId gaugeId, Gauge gauge);

    /**
     * @notice Emitted when a Gauge's data is updated (outside of the engage function).
     * @param gaugeId The id of the Gauge that was updated.
     * @param data The data of the Gauge that was updated.
     */
    event UpdatedGaugeData(GaugeId gaugeId, bytes data);

    /**
     * @notice Emitted when a Gauge's value is updated (outside of the engage function).
     * @param gaugeId The id of the Gauge that was updated.
     * @param value The value of the Gauge that was updated.
     */
    event UpdatedGaugeValue(GaugeId gaugeId, bytes value);

    /**
     * @notice Calls all generalized Gauges, and updates their values.
     * @param systemData The system data to pass to the Gauges.
     */
    function engage(bytes memory systemData) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        for (uint256 i = 0; i < s.sys.gaugeData.gaugeIds.length; i++) {
            callGaugeId(s.sys.gaugeData.gaugeIds[i], systemData);
        }
    }

    /**
     * @notice Calls a Gauge by its id, and updates the Gauge's value.
     * @dev Returns g.value if the call fails.
     */
    function callGaugeId(GaugeId gaugeId, bytes memory systemData) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // gs = `gauge storage`
        Gauge storage gs = s.sys.gaugeData.gauges[gaugeId];

        // if the gauge is stateful, call the stateful gauge result.
        if (s.sys.gaugeData.stateful[gaugeId]) {
            (gs.value, gs.data) = getStatefulGaugeResult(gs, systemData);
        } else {
            (gs.value, gs.data) = getStatelessGaugeResult(gs, systemData);
        }

        // emit change in gauge value and data
        emit Engaged(gaugeId, gs.value);
        emit EngagedData(gaugeId, gs.data);
    }

    /**
     * @notice Calls a Stateless Gauge.
     * @dev Returns the original value and data of the Gauge if the call fails.
     */
    function getStatelessGaugeResult(
        Gauge memory g,
        bytes memory systemData
    ) internal view returns (bytes memory, bytes memory) {
        if (g.selector == bytes4(0)) return (g.value, g.data);
        (bool success, bytes memory returnData) = g.target.staticcall(getCallData(g, systemData));
        return getCallResult(g, success, returnData);
    }

    /**
     * @notice Calls a Stateful Gauge.
     * @dev Returns the original value and data of the Gauge if the call fails.
     */
    function getStatefulGaugeResult(
        Gauge memory g,
        bytes memory systemData
    ) internal returns (bytes memory, bytes memory) {
        if (g.selector == bytes4(0)) return (g.value, g.data);
        (bool success, bytes memory returnData) = g.target.call(getCallData(g, systemData));
        return getCallResult(g, success, returnData);
    }

    /**
     * @notice Returns the call data for a Gauge.
     */
    function getCallData(
        Gauge memory g,
        bytes memory systemData
    ) internal view returns (bytes memory) {
        // if the Gauge does not have a target, assume the target is address(this)
        if (g.target == address(0)) {
            g.target = address(this);
        }

        return abi.encodeWithSelector(g.selector, g.value, systemData, g.data);
    }

    function getCallResult(
        Gauge memory g,
        bool success,
        bytes memory returnData
    ) internal pure returns (bytes memory, bytes memory) {
        if (!success) {
            return (g.value, g.data); // In case of failure, return value unadjusted
        }
        return abi.decode(returnData, (bytes, bytes));
    }

    /**
     * @notice Adds a Gauge to the system.
     * @dev Gauges are not stateful by default. Stateful gauges are added using `addStatefulGauge`.
     * @param gaugeId The id of the Gauge to add.
     * @param g The Gauge to add.
     */
    function addGauge(GaugeId gaugeId, Gauge memory g) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // verify that the gaugeId is not already in the array
        for (uint256 i = 0; i < s.sys.gaugeData.gaugeIds.length; i++) {
            if (s.sys.gaugeData.gaugeIds[i] == gaugeId) {
                revert("GaugeId already exists");
            }
        }
        s.sys.gaugeData.gaugeIds.push(gaugeId);
        s.sys.gaugeData.gauges[gaugeId] = g;

        emit AddedGauge(gaugeId, g);
    }

    function addStatefulGauge(GaugeId gaugeId, Gauge memory g) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        addGauge(gaugeId, g);
        s.sys.gaugeData.stateful[gaugeId] = true;
        emit AddedStatefulGauge(gaugeId, g);
    }

    function updateGauge(GaugeId gaugeId, Gauge memory g) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.gaugeData.gauges[gaugeId] = g;

        emit UpdatedGauge(gaugeId, g);
    }

    function updateGaugeValue(GaugeId gaugeId, bytes memory value) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.gaugeData.gauges[gaugeId].value = value;

        emit UpdatedGaugeValue(gaugeId, value);
    }

    function updateGaugeData(GaugeId gaugeId, bytes memory data) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.gaugeData.gauges[gaugeId].data = data;

        emit UpdatedGaugeData(gaugeId, data);
    }

    function removeGauge(GaugeId gaugeId) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // remove the gauge from the array
        uint256 index = findGaugeIndex(gaugeId);
        s.sys.gaugeData.gaugeIds[index] = s.sys.gaugeData.gaugeIds[
            s.sys.gaugeData.gaugeIds.length - 1
        ];
        s.sys.gaugeData.gaugeIds.pop();
        delete s.sys.gaugeData.gauges[gaugeId];

        emit RemovedGauge(gaugeId);
    }

    function findGaugeIndex(GaugeId gaugeId) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        for (uint256 i = 0; i < s.sys.gaugeData.gaugeIds.length; i++) {
            if (s.sys.gaugeData.gaugeIds[i] == gaugeId) {
                return i;
            }
        }
        revert("Gauge not found");
    }

    function getGaugeValue(GaugeId gaugeId) internal view returns (bytes memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.sys.gaugeData.gauges[gaugeId].value;
    }

    function getGaugeData(GaugeId gaugeId) internal view returns (bytes memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.sys.gaugeData.gauges[gaugeId].data;
    }

    /// GAUGE SPECIFIC HELPERS ///

    /**
     * @notice Updates the previous season temperature, in the Cultivation Factor Gauge.
     * @param temperature The temperature of the last season.
     */
    function updatePrevSeasonTemp(uint256 temperature) internal {
        (
            uint256 minDeltaCf,
            uint256 maxDeltaCf,
            uint256 minCf,
            uint256 maxCf,
            uint256 soldOutTemp,

        ) = abi.decode(
                getGaugeData(GaugeId.CULTIVATION_FACTOR),
                (uint256, uint256, uint256, uint256, uint256, uint256)
            );
        updateGaugeData(
            GaugeId.CULTIVATION_FACTOR,
            abi.encode(minDeltaCf, maxDeltaCf, minCf, maxCf, soldOutTemp, temperature)
        );
    }

    /**
     * @notice Updates the convert capacity factor based on the convert demand and capacity utilization.
     * @param gv The value of the Convert Bonus Gauge.
     * @param gd The data of the Convert Bonus Gauge.
     * @param cbu how much capacity was utilized last season.
     * @param cd the demand for converting over the past 2 seasons.
     * @param lpToSupplyRatio the twa lpToSupplyRatio from sunrise.
     * @return convertCapacityFactor The updated convert capacity factor.
     * @return lastConvertBonusTaken The last convert bonus taken.
     */
    function updateConvertCapacityFactor(
        ConvertBonusGaugeValue memory gv,
        ConvertBonusGaugeData memory gd,
        ConvertBonusCapacityUtilization cbu,
        ConvertDemand cd,
        uint256 lpToSupplyRatio
    ) internal view returns (uint256 convertCapacityFactor, uint256 lastConvertBonusTaken) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // if the capacity is filled or mostly filled, and the demand for convert is not decreasing,
        // set the last convert bonus taken to the current bonus stalk per bdv.
        if (cbu != ConvertBonusCapacityUtilization.NOT_FILLED && cd != ConvertDemand.DECREASING) {
            gd.lastConvertBonusTaken = gv.bonusStalkPerBdv;
        }
        lastConvertBonusTaken = gd.lastConvertBonusTaken;

        // determine amount change as a function of twaL2SR.
        // amount change has 6 decimal precision.
        uint256 amountChange = LibGaugeHelpers.linearInterpolation(
            lpToSupplyRatio,
            true,
            s.sys.evaluationParameters.lpToSupplyRatioLowerBound,
            s.sys.evaluationParameters.lpToSupplyRatioUpperBound,
            gd.minDeltaCapacity,
            gd.maxDeltaCapacity
        );

        // update the convert capacity based on
        // 1) Capacity utilization
        // 2) Demand for converts (steady/increasing, or decreasing)
        // 3) the last convert bonus taken.
        if (cbu == ConvertBonusCapacityUtilization.FILLED) {
            // capacity filled: increase convert capacity factor
            convertCapacityFactor = LibGaugeHelpers.linear256(
                gv.convertCapacityFactor,
                true,
                amountChange,
                MIN_CONVERT_CAPACITY_FACTOR,
                MAX_CONVERT_CAPACITY_FACTOR
            );
        } else if (
            cbu == ConvertBonusCapacityUtilization.NOT_FILLED &&
            (cd != ConvertDemand.DECREASING || gv.bonusStalkPerBdv >= gd.lastConvertBonusTaken)
        ) {
            // this if block is executed when:
            // 1) capacity not filled
            // AND either:
            // 2a) demand is not decreasing (steady/increasing), OR
            // 2b) demand is decreasing AND current bonus < last bonus taken
            //
            // decrease convert capacity factor:
            amountChange = 1e12 / amountChange;
            convertCapacityFactor = LibGaugeHelpers.linear256(
                gv.convertCapacityFactor,
                false,
                amountChange,
                MIN_CONVERT_CAPACITY_FACTOR,
                MAX_CONVERT_CAPACITY_FACTOR
            );
        } else {
            // if capacity is mostly filled, keep the capacity factor the same.
            convertCapacityFactor = gv.convertCapacityFactor;
        }
        // Note: convertCapacityFactor remains unchanged when:
        // - capacity is mostly filled (optimal utilization), OR
        // - capacity not filled AND demand is decreasing AND current bonus < last bonus taken (poor conditions)
    }

    /**
     * @notice Gets the bonus stalk per bdv for the current season.
     * @dev the bonus stalk per Bdv is updated based on the convert demand and the difference between the bean seeds and the max lp seeds.
     * @param bonusStalkPerBdv The bonus stalk per bdv from the previous season.
     * @param cbu The convert bonus capacity utilization.
     * @param cd The convert demand state (INCREASING, STEADY, or DECREASING).
     * @return The updated bonus stalk per bdv.
     */
    function updateBonusStalkPerBdv(
        uint256 bonusStalkPerBdv,
        ConvertBonusCapacityUtilization cbu,
        ConvertDemand cd
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // get stem tips for all whitelisted lp tokens and get the min
        address[] memory lpTokens = LibWhitelistedTokens.getWhitelistedLpTokens();
        uint256 beanSeeds = s.sys.silo.assetSettings[s.sys.bean].stalkEarnedPerSeason;
        uint256 maxLpSeeds;
        // find the largest LP seeds.
        for (uint256 i = 0; i < lpTokens.length; i++) {
            uint256 lpSeeds = s.sys.silo.assetSettings[lpTokens[i]].stalkEarnedPerSeason;
            if (lpSeeds > maxLpSeeds) maxLpSeeds = lpSeeds;
        }
        // when bean seeds > max lp seeds, the bonus increases/decreases as a
        // function of convert demand and capacity utilization.
        uint256 bonusStalkPerBdvChange;
        if (beanSeeds >= maxLpSeeds) {
            bonusStalkPerBdvChange = beanSeeds - maxLpSeeds;
        } else {
            bonusStalkPerBdvChange = bonusStalkPerBdv / 100;
        }
        if (
            cd == ConvertDemand.INCREASING ||
            cbu == LibGaugeHelpers.ConvertBonusCapacityUtilization.FILLED
        ) {
            if (bonusStalkPerBdvChange > bonusStalkPerBdv) {
                return 0;
            } else {
                return bonusStalkPerBdv - bonusStalkPerBdvChange;
            }
        } else if (cd == ConvertDemand.DECREASING && beanSeeds >= maxLpSeeds) {
            // if demand is decreasing and Bean Seeds are greater than or equal to max lp seeds,
            // the bonus increases as a function of the change in bonus stalk per bdv.
            return bonusStalkPerBdv + bonusStalkPerBdvChange;
        } else {
            return bonusStalkPerBdv;
        }
    }

    /**
     * @notice returns the ConvertBonusCapacityUtilization and ConvertDemand.
     * @dev helper function to return both Structs.
     */
    function getCapacityUtilizationAndConvertDemand(
        uint256 bdvConvertedThisSeason,
        uint256 bdvConvertedLastSeason,
        uint256 maxConvertCapacityThisSeason
    ) internal pure returns (ConvertBonusCapacityUtilization cbu, ConvertDemand cd) {
        cbu = getConvertBonusCapacityUtilization(
            bdvConvertedThisSeason,
            maxConvertCapacityThisSeason
        );
        cd = calculateConvertDemand(bdvConvertedThisSeason, bdvConvertedLastSeason);
        return (cbu, cd);
    }

    /**
     * @notice Returns an enum indicating how much of the convert capacity has been filled. Used in the Convert Bonus Gauge.
     * @param bdvConvertedThisSeason The amount of bdv converted this season.
     * @param maxConvertCapacity The maximum amount of bdv that can be converted in a season and get a bonus.
     * @return The capacity filled state.
     */
    function getConvertBonusCapacityUtilization(
        uint256 bdvConvertedThisSeason,
        uint256 maxConvertCapacity
    ) internal pure returns (ConvertBonusCapacityUtilization) {
        if (maxConvertCapacity > 0) {
            if (
                bdvConvertedThisSeason >=
                (maxConvertCapacity * CONVERT_CAPACITY_FILLED) / C.PRECISION_6
            ) {
                return ConvertBonusCapacityUtilization.FILLED;
            } else if (
                bdvConvertedThisSeason >=
                (maxConvertCapacity * CONVERT_CAPACITY_MOSTLY_FILLED) / C.PRECISION_6
            ) {
                return ConvertBonusCapacityUtilization.MOSTLY_FILLED;
            } else {
                return ConvertBonusCapacityUtilization.NOT_FILLED;
            }
        } else {
            // if there is no convert capacity, the capacity is not filled by default.
            // note: normal behavior should never hit this block and is placed here as
            // a failsafe.
            return ConvertBonusCapacityUtilization.NOT_FILLED;
        }
    }

    /**
     * @notice Calculates the demand for converts based on current and previous season BDV converted.
     * @param bdvConvertedThisSeason The BDV converted in the current season.
     * @param bdvConvertedLastSeason The BDV converted in the previous season.
     * @return The convert demand state (INCREASING, STEADY, or DECREASING).
     */
    function calculateConvertDemand(
        uint256 bdvConvertedThisSeason,
        uint256 bdvConvertedLastSeason
    ) internal pure returns (ConvertDemand) {
        // if nothing was converted last season, and something was converted this season,
        // the demand is increasing.
        if (bdvConvertedLastSeason == 0) {
            if (bdvConvertedThisSeason > 0) {
                return ConvertDemand.INCREASING;
            } else {
                // if nothing was converted in this season and last season, demand is decreasing.
                return ConvertDemand.DECREASING;
            }
        } else {
            // calculate the convert demand in order to determine if the demand is increasing or decreasing.
            uint256 convertDemand = (bdvConvertedThisSeason * C.PRECISION_6) /
                bdvConvertedLastSeason;
            if (convertDemand > CONVERT_DEMAND_UPPER_BOUND) {
                return ConvertDemand.INCREASING;
            } else if (convertDemand < CONVERT_DEMAND_LOWER_BOUND) {
                return ConvertDemand.DECREASING;
            } else {
                return ConvertDemand.STEADY;
            }
        }
    }

    /// GAUGE BLOCKS ///

    /**
     * @notice linear is a implementation that adds or
     * subtracts an absolute value, as a function of
     * the current value, the amount, and the max and min values.
     */
    function linear(
        int256 currentValue,
        bool increase,
        uint256 amount,
        int256 minValue,
        int256 maxValue
    ) internal pure returns (int256) {
        if (increase) {
            if (maxValue - currentValue < int256(amount)) {
                currentValue = maxValue;
            } else {
                currentValue += int256(amount);
            }
        } else {
            if (currentValue - minValue < int256(amount)) {
                currentValue = minValue;
            } else {
                currentValue -= int256(amount);
            }
        }

        return currentValue;
    }

    /**
     * @notice linear256 is uint256 version of linear.
     */
    function linear256(
        uint256 currentValue,
        bool increase,
        uint256 amount,
        uint256 minValue,
        uint256 maxValue
    ) internal pure returns (uint256) {
        return
            uint256(
                linear(int256(currentValue), increase, amount, int256(minValue), int256(maxValue))
            );
    }

    /**
     * @notice linearInterpolation is a function that interpolates a value between two points.
     * clamps x to the x1 and x2.
     * @dev https://www.cuemath.com/linear-interpolation-formula/
     */
    function linearInterpolation(
        uint256 x,
        bool proportional,
        uint256 x1,
        uint256 x2,
        uint256 y1,
        uint256 y2
    ) internal pure returns (uint256) {
        // verify that x1 is less than x2.
        // verify that y1 is less than y2.
        if (x1 > x2 || y1 > y2 || x1 == x2) {
            revert("invalid values");
        }

        // if the y values are the same, return y1.
        if (y1 == y2) {
            return y1;
        }

        // if the current value is greater than the max value, return y2 or y1, depending on proportional.
        if (x > x2) {
            if (proportional) {
                return y2;
            } else {
                return y1;
            }
        } else if (x < x1) {
            if (proportional) {
                return y1;
            } else {
                return y2;
            }
        }

        // scale the value to the range [y1, y2]
        uint256 dy = ((x - x1) * (y2 - y1)) / (x2 - x1);

        // if proportional, y should increase with an increase in x.
        // (i.e y = y1 + ((x - x1) * (y2 - y1)) / (x2 - x1))
        if (proportional) {
            return y1 + dy;
        } else {
            // if inversely proportional, y should decrease with an increase in x.
            // (i.e y = y2 - ((x - x1) * (y2 - y1)) / (x2 - x1))
            return y2 - dy;
        }
    }
}

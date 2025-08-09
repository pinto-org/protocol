// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Gauge, GaugeId} from "../beanstalk/storage/System.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";

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
        Gauge memory g = s.sys.gaugeData.gauges[gaugeId];
        (
            s.sys.gaugeData.gauges[gaugeId].value,
            s.sys.gaugeData.gauges[gaugeId].data
        ) = getGaugeResult(g, systemData);

        // emit change in gauge value and data
        emit Engaged(gaugeId, s.sys.gaugeData.gauges[gaugeId].value);
        emit EngagedData(gaugeId, s.sys.gaugeData.gauges[gaugeId].data);
    }

    /**
     * @notice Calls a Gauge.
     * @dev Returns the original value of the Gauge if the call fails.
     */
    function getGaugeResult(
        Gauge memory g,
        bytes memory systemData
    ) internal view returns (bytes memory, bytes memory) {
        // if the Gauge does not have a target, assume the target is address(this)
        if (g.target == address(0)) {
            g.target = address(this);
        }

        // if the Gauge does not have a selector, return original value
        if (g.selector == bytes4(0)) {
            return (g.value, g.data);
        }

        (bool success, bytes memory returnData) = g.target.staticcall(
            abi.encodeWithSelector(g.selector, g.value, systemData, g.data)
        );
        if (!success) {
            return (g.value, g.data); // In case of failure, return value unadjusted
        }

        return abi.decode(returnData, (bytes, bytes));
    }

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
        if (x1 > x2 || y1 > y2 || x1 == x2 || y1 == y2) {
            revert("invalid values");
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

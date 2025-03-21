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
    // Gauge events

    /**
     * @notice Emitted when a Gauge is engaged (i.e. its value is updated).
     * @param gaugeId The id of the Gauge that was engaged.
     * @param value The value of the Gauge after it was engaged.
     */
    event Engaged(GaugeId gaugeId, bytes value);

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

        // emit change in gauge value
        emit Engaged(gaugeId, s.sys.gaugeData.gauges[gaugeId].value);
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

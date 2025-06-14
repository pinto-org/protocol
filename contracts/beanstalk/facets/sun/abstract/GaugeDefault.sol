/*
 * SPDX-License-Identifier: MIT
 */

pragma solidity ^0.8.20;

/**
 * @title GaugeDefault
 * @notice Calculates the gaugePoints for whitelisted Silo LP tokens
 * in a token-agnostic manner.
 */
abstract contract GaugeDefault {
    uint256 private constant EXTREME_FAR_POINT = 5e18;
    uint256 private constant RELATIVE_FAR_POINT = 3e18;
    uint256 private constant RELATIVE_CLOSE_POINT = 1e18;
    // uint256 private constant EXCESSIVELY_CLOSE_POINT = 0e18;

    uint256 private constant MAX_GAUGE_POINTS = 1000e18;
    uint256 private constant MAX_PERCENT = 100e6;

    uint256 private constant EXCESSIVELY_FAR = 66.666666e6;
    uint256 private constant RELATIVELY_FAR = 33.333333e6;
    uint256 private constant RELATIVELY_CLOSE = 10e6;
    uint256 private constant PRECISION = 100e6;

    /**
     * @notice defaultGaugePoints
     * is the default function to calculate the gauge points
     * of an LP asset.
     *
     * @dev If % of deposited BDV is within range of optimal,
     * keep gauge points the same (RELATIVELY_CLOSE).
     *
     * Cap gaugePoints to MAX_GAUGE_POINTS to avoid runaway gaugePoints.
     */
    function defaultGaugePoints(
        uint256 currentGaugePoints,
        uint256 optimalPercentDepositedBdv,
        uint256 percentOfDepositedBdv,
        bytes memory
    ) public pure returns (uint256 newGaugePoints) {
        if (percentOfDepositedBdv > getRelativelyCloseAbove(optimalPercentDepositedBdv)) {
            // Cap gauge points to MAX_PERCENT if it exceeds.
            if (percentOfDepositedBdv > MAX_PERCENT) {
                percentOfDepositedBdv = MAX_PERCENT;
            }
            uint256 deltaPoints = getDeltaPoints(
                optimalPercentDepositedBdv,
                percentOfDepositedBdv,
                true
            );

            // gauge points cannot go below 0.
            if (deltaPoints < currentGaugePoints) {
                return currentGaugePoints - deltaPoints;
            } else {
                // Cap gaugePoints to 0 if it exceeds.
                return 0;
            }
        } else if (percentOfDepositedBdv < getRelativelyCloseBelow(optimalPercentDepositedBdv)) {
            uint256 deltaPoints = getDeltaPoints(
                optimalPercentDepositedBdv,
                percentOfDepositedBdv,
                false
            );

            // gauge points cannot go above MAX_GAUGE_POINTS.
            if (deltaPoints + currentGaugePoints < MAX_GAUGE_POINTS) {
                return currentGaugePoints + deltaPoints;
            } else {
                // Cap gaugePoints to MAX_GAUGE_POINTS if it exceeds.
                return MAX_GAUGE_POINTS;
            }
        } else {
            // If % of deposited BDV is 10% within range of optimal,
            // keep gauge points the same.
            return currentGaugePoints;
        }
    }

    /**
     * @notice returns the amount of points to increase or decrease.
     * @dev the points change depending on the distance the % of deposited BDV
     * is from the optimal % of deposited BDV.
     */
    function getDeltaPoints(
        uint256 optimalPercentBdv,
        uint256 percentBdv,
        bool isAboveOptimal
    ) private pure returns (uint256) {
        uint256 exsFar;
        uint256 relFar;
        if (isAboveOptimal) {
            exsFar = getExtremelyFarAbove(optimalPercentBdv);
            relFar = getRelativelyFarAbove(optimalPercentBdv);

            if (percentBdv > exsFar) {
                return EXTREME_FAR_POINT;
            } else if (percentBdv > relFar) {
                return RELATIVE_FAR_POINT;
            } else {
                return RELATIVE_CLOSE_POINT;
            }
        } else {
            exsFar = getExtremelyFarBelow(optimalPercentBdv);
            relFar = getRelativelyFarBelow(optimalPercentBdv);

            if (percentBdv < exsFar) {
                return EXTREME_FAR_POINT;
            } else if (percentBdv < relFar) {
                return RELATIVE_FAR_POINT;
            } else {
                return RELATIVE_CLOSE_POINT;
            }
        }
    }

    function getExtremelyFarAbove(uint256 optimalPercentBdv) public pure returns (uint256) {
        return
            (((MAX_PERCENT - optimalPercentBdv) * EXCESSIVELY_FAR) / PRECISION) + optimalPercentBdv;
    }

    function getRelativelyFarAbove(uint256 optimalPercentBdv) public pure returns (uint256) {
        return
            (((MAX_PERCENT - optimalPercentBdv) * RELATIVELY_FAR) / PRECISION) + optimalPercentBdv;
    }

    function getRelativelyCloseAbove(uint256 optimalPercentBdv) public pure returns (uint256) {
        return
            (((MAX_PERCENT - optimalPercentBdv) * RELATIVELY_CLOSE) / PRECISION) +
            optimalPercentBdv;
    }

    function getExtremelyFarBelow(uint256 optimalPercentBdv) public pure returns (uint256) {
        return (optimalPercentBdv * (PRECISION - EXCESSIVELY_FAR)) / PRECISION;
    }

    function getRelativelyFarBelow(uint256 optimalPercentBdv) public pure returns (uint256) {
        return (optimalPercentBdv * (PRECISION - RELATIVELY_FAR)) / PRECISION;
    }

    function getRelativelyCloseBelow(uint256 optimalPercentBdv) public pure returns (uint256) {
        return (optimalPercentBdv * (PRECISION - RELATIVELY_CLOSE)) / PRECISION;
    }
}

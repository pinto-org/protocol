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

    uint256 private constant UPPER_THRESHOLD = 10050;
    uint256 private constant LOWER_THRESHOLD = 9950;
    uint256 private constant THRESHOLD_PRECISION = 10000;
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
     */
    function defaultGaugePoints(
        uint256 currentGaugePoints,
        uint256 optimalPercentDepositedBdv,
        uint256 percentOfDepositedBdv,
        bytes memory
    ) public pure returns (uint256 newGaugePoints) {
        // Get the relatively close bound above optimal
        uint256 upperBound = getRelativelyCloseBound(optimalPercentDepositedBdv, true);

        if (percentOfDepositedBdv > upperBound) {
            // Cap gauge points to MAX_PERCENT if it exceeds
            if (percentOfDepositedBdv > MAX_PERCENT) {
                percentOfDepositedBdv = MAX_PERCENT;
            }
            uint256 deltaPoints = getDeltaPoints(
                optimalPercentDepositedBdv,
                percentOfDepositedBdv,
                true
            );

            // gauge points cannot go below 0
            if (deltaPoints < currentGaugePoints) {
                return currentGaugePoints - deltaPoints;
            } else {
                // Cap gaugePoints to 0 if it exceeds
                return 0;
            }
        } else if (
            percentOfDepositedBdv < getRelativelyCloseBound(optimalPercentDepositedBdv, false)
        ) {
            uint256 deltaPoints = getDeltaPoints(
                optimalPercentDepositedBdv,
                percentOfDepositedBdv,
                false
            );
            return currentGaugePoints + deltaPoints;
        } else {
            // If % of deposited BDV is within range of optimal,
            // keep gauge points the same
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
        if (isAboveOptimal) {
            if (percentBdv > getExtremelyFarBound(optimalPercentBdv, true)) {
                return EXTREME_FAR_POINT;
            } else if (percentBdv > getRelativelyFarBound(optimalPercentBdv, true)) {
                return RELATIVE_FAR_POINT;
            } else {
                return RELATIVE_CLOSE_POINT;
            }
        } else {
            if (percentBdv < getExtremelyFarBound(optimalPercentBdv, false)) {
                return EXTREME_FAR_POINT;
            } else if (percentBdv < getRelativelyFarBound(optimalPercentBdv, false)) {
                return RELATIVE_FAR_POINT;
            } else {
                return RELATIVE_CLOSE_POINT;
            }
        }
    }

    /**
     * @notice Calculates the offset from the optimal percentage based on a multiplier
     * @param optimalPercentBdv The optimal percentage of BDV (1e6 = 1%)
     * @param multiplier The multiplier to determine the offset
     * @return The calculated offset value based on the distance to 100% if above 50%, or based on current value if below 50%
     */
    function _getOffset(
        uint256 optimalPercentBdv,
        uint256 multiplier
    ) private pure returns (uint256) {
        // cap multiplier at 100e6, in case of error.
        if (multiplier > 100e6) {
            multiplier = 100e6;
        }

        if (optimalPercentBdv > 50e6) {
            // Base offset on remaining distance to 100%
            return ((MAX_PERCENT - optimalPercentBdv) * multiplier) / PRECISION;
        } else {
            // Base offset on current percentage
            return (optimalPercentBdv * multiplier) / PRECISION;
        }
    }

    /**
     * @notice Calculates a boundary value above or below the optimal percentage
     * @param optimalPercentBdv The optimal percentage of BDV (1e6 = 1%)
     * @param offset The offset to add/subtract from optimal
     * @param above If true, calculates upper bound; if false, calculates lower bound
     * @return The boundary value
     */
    function _getBound(
        uint256 optimalPercentBdv,
        uint256 offset,
        bool above
    ) private pure returns (uint256) {
        return above ? optimalPercentBdv + offset : optimalPercentBdv - offset;
    }

    /**
     * @notice Gets the extremely far boundary from the optimal percentage
     * @param optimalPercentBdv The optimal percentage of BDV (1e6 = 1%)
     * @param above If true, returns upper bound; if false, returns lower bound
     * @return The extremely far boundary value
     */
    function getExtremelyFarBound(
        uint256 optimalPercentBdv,
        bool above
    ) public pure returns (uint256) {
        return _getBound(optimalPercentBdv, _getOffset(optimalPercentBdv, EXCESSIVELY_FAR), above);
    }

    /**
     * @notice Gets the relatively far boundary from the optimal percentage
     * @param optimalPercentBdv The optimal percentage of BDV (1e6 = 1%)
     * @param above If true, returns upper bound; if false, returns lower bound
     * @return The relatively far boundary value
     */
    function getRelativelyFarBound(
        uint256 optimalPercentBdv,
        bool above
    ) public pure returns (uint256) {
        return _getBound(optimalPercentBdv, _getOffset(optimalPercentBdv, RELATIVELY_FAR), above);
    }

    /**
     * @notice Gets the relatively close boundary from the optimal percentage
     * @param optimalPercentBdv The optimal percentage of BDV (1e6 = 1%)
     * @param above If true, returns upper bound; if false, returns lower bound
     * @return The relatively close boundary value
     */
    function getRelativelyCloseBound(
        uint256 optimalPercentBdv,
        bool above
    ) public pure returns (uint256) {
        return _getBound(optimalPercentBdv, _getOffset(optimalPercentBdv, RELATIVELY_CLOSE), above);
    }
}

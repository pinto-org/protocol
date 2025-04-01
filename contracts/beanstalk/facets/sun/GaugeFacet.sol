/*
 * SPDX-License-Identifier: MIT
 */

pragma solidity ^0.8.20;

import {GaugeDefault} from "./abstract/GaugeDefault.sol";
import {Decimal} from "contracts/libraries/Decimal.sol";
import {LibEvaluate} from "contracts/libraries/LibEvaluate.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {C} from "contracts/C.sol";
import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";
import {Gauge, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {PRBMathUD60x18} from "@prb/math/contracts/PRBMathUD60x18.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {LibTokenSilo} from "contracts/libraries/Silo/LibTokenSilo.sol";
import {console} from "forge-std/console.sol";

/**
 * @title GaugeFacet
 * @notice Calculates the gaugePoints for whitelisted Silo LP tokens.
 */
interface IGaugeFacet {
    function defaultGaugePoints(
        uint256 currentGaugePoints,
        uint256 optimalPercentDepositedBdv,
        uint256 percentOfDepositedBdv,
        bytes memory
    ) external pure returns (uint256 newGaugePoints);

    function cultivationFactor(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) external view returns (bytes memory result);

    function convertDownPenaltyGauge(
        bytes memory value,
        bytes memory,
        bytes memory gaugeData
    ) external view returns (bytes memory, bytes memory);

    function convertUpBonusGauge(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) external view returns (bytes memory, bytes memory);
}

/**
 * @notice GaugeFacet is a facet that contains the logic for all gauges in Beanstalk.
 * as well as adding, replacing, and removing Gauges.
 */
contract GaugeFacet is GaugeDefault, ReentrancyGuard {
    uint256 internal constant PRICE_PRECISION = 1e6;
    uint256 internal constant DELTA_C_PRECISION = 1e18;
    uint256 internal constant DELTA_B_PRECISION = 1e6;
    uint256 internal constant STALK_PRECISION = 1e16;
    uint256 internal constant CONVERT_BONUS_RATIO_PRECISION = 1e18;

    /**
     * @notice cultivationFactor is a gauge implementation that returns the adjusted cultivationFactor based on the podRate and the price of Pinto.
     */
    function cultivationFactor(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) external view returns (bytes memory, bytes memory) {
        uint256 currentValue = abi.decode(value, (uint256));
        LibEvaluate.BeanstalkState memory bs = abi.decode(systemData, (LibEvaluate.BeanstalkState));

        // if the price is 0, return the current value.
        if (bs.largestLiquidWellTwapBeanPrice == 0) {
            return (value, gaugeData);
        }

        // clamp the price to 1e6, to prevent overflows.
        if (bs.largestLiquidWellTwapBeanPrice > PRICE_PRECISION) {
            bs.largestLiquidWellTwapBeanPrice = PRICE_PRECISION;
        }

        (
            uint256 minDeltaCultivationFactor,
            uint256 maxDeltaCultivationFactor,
            uint256 minCultivationFactor,
            uint256 maxCultivationFactor
        ) = abi.decode(gaugeData, (uint256, uint256, uint256, uint256));

        // determine increase or decrease based on demand for soil.
        bool soilSoldOut = s.sys.weather.lastSowTime < type(uint32).max;
        // determine amount change as a function of podRate.
        uint256 amountChange = LibGaugeHelpers.linearInterpolation(
            bs.podRate.value,
            false,
            s.sys.evaluationParameters.podRateLowerBound,
            s.sys.evaluationParameters.podRateUpperBound,
            minDeltaCultivationFactor,
            maxDeltaCultivationFactor
        );
        // update the change based on price.
        amountChange = (amountChange * bs.largestLiquidWellTwapBeanPrice) / PRICE_PRECISION;

        // if soil did not sell out, inverse the amountChange.
        if (!soilSoldOut) {
            amountChange = 1e12 / amountChange;
        }

        // return the new cultivationFactor.
        // return unchanged gaugeData.
        return (
            abi.encode(
                LibGaugeHelpers.linear(
                    int256(currentValue),
                    soilSoldOut,
                    amountChange,
                    int256(minCultivationFactor),
                    int256(maxCultivationFactor)
                )
            ),
            gaugeData
        );
    }

    /**
     * @notice Tracks the down convert penalty ratio and the rolling count of seasons above peg.
     * Penalty ratio is the % of grown stalk lost on a down convert (1e18 = 100% penalty).
     * value is encoded as (uint256, uint256):
     *     penaltyRatio - the penalty ratio.
     *     rollingSeasonsAbovePeg - the rolling count of seasons above peg.
     * gaugeData encoded as (uint256, uint256):
     *     rollingSeasonsAbovePegRate - amount to change the the rolling count by each season.
     *     rollingSeasonsAbovePegCap - upper limit of rolling count.
     * @dev returned penalty ratio has 18 decimal precision.
     */
    function convertDownPenaltyGauge(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) external view returns (bytes memory, bytes memory) {
        LibEvaluate.BeanstalkState memory bs = abi.decode(systemData, (LibEvaluate.BeanstalkState));
        (uint256 rollingSeasonsAbovePegRate, uint256 rollingSeasonsAbovePegCap) = abi.decode(
            gaugeData,
            (uint256, uint256)
        );

        (uint256 penaltyRatio, uint256 rollingSeasonsAbovePeg) = abi.decode(
            value,
            (uint256, uint256)
        );
        rollingSeasonsAbovePeg = uint256(
            LibGaugeHelpers.linear(
                int256(rollingSeasonsAbovePeg),
                bs.twaDeltaB > 0 ? true : false,
                rollingSeasonsAbovePegRate,
                0,
                int256(rollingSeasonsAbovePegCap)
            )
        );

        // Do not update penalty ratio if l2sr failed to compute.
        if (bs.lpToSupplyRatio.value == 0) {
            return (abi.encode(penaltyRatio, rollingSeasonsAbovePeg), gaugeData);
        }

        // Scale L2SR by the optimal L2SR.
        uint256 l2srRatio = (1e18 * bs.lpToSupplyRatio.value) /
            s.sys.evaluationParameters.lpToSupplyRatioOptimal;

        uint256 timeRatio = (1e18 * PRBMathUD60x18.log2(rollingSeasonsAbovePeg * 1e18 + 1e18)) /
            PRBMathUD60x18.log2(rollingSeasonsAbovePegCap * 1e18 + 1e18);

        penaltyRatio = Math.min(1e18, (l2srRatio * (1e18 - timeRatio)) / 1e18);
        return (abi.encode(penaltyRatio, rollingSeasonsAbovePeg), gaugeData);
    }

    /**
     * @notice Calculates the maximum stalk the protocol is willing to issue
     * for upward converts every season as a percentage of the total stalk supply.
     * ----------------------------------------------------------------
     * @notice Adjusts the scalar of the maximum stalk the protocol is willing to issue
     * in a given season as a bonus of converting up towards peg (C parameter).
     * - C ranges from 0 to 1e18, where 0 is no bonus and 1e18 is full bonus (0-100%).
     * - C Resets to 0 upon the system crossing target. Stays at 0 above target.
     * - C does not increase until after 12 seasons after a below target cross.
     * ---------------------------------------------------------------
     * C decreases by X when the system converts at least Z pdv in a season.
     * X = (bs.previousSeasonBeanPrice * deltaC) / bs.lpToSupplyRatio.value
     * ---------------------------------------------------------------
     * C increases by Y when it converts less than Z pdv in a season.
     * Y = (deltaC * 0.01e18) / (bs.previousSeasonBeanPrice * deltaC)
     * ---------------------------------------------------------------
     * @notice Calculates the stalkPerBdv bonus for the current season.
     * The stalkPerBdv is the difference between the current stem tip and
     * the stemTip at a target cross, choosing the smallest amongst all whitelisted lp tokens.
     * ----------------------------------------------------------------
     * @notice From the values above, it calculates the amount of bonus stalk available for converts
     * in the current season. From that, it calculates the convert bonus pdv capacity as
     * stalkToIssue / stalkPerBdv.
     * ----------------------------------------------------------------
     * @return value
     *  The gauge value is encoded as (uint256, uint256, uint256):
     *     - seasonsBelowPeg - the rolling count of seasons below peg.
     *     - convertBonusRatio - the convert bonus ratio.
     *     - bonusStalkPerBdv - the bonus stalk per bdv to issue for converts.
     * @return gaugeData
     *  The gaugeData are ecoded as (uint256, uint256, uint256, uint256, uint256):
     *     - deltaC - the delta used in adjusting convertBonusRatio.
     *     - minDeltaC - the minimum delta for decreasing convertBonusRatio.
     *     - maxDeltaC - the maximum delta for increasing convertBonusRatio.
     *     - previousSeasonBdvConverted - how much pdv was converted in the previous season and received a bonus.
     *     (resets at the gauge level and gets updated by the convert system)
     *     previousSeasonBdvCapacity - previous season's initial convertBonusBdvCapacity.
     */
    function convertUpBonusGauge(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) external view returns (bytes memory, bytes memory) {
        LibEvaluate.BeanstalkState memory bs = abi.decode(systemData, (LibEvaluate.BeanstalkState));

        // Decode current convert bonus ratio value and rolling count of seasons below peg
        (uint256 seasonsBelowPeg, uint256 convertBonusRatio, uint256 bonusStalkPerBdv) = abi.decode(
            value,
            (uint256, uint256, uint256)
        );

        // Decode gauge data
        (
            uint256 deltaC, // delta used in adjusting convertBonusRatio
            uint256 minConvertBonusRatio, // minimum value of the conversion factor
            uint256 maxConvertBonusRatio, // maximum value of the conversion factor
            uint256 previousSeasonBdvCapacityLeft, // how much bonus pdv capacity was left in the previous season
            uint256 previousSeasonBdvCapacity // previous season's initial convertBonusBdvCapacity
        ) = abi.decode(gaugeData, (uint256, uint256, uint256, uint256, uint256));

        // If twaDeltaB > 0 (above peg), reset values to 0
        if (bs.twaDeltaB > 0) {
            console.log("twaDeltaB > 0, reset convertBonusRatio and seasonsBelowPeg to 0");
            return (abi.encode(0, 0, 0), gaugeData);
        }

        // If seasonsBelowPeg < 12, convertBonusRatio is 0 but seasonsBelowPeg increases
        if (bs.twaDeltaB <= 0 && seasonsBelowPeg < 12) {
            console.log("twaDeltaB <= 0 and seasonsBelowPeg < 12, increase seasonsBelowPeg by 1");
            return (abi.encode(seasonsBelowPeg + 1, 0, 0), gaugeData);
        }

        // twaDeltaB <= 0 (below peg) && seasonsBelowPeg >= 12, ready to modify convertBonusRatio
        // and set convert bonus pdv capacity
        console.log("twaDeltaB <= 0 and seasonsBelowPeg >= 12, ready to modify convertBonusRatio");

        // 1. set vmax (the maximum stalk Pinto is willing to issue for converts every season.)
        // (0,01% of total stalk supply)
        // todo: change to a % of grown stalk supply after we figure out how to get that
        // note: Stalk has 16 decimal precision.
        // 1e16 * 1e18 / 1e18 = 1e16
        uint256 maxStalkToIssue = (s.sys.silo.stalk *
            s.sys.extEvaluationParameters.convertBonusStalkScalar) / C.PRECISION;

        // PRECISIONS:
        // l2sr precision is 1e18
        // price precision is 1e6
        // deltaC precision is 1e18
        // stalk precision is 1e16
        // convertBonusRatio precision is 1e18

        // 2. determine C, the Vmax scalar for the season
        // twaDeltaB is negative, so we need to convert it to a positive value uint25

        // if the amount of pdv converted in the previous season is less than Z, we should increase the convertBonusRatio
        bool shouldIncrease = (previousSeasonBdvCapacity - previousSeasonBdvCapacityLeft) <
            getConvertBonusBdvUsedThreshold(uint256(-bs.twaDeltaB), previousSeasonBdvCapacity);

        uint256 amountChange;
        if (shouldIncrease) {
            console.log("previousSeasonBdvConverted < Z Pdv, increase convertBonusRatio");
            // Less than Z Pdv was converted, so we increase the percentage of stalk to issue as a bonus
            // convertBonusRatio = convertBonusRatio + (Δc × 0.01/(Δc×Pt-1)))
            amountChange = (deltaC * 0.01e18) / (deltaC * bs.largestLiquidWellTwapBeanPrice);
        } else {
            console.log("previousSeasonBdvConverted >= Z Pdv, decrease convertBonusRatio");
            // if at least Z Pdv was converted case, we decrease the percentage of stalk to issue as a bonus
            // convertBonusRatio = convertBonusRatio - (Δc × Pt-1/L2SR))
            amountChange =
                (deltaC * (bs.largestLiquidWellTwapBeanPrice * C.PRECISION)) /
                bs.lpToSupplyRatio.value /
                1e6;
        }

        // update convertBonusRatio via the linear function
        convertBonusRatio = uint256(
            LibGaugeHelpers.linear(
                int256(convertBonusRatio),
                shouldIncrease,
                amountChange,
                int256(minConvertBonusRatio),
                int256(maxConvertBonusRatio)
            )
        );

        // we now know Vmax and C --> we can get V (the amount of stalk the protocol will issue for converts)
        // V = C * Vmax
        // 1e18 * 1e16 / 1e18 = 1e16
        uint256 stalkToIssue = (convertBonusRatio * maxStalkToIssue) / C.PRECISION;

        // we now know V, so we can set the convert bonus pdv capacity as V / stalkPerBdv
        // where stalkPerBdv is determined by taking the difference between the current stem tip
        // and the stemTip at a target cross, and choosing the smallest amongst all whitelisted lp tokens.

        // 3. set the convert bonus pdv capacity as V / stalkPerBdv
        uint256 convertBonusBdvCapacity = (stalkToIssue * C.PRECISION) /
            getCurrentBonusStalkPerBdv();

        // value, gaugeData
        return (
            abi.encode(seasonsBelowPeg + 1, convertBonusRatio, getCurrentBonusStalkPerBdv()),
            abi.encode(
                deltaC, // same constant as before
                minConvertBonusRatio, // same constant as before
                maxConvertBonusRatio, // same constant as before
                0, // previousSeasonBdvConverted resets to 0 at the start of the new season
                convertBonusBdvCapacity
            )
        );
    }

    /**
     * @notice Gets the threshold amount of PDV (Z) that determines whether C increases or decreases
     * @dev If the amount of PDV converted in the previous season is:
     *      - Greater than Z: C decreases by X
     *      - Less than Z: C increases by Y
     * @dev Z is calculated as:
     *      - min(max(50 PDV, 1% of deltaP), previous season's maximum PDV eligible for bonus)
     */
    function getConvertBonusBdvUsedThreshold(
        uint256 deltaB,
        uint256 previousSeasonConvertBonusBdvCapacity
    ) internal view returns (uint256) {
        return
            Math.min(
                Math.max(50e6, (deltaB * 0.01e6) / DELTA_B_PRECISION),
                previousSeasonConvertBonusBdvCapacity
            );
    }

    // todo: move this elsewhere, figure out logic
    // the stalkPerPDV is determined by taking the difference between the current stem tip and the stemTip at a target cross,
    // and choosing the smallest amongst all whitelisted lp tokens.
    function getCurrentBonusStalkPerBdv() internal view returns (uint256 stalkPerBdv) {
        // get current stem tips for all whitelisted lp tokens and get the min
        // (address token, int96 minStemTip) = getMinStemTip();
        // // get stem tip of token at target cross
        // int96 currentStemTip = s.sys.belowPegCrossStems[token];
        // // calculate the difference
        // stalkPerBdv = uint256(currentStemTip - minStemTip);
        return 1e18;
    }

    // todo: move this elsewhere, figure out logic
    function getMinStemTip() internal view returns (address token, int96 minStemTip) {
        // get stem tips for all whitelisted lp tokens and get the min
        address[] memory lpTokens = LibWhitelistedTokens.getWhitelistedLpTokens();
        int96 minStemTip = type(int96).min;
        for (uint256 i = 0; i < lpTokens.length; i++) {
            int96 stemTip = LibTokenSilo.stemTipForToken(lpTokens[i]);
            if (stemTip < minStemTip) {
                minStemTip = stemTip;
                token = lpTokens[i];
            }
        }
        return (token, minStemTip);
    }

    /// GAUGE ADD/REMOVE/UPDATE ///

    // function addGauge(GaugeId gaugeId, Gauge memory gauge) external {
    //     LibDiamond.enforceIsContractOwner();
    //     LibGaugeHelpers.addGauge(gaugeId, gauge);
    // }

    // function removeGauge(GaugeId gaugeId) external {
    //     LibDiamond.enforceIsContractOwner();
    //     LibGaugeHelpers.removeGauge(gaugeId);
    // }

    // function updateGauge(GaugeId gaugeId, Gauge memory gauge) external {
    //     LibDiamond.enforceIsContractOwner();
    //     LibGaugeHelpers.updateGauge(gaugeId, gauge);
    // }

    function getGauge(GaugeId gaugeId) external view returns (Gauge memory) {
        return s.sys.gaugeData.gauges[gaugeId];
    }

    function getGaugeValue(GaugeId gaugeId) external view returns (bytes memory) {
        return s.sys.gaugeData.gauges[gaugeId].value;
    }

    function getGaugeData(GaugeId gaugeId) external view returns (bytes memory) {
        return s.sys.gaugeData.gauges[gaugeId].data;
    }

    // /**
    //  * @notice returns the result of calling a gauge.
    //  */
    // function getGaugeResult(
    //     Gauge memory gauge,
    //     bytes memory systemData
    // ) external returns (bytes memory, bytes memory) {
    //     return LibGaugeHelpers.getGaugeResult(gauge, systemData);
    // }

    // /**
    //  * @notice returns the result of calling a gauge by its id.
    //  */
    // function getGaugeIdResult(
    //     GaugeId gaugeId,
    //     bytes memory systemData
    // ) external returns (bytes memory, bytes memory) {
    //     Gauge memory g = s.sys.gaugeData.gauges[gaugeId];
    //     return LibGaugeHelpers.getGaugeResult(g, systemData);
    // }
}

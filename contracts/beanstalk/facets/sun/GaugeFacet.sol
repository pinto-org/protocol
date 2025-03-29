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
}

/**
 * @notice GaugeFacet is a facet that contains the logic for all gauges in Beanstalk.
 * as well as adding, replacing, and removing Gauges.
 */
contract GaugeFacet is GaugeDefault, ReentrancyGuard {
    uint256 internal constant PRICE_PRECISION = 1e6;

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
     * - C ranges from 0 to 1e18, where 0 is no bonus and 1e18 is full bonus.
     * - C Resets to 0 upon the system crossing target. Stays at 0 above target.
     * - C does not increase until after 12 seasons after a below target cross.
     * ---------------------------------------------------------------
     * C decreases by X when the system converts at least Z pdv in a season.
     * X = (bs.previousSeasonBeanPrice * deltaC) / bs.lpToSupplyRatio.value
     * ---------------------------------------------------------------
     * C increases by Y when it converts less than Z pdv in a season.
     * Y = (bs.lpToSupplyRatio.value * 0.01e18) / (bs.previousSeasonBeanPrice * deltaC)
     * ---------------------------------------------------------------
     * @notice Calculates the stalkPerBdv bonus for the current season. 
     * The stalkPerBdv is the difference between the current stem tip and
     * the stemTip at a target cross, choosing the smallest amongst all whitelisted lp tokens.
     * ----------------------------------------------------------------
     * @notice From the values above, it calculates the amount of bonus stalk available for converts
     * in the current season. From that, it calculates the convert bonus pdv capacity as
     * stalkToIssue / stalkPerBdv.
     */
    function convertUpBonusGauge(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) external view returns (bytes memory, bytes memory) {
        LibEvaluate.BeanstalkState memory bs = abi.decode(systemData, (LibEvaluate.BeanstalkState));

        (uint256 deltaC, uint256 minDeltaC, uint256 maxDeltaC) = abi.decode(
            gaugeData,
            (uint256, uint256, uint256)
        );

        // get how much pdv was converted in the previous season
        // todo: add as a storage variable when doing a convert in one season?
        // uint256 previousSeasonPdv = s.sys.season.previousSeasonPdvConverted;
        uint256 previousSeasonPdv = 0;

        // Decode current convert bonus ratio value and rolling count of seasons below peg
        (uint256 convertBonusRatio, uint256 seasonsBelowPeg) = abi.decode(
            value,
            (uint256, uint256)
        );

        // If twaDeltaB > 0 (above peg), reset convertBonusRatio and seasonsBelowPeg to 0
        if (bs.twaDeltaB > 0) {
            return (abi.encode(0, 0), gaugeData);
        }

        // If seasonsBelowPeg < 12, convertBonusRatio is 0 but seasonsBelowPeg increases
        if (bs.twaDeltaB <= 0 && seasonsBelowPeg < 12) {
            return (abi.encode(0, seasonsBelowPeg + 1), gaugeData);
        }

        // twaDeltaB <= 0 (below peg) && seasonsBelowPeg >= 12, ready to modify convertBonusRatio
        // and set convert bonus pdv capacity

        // 1. set vmax (the maximum stalk Pinto is willing to issue for converts every season.)
        // (0,01% of total stalk supply)
        // todo: change to a % of grown stalk supply after we figure out how to get that
        uint256 vmax = (s.sys.silo.stalk * s.sys.extEvaluationParameters.convertBonusStalkScalar) /
            C.PRECISION;

        // 2. determine C, the Vmax scalar for the season
        // todo : change 0 to a threshold
        // todo : fix decimal precision
        if (previousSeasonPdv > 0) {
            // if Z Pdv was converted case
            // convertBonusRatio = min(1, convertBonusRatio - (Δc × Pt-1/L2SR))
            uint256 reduction = (deltaC * bs.largestLiquidWellTwapBeanPrice) / bs.lpToSupplyRatio.value;
            convertBonusRatio = convertBonusRatio > reduction ? convertBonusRatio - reduction : 0;
            convertBonusRatio = Math.min(convertBonusRatio, minDeltaC);
        } else {
            // Otherwise case
            // convertBonusRatio = max(0, convertBonusRatio + (L2SR × 0.01/(Δc×Pt-1)))
            uint256 increase = (bs.lpToSupplyRatio.value * 0.01e18) /
                (deltaC * bs.largestLiquidWellTwapBeanPrice);
            convertBonusRatio = convertBonusRatio + increase;
            convertBonusRatio = Math.max(convertBonusRatio, maxDeltaC);
        }

        // we now know Vmac and C --> we can get V (the amount of stalk the protocol will issue for converts)
        // V = C * Vmax
        uint256 V = (convertBonusRatio * vmax) / C.PRECISION;

        // we now know V, so we can set the convert bonus pdv capacity as V / stalkPerBdv
        // where stalkPerBdv is determined by taking the difference between the current stem tip
        // and the stemTip at a target cross, and choosing the smallest amongst all whitelisted lp tokens.

        // 3. set the convert bonus pdv capacity as V / stalkPerBdv
        uint256 stalkPerBdv = getCurrentBonusStalkPerBdv();
        uint256 convertBonusBdvCapacity = V / stalkPerBdv;

        return (abi.encode(convertBonusBdvCapacity, stalkPerBdv), gaugeData);
    }

    // todo: move this elsewhere
    // the stalkPerPDV is determined by taking the difference between the current stem tip and the stemTip at a target cross,
    // and choosing the smallest amongst all whitelisted lp tokens.
    function getCurrentBonusStalkPerBdv() internal view returns (uint256 stalkPerBdv) {
        // get current stem tips for all whitelisted lp tokens and get the min
        // (address token, int96 minStemTip) = getMinStemTip();
        // // get stem tip of token at target cross
        // int96 currentStemTip = s.sys.belowPegCrossStems[token];
        // // calculate the difference
        // stalkPerBdv = uint256(currentStemTip - minStemTip);
    }

    function getMinStemTip() internal view returns (address token, int96 minStemTip) {
        // get stem tips for all whitelisted lp tokens and get the min
        // address[] memory lpTokens = LibWhitelistedTokens.getWhitelistedLpTokens();
        // int96 minStemTip = type(int96).min;
        // for (uint256 i = 0; i < lpTokens.length; i++) {
        //     stemTip = LibTokenSilo.stemTipForToken(lpTokens[i]);
        //     if (stemTip < minStemTip) {
        //         minStemTip = stemTip;
        //         token = lpTokens[i];
        //     }
        // }
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

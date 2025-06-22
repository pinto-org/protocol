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
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {LibWellMinting} from "contracts/libraries/Minting/LibWellMinting.sol";
import {LibMinting} from "contracts/libraries/Minting/LibMinting.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";

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

    // Convert Bonus Gauge Constants are defined in LibGaugeHelpers

    // Cultivation Factor Gauge Constants //
    uint256 internal constant SOIL_ALMOST_SOLD_OUT = type(uint32).max - 1;

    /**
     * @notice cultivationFactor is a gauge implementation that is used when issuing soil below peg.
     * The value increases as soil is sold out (and vice versa), with the amount being a function of
     * podRate and price. It ranges between 1% to 100% and uses 6 decimal precision.
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
            uint256 minDeltaCultivationFactor, // min change in cultivation factor
            uint256 maxDeltaCultivationFactor, // max change in cultivation factor
            uint256 minCultivationFactor, // min cultivation factor.
            uint256 maxCultivationFactor, // max cultivation factor.
            uint256 cultivationTemp, // temperature when soil was selling out and demand for soil was not decreasing.
            uint256 prevSeasonTemp // temperature of the previous season.
        ) = abi.decode(gaugeData, (uint256, uint256, uint256, uint256, uint256, uint256));

        // determine if soil was sold out or mostly sold out.
        // the protocol uses the lastSowTime to determine if soil was sold out or mostly sold out. See LibEvaluate.calcDeltaPodDemand.
        bool soilSoldOut = s.sys.weather.lastSowTime < SOIL_ALMOST_SOLD_OUT;
        bool soilMostlySoldOut = s.sys.weather.lastSowTime == SOIL_ALMOST_SOLD_OUT;

        // if soil was mostly sold out or sold out, and demand for soil is NOT decreasing (i.e. increasing or steady),
        //  set cultivationTemp to the previous season temperature.
        if (
            (soilMostlySoldOut || soilSoldOut) &&
            bs.deltaPodDemand.value >= s.sys.evaluationParameters.deltaPodDemandLowerBound
        ) {
            cultivationTemp = prevSeasonTemp;
            gaugeData = abi.encode(
                minDeltaCultivationFactor,
                maxDeltaCultivationFactor,
                minCultivationFactor,
                maxCultivationFactor,
                cultivationTemp,
                prevSeasonTemp
            );
        }

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

        // update the cultivation factor based on
        // 1) the sell state of soil (not selling out, almost selling out, or sold out)
        // 2) the demand for soil (steady/increasing, or decreasing)
        // 3) the previous season temperature (if it was above the cultivation temperature)
        if (soilSoldOut) {
            // increase cultivation factor if soil sold out.
            currentValue = LibGaugeHelpers.linear256(
                currentValue,
                true,
                amountChange,
                minCultivationFactor,
                maxCultivationFactor
            );
        } else if (soilMostlySoldOut) {
            // if soil mostly sold out, return unchanged gauge data and value.
            return (abi.encode(currentValue), gaugeData);
        } else if (
            bs.deltaPodDemand.value < s.sys.evaluationParameters.deltaPodDemandLowerBound &&
            prevSeasonTemp < cultivationTemp
        ) {
            // if soil is not selling out, and previous season temperature < cultivation temperature,
            // return unchanged gauge data and value.
            return (abi.encode(currentValue), gaugeData);
        } else {
            // demand for soil is steady/increasing (but not selling out)
            // or previous season temperature >= cultivation temperature.
            // decrease cultivation factor.
            // the decrease in cultivation factor is the inverse of the increase in cultivation factor.
            // See Whitepaper for formula.
            amountChange = 1e12 / amountChange;
            currentValue = LibGaugeHelpers.linear256(
                currentValue,
                false,
                amountChange,
                minCultivationFactor,
                maxCultivationFactor
            );
        }

        // update the gauge data.
        return (abi.encode(currentValue), gaugeData);
    }

    /**
     * @notice tracks the down convert penalty ratio and the rolling count of seasons above peg.
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

        // Scale L2SR by the optimal L2SR. Cap the current L2SR at the optimal L2SR.
        uint256 l2srRatio = (1e18 *
            Math.min(
                bs.lpToSupplyRatio.value,
                s.sys.evaluationParameters.lpToSupplyRatioLowerBound
            )) / s.sys.evaluationParameters.lpToSupplyRatioLowerBound;

        uint256 timeRatio = (1e18 * PRBMathUD60x18.log2(rollingSeasonsAbovePeg * 1e18 + 1e18)) /
            PRBMathUD60x18.log2(rollingSeasonsAbovePegCap * 1e18 + 1e18);

        penaltyRatio = Math.min(1e18, (l2srRatio * (1e18 - timeRatio)) / 1e18);
        return (abi.encode(penaltyRatio, rollingSeasonsAbovePeg), gaugeData);
    }

    /**
     * @notice Calculates the stalk per bdv the protocol is willing to issue along with the
     * corresponding bdv capacity.
     * ----------------------------------------------------------------
     * @return value
     *  The gauge value is encoded as LibGaugeHelpers.ConvertBonusGaugeValue.
     * @return gaugeData
     *  The gaugeData are encoded as a struct of type LibGaugeHelpers.ConvertBonusGaugeData.
     */
    function convertUpBonusGauge(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) external view returns (bytes memory, bytes memory) {
        LibEvaluate.BeanstalkState memory bs = abi.decode(systemData, (LibEvaluate.BeanstalkState));

        // Decode Gauge Value and Data.
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
            value,
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );
        LibGaugeHelpers.ConvertBonusGaugeData memory gd = abi.decode(
            gaugeData,
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        // initialize convert demand to decreasing.
        LibConvert.ConvertDemand cd = LibConvert.ConvertDemand.DECREASING;

        // if there is a non-zero convert capacity, calculate the demand for a bonus and update the capacity factor.
        if (gv.maxConvertCapacity > 0) {
            // determined if capacity is filled or mostly filled.
            LibGaugeHelpers.ConvertBonusCapacityUtilization cbu = LibGaugeHelpers
                .getConvertBonusCapacityUtilization(
                    gd.bdvConvertedThisSeason,
                    gv.maxConvertCapacity
                );

            cd = LibConvert.calculateConvertDemand(
                gd.bdvConvertedThisSeason,
                gd.bdvConvertedLastSeason
            );

            // if the capacity is filled or mostly filled, and the demand for convert is not decreasing,
            // set the last convert bonus taken to the current bonus stalk per bdv.
            if (
                cbu != LibGaugeHelpers.ConvertBonusCapacityUtilization.NOT_FILLED &&
                cd != LibConvert.ConvertDemand.DECREASING
            ) {
                gd.lastConvertBonusTaken = gv.bonusStalkPerBdv;
            }

            // determine amount change as a function of twaL2SR.
            // amount change has 6 decimal precision.
            uint256 amountChange = LibGaugeHelpers.linearInterpolation(
                bs.lpToSupplyRatio.value,
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
            if (cbu == LibGaugeHelpers.ConvertBonusCapacityUtilization.FILLED) {
                // capacity filled: increase convert capacity factor
                gv.convertCapacityFactor = LibGaugeHelpers.linear256(
                    gv.convertCapacityFactor,
                    true,
                    amountChange,
                    LibGaugeHelpers.MIN_CONVERT_CAPACITY_FACTOR,
                    LibGaugeHelpers.MAX_CONVERT_CAPACITY_FACTOR
                );
            } else if (
                cbu == LibGaugeHelpers.ConvertBonusCapacityUtilization.NOT_FILLED &&
                (cd != LibConvert.ConvertDemand.DECREASING ||
                    gv.bonusStalkPerBdv < gd.lastConvertBonusTaken)
            ) {
                // this if block is executed when:
                // 1) capacity not filled
                // AND either:
                // 2a) demand is not decreasing (steady/increasing), OR
                // 2b) demand is decreasing AND current bonus < last bonus taken
                //
                // decrease convert capacity factor:
                amountChange = 1e12 / amountChange;
                gv.convertCapacityFactor = LibGaugeHelpers.linear256(
                    gv.convertCapacityFactor,
                    false,
                    amountChange,
                    LibGaugeHelpers.MIN_CONVERT_CAPACITY_FACTOR,
                    LibGaugeHelpers.MAX_CONVERT_CAPACITY_FACTOR
                );
            }
            // Note: convertCapacityFactor remains unchanged when:
            // - capacity is mostly filled (optimal utilization), OR
            // - capacity not filled AND demand is decreasing AND current bonus < last bonus taken (poor conditions)
        }

        // update the bonus stalk per bdv.
        gv.bonusStalkPerBdv = LibConvert.updateBonusStalkPerBdv(
            gv.bonusStalkPerBdv,
            cd,
            bs.twaDeltaB
        );

        // reset maxTwaDeltaB if there is no bonus.
        if (gv.bonusStalkPerBdv == 0) {
            gd.maxTwaDeltaB = 0;
        }

        if (bs.twaDeltaB >= 0) {
            // If twaDeltaB is positive, set capacity to 0 (no convert up bonus)
            gv.maxConvertCapacity = 0;
        } else if (gv.bonusStalkPerBdv > 0) {
            // Calculate target seasons based on podRate.
            uint256 targetSeasons = LibGaugeHelpers.linearInterpolation(
                bs.podRate.value,
                false,
                s.sys.evaluationParameters.podRateLowerBound,
                s.sys.evaluationParameters.podRateUpperBound,
                gd.minSeasonTarget,
                gd.maxSeasonTarget
            );

            // Update maxTwaDeltaB if current -twaDeltaB is larger.
            uint256 currentTwaDeltaB = uint256(-bs.twaDeltaB);
            if (currentTwaDeltaB > gd.maxTwaDeltaB) {
                gd.maxTwaDeltaB = currentTwaDeltaB;
            }

            // Calculate convert capacity
            // `twaDeltaB`, `targetSeasons`, and `convertCapacityFactor` have 6 decimal precision.
            // 6 + 6 - 6 = 6 decimal precision.
            gv.maxConvertCapacity = (gd.maxTwaDeltaB * gv.convertCapacityFactor) / targetSeasons;
        }

        // always reset bdv converted tracking for next season
        gd.bdvConvertedLastSeason = gd.bdvConvertedThisSeason;
        gd.bdvConvertedThisSeason = 0;

        return (abi.encode(gv), abi.encode(gd));
    }

    /// GAUGE ADD/REMOVE/UPDATE ///

    function getGauge(GaugeId gaugeId) external view returns (Gauge memory) {
        return s.sys.gaugeData.gauges[gaugeId];
    }

    function getGaugeValue(GaugeId gaugeId) external view returns (bytes memory) {
        return s.sys.gaugeData.gauges[gaugeId].value;
    }

    function getGaugeData(GaugeId gaugeId) external view returns (bytes memory) {
        return s.sys.gaugeData.gauges[gaugeId].data;
    }

    /**
     * @notice returns the result of calling a gauge.
     */
    function getGaugeResult(
        Gauge memory gauge,
        bytes memory systemData
    ) external view returns (bytes memory, bytes memory) {
        return LibGaugeHelpers.getGaugeResult(gauge, systemData);
    }

    /**
     * @notice returns the result of calling a gauge by its id.
     */
    function getGaugeIdResult(
        GaugeId gaugeId,
        bytes memory systemData
    ) external view returns (bytes memory, bytes memory) {
        Gauge memory g = s.sys.gaugeData.gauges[gaugeId];
        return LibGaugeHelpers.getGaugeResult(g, systemData);
    }
}

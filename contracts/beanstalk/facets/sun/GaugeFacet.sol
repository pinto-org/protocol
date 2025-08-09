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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    uint256 internal constant MAX_PENALTY_RATIO = 1e18;

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
     * @notice the convert down penalty gauge adds a penalty when converting down, in certain cases.
     * The penalty can be split into two parts:
     * 1) a mint penalty, which is applied when the system is below value target.
     * 2) a subseqently penalty that decays over the course of N seasons.
     *
     * @dev returned penalty ratio has 18 decimal precision.
     */
    function convertDownPenaltyGauge(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) external view returns (bytes memory, bytes memory) {
        LibEvaluate.BeanstalkState memory bs = abi.decode(systemData, (LibEvaluate.BeanstalkState));

        // decode the value and data.
        LibGaugeHelpers.ConvertDownPenaltyValue memory gv = abi.decode(
            value,
            (LibGaugeHelpers.ConvertDownPenaltyValue)
        );

        LibGaugeHelpers.ConvertDownPenaltyData memory gd = abi.decode(
            gaugeData,
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );

        //////// MINT PENALTY ////////

        // when the system is below value target, the system increments `beanMintedThreshold`.
        // when the system crosses value target, `beansMintedAbovePeg` is incremented by twaDeltaB.
        // a penalty is applied until `beansMintedAbovePeg` > `beanMintedThreshold`, or in other words,
        // the system has minted enough beans above the threshold.
        // Once this condition is achieved, then this specific penalty is removed, and `beanMintedThreshold` is reset to 0.
        // Once the system crosses value target upwards, `beanMintedThreshold` should remain static,
        // until the threshold is hit (i.e, `beansMintedAbovePeg` > `beanMintedThreshold`),
        // even if the system crosses value target downwards.

        // To account for cases where the system crosses above peg,
        // but goes back below peg without hitting the mint threshold,
        // AND the system experiences a sustained period of below peg,
        // a "running threshold" is used to track the highest threshold
        // upon the running threshold exceeding `beanMintedThreshold`,
        // `beanMintedThreshold` is set to the running threshold, and
        // the threshold is `unset`.

        if (bs.twaDeltaB > 0 && gd.beanMintedThreshold > 0) {
            // reset the running threshold.
            gd.runningThreshold = 0;
            if (gd.thresholdSet == false) {
                // if the threshold was not set, set it to true. Threshold is now "locked" until the threshold is hit
                // (unless the system is below value target for an extended period of time).
                gd.thresholdSet = true;
            }

            // check whether the system should increment the beanMintedThreshold.
            // increment the beans minted above peg by the twaDeltaB.
            gd.beansMintedAbovePeg = gd.beansMintedAbovePeg + uint256(bs.twaDeltaB);

            if (gd.beansMintedAbovePeg < gd.beanMintedThreshold) {
                // if the beans minted above peg is less than the threshold,
                // set the penalty ratio to maximum.
                gv.penaltyRatio = MAX_PENALTY_RATIO;
                return (abi.encode(gv), abi.encode(gd));
            } else {
                // once the beans minted above peg is greater than the threshold,
                // reset the threshold(s). reset flag and threshold.
                gd.beanMintedThreshold = 0;
                gd.beansMintedAbovePeg = 0;
                gd.thresholdSet = false;
                return (abi.encode(gv), abi.encode(gd));
            }
            // at this point, the mint penalty is not active.
        } else if (bs.twaDeltaB < 0) {
            uint256 currentSupply = IERC20(s.sys.bean).totalSupply();
            uint256 additionalBeans = (currentSupply * gd.percentSupplyThresholdRate) / C.PRECISION;

            // when the threshold is not set, increment `beanMintedThreshold` by the additional beans.
            if (gd.thresholdSet == false) {
                gd.beanMintedThreshold = gd.beanMintedThreshold + additionalBeans;
            } else {
                // if the threshold was set, but the system is below value target,
                // increment `runningThreshold`.
                gd.runningThreshold = gd.runningThreshold + additionalBeans;
                // if `runningThreshold` exceeds `beanMintedThreshold`,
                // reset `beanMintedThreshold` to `runningThreshold`.
                if (gd.runningThreshold > gd.beanMintedThreshold) {
                    gd.beanMintedThreshold = gd.runningThreshold;
                    gd.runningThreshold = 0;
                    gd.thresholdSet = false;
                }
            }
        }

        //////// TIME PENALTY ////////

        // increment the rolling count of seasons above peg
        // the rolling seasons above peg is only incremented after the system
        // issues more beans above the threshold.
        gv.rollingSeasonsAbovePeg = uint256(
            LibGaugeHelpers.linear(
                int256(gv.rollingSeasonsAbovePeg),
                bs.twaDeltaB > 0 ? true : false,
                gd.rollingSeasonsAbovePegRate,
                0,
                int256(gd.rollingSeasonsAbovePegCap)
            )
        );

        // Do not update penalty ratio if l2sr failed to compute.
        if (bs.lpToSupplyRatio.value == 0) {
            return (abi.encode(gv), abi.encode(gd));
        }

        // Scale L2SR by the optimal L2SR. Cap the current L2SR at the optimal L2SR.
        uint256 l2srRatio = (1e18 *
            Math.min(
                bs.lpToSupplyRatio.value,
                s.sys.evaluationParameters.lpToSupplyRatioLowerBound
            )) / s.sys.evaluationParameters.lpToSupplyRatioLowerBound;

        uint256 timeRatio = (1e18 * PRBMathUD60x18.log2(gv.rollingSeasonsAbovePeg * 1e18 + 1e18)) /
            PRBMathUD60x18.log2(gd.rollingSeasonsAbovePegCap * 1e18 + 1e18);

        gv.penaltyRatio = Math.min(MAX_PENALTY_RATIO, (l2srRatio * (1e18 - timeRatio)) / 1e18);
        return (abi.encode(gv), abi.encode(gd));
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

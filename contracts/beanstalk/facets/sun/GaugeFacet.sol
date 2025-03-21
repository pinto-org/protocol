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

    function convertDownPenaltyRatioGauge(
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
     * @notice tracks the down convert penalty ratio and the rolling count of seasons above peg.
     * Penalty ratio is the % of grown stalk lost on a down convert (1.0 = 100% penalty).
     * value is encoded as (uint256, uint256):
     *     penaltyRatio - the penalty ratio.
     *     rollingSeasonsAbovePeg - the rolling count of seasons above peg.
     * gaugeData encoded as (uint256, uint256):
     *     rollingSeasonsAbovePegRate - amount to change the the rolling count by each season.
     *     rollingSeasonsAbovePegCap - upper limit of rolling count.
     */
    function convertDownPenaltyRatioGauge(
        bytes memory value,
        bytes memory systemData,
        bytes memory gaugeData
    ) external view returns (bytes memory, bytes memory) {
        LibEvaluate.BeanstalkState memory bs = abi.decode(systemData, (LibEvaluate.BeanstalkState));
        (uint256 rollingSeasonsAbovePegRate, uint256 rollingSeasonsAbovePegCap) = abi.decode(
            gaugeData,
            (uint256, uint256)
        );

        (, uint256 rollingSeasonsAbovePeg) = abi.decode(value, (uint256, uint256));
        rollingSeasonsAbovePeg = uint256(
            LibGaugeHelpers.linear(
                int256(rollingSeasonsAbovePeg),
                bs.twaDeltaB > 0 ? true : false,
                rollingSeasonsAbovePegRate,
                0,
                int256(rollingSeasonsAbovePegCap)
            )
        );

        uint256 timeRatio;
        if (rollingSeasonsAbovePeg == 0) {
            timeRatio = 0;
        } else {
            timeRatio =
                (1e18 * PRBMathUD60x18.log2(rollingSeasonsAbovePeg * 1e18)) /
                PRBMathUD60x18.log2(rollingSeasonsAbovePegCap * 1e18);
        }

        uint256 penaltyRatio = bs.lpToSupplyRatio.value -
            (timeRatio * bs.lpToSupplyRatio.value) /
            1e18;

        return (abi.encode(penaltyRatio, rollingSeasonsAbovePeg), gaugeData);
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

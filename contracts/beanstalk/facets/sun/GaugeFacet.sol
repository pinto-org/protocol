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
    // the threshold at which the convert capacity is considered reached.
    uint256 internal constant CONVERT_CAPACITY_THRESHOLD = 0.95e6;
    uint256 internal constant PRECISION_6 = 1e6;

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
            uint256 minDeltaCultivationFactor,
            uint256 maxDeltaCultivationFactor,
            uint256 minCultivationFactor,
            uint256 maxCultivationFactor,
            uint256 soldOutTemp,
            uint256 prevSeasonTemp
        ) = abi.decode(gaugeData, (uint256, uint256, uint256, uint256, uint256, uint256));

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

        // cultivation factor increases if soil sold out.
        // cultivation factor stays the same if soil did not sell out AND previous season temperature < sold out temperature.
        // cultivation factor decreases if soil did not sell out AND previous season temperature >= sold out temperature.
        if (soilSoldOut || (!soilSoldOut && prevSeasonTemp >= soldOutTemp)) {
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
        } else {
            // return unchanged gauge data and value.
            return (abi.encode(currentValue), abi.encode(gaugeData));
        }
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
            Math.min(bs.lpToSupplyRatio.value, s.sys.evaluationParameters.lpToSupplyRatioOptimal)) /
            s.sys.evaluationParameters.lpToSupplyRatioOptimal;

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

        // cache the totalBdvConvertedBonus, reset the totalBdvConvertedBonus to 0.
        uint256 totalBdvConvertedBonus = gd.totalBdvConvertedBonus;
        gd.totalBdvConvertedBonus = 0;

        // twaDeltaB >= 0 (above value target)
        if (bs.twaDeltaB >= 0) {
            // if the peg was crossed, set factors to min/max, and bonus/capacity to 0 to signal that the bonus is not active.
            if (s.sys.season.pegCrossSeason == s.sys.season.current) {
                gv.convertBonusFactor = gd.maxConvertBonusFactor;
                gv.convertCapacityFactor = gd.minCapacityFactor;
                gv.bonusStalkPerBdv = 0;
                gv.maxConvertCapacity = 0;
            }

            // return the gauge values.
            return (abi.encode(gv), abi.encode(gd));
        }

        // twaDeltaB < 0 (below value target)

        // update the bonus stalk per bdv.
        gv.bonusStalkPerBdv = LibConvert.updateBonusStalkPerBdv(
            gv.bonusStalkPerBdv,
            gv.convertBonusFactor
        );

        // if the peg was crossed, initialize the bonus and capacity.
        if (s.sys.season.pegCrossSeason == s.sys.season.current) {
            gv.convertBonusFactor = gd.maxConvertBonusFactor;
            gv.convertCapacityFactor = gd.minCapacityFactor;
        } else if (gv.bonusStalkPerBdv > 0) {
            // if the bonus is greater than 0, check if the capacity has been reached and update the bonus and capacity.
            // bonus increases if capacity is not reached (and vice versa).
            // capacity decreases if capacity is reached (and vice versa).
            bool capacityReached = totalBdvConvertedBonus >=
                (gv.maxConvertCapacity * CONVERT_CAPACITY_THRESHOLD) / PRECISION_6;

            gv.convertBonusFactor = LibGaugeHelpers.linear256(
                gv.convertBonusFactor,
                !capacityReached,
                gd.deltaC,
                gd.minConvertBonusFactor,
                gd.maxConvertBonusFactor
            );

            gv.convertCapacityFactor = LibGaugeHelpers.linear256(
                gv.convertCapacityFactor,
                capacityReached,
                gd.deltaD,
                gd.minCapacityFactor,
                gd.maxCapacityFactor
            );
        }
        // update the convert capacity.
        gv.maxConvertCapacity = ((uint256(-bs.twaDeltaB) * gv.convertCapacityFactor) / C.PRECISION);

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

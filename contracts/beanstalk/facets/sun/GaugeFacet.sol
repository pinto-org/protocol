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

    // Convert Bonus Gauge Constants are now defined in LibGaugeHelpers

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

        if (bs.twaDeltaB < 0) {
            // check whether the current twaDeltaB is greater than the max twaDeltaB.
            if (uint256(-bs.twaDeltaB) > gd.maxTwaDeltaB) {
                gd.maxTwaDeltaB = uint256(-bs.twaDeltaB);
            }
        }
        // if the bonus is greater than 0, calculate convert capacity

        // update the bonus stalk per bdv.
        gv.bonusStalkPerBdv = LibConvert.updateBonusStalkPerBdv(
            gv.bonusStalkPerBdv,
            gd.bdvConvertedThisSeason,
            gd.bdvConvertedLastSeason
        );

        // update capacity factor based on convert demand, regardless of bonus stalk
        bool capacityFilled;
        bool capacityMostlyFilled;
        if (gv.maxConvertCapacity > 0) {
            capacityFilled =
                gd.bdvConvertedThisSeason >=
                (gv.maxConvertCapacity * LibGaugeHelpers.CONVERT_CAPACITY_FILLED) / C.PRECISION_6;

            capacityMostlyFilled =
                gd.bdvConvertedThisSeason >=
                (gv.maxConvertCapacity * LibGaugeHelpers.CONVERT_CAPACITY_MOSTLY_FILLED) /
                    C.PRECISION_6;
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

        // update the capacity factor based on capacity filling.
        // capacity filled == true, capacity mostly filled == false => increase capacity factor.
        // capacity filled == true, capacity mostly filled == true => increase capacity factor.
        // capacity filled == false, capacity mostly filled == false => decrease capacity factor.
        // capacity filled == false, capacity mostly filled == true => do nothing.
        if (capacityFilled || (!capacityFilled && !capacityMostlyFilled)) {
            if (!capacityFilled) {
                // if convert capacity is decreasing, inverse the amount change.
                // see whitepaper for more details.
                amountChange = 1e12 / amountChange;
            }
            gv.convertCapacityFactor = LibGaugeHelpers.linear256(
                gv.convertCapacityFactor,
                capacityFilled,
                amountChange,
                LibGaugeHelpers.MIN_CONVERT_CAPACITY_FACTOR,
                LibGaugeHelpers.MAX_CONVERT_CAPACITY_FACTOR
            );
        }

        // if the bonus is greater than 0, calculate convert capacity
        if (gv.bonusStalkPerBdv > 0) {
            // calculate the target seasons as a function of podRate.
            // @dev `targetSeasons` has 6 decimal precision.
            uint256 targetSeasons = LibGaugeHelpers.linearInterpolation(
                bs.podRate.value, // scaling podRate.
                false, // inversely proportional to podRate.
                s.sys.evaluationParameters.podRateLowerBound, // min podRate.
                s.sys.evaluationParameters.podRateUpperBound, // max podRate.
                gd.minSeasonTarget, // min target seasons.
                gd.maxSeasonTarget // max target seasons.
            );

            // update the convert capacity
            // @dev `twaDeltaB` has 6 decimal precision.
            // @dev `targetSeasons` has 6 decimal precision.
            // @dev `convertCapacityFactor` has 6 decimal precision.
            // 6 + 6 - 6 = 6 decimal precision.
            gv.maxConvertCapacity = (gd.maxTwaDeltaB * gv.convertCapacityFactor) / targetSeasons;
        } else {
            // if the bonus is 0, reset max convert capacity only.
            gv.maxConvertCapacity = 0;
        }

        // always reset bdv converted tracking for next season
        gd.bdvConvertedLastSeason = gd.bdvConvertedThisSeason;
        gd.bdvConvertedThisSeason = 0;

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

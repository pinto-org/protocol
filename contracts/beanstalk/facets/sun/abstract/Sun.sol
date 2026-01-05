// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Oracle, C} from "./Oracle.sol";
import {Distribution} from "./Distribution.sol";
import {LibRedundantMath128} from "contracts/libraries/Math/LibRedundantMath128.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {Decimal} from "contracts/libraries/Decimal.sol";
import {LibShipping} from "contracts/libraries/LibShipping.sol";
import {LibWellMinting} from "contracts/libraries/Minting/LibWellMinting.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {LibEvaluate} from "contracts/libraries/LibEvaluate.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";
import {LibDibbler} from "contracts/libraries/LibDibbler.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {Gauge} from "contracts/beanstalk/storage/System.sol";
import {IGaugeFacet} from "contracts/beanstalk/facets/sun/GaugeFacet.sol";
import {LibGaugeHelpers} from "contracts/libraries/Gauge/LibGaugeHelpers.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";

/**
 * @title Sun
 * @notice Sun controls the minting of new Beans to the Field and Silo.
 */
abstract contract Sun is Oracle, Distribution {
    using SafeCast for uint256;
    using LibRedundantMath256 for uint256;
    using LibRedundantMath128 for uint128;
    using SignedMath for int256;
    using Decimal for Decimal.D256;

    uint256 internal constant SOIL_PRECISION = 1e6;
    uint256 internal constant ONE_HUNDRED_SCALAR = 100 * SOIL_PRECISION;

    /**
     * @notice Emitted during Sunrise when Beanstalk adjusts the amount of available Soil.
     * @param season The Season in which Soil was adjusted.
     * @param soil The new amount of Soil available.
     */
    event Soil(uint32 indexed season, uint256 soil);

    //////////////////// SUN INTERNAL ////////////////////

    /**
     * @param bs Pre-calculated Beanstalk state from {LibEvaluate.evaluateBeanstalk}.
     * Includes deltaPodDemand, lpToSupplyRatio, podRate, largestLiquidWellTwapBeanPrice, twaDeltaB.
     *
     * - When below peg (twaDeltaB<0), Beanstalk wants to issue debt for beans to be sown(burned),
     * and removed from the supply, pushing the price up. It does that by fetching both the time
     * weighted average and instantaneous deltaB.
     *
     * -- If the instantaneous deltaB is also negative, Beanstalk compares the instDeltaB to the twaDeltaB
     * and picks the minimum of the two, to avoid over-issuing soil.
     * -- If the instDeltaB is positive, Beanstalk issues soil as a percentage of the twaDeltaB and scales it
     * according to the pod rate, and cultivation factor as it does when above peg.
     *
     * Issuing soil below peg is also a function of the L2SR.
     * The higher the L2SR, the less soil is issued, as Beanstalk is more willing to
     * sacrifice liquidity via converts than to issue more debt to get back to peg.
     *
     * - When above peg, Beanstalk wants to gauge demand for Soil. Here it
     * issues the amount of Soil that would result in the same number of Pods
     * as became Harvestable during the last Season. It then scales that soil based
     * on the pod rate and cultivation factor.
     */
    function stepSun(LibEvaluate.BeanstalkState memory bs) internal {
        int256 twaDeltaB = bs.twaDeltaB;
        // Above peg
        if (twaDeltaB > 0) {
            uint256 priorHarvestable = s.sys.fields[s.sys.activeField].harvestable;

            s.sys.season.standardMintedBeans = uint256(twaDeltaB);
            BeanstalkERC20(s.sys.bean).mint(address(this), uint256(twaDeltaB));
            LibShipping.ship(uint256(twaDeltaB));
            uint256 newHarvestable = s.sys.fields[s.sys.activeField].harvestable -
                priorHarvestable +
                s.sys.rain.floodHarvestablePods;
            setSoilAbovePeg(newHarvestable, bs.podRate);
            s.sys.season.abovePeg = true;
        } else {
            // Below peg
            int256 instDeltaB = LibWellMinting.getTotalInstantaneousDeltaB();
            uint256 soil;
            if (instDeltaB > 0) {
                // twaDeltaB < 0 and instDeltaB > 0, beanstalk ended the season above peg
                soil =
                    (uint256(-twaDeltaB) * s.sys.extEvaluationParameters.abovePegDeltaBSoilScalar) /
                    SOIL_PRECISION;
                setSoil(scaleSoilAbovePeg(soil, bs.podRate));
            } else {
                // twaDeltaB < 0 and instDeltaB <= 0, beanstalk ended the season below peg
                soil = Math.min(uint256(-twaDeltaB), uint256(-instDeltaB));
                setSoil(scaleSoilBelowPeg(soil, bs.lpToSupplyRatio));
            }
            s.sys.season.abovePeg = false;
        }
    }

    //////////////////// SET SOIL ////////////////////

    /**
     * @param newHarvestable The number of Beans that were minted to the Field.
     * @param podRate The protocol debt level (Pod supply) relative to the Pinto supply.
     * @dev To calculate the amount of Soil to issue, Beanstalk first calculates the number
     * of Harvestable Pods that would result in the same number of Beans as were minted to the Field.
     * It then scales this number based on the pod rate and cultivation factor.
     *
     * When the pod referral system is enabled, the protocol assumes that all Sows within the Season
     * utilizes the referral system, and adjusts the soil issuance accordingly.
     */
    function setSoilAbovePeg(uint256 newHarvestable, Decimal.D256 memory podRate) internal {
        // scale the temperature
        uint256 newSoil = newHarvestable.mul(LibDibbler.ONE_HUNDRED_TEMP).div(
            ((LibDibbler.ONE_HUNDRED_TEMP + s.sys.weather.temp) *
                (ONE_HUNDRED_SCALAR + s.sys.referrerPercentage + s.sys.refereePercentage)) /
                ONE_HUNDRED_SCALAR
        );
        setSoil(scaleSoilAbovePeg(newSoil, podRate));
    }

    /**
     * @param soilAmount The amount of Soil, as a result of the
     * - New Harvestable Pods (above peg).
     * - A percentage of the twaDeltaB (below peg).
     * @param podRate The protocol debt level (Pod supply) relative to the Pinto supply.
     * @dev Scales the Soil amount above peg as a function of
     * new Harvestable Pods, Pod rate and the CultivationFactor gauge.
     */
    function scaleSoilAbovePeg(
        uint256 soilAmount,
        Decimal.D256 memory podRate
    ) internal view returns (uint256) {
        // determine pod rate scalar as a function of podRate.
        uint256 podRateScalar = LibGaugeHelpers.linearInterpolation(
            podRate.value,
            false, // when podrate increases, the scalar decreases
            s.sys.evaluationParameters.podRateLowerBound,
            s.sys.evaluationParameters.podRateUpperBound,
            s.sys.evaluationParameters.soilCoefficientHigh,
            s.sys.evaluationParameters.soilCoefficientLow
        );

        // soilAmount * podRateScalar
        return Math.mulDiv(soilAmount, podRateScalar, C.PRECISION);
    }

    /**
     * @dev Scales the soil amount below peg as a function of L2SR, soil distribution period, and cultivationFactor.
     * @param soilAmount The amount of soil to scale.
     * @return The scaled amount of soil.
     */
    function scaleSoilBelowPeg(
        uint256 soilAmount,
        Decimal.D256 memory lpToSupplyRatio
    ) internal view returns (uint256) {
        // If soilAmount is 0, return 0 directly
        if (soilAmount == 0) return 0;

        Decimal.D256 memory scalar = Decimal.ratio(
            s.sys.extEvaluationParameters.belowPegSoilL2SRScalar,
            1e6
        );

        // Minimum of 1% of soilAmount.
        Decimal.D256 memory scaledL2SR = lpToSupplyRatio.mul(scalar);
        if (scaledL2SR.greaterThanOrEqualTo(Decimal.ratio(99, 100))) {
            scaledL2SR = Decimal.ratio(99, 100);
        }

        // (1 - L2SR * scalar) * soilAmount
        uint256 scaledAmount = Decimal
            .one()
            .sub(scaledL2SR)
            .mul(Decimal.from(soilAmount))
            .asUint256();

        // Scale by 1 hour (in seconds) / soilDistributionPeriod to distribute soil availability over the target distribution period
        scaledAmount = Math.mulDiv(
            scaledAmount,
            3600,
            s.sys.extEvaluationParameters.soilDistributionPeriod
        );

        // Apply cultivationFactor scaling (cultivationFactor is a percentage with 6 decimal places, where 100e6 = 100%)
        uint256 cultivationFactor = abi.decode(
            LibGaugeHelpers.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );

        return
            Math.max(
                Math.mulDiv(scaledAmount, cultivationFactor, 100e6),
                s.sys.extEvaluationParameters.minSoilIssuance
            );
    }

    /**
     * @param amount The new amount of Soil available.
     * @dev Sets the amount of Soil available and emits a Soil event.
     * Also sets the initialSoil amount as s.sys.soil gets decremented when sowing.
     * initialSoil gets used to calculate deltaPodDemand and amount needed to consider soil sold out.
     */
    function setSoil(uint256 amount) internal {
        s.sys.soil = amount.toUint128();
        s.sys.initialSoil = amount.toUint128();
        emit Soil(s.sys.season.current, amount.toUint128());
    }
}

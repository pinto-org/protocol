// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PRBMath} from "@prb/math/contracts/PRBMath.sol";
import {LibPRBMathRoundable} from "contracts/libraries/Math/LibPRBMathRoundable.sol";
import {PRBMathUD60x18} from "@prb/math/contracts/PRBMathUD60x18.sol";
import {LibAppStorage, AppStorage} from "./LibAppStorage.sol";
import {Account, Field} from "contracts/beanstalk/storage/Account.sol";
import {LibRedundantMath128} from "./Math/LibRedundantMath128.sol";
import {LibRedundantMath32} from "./Math/LibRedundantMath32.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {IBean} from "contracts/interfaces/IBean.sol";
import {LibGaugeHelpers} from "./Gauge/LibGaugeHelpers.sol";
import {C} from "contracts/C.sol";

/**
 * @title LibDibbler
 * @notice Calculates the amount of Pods received for Sowing under certain conditions.
 * Provides functions to calculate the instantaneous Temperature, which is adjusted by the
 * Morning Auction functionality. Provides additional functionality used by field/market.
 */
library LibDibbler {
    using PRBMath for uint256;
    using LibPRBMathRoundable for uint256;
    using LibRedundantMath256 for uint256;
    using LibRedundantMath32 for uint32;
    using LibRedundantMath128 for uint128;

    /// @dev The precision of s.sys.weather.temp
    uint256 internal constant TEMPERATURE_PRECISION = 1e6;

    /// @dev Simplifies conversion of Beans to Pods:
    /// `pods = beans * (1 + temperature)`
    /// `pods = beans * (100% + temperature) / 100%`
    uint256 internal constant ONE_HUNDRED_TEMP = 100 * TEMPERATURE_PRECISION;

    /// @dev If less than `SOLD_OUT_THRESHOLD_PERCENT`% of the initial soil is left, soil is sold out.
    /// @dev If less than `ALMOST_SOLD_OUT_THRESHOLD_PERCENT`% of the initial soil is left, soil is mostly sold out.
    uint256 internal constant MAXIMUM_SOIL_SOLD_OUT_THRESHOLD = 50e6;
    uint256 internal constant SOLD_OUT_THRESHOLD_PERCENT = 10e6;
    uint256 internal constant ALMOST_SOLD_OUT_THRESHOLD_PERCENT = 20e6;
    uint256 internal constant SOLD_OUT_PRECISION = 100e6;

    uint32 internal constant SOIL_ALMOST_SOLD_OUT_TIME = type(uint32).max - 1;

    /**
     * @notice Emitted from {LibDibbler.sow} when an `account` creates a plot.
     * A Plot is a set of Pods created in from a single {sow} or {fund} call.
     * @param account The account that sowed Bean for Pods
     * @param index The place in line of the Plot
     * @param beans The amount of Bean burnt to create the Plot
     * @param pods The amount of Pods associated with the created Plot
     */
    event Sow(address indexed account, uint256 fieldId, uint256 index, uint256 beans, uint256 pods);

    /**
     * @notice Emitted from {LibDibbler._saveSowTime} when soil is mostly sold out.
     */
    event SoilMostlySoldOut(uint256 secondsSinceStart);

    /**
     * @notice Emitted from {LibDibbler._saveSowTime} when soil is sold out.
     * @param secondsSinceStart the number of seconds elapsed until soil was sold out.
     */
    event SoilSoldOut(uint256 secondsSinceStart);

    /**
     * @notice Emitted from {LibDibbler._sow} when an `account` sows Beans for Pods, and has a referral.
     * @param referrer The account that referred the `account`
     * @param referee The account that was referred by the `referrer`
     * @param referrerPods The amount of Pods associated with the referral
     * @param refereePods The amount of Pods associated with the referee
     */
    event SowReferral(
        address indexed referrer,
        uint256 referrerIndex,
        uint256 referrerPods,
        address indexed referee,
        uint256 refereeIndex,
        uint256 refereePods
    );

    //////////////////// SOW ////////////////////

    function sowWithMin(
        uint256 beans,
        uint256 minTemperature,
        uint256 minSoil,
        LibTransfer.From mode,
        address referral
    ) internal returns (uint256 pods, uint256 referrerPods, uint256 refereePods) {
        // `soil` is the remaining Soil
        (uint256 soil, uint256 _morningTemperature, bool abovePeg) = _totalSoilAndTemperature();

        require(soil >= minSoil && beans >= minSoil, "Field: Soil Slippage");
        require(_morningTemperature >= minTemperature, "Field: Temperature Slippage");

        // If beans >= soil, Sow all of the remaining Soil
        if (beans < soil) {
            soil = beans;
        }

        // 1 Bean is Sown in 1 Soil, i.e. soil = beans
        (pods, referrerPods, refereePods) = _sow(
            soil,
            _morningTemperature,
            abovePeg,
            mode,
            referral
        );
    }

    /**
     * @dev Burn Beans, Sows at the provided `_morningTemperature`, increments the total
     * number of `beanSown`.
     */
    function _sow(
        uint256 beans,
        uint256 _morningTemperature,
        bool peg,
        LibTransfer.From mode,
        address referrer
    ) internal returns (uint256 pods, uint256 referrerPods, uint256 refereePods) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        address user = LibTractor._user();
        beans = LibTransfer.burnToken(IBean(s.sys.bean), beans, user, mode);
        (pods, ) = sow(beans, _morningTemperature, user, peg, true, false);
        updateReferralEligibility(user, beans);
        if (isValidReferral(referrer, user)) {
            (referrerPods, refereePods) = sowBonus(beans, _morningTemperature, referrer, user, peg);
        }
        s.sys.beanSown += SafeCast.toUint128(beans);
    }

    /**
     * @param beans The number of Beans to Sow
     * @param _morningTemperature Pre-calculated {morningTemperature()}
     * @param account The account sowing Beans
     * @param abovePeg Whether the TWA deltaB of the previous season was positive (true) or negative (false)
     * @dev
     *
     * ## Above Peg
     *
     * | t   | Max pods  | s.sys.soil            | soil                    | temperature              | maxTemperature |
     * |-----|-----------|-----------------------|-------------------------|--------------------------|----------------|
     * | 0   | 500e6     | ~37e6 500e6/(1+1250%) | ~495e6 500e6/(1+1%))    | 1e6 (1%)                 | 1250 (1250%)   |
     * | 12  | 500e6     | ~37e6                 | ~111e6 500e6/(1+348%))  | 348.75e6 (27.9% * 1250)  | 1250           |
     * | 300 | 500e6     | ~37e6                 |  ~37e6 500e6/(1+1250%)  | 1250e6                   | 1250           |
     *
     * ## Below Peg
     *
     * | t   | Max pods                        | soil  | temperature                   | maxTemperature     |
     * |-----|---------------------------------|-------|-------------------------------|--------------------|
     * | 0   | 505e6 (500e6 * (1+1%))          | 500e6 | 1e6 (1%)                      | 1250 (1250%)       |
     * | 12  | 2243.75e6 (500e6 * (1+348.75%)) | 500e6 | 348.75e6 (27.9% * 1250 * 1e6) | 1250               |
     * | 300 | 6750e6 (500e6 * (1+1250%))      | 500e6 | 1250e6                        | 1250               |
     */
    function sow(
        uint256 beans,
        uint256 _morningTemperature,
        address account,
        bool abovePeg,
        bool useSoil,
        bool isReferral
    ) internal returns (uint256, uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        uint256 pods;
        uint256 soilUsed;
        if (abovePeg) {
            uint256 maxTemperature = uint256(s.sys.weather.temp);
            // amount sown is rounded up, because
            // 1: temperature is rounded down.
            // 2: pods are rounded down.
            soilUsed = scaleSoilDown(beans, _morningTemperature, maxTemperature);
            pods = beansToPods(soilUsed, maxTemperature);
        } else {
            // below peg, beans are used directly.
            soilUsed = beans;
            pods = beansToPods(soilUsed, _morningTemperature);
        }
        if (isReferral) {
            // note: referral system is disabled once s.sys.totalReferralPods == s.sys.maximumReferralPods.
            // total referral pods should never exceed the maximum referral pods.
            uint256 maxReferralPods = s.sys.maximumReferralPods - s.sys.totalReferralPods;
            if (pods > maxReferralPods) {
                pods = maxReferralPods;
            }
            s.sys.totalReferralPods += uint128(pods);
        }

        require(pods > 0, "Pods must be greater than 0");

        // In the case of an overflow, its equivalent to having no soil left.
        if (useSoil) {
            if (s.sys.soil < soilUsed) {
                s.sys.soil = 0;
            } else {
                s.sys.soil = s.sys.soil.sub(uint128(soilUsed));
            }
        } else {
            // beans are set to 0, as soil is not being consumed.
            // this is equivalent to creating a plot without sowing.
            // currently, this is used in the Pod Referral system.
            beans = 0;
        }

        // cache the time in which the plot was sown, if most of the soil was sown into.
        _saveSowTime();
        return (pods, addPlotToAccount(account, beans, pods));
    }

    function addPlotToAccount(
        address account,
        uint256 beans,
        uint256 pods
    ) internal returns (uint256 index) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 activeField = s.sys.activeField;
        index = s.sys.fields[activeField].pods;
        s.accts[account].fields[activeField].plots[index] = pods;
        s.accts[account].fields[activeField].plotIndexes.push(index);
        s.accts[account].fields[activeField].piIndex[index] =
            s.accts[account].fields[activeField].plotIndexes.length -
            1;
        s.sys.fields[activeField].pods += pods;
        emit Sow(account, activeField, index, beans, pods);
    }

    /**
     * @dev Stores the time elapsed from the start of the Season to the time
     * at which Soil is "sold out", i.e. the remaining Soil is less than a
     * threshold.
     *
     * That threshold is calculated based on the soil at the start of the season, set in {setSoil} and is
     * currently set to 0 if the initial soil was <100e6, and `SOLD_OUT_THRESHOLD_PERCENT`% of the initial soil otherwise.
     *
     * RATIONALE: Beanstalk utilizes the time elapsed for Soil to "sell out" to
     * gauge demand for Soil, which affects how the Temperature is adjusted. For
     * example, if all Soil is Sown in 1 second vs. 1 hour, Beanstalk assumes
     * that the former shows more demand than the latter.
     *
     * `thisSowTime` represents the target time of the first Sow for the *next*
     * Season to be considered increasing in demand.
     *
     * `thisSowTime` should only be updated if:
     *  (a) there is less than the threshold Soil available after this Sow, and
     *  (b) it has not yet been updated this Season.
     *
     * Note that:
     *  - `s.sys.soil` was decremented in the upstream {sow} function.
     *  - `s.sys.weather.thisSowTime` is set to `type(uint32).max` during {sunrise}.
     *  - `s.sys.initialSoil` is the initial soil at the start of the season.
     *  - `s.sys.weather.thisSowTime` is `type(uint32).max` if the soil has not sold out, and `type(uint32).max - 1` if the soil is mostly sold out.
     */
    function _saveSowTime() private {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 initialSoil = s.sys.initialSoil;
        uint256 soil = s.sys.soil;
        uint256 thisSowTime = s.sys.weather.thisSowTime;

        uint256 soilSoldOutThreshold = getSoilSoldOutThreshold(initialSoil);
        uint256 soilMostlySoldOutThreshold = getSoilMostlySoldOutThreshold(
            initialSoil,
            soilSoldOutThreshold
        );

        if (soil <= soilMostlySoldOutThreshold && thisSowTime >= SOIL_ALMOST_SOLD_OUT_TIME) {
            if (thisSowTime == type(uint32).max) {
                // if this is the first time in the season soil mostly sold out,
                // set thisSowTime and emit event.
                if (soil >= soilSoldOutThreshold) {
                    s.sys.weather.thisSowTime = SOIL_ALMOST_SOLD_OUT_TIME;
                    emit SoilMostlySoldOut(block.timestamp.sub(s.sys.season.timestamp));
                    return;
                }
            }

            if (soil <= soilSoldOutThreshold) {
                // soil is sold out.
                s.sys.weather.thisSowTime = uint32(block.timestamp.sub(s.sys.season.timestamp));
                emit SoilSoldOut(block.timestamp.sub(s.sys.season.timestamp));
            }
        }
    }

    /**
     * @dev Gets the current `soil`, `_morningTemperature` and `abovePeg`. Provided as a gas
     * optimization to prevent recalculation of {LibDibbler.morningTemperature} for
     * upstream functions.
     * Note: the `soil` return value is symmetric with `totalSoil`.
     */
    function _totalSoilAndTemperature()
        private
        view
        returns (uint256 soil, uint256 _morningTemperature, bool abovePeg)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        _morningTemperature = morningTemperature();
        abovePeg = s.sys.season.abovePeg;

        // Below peg: Soil is fixed to the amount set during {calcCaseId}.
        // Morning Temperature is dynamic, starting small and logarithmically
        // increasing to `s.weather.t` across the first 25 blocks of the Season.
        if (!abovePeg) {
            soil = uint256(s.sys.soil);
        } else {
            // Above peg: the maximum amount of Pods that Beanstalk is willing to mint
            // stays fixed; since {morningTemperature} is scaled down when `delta < 25`, we
            // need to scale up the amount of Soil to hold Pods constant.
            soil = scaleSoilUp(
                uint256(s.sys.soil), // max soil offered this Season, reached when `t >= 25`
                uint256(s.sys.weather.temp), // max temperature (1e6 precision)
                _morningTemperature // temperature adjusted by number of blocks since Sunrise
            );
        }
    }

    //////////////////// TEMPERATURE ////////////////////

    /**
     * @notice Returns the temperature `s.sys.weather.temp` scaled down based on the second delta.
     * Precision level 1e6, as soil has 1e6 precision (1% = 1e6)
     * the formula `log2(A * delta  + 1)/log2(A * s.sys.weather.morningDuration + 1)` is applied, where:
     * `A = 0.1`
     */
    function morningTemperature() internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 maxTemperature = s.sys.weather.temp;
        uint256 delta;
        // in theory, block.timestamp should never be less than s.sys.season.timestamp,
        // but if so, we'll use the delta as 0.
        if (block.timestamp > s.sys.season.timestamp) {
            delta = block.timestamp - s.sys.season.timestamp;
        }

        uint256 morningDuration = s.sys.weather.morningDuration;
        // if the delta is greater than the morning duration, return the max temperature.
        if (delta >= morningDuration) {
            return maxTemperature;
        }

        uint256 scaledTemperature = _scaleTemperature(maxTemperature, morningDuration, delta);

        // set a temperature floor of 1% of max temperature.
        if (scaledTemperature < maxTemperature / 100) {
            return maxTemperature / 100;
        }

        return scaledTemperature;
    }

    /**
     * Formula:
     * T * log2(delta * c + 1) / log2(morningDuration * c + 1)
     * where c <= morningDuration.
     */
    function _scaleTemperature(
        uint256 maxTemperature,
        uint256 morningDuration,
        uint256 delta
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 c = s.sys.weather.morningControl;
        return
            (maxTemperature *
                PRBMathUD60x18.log2(((delta * C.PRECISION * c) / C.PRECISION) + C.PRECISION)) /
            PRBMathUD60x18.log2(((morningDuration * C.PRECISION * c) / C.PRECISION) + C.PRECISION);
    }

    /**
     * @param beans The number of Beans to convert to Pods.
     * @param _morningTemperature The current Temperature, measured to 1e8.
     * @dev Converts Beans to Pods based on `_morningTemperature`.
     *
     * `pods = beans * (100e6 + _morningTemperature) / 100e6`
     * `pods = beans * (1 + _morningTemperature / 100e6)`
     *
     * Beans and Pods are measured to 6 decimals.
     *
     * 1e8 = 100e6 = 100% = 1.
     */
    function beansToPods(
        uint256 beans,
        uint256 _morningTemperature
    ) internal pure returns (uint256 pods) {
        pods = beans.mulDiv(_morningTemperature.add(ONE_HUNDRED_TEMP), ONE_HUNDRED_TEMP);
    }

    /**
     * @dev Scales Soil up when Beanstalk is above peg.
     * `(1 + maxTemperature) / (1 + morningTemperature)`
     */
    function scaleSoilUp(
        uint256 soil,
        uint256 maxTemperature,
        uint256 _morningTemperature
    ) internal pure returns (uint256) {
        return
            soil.mulDiv(
                maxTemperature.add(ONE_HUNDRED_TEMP),
                _morningTemperature.add(ONE_HUNDRED_TEMP)
            );
    }

    /**
     * @dev Scales Soil down when Beanstalk is above peg.
     *
     * When Beanstalk is above peg, the Soil issued changes. Example:
     *
     * If 500 Soil is issued when `s.weather.temp = 100e6 = 100%`
     * At delta = 0:
     *  morningTemperature() = 1%
     *  Soil = `500*(100 + 100%)/(100 + 1%)` = 990.09901 soil
     *
     * If someone sow'd ~495 soil, it's equivalent to sowing 250 soil at t > 25.
     * Thus when someone sows during this time, the amount subtracted from s.sys.soil
     * should be scaled down.
     *
     * Note: param ordering matches the mulDiv operation
     */
    function scaleSoilDown(
        uint256 soil,
        uint256 _morningTemperature,
        uint256 maxTemperature
    ) internal pure returns (uint256) {
        return
            soil.mulDiv(
                _morningTemperature.add(ONE_HUNDRED_TEMP),
                maxTemperature.add(ONE_HUNDRED_TEMP),
                LibPRBMathRoundable.Rounding.Up
            );
    }

    /**
     * @notice Returns the remaining Pods that could be issued this Season.
     */
    function remainingPods() internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Above peg: number of Pods is fixed, Soil adjusts
        if (s.sys.season.abovePeg) {
            return
                beansToPods(
                    s.sys.soil, // 1 bean = 1 soil
                    uint256(s.sys.weather.temp)
                );
        } else {
            // Below peg: amount of Soil is fixed, temperature adjusts
            return
                beansToPods(
                    s.sys.soil, // 1 bean = 1 soil
                    morningTemperature()
                );
        }
    }

    /**
     * @notice removes a plot index from an accounts plotIndex list.
     */
    function removePlotIndexFromAccount(
        address account,
        uint256 fieldId,
        uint256 plotIndex
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 i = findPlotIndexForAccount(account, fieldId, plotIndex);
        Field storage field = s.accts[account].fields[fieldId];
        field.plotIndexes[i] = field.plotIndexes[field.plotIndexes.length - 1];
        field.piIndex[field.plotIndexes[i]] = i;
        field.piIndex[plotIndex] = type(uint256).max;
        field.plotIndexes.pop();
    }

    /**
     * @notice finds the index of a plot in an accounts plotIndex list.
     */
    function findPlotIndexForAccount(
        address account,
        uint256 fieldId,
        uint256 plotIndex
    ) internal view returns (uint256 i) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.accts[account].fields[fieldId].piIndex[plotIndex];
    }

    /**
     * @notice Returns the threshold at which soil is considered sold out.
     * @dev Soil is considered sold out if it has less than SOLD_OUT_THRESHOLD_PERCENT% of the initial soil left
     * @param initialSoil The initial soil at the start of the season.
     * @return soilSoldOutThreshold The threshold at which soil is considered sold out.
     */
    function getSoilSoldOutThreshold(uint256 initialSoil) internal pure returns (uint256) {
        return
            Math.min(
                MAXIMUM_SOIL_SOLD_OUT_THRESHOLD,
                (initialSoil * SOLD_OUT_THRESHOLD_PERCENT) / SOLD_OUT_PRECISION
            );
    }

    /**
     * @notice Returns the threshold at which soil is considered mostly sold out.
     * @dev Soil is considered mostly sold out if it has less than ALMOST_SOLD_OUT_THRESHOLD_PERCENT% + soilSoldOutThreshold of the initial soil left
     * @param initialSoil The initial soil at the start of the season.
     * @param soilSoldOutThreshold The threshold at which soil is considered sold out.
     * @return soilMostlySoldOutThreshold The threshold at which soil is considered mostly sold out.
     */
    function getSoilMostlySoldOutThreshold(
        uint256 initialSoil,
        uint256 soilSoldOutThreshold
    ) internal pure returns (uint256) {
        return
            ((initialSoil - getSoilSoldOutThreshold(initialSoil)) *
                ALMOST_SOLD_OUT_THRESHOLD_PERCENT) /
            SOLD_OUT_PRECISION +
            soilSoldOutThreshold;
    }

    // REFERRAL BONUS //

    /**
     * @notice internal function for sowing referral plots.
     */
    function sowBonus(
        uint256 beans,
        uint256 _morningTemperature,
        address referrer,
        address referee,
        bool peg
    ) internal returns (uint256 referrerPods, uint256 refereePods) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (
            s.sys.totalReferralPods < s.sys.maximumReferralPods &&
            (s.sys.referrerPercentage != 0 || s.sys.refereePercentage != 0)
        ) {
            uint256 referrerBeans = (beans * s.sys.referrerPercentage) / C.PRECISION;
            uint256 refereeBeans = (beans * s.sys.refereePercentage) / C.PRECISION;
            uint256 referrerIndex;
            uint256 refereeIndex;
            if (refereeBeans > 0) {
                (refereePods, refereeIndex) = sow(
                    refereeBeans,
                    _morningTemperature,
                    referee,
                    peg,
                    false,
                    true
                );
            }
            if (referrerBeans > 0) {
                (referrerPods, referrerIndex) = sow(
                    referrerBeans,
                    _morningTemperature,
                    referrer,
                    peg,
                    false,
                    true
                );
            }
            emit SowReferral(
                referrer,
                referrerIndex,
                referrerPods,
                referee,
                refereeIndex,
                refereePods
            );
        }
        return (referrerPods, refereePods);
    }

    /**
     * @notice internal function for checking if a referral is valid.
     * a valid referral is one where the referral address is not the zero address and not the sower's address,
     * AND the referral address is eligible to be a referrer.
     */
    function isValidReferral(address referrer, address referee) internal view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 af = s.sys.activeField;
        return
            s.accts[referrer].fields[af].referral.eligibility == true &&
            referrer != referee &&
            referrer != address(0);
    }

    function updateReferralEligibility(address user, uint256 beanSown) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 af = s.sys.activeField;
        // increment the number of beans the user has sown for referrals.
        s.accts[user].fields[af].referral.beans += uint128(beanSown);
        // if the user is not eligible already, increment their eligibility sown
        if (
            !s.accts[user].fields[af].referral.eligibility &&
            s.accts[user].fields[af].referral.beans >= s.sys.referralBeanSownEligibilityThreshold
        ) {
            s.accts[user].fields[af].referral.eligibility = true;
        }
    }
}

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

    /// @dev The divisor of s.sys.weather.temp in the morning auction
    uint256 internal constant TEMPERATURE_DIVISOR = 1e12;

    /// @dev Simplifies conversion of Beans to Pods:
    /// `pods = beans * (1 + temperature)`
    /// `pods = beans * (100% + temperature) / 100%`
    uint256 internal constant ONE_HUNDRED_TEMP = 100 * TEMPERATURE_PRECISION;

    /// @dev If less than `SOLD_OUT_THRESHOLD`% of the initial soil is left, soil is sold out.
    uint256 internal constant SOLD_OUT_THRESHOLD = 1e6;
    uint256 internal constant SOLD_OUT_PRECISION = 100e6;

    /**
     * @notice Emitted from {LibDibbler.sow} when an `account` creates a plot.
     * A Plot is a set of Pods created in from a single {sow} or {fund} call.
     * @param account The account that sowed Bean for Pods
     * @param index The place in line of the Plot
     * @param beans The amount of Bean burnt to create the Plot
     * @param pods The amount of Pods associated with the created Plot
     */
    event Sow(address indexed account, uint256 fieldId, uint256 index, uint256 beans, uint256 pods);

    //////////////////// SOW ////////////////////

    function sowWithMin(
        uint256 beans,
        uint256 minTemperature,
        uint256 minSoil,
        LibTransfer.From mode
    ) internal returns (uint256 pods) {
        // `soil` is the remaining Soil
        (uint256 soil, uint256 _morningTemperature, bool abovePeg) = _totalSoilAndTemperature();

        require(soil >= minSoil && beans >= minSoil, "Field: Soil Slippage");
        require(_morningTemperature >= minTemperature, "Field: Temperature Slippage");

        // If beans >= soil, Sow all of the remaining Soil
        if (beans < soil) {
            soil = beans;
        }

        // 1 Bean is Sown in 1 Soil, i.e. soil = beans
        pods = _sow(soil, _morningTemperature, abovePeg, mode);
    }

    /**
     * @dev Burn Beans, Sows at the provided `_morningTemperature`, increments the total
     * number of `beanSown`.
     */
    function _sow(
        uint256 beans,
        uint256 _morningTemperature,
        bool peg,
        LibTransfer.From mode
    ) internal returns (uint256 pods) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        beans = LibTransfer.burnToken(IBean(s.sys.bean), beans, LibTractor._user(), mode);
        pods = sow(beans, _morningTemperature, LibTractor._user(), peg);
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
        bool abovePeg
    ) internal returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 activeField = s.sys.activeField;

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

        require(pods > 0, "Pods must be greater than 0");

        // In the case of an overflow, its equivalent to having no soil left.
        if (s.sys.soil < soilUsed) {
            s.sys.soil = 0;
        } else {
            s.sys.soil = s.sys.soil.sub(uint128(soilUsed));
        }

        uint256 index = s.sys.fields[activeField].pods;

        s.accts[account].fields[activeField].plots[index] = pods;
        s.accts[account].fields[activeField].plotIndexes.push(index);
        s.accts[account].fields[activeField].piIndex[index] =
            s.accts[account].fields[activeField].plotIndexes.length -
            1;
        emit Sow(account, activeField, index, beans, pods);

        s.sys.fields[activeField].pods += pods;
        _saveSowTime();
        return pods;
    }

    /**
     * @dev Stores the time elapsed from the start of the Season to the time
     * at which Soil is "sold out", i.e. the remaining Soil is less than a
     * threshold.
     *
     * That threshold is calculated based on the soil at the start of the season, set in {setSoil} and is
     * currently set to 0 if the initial soil was <100e6, and `SOLD_OUT_THRESHOLD`% of the initial soil otherwise.
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
     *  - `s.soil` was decremented in the upstream {sow} function.
     *  - `s.weather.thisSowTime` is set to `type(uint32).max` during {sunrise}.
     */
    function _saveSowTime() private {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 soilSoldOutThreshold;
        uint256 initialSoil = s.sys.initialSoil;
        if (initialSoil > 100e6) {
            soilSoldOutThreshold = (initialSoil * SOLD_OUT_THRESHOLD) / SOLD_OUT_PRECISION;
        }

        // If the initial Soil was less than 100e6, set the threshold to 50% of the initial Soil.
        // Otherwise the threshold is 50e6.
        uint256 soilSoldOutThreshold = (s.sys.initialSoil < 100e6)
            ? ((s.sys.initialSoil * 50e6) / 100e6)
            : MAX_SOIL_SOLD_OUT_THRESHOLD;

        // s.sys.soil is now the soil remaining after this Sow.
        if (s.sys.soil > soilSoldOutThreshold || s.sys.weather.thisSowTime < type(uint32).max) {
            // haven't sold enough soil, or already set thisSowTime for this Season.
            return;
        }

        s.sys.weather.thisSowTime = uint32(block.timestamp.sub(s.sys.season.timestamp));
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
     * @notice Returns the temperature `s.sys.weather.temp` scaled down based on the block delta.
     * Precision level 1e6, as soil has 1e6 precision (1% = 1e6)
     * the formula `log2(A * CHUNKS_ELAPSED + 1)/log2(A * MAX_CHUNKS + 1)` is applied, where:
     * `A = 0.1`
     * `MAX_CHUNKS = 25`
     * @dev This function implements the log formula in a discrete fashion (in chunks),
     * rather than in an continuous manner. Previously, these chunks were chosen with
     * the Ethereum L1 block time in mind, such that the duration of the morning auction
     * was 5 minutes.
     
     * When deploying a beanstalk on other EVM chains/layers, `L2_BLOCK_TIME` will need
     * to be adjusted such that the duration of the morning auction is constant.
     * An additional divisor is implemented such that the duration can be adjusted independent of the
     * block times.
     */
    function morningTemperature() internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 maxTemperature = s.sys.weather.temp;
        uint256 delta = block.timestamp - s.sys.season.timestamp;
        uint256 morningDuration = s.sys.weather.morningDuration;
        if (delta >= morningDuration) {
            return maxTemperature;
        }

        uint256 scaledTemperature = _scaleTemperature(maxTemperature, morningDuration, delta);

        // set a temperature floor of 1% of max temperature
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
}

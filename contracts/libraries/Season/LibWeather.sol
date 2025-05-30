// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AppStorage, LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibTokenSilo} from "contracts/libraries/Silo/LibTokenSilo.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {LibRedundantMath128} from "contracts/libraries/Math/LibRedundantMath128.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibRedundantMathSigned256} from "contracts/libraries/Math/LibRedundantMathSigned256.sol";
import {LibEvaluate} from "contracts/libraries/LibEvaluate.sol";
import {LibCases} from "contracts/libraries/LibCases.sol";
/**
 * @title LibWeather
 * @notice Library for managing Weather state in Beanstalk, including Temperature and Grown Stalk to LP ratios.
 * @dev Weather controls the Temperature and Grown Stalk to LP on the Farm.
 */
library LibWeather {
    using LibRedundantMath256 for uint256;
    using LibRedundantMathSigned256 for int256;
    using LibRedundantMath128 for uint128;

    uint128 internal constant MAX_BEAN_LP_GP_PER_BDV_RATIO = 100e18;

    /**
     * @notice Emitted when the Temperature (fka "Weather") changes.
     * @param season The current Season
     * @param caseId The Weather case, which determines how much the Temperature is adjusted.
     * @param absChange The absolute change in Temperature.
     * @dev formula: T_n = T_n-1 +/- bT
     */
    event TemperatureChange(
        uint256 indexed season,
        uint256 caseId,
        int32 absChange,
        uint256 fieldId
    );

    /**
     * @notice Emitted when the grownStalkToLP changes.
     * @param season The current Season
     * @param caseId The Weather case, which determines how the BeanToMaxLPGpPerBDVRatio is adjusted.
     * @param absChange The absolute change in the BeanToMaxLPGpPerBDVRatio.
     * @dev formula: L_n = L_n-1 +/- bL
     */
    event BeanToMaxLpGpPerBdvRatioChange(uint256 indexed season, uint256 caseId, int80 absChange);

    /**
     * @notice Emitted when bean crosses below its value target.
     * @param season The season in which the bean crossed below its value target.
     * @param tokens The tokens that were updated.
     * @param stems The new stemTips stored at the peg cross.
     */
    event UpdatedBelowPegCrossStems(uint256 indexed season, address[] tokens, int96[] stems);

    /**
     * @notice Emitted when the peg state is updated.
     * @param season The season in which the peg state was updated.
     * @param abovePeg Whether the peg is above or below.
     */
    event PegStateUpdated(uint32 season, bool abovePeg);

    /**
     * @notice updates the temperature and BeanToMaxLpGpPerBdvRatio, based on the caseId.
     * @param caseId the state beanstalk is in, based on the current season.
     * @dev currently, an oracle failure does not affect the temperature, as
     * the temperature is not affected by liquidity levels. The function will
     * need to be updated if the temperature is affected by liquidity levels.
     * This is implemented such that liveliness in change in temperature is retained.
     */
    function updateTemperatureAndBeanToMaxLpGpPerBdvRatio(
        uint256 caseId,
        LibEvaluate.BeanstalkState memory bs,
        bool oracleFailure
    ) external {
        LibCases.CaseData memory cd = LibCases.decodeCaseData(caseId);

        // if the podrate is > 100% and deltaB is negative, set bt based on soil demand:
        if (bs.podRate.value > 1e18) {
            if (bs.twaDeltaB < 0) {
                if (caseId % 3 == 0) {
                    // decreasing
                    cd.bT = 0.5e6;
                } else if (caseId % 3 == 1) {
                    // steady
                    cd.bT = 0;
                } else if (caseId % 3 == 2) {
                    // increasing
                    cd.bT = -1e6;
                }
            }
            // append 1000 to the caseId to indicate that the podrate is > 100%
            caseId = caseId + 1000;
        }

        updateTemperature(cd.bT, caseId);

        // if one of the oracles needed to calculate usd liquidity fails,
        // the beanToMaxLpGpPerBdvRatio should not be updated.
        if (oracleFailure) return;
        updateBeanToMaxLPRatio(cd.bL, caseId);
    }

    /**
     * @notice Changes the current Temperature `s.weather.t` based on the Case Id.
     * @dev bT are set during edge cases such that the event emitted is valid.
     */
    function updateTemperature(int32 bT, uint256 caseId) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 t = s.sys.weather.temp;
        if (bT < 0) {
            if (t <= uint256(int256(-bT))) {
                // if temp is to be decreased and the change is greater than the current temp,
                // - then the new temp will be 1e6.
                // - and the change in temp bT will be the difference between the new temp and the old temp.
                // if (change < 0 && t <= uint32(-change)),
                // then 0 <= t <= type(int32).max because change is an int32.
                bT = 1e6 - int32(int256(t));
                s.sys.weather.temp = 1e6;
            } else {
                s.sys.weather.temp = uint32(t - uint256(int256(-bT)));
            }
        } else {
            s.sys.weather.temp = uint32(t + uint256(int256(bT)));
        }

        emit TemperatureChange(s.sys.season.current, caseId, bT, s.sys.activeField);
    }

    /**
     * @notice Changes the grownStalkPerBDVPerSeason based on the CaseId.
     * @dev bL are set during edge cases such that the event emitted is valid.
     */
    function updateBeanToMaxLPRatio(int80 bL, uint256 caseId) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint128 beanToMaxLpGpPerBdvRatio = s.sys.seedGauge.beanToMaxLpGpPerBdvRatio;
        if (bL < 0) {
            if (beanToMaxLpGpPerBdvRatio <= uint128(int128(-bL))) {
                bL = -SafeCast.toInt80(int256(uint256(beanToMaxLpGpPerBdvRatio)));
                s.sys.seedGauge.beanToMaxLpGpPerBdvRatio = 0;
            } else {
                s.sys.seedGauge.beanToMaxLpGpPerBdvRatio = beanToMaxLpGpPerBdvRatio.sub(
                    uint128(int128(-bL))
                );
            }
        } else {
            if (beanToMaxLpGpPerBdvRatio.add(uint128(int128(bL))) >= MAX_BEAN_LP_GP_PER_BDV_RATIO) {
                // if (change > 0 && 100e18 - beanToMaxLpGpPerBdvRatio <= bL),
                // then bL cannot overflow.
                bL = int80(
                    SafeCast.toInt80(
                        int256(uint256(MAX_BEAN_LP_GP_PER_BDV_RATIO.sub(beanToMaxLpGpPerBdvRatio)))
                    )
                );
                s.sys.seedGauge.beanToMaxLpGpPerBdvRatio = MAX_BEAN_LP_GP_PER_BDV_RATIO;
            } else {
                s.sys.seedGauge.beanToMaxLpGpPerBdvRatio = beanToMaxLpGpPerBdvRatio.add(
                    uint128(int128(bL))
                );
            }
        }

        emit BeanToMaxLpGpPerBdvRatioChange(s.sys.season.current, caseId, bL);
    }

    /**
     * @notice Updates the peg state based on the twaDeltaB and whether the peg was crossed.
     * @param twaDeltaB The twaDeltaB from the Oracle.
     */
    function updatePegState(int256 twaDeltaB) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        bool lastSeasonPeg = s.sys.season.abovePeg;
        s.sys.season.abovePeg = twaDeltaB > 0;

        // if the last season peg state is not the same as the current peg state,
        // the system has crossed peg.
        if (lastSeasonPeg != s.sys.season.abovePeg) {
            s.sys.season.pegCrossSeason = s.sys.season.current;
            if (twaDeltaB <= 0) {
                // if the peg was crossed below, cache the stems for each whitelisted token.
                address[] memory lpTokens = LibWhitelistedTokens.getWhitelistedLpTokens();
                int96[] memory stems = new int96[](lpTokens.length);
                for (uint256 i = 0; i < lpTokens.length; i++) {
                    stems[i] = LibTokenSilo.stemTipForToken(lpTokens[i]);
                    s.sys.belowPegCrossStems[lpTokens[i]] = stems[i];
                }
                emit UpdatedBelowPegCrossStems(s.sys.season.pegCrossSeason, lpTokens, stems);
            }
            emit PegStateUpdated(s.sys.season.current, s.sys.season.abovePeg);
        }
    }
}

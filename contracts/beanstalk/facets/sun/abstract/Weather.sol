// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Sun, C} from "./Sun.sol";
import {LibEvaluate} from "contracts/libraries/LibEvaluate.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibRedundantMathSigned256} from "contracts/libraries/Math/LibRedundantMathSigned256.sol";
import {AppStorage, LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibFlood} from "contracts/libraries/Silo/LibFlood.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";
import {LibWeather} from "contracts/libraries/Sun/LibWeather.sol";

/**
 * @title Weather
 * @notice Weather controls the Temperature and Grown Stalk to LP on the Farm.
 */
abstract contract Weather is Sun {
    // @notice This controls the percentage of Bean supply that is flooded to the field.
    // 1000 represents 1/1000, or 0.1% of total Bean supply.
    uint256 internal constant FLOOD_PODLINE_PERCENT_DENOMINATOR = 1000;

    // @dev In-memory struct used to store current deltaB, and then reduction amount per-well.
    struct WellDeltaB {
        address well;
        int256 deltaB;
    }

    /**
     * @notice Emitted when Beans are minted to the Field during the Season of Plenty.
     * @param toField The amount of Beans which were distributed to remaining Pods in the Field.
     */
    event SeasonOfPlentyField(uint256 toField);

    //////////////////// WEATHER INTERNAL ////////////////////

    /**
     * @notice from deltaB, podRate, change in soil demand, and liquidity to supply ratio,
     * calculate the caseId, and update the temperature and grownStalkPerBdvToLp.
     * @param deltaB Pre-calculated deltaB from {Oracle.stepOracle}.
     * @dev A detailed explanation of the temperature and grownStalkPerBdvToLp
     * mechanism can be found in the Beanstalk whitepaper.
     * An explanation of state variables can be found in {AppStorage}.
     */
    function calcCaseIdAndHandleRain(
        int256 deltaB
    ) internal returns (uint256 caseId, LibEvaluate.BeanstalkState memory bs) {
        uint256 beanSupply = BeanstalkERC20(s.sys.bean).totalSupply();
        // prevents infinite L2SR and podrate
        if (beanSupply == 0) {
            s.sys.weather.temp = 1e6;
            // Returns an uninitialized Beanstalk State.
            return (9, bs); // Reasonably low
        }

        // Calculate Case Id
        (caseId, bs) = LibEvaluate.evaluateBeanstalk(deltaB, beanSupply);
        LibWeather.updateTemperatureAndBeanToMaxLpGpPerBdvRatio(caseId, bs, bs.oracleFailure);
        LibFlood.handleRain(caseId);
    }
}

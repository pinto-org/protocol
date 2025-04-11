/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import "../../libraries/LibCases.sol";

/**
 * @title InitPI5`.
 * @dev Initializes parameters for pinto improvement set 5
 **/
contract InitPI5 {
    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        s.sys.extEvaluationParameters.belowPegSoilL2SRScalar = 1.0e6;

        // modify soil coefficients above peg
        s.sys.evaluationParameters.soilCoefficientHigh = 0.25e18;
        s.sys.extEvaluationParameters.soilCoefficientRelativelyHigh = 0.5e18;
        s.sys.extEvaluationParameters.soilCoefficientRelativelyLow = 1e18;
        s.sys.evaluationParameters.soilCoefficientLow = 1.2e18;

        // Set the abovePegDeltaBSoilScalar to 0.01e6 (1% of twaDeltaB)
        s.sys.extEvaluationParameters.abovePegDeltaBSoilScalar = 0.01e6;

        // Update cases, which updates the temperature precision to 6 decimals
        LibCases.setCasesV2();

        // Temperature is stored with 6 decimals now so we need to scale the current storage variable
        s.sys.weather.temp = s.sys.weather.temp * 1e6;
    }
}

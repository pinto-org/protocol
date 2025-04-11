/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import "../../libraries/LibCases.sol";
import "../../interfaces/IBean.sol";

/**
 * @title InitPI3`.
 **/
contract InitPI3 {
    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // modify pod rate lower bound from 5% to 3%
        s.sys.evaluationParameters.podRateLowerBound = 0.03e18; // 3%

        // decrease soil scaler from 1.5x to 1.2x
        s.sys.evaluationParameters.soilCoefficientLow = 1.2e18; // 1.2x

        // Update cases, which updates temperature changes from 3% to 2%
        LibCases.setCasesV2();

        // Update flood soil, if the system is flooding and podline has been paid off, init some soil
        // if currently sopping/flooding
        if (s.sys.season.lastSopSeason == s.sys.season.current) {
            uint256 harvestableIndex = s.sys.fields[s.sys.activeField].harvestable -
                s.sys.fields[s.sys.activeField].harvestable;

            // if no harvestable pods, issue soil equal to 0.1% of total bean supply
            if (harvestableIndex == 0) {
                uint256 soilAmount = (IBean(s.sys.bean).totalSupply() / 1000);
                s.sys.soil += uint128(soilAmount);
            }
        }
    }
}

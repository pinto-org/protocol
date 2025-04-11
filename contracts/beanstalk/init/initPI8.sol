/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {LibUpdate} from "../../libraries/LibUpdate.sol";
import {Weather} from "../facets/sun/abstract/Weather.sol";
/**
 * @title InitPI8
 * @dev Updates parameters for pinto improvement 8.
 **/
contract InitPI8 {
    uint256 internal constant MIN_SOIL_SOWN_DEMAND = 5e6; // 5

    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Update min soil sown demand. note: was removed in PI9
        // s.sys.extEvaluationParameters.minSoilSownDemand = MIN_SOIL_SOWN_DEMAND;
        // emit LibUpdate.UpdatedExtEvaluationParameters(
        //     s.sys.season.current,
        //     s.sys.extEvaluationParameters
        // );

        // increase max crop ratio to 200%
        s.sys.evaluationParameters.maxBeanMaxLpGpPerBdvRatio = 200e18;
        emit LibUpdate.UpdatedEvaluationParameters(
            s.sys.season.current,
            s.sys.evaluationParameters
        );
    }
}

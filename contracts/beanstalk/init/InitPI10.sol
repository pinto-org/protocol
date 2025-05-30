/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {LibInitGauges} from "../../libraries/LibInitGauges.sol";
import {LibUpdate} from "../../libraries/LibUpdate.sol";

/**
 * @title InitPI10
 * @dev Initializes parameters for pinto improvement 10.
 **/
contract InitPI10 {
    // the minimum amount of beans needed to be sown for demand to be measured, as a % of supply.
    uint256 internal constant INIT_BEAN_SUPPLY_POD_DEMAND_SCALAR = 0.00001e6; // 0.001%
    // the amount of beans needed to be sown for demand to be measured, as a % of soil issued.
    uint256 internal constant INITIAL_SOIL_POD_DEMAND_SCALAR = 0.25e6; // 25%
    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.extEvaluationParameters.supplyPodDemandScalar = INIT_BEAN_SUPPLY_POD_DEMAND_SCALAR;
        s.sys.extEvaluationParameters.initialSoilPodDemandScalar = INITIAL_SOIL_POD_DEMAND_SCALAR;
        emit LibUpdate.UpdatedExtEvaluationParameters(
            s.sys.season.current,
            s.sys.extEvaluationParameters
        );

        LibInitGauges.initConvertUpBonusGauge(); // add the convert up bonus gauge
    }
}

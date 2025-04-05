/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";

/**
 * @title InitPI7`.
 * @dev Initializes parameters for pinto improvement set 7
 **/
contract InitPI7 {
    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        s.sys.extEvaluationParameters.supplyPodDemandScalar = 0.00001e6; // 0.001%
        s.sys.extEvaluationParameters.initialSoilPodDemandScalar = 0.25e6; // 25%
    }
}

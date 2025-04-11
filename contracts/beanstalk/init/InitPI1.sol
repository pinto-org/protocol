/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";

/**
 * @title InitPI1 sets the `rainingMinBeanMaxLpGpPerBdvRatio`.
 **/
contract InitPI1 {
    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.evaluationParameters.rainingMinBeanMaxLpGpPerBdvRatio = 33333333333333333333;
    }
}

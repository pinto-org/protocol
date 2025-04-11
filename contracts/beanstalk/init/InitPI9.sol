/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {LibInitGauges} from "../../libraries/LibInitGauges.sol";
/**
 * @title InitPI9
 * @dev Initializes parameters for pinto improvement 9.
 **/
contract InitPI9 {
    function init() external {
        LibInitGauges.initConvertUpBonusGauge(); // add the convert up bonus gauge
    }
}

/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {LibGauge} from "../../libraries/LibGauge.sol";
import {LibGaugeHelpers} from "../../libraries/LibGaugeHelpers.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";

/**
 * @title InitPI10
 * @dev Initializes parameters for pinto improvement 10.
 **/
contract InitPI10 {
    function init() external {
        initCultivationFactorGaugeV1_1();
    }

    uint256 internal constant CULTIVATION_TEMP = 0;
    uint256 internal constant PREV_SEASON_TEMP = 0;

    function initCultivationFactorGaugeV1_1() internal {
        (uint256 minDeltaCf, uint256 maxDeltaCf, uint256 minCf, uint256 maxCf) = abi.decode(
            LibGaugeHelpers.getGaugeData(GaugeId.CULTIVATION_FACTOR),
            (uint256, uint256, uint256, uint256)
        );

        // updates the gauge data to the new version, with the cultivation temperature and previous season temperature set on initialization.
        LibGaugeHelpers.updateGaugeData(
            GaugeId.CULTIVATION_FACTOR,
            abi.encode(minDeltaCf, maxDeltaCf, minCf, maxCf, CULTIVATION_TEMP, PREV_SEASON_TEMP)
        );
    }
}

/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {Gauge, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibGaugeHelpers} from "../../libraries/LibGaugeHelpers.sol";
import {IGaugeFacet} from "contracts/beanstalk/facets/sun/GaugeFacet.sol";

/**
 * @title InitPI7
 * @dev Initializes parameters for pinto improvement 7.
 **/
contract InitPI7 {
    uint256 internal constant INIT_CONVERT_DOWN_PENALTY_RATIO = 0;
    uint256 internal constant INIT_ROLLING_SEASONS_ABOVE_PEG = 0;
    uint256 internal constant ROLLING_SEASONS_ABOVE_PEG_CAP = 12;
    uint256 internal constant ROLLING_SEASONS_ABOVE_PEG_RATE = 1;

    // Excessive price threshold constant
    uint256 internal constant EXCESSIVE_PRICE_THRESHOLD = 1.025e6;

    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Update Q.
        s.sys.evaluationParameters.excessivePriceThreshold = EXCESSIVE_PRICE_THRESHOLD;

        // Initialize and add convertDownPenaltyGauge.
        Gauge memory convertDownPenaltyGauge = Gauge(
            abi.encode(INIT_CONVERT_DOWN_PENALTY_RATIO, INIT_ROLLING_SEASONS_ABOVE_PEG),
            address(this),
            IGaugeFacet.convertDownPenaltyGauge.selector,
            abi.encode(ROLLING_SEASONS_ABOVE_PEG_RATE, ROLLING_SEASONS_ABOVE_PEG_CAP)
        );
        LibGaugeHelpers.addGauge(GaugeId.CONVERT_DOWN_PENALTY, convertDownPenaltyGauge);
    }
}

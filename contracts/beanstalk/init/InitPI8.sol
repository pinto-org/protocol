/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {Gauge, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibGaugeHelpers} from "../../libraries/LibGaugeHelpers.sol";
import {IGaugeFacet} from "contracts/beanstalk/facets/sun/GaugeFacet.sol";

/**
 * @title InitPI8
 * @dev Initializes parameters for pinto improvement 8.
 **/
contract InitPI8 {
    // Gauge values
    uint256 internal constant INIT_CONVERT_UP_PENALTY_BONUS_RATIO = 0;
    uint256 internal constant INIT_SEASONS_BELOW_PEG = 0;
    // Gauge data
    uint256 internal constant INIT_DELTA_C = 2;
    uint256 internal constant INIT_MIN_DELTA_C = 1;
    uint256 internal constant INIT_MAX_DELTA_C = 0;
    uint256 internal constant INIT_PREVIOUS_SEASON_BVD_CONVERTED = 0;
    uint256 internal constant INIT_PREVIOUS_SEASON_BVD_CAPACITY = 0;

    uint256 internal constant CONVERT_BONUS_STALK_SCALAR = 0.0001e18; // 0.01% of total stalk

    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Update convertBonusStalkScalar.
        s.sys.extEvaluationParameters.convertBonusStalkScalar = CONVERT_BONUS_STALK_SCALAR;

        // Initialize and add convertDownPenaltyGauge.
        Gauge memory convertBonusGauge = Gauge(
            abi.encode(INIT_CONVERT_UP_PENALTY_BONUS_RATIO, INIT_SEASONS_BELOW_PEG),
            address(this),
            IGaugeFacet.convertUpBonusGauge.selector,
            abi.encode(
                INIT_DELTA_C,
                INIT_MIN_DELTA_C,
                INIT_MAX_DELTA_C,
                INIT_PREVIOUS_SEASON_BVD_CONVERTED,
                INIT_PREVIOUS_SEASON_BVD_CAPACITY
            )
        );
        LibGaugeHelpers.addGauge(GaugeId.CONVERT_UP_BONUS, convertBonusGauge);
    }
}

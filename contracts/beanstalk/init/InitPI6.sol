/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {Gauge, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibGaugeHelpers} from "contracts/libraries/Gauge/LibGaugeHelpers.sol";
import {IGaugeFacet} from "contracts/beanstalk/facets/sun/GaugeFacet.sol";
import {LibCases} from "../../libraries/LibCases.sol";

/**
 * @title InitPI6
 * @dev Initializes parameters for pinto improvement set 6
 **/
contract InitPI6 {
    uint256 internal constant INIT_CULTIVATION_FACTOR = 50e6; // 50%
    uint256 internal constant MIN_DELTA_CULTIVATION_FACTOR = 0.5e6; // 0.5%
    uint256 internal constant MAX_DELTA_CULTIVATION_FACTOR = 2e6; // 2%
    uint256 internal constant MIN_CULTIVATION_FACTOR = 1e6; // 1%
    uint256 internal constant MAX_CULTIVATION_FACTOR = 100e6; // 100%
    uint256 internal constant SOIL_DISTRIBUTION_PERIOD = 24 * 60 * 60; // 86400 seconds, 24 hours
    uint256 internal constant MIN_SOIL_ISSUANCE = 50e6;

    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Set soilDistributionPeriod to 24 hours (in seconds)
        s.sys.extEvaluationParameters.soilDistributionPeriod = SOIL_DISTRIBUTION_PERIOD;

        // Set minSoilIssuance to 50
        s.sys.extEvaluationParameters.minSoilIssuance = MIN_SOIL_ISSUANCE;

        // CULTIVATION FACTOR GAUGE //
        Gauge memory cultivationFactorGauge = Gauge(
            abi.encode(INIT_CULTIVATION_FACTOR),
            address(this),
            IGaugeFacet.cultivationFactor.selector,
            abi.encode(
                MIN_DELTA_CULTIVATION_FACTOR,
                MAX_DELTA_CULTIVATION_FACTOR,
                MIN_CULTIVATION_FACTOR,
                MAX_CULTIVATION_FACTOR
            )
        );

        LibGaugeHelpers.addGauge(GaugeId.CULTIVATION_FACTOR, cultivationFactorGauge);

        // Update cases, which updates the Bean2maxLpGpPerBdv decreased by 2 cases
        LibCases.setCasesV2();

        // Increase beanMaxLpGpRatioRange to 150%
        s.sys.evaluationParameters.maxBeanMaxLpGpPerBdvRatio = 150e18;

        // Update beanToMaxLpGpPerBdvRatio to 67%
        s.sys.seedGauge.beanToMaxLpGpPerBdvRatio = 67e18;
    }
}

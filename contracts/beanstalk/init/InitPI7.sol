/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import "../../libraries/LibCases.sol";
import "../../C.sol";
import "../../libraries/Silo/LibWhitelistedTokens.sol";

/**
 * @title InitPI7`.
 * @dev Initializes parameters for pinto improvement set 7
 **/
contract InitPI7 {
    uint128 constant MAX_TOTAL_GAUGE_POINTS = 2000e18;

    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Set the max total gauge points to 2000e6
        s.sys.seedGauge.maxTotalGaugePoints = MAX_TOTAL_GAUGE_POINTS;

        address[] memory whitelistedLpTokens = LibWhitelistedTokens.getWhitelistedLpTokens();
        // iterate over all the whitelisted LP tokens
        uint256 totalGaugePoints = 0;
        for (uint256 i = 0; i < whitelistedLpTokens.length; i++) {
            totalGaugePoints += s.sys.silo.assetSettings[whitelistedLpTokens[i]].gaugePoints;
        }
        // set the gauge points to the normalized gauge points
        for (uint256 i = 0; i < whitelistedLpTokens.length; i++) {
            s.sys.silo.assetSettings[whitelistedLpTokens[i]].gaugePoints = uint128(
                (uint256(s.sys.silo.assetSettings[whitelistedLpTokens[i]].gaugePoints) *
                    MAX_TOTAL_GAUGE_POINTS) / totalGaugePoints
            );
        }
    }
}

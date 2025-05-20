/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "../../libraries/LibAppStorage.sol";
import {LibUpdate} from "../../libraries/LibUpdate.sol";
import {Weather} from "../facets/sun/abstract/Weather.sol";
import {LibGauge} from "../../libraries/LibGauge.sol";
/**
 * @title InitPI8
 * @dev Updates parameters for pinto improvement 8.
 **/
contract InitPI8 {
    event BeanToMaxLpGpPerBdvRatioChange(uint256 indexed season, uint256 caseId, int80 absChange);
    uint256 internal constant MIN_SOIL_SOWN_DEMAND = 25e6; // 25

    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Update min soil sown demand. note: was removed in PI9
        // s.sys.extEvaluationParameters.minSoilSownDemand = MIN_SOIL_SOWN_DEMAND;
        // emit LibUpdate.UpdatedExtEvaluationParameters(
        //     s.sys.season.current,
        //     s.sys.extEvaluationParameters
        // );

        uint256 oldMaxBeanMaxLpGpPerBdvRatio = s.sys.seedGauge.beanToMaxLpGpPerBdvRatio;
        // get current crop ratio
        uint256 oldMaxBeanMaxLpGpPerBdvScaled = LibGauge.getBeanToMaxLpGpPerBdvRatioScaled(
            s.sys.seedGauge.beanToMaxLpGpPerBdvRatio
        );

        // increase max crop ratio to 200%
        s.sys.evaluationParameters.maxBeanMaxLpGpPerBdvRatio = 200e18;
        emit LibUpdate.UpdatedEvaluationParameters(
            s.sys.season.current,
            s.sys.evaluationParameters
        );

        // get new range
        uint256 beanMaxLpGpRatioRange = s.sys.evaluationParameters.maxBeanMaxLpGpPerBdvRatio -
            s.sys.evaluationParameters.minBeanMaxLpGpPerBdvRatio;

        // calculate the scalar such that the crop ratio is the same,
        uint256 newMaxBeanMaxLpGpPerBdvRatio = ((oldMaxBeanMaxLpGpPerBdvScaled -
            s.sys.evaluationParameters.minBeanMaxLpGpPerBdvRatio) * 100e18) / beanMaxLpGpRatioRange;

        // truncate to 18 decimals.
        newMaxBeanMaxLpGpPerBdvRatio = (newMaxBeanMaxLpGpPerBdvRatio / 1e18) * 1e18;

        // set new crop scalar.
        uint256 delta = oldMaxBeanMaxLpGpPerBdvRatio - newMaxBeanMaxLpGpPerBdvRatio;
        s.sys.seedGauge.beanToMaxLpGpPerBdvRatio = uint128(newMaxBeanMaxLpGpPerBdvRatio);
        emit BeanToMaxLpGpPerBdvRatioChange(
            s.sys.season.current,
            type(uint256).max,
            -int80(int256(delta))
        );
    }
}

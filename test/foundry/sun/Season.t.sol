// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {LibIncentive} from "contracts/libraries/LibIncentive.sol";
import {LibAppStorage, AppStorage} from "contracts/libraries/LibAppStorage.sol";

/**
 * @title SeasonTest
 */
contract SeasonTest is TestHelper {
    function setUp() public {
        initializeBeanstalkTestState(true, false);
    }

    function test_sunriseIncentive() public {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.evaluationParameters.baseReward = 5e6;

        uint256 previousReward;
        // loop from 0 to 300 seconds
        for (uint256 i; i < 300; i++) {
            uint256 reward = LibIncentive.determineReward(i);
            assertGt(reward, 0, "Reward is 0");
            assertGe(reward, previousReward, "Reward is not increasing");
            previousReward = reward;
        }
    }
}

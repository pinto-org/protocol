// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {IBean} from "contracts/interfaces/IBean.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

contract PIFloodSoilTest is TestHelper {
    // test accounts
    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        // init user.
        farmers.push(users[1]);
    }

    /*
    Season 400 soil demand was steady
    Season 399 was at block 23352127

    // in season 399, lastSowTime was 1034, which is 18 mins into the season
    // Season 400 was considered to be steady, but with the 20 minute window, it should be increasing soil demand
    // here we jump to right after that last sow, which happened at block 23352671
    */
    function test_forkBaseWhenSoilSteadyTest20MinIncreasingDemandWindow() public {
        uint256 forkBlock = 23352671 + 1; // this block is more than 10 minutes into season 399
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock);
        bs = IMockFBeanstalk(PINTO);

        // get the caseId
        uint256 caseIdBefore = jumpToNextSeasonAndGetCaseId();

        // to get the change in soil demand, caseId mod by 3.
        // 0 = decreasing, 1 = steady, 2 = increasing
        uint256 changeInSoilDemandBefore = caseIdBefore % 3;
        console.log("Change in soil demand before:", changeInSoilDemandBefore);

        // now fork off the same block, but with the upgrade.
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "");

        uint256 caseIdAfter = jumpToNextSeasonAndGetCaseId();
        uint256 changeInSoilDemandAfter = caseIdAfter % 3;
        console.log("Change in soil demand after:", changeInSoilDemandAfter);

        // verify that the caseId is different
        assertNotEq(caseIdBefore, caseIdAfter, "caseId should be different");

        // verify that the change in soil demand is different
        assertNotEq(
            changeInSoilDemandBefore,
            changeInSoilDemandAfter,
            "change in soil demand should be different"
        );
    }

    // fork at beginning of season 399, then jump to 21 minutes in and sow all soil
    // on the old system, it would considered: decreasing
    // on the new system, it should be considered: steady
    function test_forkBaseWhenSoilSteadyTest10MinSteadyWindow() public {
        uint256 forkBlock = 23352127 + 1;
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock);
        bs = IMockFBeanstalk(PINTO);

        // increase block time by 21 minutes
        vm.warp(block.timestamp + 21 * 60);

        // sow all soil
        sowBeans();

        // jump to next season and get the caseId
        uint256 caseIdBefore = jumpToNextSeasonAndGetCaseId();

        uint256 changeInSoilDemandBefore = caseIdBefore % 3;
        console.log("Change in soil demand before:", changeInSoilDemandBefore);

        // now fork off the same block, but with the upgrade.
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "");

        // increase block time by 21 minutes
        vm.warp(block.timestamp + 21 * 60);

        // sow all soil
        sowBeans();

        uint256 caseIdAfter = jumpToNextSeasonAndGetCaseId();
        uint256 changeInSoilDemandAfter = caseIdAfter % 3;
        console.log("Change in soil demand after:", changeInSoilDemandAfter);

        // verify that the caseId is different
        assertNotEq(caseIdBefore, caseIdAfter, "caseId should be different");

        // verify that the change in soil demand is different
        assertNotEq(
            changeInSoilDemandBefore,
            changeInSoilDemandAfter,
            "change in soil demand should be different"
        );
    }

    function jumpToNextSeasonAndGetCaseId() public returns (uint256 caseId) {
        // jump forward 1 hour
        vm.warp(block.timestamp + 3600);

        bytes32 expectedSig = keccak256("TemperatureChange(uint256,uint256,int8,uint256)");

        // Start recording logs to capture events
        vm.recordLogs();

        bs.sunrise();

        // Get the recorded logs
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Find the BeanToMaxLpGpPerBdvRatioChange event
        for (uint i = 0; i < entries.length; i++) {
            // The event signature for BeanToMaxLpGpPerBdvRatioChange
            if (entries[i].topics[0] == expectedSig) {
                // console.log("found event");
                // Since season is indexed, it's in topics[1]
                // caseId and absChange are in the data
                (uint256 eventCaseId, int8 absChange, uint256 fieldId) = abi.decode(
                    entries[i].data,
                    (uint256, int8, uint256)
                );
                caseId = eventCaseId;
                break;
            }
        }
    }

    // sows total soil available worth of beans (mints soil to test user)
    function sowBeans() public {
        uint256 soil = bs.totalSoil();

        uint256 beans = soil;
        vm.prank(PINTO);
        IBean(L2_PINTO).mint(users[1], soil);

        // approve spending to Pinto diamond
        vm.prank(users[1]);
        IBean(L2_PINTO).approve(address(bs), type(uint256).max);

        // sows beans
        vm.prank(users[1]);
        bs.sow(soil, 1, 0);
    }
}

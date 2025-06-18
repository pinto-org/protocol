// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import "forge-std/console.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev forks base and tests different cultivation factor scenarios
 * InitPI10Mock is used as the init facet to init the cultivation temperatures to 748.5e6 instead of 0
 **/
contract Pi10ForkTest is TestHelper {
    address farmer1 = makeAddr("farmer1");
    address farmer2 = makeAddr("farmer2");
    string constant CSV_PATH = "oscillation_data.csv";

    struct CultivationData {
        uint256 cultivationFactor;
        uint256 cultivationTemp;
        uint256 prevSeasonTemp;
    }

    function setUp() public {
        initializeBeanstalkTestState(true, false);
    }

    /////////////////// TEST FUNCTIONS ///////////////////

    function test_forkBase_cultivationFactor_parameters() public {
        bs = IMockFBeanstalk(PINTO);
        uint256 forkBlock = 31599727 - 1;
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI10");

        // assert that cultivation temp and prev season temp are 0 after upgrade, before sunrise
        CultivationData memory cultivationDataBeforeSunrise = getCultivationData();
        assertEq(cultivationDataBeforeSunrise.cultivationTemp, 0);
        assertEq(cultivationDataBeforeSunrise.prevSeasonTemp, 0);
        assertEq(
            cultivationDataBeforeSunrise.cultivationFactor,
            1e6,
            "cultivationFactor should be 1e6 (minimum cultivation factor)"
        );

        advanceToNextSeason();
        uint256 sowTemp = bs.weather().temp;
        console.log("sowTemp", sowTemp);

        // sow all soil to set cultivation temp
        sowAllAtTemp(farmer1, 0);
        // advance to next season to update gauge
        stepSeason();

        CultivationData memory data = getCultivationData();

        assertEq(
            data.cultivationTemp,
            sowTemp,
            "cultivationTemp should be equal to the temperature before sowing"
        );
        assertEq(
            data.prevSeasonTemp,
            sowTemp,
            "prevSeasonTemp should be the same as the temperature before sowing"
        );
    }

    function test_forkBase_cultivationFactor_oscillate_oneOrder() public {
        bs = IMockFBeanstalk(PINTO);
        uint256 forkBlock = 31599727 - 1;
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI10");

        uint256 temperatureBeforeUpgrade = bs.weather().temp;
        advanceToNextSeason();

        // 4 seasons of soil selling out, temp goes down to 745%
        uint256 cultivationFactorFlat;
        for (uint256 i = 0; i < 4; i++) {
            sowAllAtTemp(farmer1, 746e6);
            stepSeason();
            logSeasonData(i + 1);

            CultivationData memory data = getCultivationData();
            if (i == 3) cultivationFactorFlat = data.cultivationFactor;
        }

        // 2 seasons of no sowing, temp increases to 746%
        console.log("--------------------------------");
        console.log("2 seasons of soil not selling out, temp should be 745%");
        console.log("--------------------------------");

        for (uint256 i = 0; i < 2; i++) {
            stepSeason();
            logSeasonData(i + 1);

            CultivationData memory data = getCultivationData();
            assertEq(data.cultivationFactor, cultivationFactorFlat);
        }

        // Soil sells out again at 746%
        console.log("--------------------------------");
        console.log("Soil sells out again at 746%, cultivation factor should increase");
        console.log("--------------------------------");

        sowAllAtTemp(farmer1, 746e6);
        stepSeason();
        logSeasonData(1);

        CultivationData memory data = getCultivationData();
        assertGt(data.cultivationFactor, cultivationFactorFlat);
    }

    function test_forkBase_cultivationFactor_oscillate_twoOrders() public {
        bs = IMockFBeanstalk(PINTO);
        uint256 forkBlock = 31599727 - 1;
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI10");

        uint256 temperatureBeforeUpgrade = bs.weather().temp;
        advanceToNextSeason();

        // Initialize CSV file
        vm.writeFile(CSV_PATH, "step,season,prev_temp,cultivation_factor\n");

        // Step 1 and 2: Soil sells out above User1 limit order temp. this increases the cultivation factor, and then oscillates between 744% and 745%
        runStep1();

        // Step 3 and 4: User2 order makes cultivation factor decrease, Cultivation eventually stabilizes
        runStep3And4();
    }

    /////////////////// HELPER FUNCTIONS ///////////////////

    //////////////// TWO ORDER SIMULATION ////////////////

    function runStep1() internal returns (uint256) {
        console.log("\n");
        console.log("==========================================");
        console.log("STEP 1: INITIAL SOIL SELLING");
        console.log("User1 sows all soil for 10 seasons");
        console.log("Temperature decreases to 739%");
        console.log("==========================================");
        console.log("\n");

        uint256 cultivationFactorFlat;
        for (uint256 i = 0; i < 15; i++) {
            bool sowed = sowAllAtTemp(farmer1, 745e6);
            stepSeason();
            logSeasonData(i + 1);

            CultivationData memory data = getCultivationData();
            if (sowed) {
                writeToCSV("step1_user1_sow_all", data);
            } else {
                writeToCSV("step1_user1_no_sow", data);
            }

            if (i == 9) cultivationFactorFlat = data.cultivationFactor;
        }
        return cultivationFactorFlat;
    }

    // user 1 will alternate between no sow and full sow, due to the min temp of 740e6, but the cultivation factor should increase
    function runStep2() internal {
        console.log("\n");
        console.log("==========================================");
        console.log("STEP 2: USER1 OSCILLATION PATTERN");
        console.log("Alternating between 2 seasons no sow and 1 season full sow");
        console.log("Temperature oscillates between 739% and 740%");
        console.log("==========================================");
        console.log("\n");

        // for the next 10 seasons, we will alternate between no sow and full sow, due to the min temp of 740e6
        for (uint256 i = 0; i < 10; i++) {
            // 1 season of full sowing
            bool sowed = sowAllAtTemp(farmer1, 740e6);
            stepSeason();
            logSeasonData(i);

            CultivationData memory data = getCultivationData();
            if (sowed) {
                writeToCSV("step2_user1_oscillation_full_sow", data);
            } else {
                writeToCSV("step2_user1_oscillation_no_sow", data);
            }
        }
    }

    // a new user is sowing at a lower temp, but with a lower capacity. this will cause the cultivation factor to decrease over time
    // EVEN though there is a first sower, the cultivation factor will decrease over time because of the new order
    function runStep3And4() internal {
        console.log("\n");
        console.log("==========================================");
        console.log("STEP 3: USER2 INITIAL SOWING");
        console.log("User2 starts sowing at 737.5% temperature");
        console.log("Cultivation factor decreases until capacity is met");
        console.log("==========================================");
        console.log("\n");

        for (uint256 i = 0; i < 15; i++) {
            // original order! Sow all at any temp at 745 and up
            bool user1Sowed = sowAllAtTemp(farmer1, 745e6);

            // new order! sow 100e6 at 737
            bool user2Sowed = sowAmountAtMinTemp(farmer2, 100e6, 740e6);
            stepSeason();
            logSeasonData(i);

            CultivationData memory data = getCultivationData();
            if (user1Sowed) {
                writeToCSV("step3_user1_some_sow", data);
            }

            if (user2Sowed) {
                writeToCSV("step3_user2_some_sow", data);
            } else {
                writeToCSV("step3_user2_no_sow", data);
            }
        }
    }

    //////////////// UTILITY FUNCTIONS ////////////////

    function getCultivationData() internal view returns (CultivationData memory) {
        bytes memory cultivationFactorData = bs.getGaugeData(GaugeId.CULTIVATION_FACTOR);
        bytes memory cultivationFactorValue = bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR);

        uint256 cultivationFactor = abi.decode(cultivationFactorValue, (uint256));

        (, , , , uint256 cultivationTemp, uint256 prevSeasonTemp) = abi.decode(
            cultivationFactorData,
            (uint256, uint256, uint256, uint256, uint256, uint256)
        );

        return CultivationData(cultivationFactor, cultivationTemp, prevSeasonTemp);
    }

    function logSeasonData(uint256 iteration) internal view {
        CultivationData memory data = getCultivationData();
        console.log("Season:", bs.season());
        console.log("Temperature:", bs.weather().temp);
        console.log("Cultivation Factor:", data.cultivationFactor);
        console.log("Cultivation Temperature:", data.cultivationTemp);
        console.log("Previous Season Temperature:", data.prevSeasonTemp);
        console.log("Total Soil:", bs.totalSoil());
        console.log("--------------------------------");
    }

    function writeToCSV(string memory step, CultivationData memory data) internal {
        string memory line = string.concat(
            step,
            ",",
            vm.toString(bs.season()),
            ",",
            vm.toString(data.prevSeasonTemp),
            ",",
            vm.toString(data.cultivationFactor)
        );
        vm.writeLine(CSV_PATH, line);
    }

    function advanceToNextSeason() internal {
        vm.roll(31599727 + 10);
        vm.warp(block.timestamp + 10 seconds);
        bs.sunrise();
    }

    function sowAllAtTemp(address farmer, uint256 minTemp) internal returns (bool) {
        uint256 soil = bs.totalSoil();
        deal(L2_PINTO, farmer, soil);
        vm.startPrank(farmer);
        IERC20(L2_PINTO).approve(address(bs), soil);
        try bs.sow(soil, minTemp, uint8(LibTransfer.From.EXTERNAL)) {
            console.log("sow successful");
            return true;
        } catch {
            console.log("sow failed");
            return false;
        }
        vm.stopPrank();
    }

    function sowAmountAtMinTemp(
        address farmer,
        uint256 amount,
        uint256 minTemp
    ) internal returns (bool) {
        deal(L2_PINTO, farmer, amount);
        vm.startPrank(farmer);
        IERC20(L2_PINTO).approve(address(bs), amount);
        try bs.sowWithMin(amount, minTemp, 0, uint8(LibTransfer.From.EXTERNAL)) {
            console.log("sow successful");
            return true;
        } catch {
            console.log("sow failed");
            return false;
        }
        vm.stopPrank();
    }

    function stepSeason() internal {
        vm.warp(block.timestamp + 61 minutes);
        vm.roll(block.number + 1);
        bs.sunrise();
        // skip 301 blocks for morning auction
        vm.roll(block.number + 301);
    }
}

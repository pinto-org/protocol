// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {IBean} from "contracts/interfaces/IBean.sol";

contract PIFloodSoilTest is TestHelper {
    // test accounts
    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        // init user.
        farmers.push(users[1]);
    }

    // fork from Base when it's flooding, verify after upgrade soil is available.
    // commented out to conserve RPC requests. Fix deployed.
    /*function test_forkBaseWhenFlooding() public {
        // 23074932 is just after season 245
        forkMainnetAndUpgradeAllFacets(
            23074932 + 900, // deploy halfway into season
            vm.envString("BASE_RPC"),
            PINTO,
            "InitPI3"
        );

        bs = IMockFBeanstalk(PINTO);

        // log current deltaB and verify it's > 0
        int256 deltaB = bs.totalDeltaB();
        assertGt(deltaB, 0, "deltaB");

        // check amount of soil available
        uint256 soil = bs.totalSoil();
        assertGt(soil, 0, "soil before sunrise"); // now soil is available because of the upgrade

        warpToNextSeasonAndUpdateOracles();

        // verify soil still available after sunrise, assuming someone sows
        bs.sunrise();

        // drive price up again so it floods
        // mint USDC to well
        mintBaseUSDCToAddress(users[1], 1000000e6);
        address usdcWell = 0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1;

        addNonPintoLiquidityToWell(usdcWell, 1000000e6, users[1], USDC_BASE);

        uint256 beans = 1000000e6;
        vm.prank(PINTO);
        IBean(L2_PINTO).mint(users[1], beans * 1e5); // increase bean supply so that flood will mint something

        bs.setSoilE(beans);

        // approve spending to Pinto diamond
        vm.prank(users[1]);
        IBean(L2_PINTO).approve(address(bs), type(uint256).max);

        // sows beans
        vm.prank(users[1]);
        bs.sow(beans, 1, 0);

        // next season, still flooding, soil still available
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();

        IMockFBeanstalk.Season memory time = bs.time();
        assertEq(time.current, time.lastSopSeason, "still flooding");

        soil = bs.totalSoil();

        assertGt(soil, 0, "soil after sunrise");
    }*/

    // for Base when it's not flooding, verify soil issuance is not changed
    // commented out to conserve RPC requests. Fix deployed.
    /*function test_forkBaseWhenNotFlooding() public {
        bs = IMockFBeanstalk(PINTO);
        // for after season 308 (which happens at block 23188327)
        uint256 forkBlock = 23188327;

        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock);

        // verify soil is available
        uint256 soilBeforeUpgrade = bs.initialSoil();
        assertGt(soilBeforeUpgrade, 0, "soil before upgrade");

        forkMainnetAndUpgradeAllFacets(
            forkBlock + 1, // right away before soil was sown
            vm.envString("BASE_RPC"),
            PINTO,
            "InitPI3"
        );

        // verify same amount of soil after upgrade
        uint256 soilAfterUpgrade = bs.initialSoil();
        assertEq(soilAfterUpgrade, soilBeforeUpgrade, "soil after upgrade");
    }*/
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {PriceManipulation} from "contracts/ecosystem/tractor/utils/PriceManipulation.sol";
import {IWell} from "contracts/interfaces/basin/IWell.sol";
import {IBean} from "contracts/interfaces/IBean.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

contract PriceManipulationTest is TestHelper {
    PriceManipulation manipulation;
    address farmer;

    address constant CBBTC_WELL = 0x3e11226fe3d85142B734ABCe6e58918d5828d1b4;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        bs = IMockFBeanstalk(PINTO);

        // uint256 forkBlock = 27218527; // season 2546
        // // uint256 forkBlock = 26045631; // season 2534
        uint256 forkBlock = 28091021; // season 3030 - $0.786, 1.273236

        // Fork base at seasonBlock+1
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock - 1);
        forkMainnetAndUpgradeAllFacets(forkBlock - 1, vm.envString("BASE_RPC"), PINTO);

        // Update oracle timeouts to ensure they're not stale
        updateOracleTimeouts(L2_PINTO, false);

        // go forward to season 2547
        vm.roll(forkBlock + 1800);
        vm.warp(block.timestamp + 3600);
        // bs.sunrise();

        manipulation = new PriceManipulation(PINTO);

        farmer = createUsers(1)[0];
        vm.prank(PINTO);
        IBean(L2_PINTO).mint(farmer, 1000000000e6);
    }

    function test_aggregateInstantPrice() public {
        uint256 lastUsdcPerSPinto;
        uint256 usdcPerSPinto;

        usdcPerSPinto = manipulation.price();
        console.log("usdcPerSPinto", usdcPerSPinto);
        assertGt(usdcPerSPinto, 0, "Price is zero");
        assertApproxEqRel(usdcPerSPinto, 0.786e24, 0.005e18);
        lastUsdcPerSPinto = usdcPerSPinto;

        // Decrease price in one well.
        {
            uint256 swapAmount = 10_000e6;
            vm.prank(farmer);
            IERC20(L2_PINTO).approve(CBBTC_WELL, swapAmount);
            vm.prank(farmer);
            IWell(CBBTC_WELL).swapFrom(
                IERC20(L2_PINTO),
                IERC20(CBBTC),
                swapAmount,
                0,
                farmer,
                type(uint256).max
            );
        }
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 200);
        IWell(CBBTC_WELL).sync(0x0000000000000000000000000000000000000001, 0);
        usdcPerSPinto = manipulation.price();
        assertLt(usdcPerSPinto, lastUsdcPerSPinto, "Price should decrease from swap");
        lastUsdcPerSPinto = usdcPerSPinto;

        // The EMA price will decrease with time as it trends towards the lower current price.
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 200);
        IWell(CBBTC_WELL).sync(0x0000000000000000000000000000000000000001, 0);
        usdcPerSPinto = manipulation.price();
        assertLt(usdcPerSPinto, lastUsdcPerSPinto, "EMA price decrease from time passing");
        lastUsdcPerSPinto = usdcPerSPinto;

        // Increase the price in the same well.
        {
            uint256 swapAmount = IERC20(CBBTC).balanceOf(farmer);
            vm.prank(farmer);
            IERC20(CBBTC).approve(CBBTC_WELL, swapAmount);
            vm.prank(farmer);
            IWell(CBBTC_WELL).swapFrom(
                IERC20(CBBTC),
                IERC20(L2_PINTO),
                swapAmount,
                0,
                farmer,
                type(uint256).max
            );
        }
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 200);
        IWell(CBBTC_WELL).sync(0x0000000000000000000000000000000000000001, 0);
        usdcPerSPinto = manipulation.price();
        assertGt(usdcPerSPinto, lastUsdcPerSPinto, "Price should increase from swap");
        lastUsdcPerSPinto = usdcPerSPinto;

        // The EMA price will increase with time as it trends towards the higher current price.
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 200);
        IWell(CBBTC_WELL).sync(0x0000000000000000000000000000000000000001, 0);
        usdcPerSPinto = manipulation.price();
        assertGt(usdcPerSPinto, lastUsdcPerSPinto, "EMA price increase from time passing");
        lastUsdcPerSPinto = usdcPerSPinto;
    }
}

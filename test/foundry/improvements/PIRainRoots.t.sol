// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {IBean} from "contracts/interfaces/IBean.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import "forge-std/console.sol";

contract PIRainRootsTest is TestHelper {
    // test accounts
    address[] farmers;

    int96[] convertStems;
    uint256[] convertAmounts;

    address constant PINTO_WETH_LP = 0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3;
    address constant PINTO_TOKEN = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        // user with rain roots that has 1 weth lp deposit
        // with stem 36585340 and amount 8447100668507073527
        // and 9 pinto deposits totalling 1575_964187 pinto
        address userWithDeposits = address(0x197440C1cE6B6adE640694E3e2aAd17e11aE4A45);
        farmers.push(userWithDeposits);
        // random user
        farmers.push(users[1]);
    }

    // fork from Base when it's flooding,
    // verify after upgrade that you can transfer and convert without losing rain roots
    // commented out to conserve RPC requests. Fix deployed.
    /*function test_forkBaseTransferRainRootsWhenFlooding(uint256 amountToTransfer) public {
        // 23074932 is just after season 245
        forkMainnetAndUpgradeAllFacets(
            23074932 + 900, // deploy halfway into season
            vm.envString("BASE_RPC"),
            PINTO,
            "InitPI3"
        );

        bs = IMockFBeanstalk(PINTO);
        bs.mow(farmers[0], PINTO_WETH_LP);

        uint256 user1RainRootsBefore = bs.balanceOfRainRoots(farmers[0]);
        uint256 user2RainRootsBefore = bs.balanceOfRainRoots(farmers[1]);
        uint256 user1RootsBefore = bs.balanceOfRoots(farmers[0]);
        uint256 user2RootsBefore = bs.balanceOfRoots(farmers[1]);
        // bound amount between 0 and the deposit amount
        amountToTransfer = bound(amountToTransfer, 1, 8447100668507073527);
        int96 depositStem = 36585340;

        // get totals
        uint256 totalRainRootsBefore = bs.totalRainRoots();
        uint256 totalRootsBefore = bs.totalRoots();

        assertGt(user1RainRootsBefore, 0);
        assertEq(user2RainRootsBefore, 0);

        // log input to transfer function
        console.log("user1RainRoots before: ", user1RainRootsBefore);
        console.log("user2RainRoots before: ", user2RainRootsBefore);
        console.log("user1Roots before: ", user1RootsBefore);
        console.log("user2Roots before: ", user2RootsBefore);
        console.log("amount to transfer from user 1: ", amountToTransfer);

        vm.prank(farmers[0]);
        bs.transferDeposit(farmers[0], farmers[1], PINTO_WETH_LP, depositStem, amountToTransfer);
        bs.mow(farmers[1], PINTO_WETH_LP);

        uint256 user1RainRootsAfter = bs.balanceOfRainRoots(farmers[0]);
        uint256 user2RainRootsAfter = bs.balanceOfRainRoots(farmers[1]);
        uint256 user1RootsAfter = bs.balanceOfRoots(farmers[0]);
        uint256 user2RootsAfter = bs.balanceOfRoots(farmers[1]);

        // log output of transfer function
        console.log("user1RainRoots after: ", user1RainRootsAfter);
        console.log("user2RainRoots after: ", user2RainRootsAfter);
        console.log("user1Roots after: ", user1RootsAfter);
        console.log("user2Roots after: ", user2RootsAfter);

        if (user1RainRootsBefore < user1RootsAfter) {
            // if the user sends less than half of his original deposit,
            // then he does not transfer any rain roots so balances stay the same as before snapshot
            console.log("user1RainRootsBefore < user1RootsAfter");
            assertEq(bs.balanceOfRainRoots(farmers[0]), user1RainRootsBefore);
            assertEq(bs.balanceOfRainRoots(farmers[1]), user2RainRootsBefore);
        } else {
            // if the user sends more than half of his original deposit amount,
            // then he transfers his difference of rain roots to the recipient
            console.log("user1RainRootsBefore >= user1RootsAfter");
            uint256 deltaRoots = user1RainRootsBefore - user1RootsAfter;
            assertEq(bs.balanceOfRainRoots(farmers[0]), user1RainRootsBefore - deltaRoots);
            assertEq(bs.balanceOfRainRoots(farmers[1]), user2RainRootsBefore + deltaRoots);
        }

        // total rain roots stay the same
        assertEq(totalRainRootsBefore, bs.totalRainRoots());

        // total roots stay the same
        assertEq(totalRootsBefore, bs.totalRoots());
    }*/

    // fork from Base when it's flooding, verify after upgrade that you can convert
    // from pinto --> lp multiple deposits without losing rain roots
    // commented out to conserve RPC requests. Fix deployed.
    /*function test_forkBaseConvertWhenFloodingDoesNotLoseRainRoots() public {
        // 23074932 is just after season 245
        forkMainnetAndUpgradeAllFacets(
            23074932 + 900, // deploy halfway into season
            vm.envString("BASE_RPC"),
            PINTO,
            "InitPI3"
        );

        bs = IMockFBeanstalk(PINTO);
        bs.mow(farmers[0], BEAN);

        // get pinto deposits to convert to lp
        IMockFBeanstalk.TokenDepositId memory tokenDepId = bs.getTokenDepositsForAccount(
            farmers[0],
            PINTO_TOKEN
        );
        for (uint256 i = 0; i < tokenDepId.depositIds.length; i++) {
            (address token, int96 stem) = bs.getAddressAndStem(tokenDepId.depositIds[i]);
            convertAmounts.push(tokenDepId.tokenDeposits[i].amount);
            convertStems.push(stem);
        }

        uint256 user1RainRootsBefore = bs.balanceOfRainRoots(farmers[0]);
        uint256 user2RainRootsBefore = bs.balanceOfRainRoots(farmers[1]);
        uint256 user1RootsBefore = bs.balanceOfRoots(farmers[0]);
        uint256 user2RootsBefore = bs.balanceOfRoots(farmers[1]);

        // get totals
        uint256 totalRainRootsBefore = bs.totalRainRoots();

        assertGt(user1RainRootsBefore, 0);
        assertEq(user2RainRootsBefore, 0);

        // log input to transfer function
        console.log("user1RainRoots before: ", user1RainRootsBefore);

        address[] memory wells = bs.getWhitelistedWellLpTokens();

        // convert beans to well
        vm.startPrank(farmers[0]);
        for (uint256 i = 0; i < convertStems.length; i++) {
            console.log("converting deposit: ", i);
            console.log("convert stem: ", convertStems[i]);
            console.log("convert amount: ", convertAmounts[i]);
            int96[] memory stems = new int96[](1);
            stems[0] = convertStems[i];
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = convertAmounts[i];
            // pick a random well by doing mod 5
            address well = wells[i % 5];
            // create encoding for a bean -> well convert.
            bytes memory convertData = convertEncoder(
                LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
                well, // well
                convertAmounts[i], // amountIn
                0 // minOut
            );
            // perform the convert
            bs.convert(convertData, stems, amounts);
        }
        vm.stopPrank();

        uint256 user1RainRootsAfter = bs.balanceOfRainRoots(farmers[0]);

        // log output of transfer function
        console.log("user1RainRoots after: ", user1RainRootsAfter);

        // user should not lose rain roots
        assertEq(user1RainRootsBefore, user1RainRootsAfter);

        // total rain roots stay the same
        assertEq(totalRainRootsBefore, bs.totalRainRoots());
    }*/
}

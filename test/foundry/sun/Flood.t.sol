// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {IWell, IERC20, Call} from "contracts/interfaces/basin/IWell.sol";
import {MockPump} from "contracts/mocks/well/MockPump.sol";
import {MockFieldFacet} from "contracts/mocks/mockFacets/MockFieldFacet.sol";
import {MockSiloFacet} from "contracts/mocks/mockFacets/MockSiloFacet.sol";
import {SeasonGettersFacet} from "contracts/beanstalk/facets/sun/SeasonGettersFacet.sol";
import {SiloGettersFacet} from "contracts/beanstalk/facets/silo/SiloGettersFacet.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {Season} from "contracts/beanstalk/storage/System.sol";
import {Rain} from "contracts/beanstalk/storage/System.sol";
import {LibFlood} from "contracts/libraries/Silo/LibFlood.sol";

/**
 * @title FloodTest
 * @notice Tests the `flood` functionality.
 */
contract FloodTest is TestHelper {
    // Interfaces.
    SeasonGettersFacet seasonGetters = SeasonGettersFacet(BEANSTALK);
    MockFieldFacet field = MockFieldFacet(BEANSTALK);
    SiloGettersFacet siloGetters = SiloGettersFacet(BEANSTALK);
    MockSiloFacet silo = MockSiloFacet(BEANSTALK);

    // test accounts
    address[] farmers;
    int96 depositStemBean;

    uint256 constant DEPOSIT_AMOUNT = 1000e6;

    event SeasonOfPlentyWell(
        uint256 indexed season,
        address well,
        address token,
        uint256 amount,
        uint256 beans
    );
    event SeasonOfPlentyField(uint256 toField);
    event RainStatus(uint256 indexed season, bool raining);

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        // init user.
        farmers.push(users[1]);
        vm.prank(farmers[0]);
        bean.approve(BEANSTALK, type(uint256).max);

        // Initialize well to balances. (1000 BEAN/ETH)
        addLiquidityToWell(
            BEAN_ETH_WELL,
            1000000e6, // 10,000 Beans
            1000 ether // 10 ether.
        );

        addLiquidityToWell(
            BEAN_WSTETH_WELL,
            10000e6, // 10,000 Beans
            10 ether // 10 ether.
        );

        season.siloSunrise(0);
        season.siloSunrise(0);

        depositStemBean = bs.stemTipForToken(BEAN);

        // users 1 and 2 deposits 1000 beans into the silo.
        address[] memory depositUsers = new address[](2);
        depositUsers[0] = users[1];
        depositUsers[1] = users[2];
        depositBeansForUsers(depositUsers, DEPOSIT_AMOUNT, 10_000e6, true);

        // give user2 some eth
        vm.deal(users[2], 10 ether);
    }

    function testBugReportLostPlenty2() public {
        season.rainSunrise();
        bs.mow(users[1], BEAN);
        season.rainSunrise();
        bs.mow(users[1], BEAN);

        // set reserves so next season plenty is accrued
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        season.rainSunrise(); // 1st actual sop
        bs.mow(users[1], BEAN);

        season.rainSunrise();
        season.rainSunrise();

        season.droughtSunrise();
        season.droughtSunrise();

        // withdraw deposit
        vm.prank(users[1]);
        bs.withdrawDeposit(BEAN, depositStemBean, 1_000e6, 0);

        season.rainSunrise();
        bs.mow(users[1], BEAN);

        uint256 userPlenty = bs.balanceOfPlenty(users[1], BEAN_ETH_WELL);
        assertEq(userPlenty, 25595575914848452999);
    }

    function testReducesRainRootsUponWithdrawal() public {
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        season.rainSunrise();
        season.rainSunrise();

        bs.mow(users[1], BEAN);

        uint256 rainRoots = bs.balanceOfRainRoots(users[1]);

        assertEq(rainRoots, 10004000000000000000000000000000);

        vm.prank(users[1]);
        bs.withdrawDeposit(BEAN, depositStemBean, 1_000e6, 0);

        rainRoots = bs.balanceOfRainRoots(users[1]);

        assertEq(rainRoots, 0);
    }

    function testStopsRainingAndWithdraw() public {
        int96 stem = bs.stemTipForToken(BEAN);
        address[] memory testUsers = new address[](1);

        testUsers[0] = users[3];
        depositBeansForUsers(testUsers, 50_000e6, 100_000e6, false);

        // set reserves so that a sop will occur
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        season.rainSunrise();
        bs.mow(users[3], BEAN);

        uint256 rainRoots = bs.balanceOfRainRoots(users[3]);
        assertEq(rainRoots, 500000000000000000000000000000000);

        season.droughtSunrise();

        // withdraw
        vm.prank(users[3]);
        bs.withdrawDeposit(BEAN, stem, 50_000e6, 0);
        rainRoots = bs.balanceOfRainRoots(users[3]);
        assertEq(rainRoots, 0);

        // start raining again
        season.rainSunrise();
        season.rainSunrise();
        bs.mow(users[3], BEAN);
        rainRoots = bs.balanceOfRainRoots(users[3]);
        assertEq(rainRoots, 0);

        // measure actual roots
        uint256 roots = bs.balanceOfRoots(users[3]);
        assertEq(roots, 0);
    }

    function testRainStatusEvent() public {
        Season memory s = seasonGetters.time();
        assertFalse(s.raining);

        // Increase Bean price over peg
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setReserves(BEAN_WSTETH_WELL, 1000000e6, 1200e18);

        warpToNextSeasonAndUpdateOracles();
        bs.sunrise(); // not raining, caseId 108

        warpToNextSeasonAndUpdateOracles();
        vm.expectEmit();
        emit RainStatus(7, true);
        bs.sunrise(); // raining, caseId 114

        // Decrease Bean price under peg
        setReserves(BEAN_ETH_WELL, 1000000e6, 900e18);
        setReserves(BEAN_WSTETH_WELL, 1000000e6, 900e18);

        warpToNextSeasonAndUpdateOracles();
        vm.expectEmit();
        emit RainStatus(8, false);
        bs.sunrise(); // not raining, 108
    }

    function testTransferRainRootsUponTransfer() public {
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        season.rainSunrise(); // start raining
        season.rainSunrise(); // sop

        bs.mow(users[1], BEAN);

        uint256 rainRoots = bs.balanceOfRainRoots(users[1]);

        assertEq(rainRoots, 10004000000000000000000000000000);

        vm.prank(users[1]);
        // user[1] transfers the whole bean deposit to user[3]
        bs.transferDeposit(users[1], users[3], BEAN, depositStemBean, 1_000e6);
        bs.mow(users[1], BEAN);

        // user[1] should have 0 rain roots
        assertEq(bs.balanceOfRainRoots(users[1]), 0);
        // user[3] should have the previous rain roots of user[1]
        assertEq(bs.balanceOfRainRoots(users[3]), 10004000000000000000000000000000);
    }

    function testTransfersHalfOfRainRootsUponHalfTransfer() public {
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        season.rainSunrise(); // start raining
        season.rainSunrise(); // sop

        bs.mow(users[1], BEAN);

        uint256 rainRoots = bs.balanceOfRainRoots(users[1]);

        assertEq(rainRoots, 10004000000000000000000000000000);

        vm.prank(users[1]);
        bs.transferDeposit(users[1], users[3], BEAN, depositStemBean, 500e6);
        bs.mow(users[1], BEAN);

        // user[1] should be down by 500 rain roots
        assertEq(bs.balanceOfRainRoots(users[1]), 5004000000000000000000000000000);
        // user[3] should have 500 rain roots
        assertEq(bs.balanceOfRainRoots(users[3]), 5000000000000000000000000000000);
    }

    function testFuzzTransferRainRoots(
        uint256 amountToSend,
        uint256 amountOfRainRootsToReduce
    ) public {
        // bound amount between 0 and the original deposit in setUp
        amountToSend = bound(amountToSend, 1, DEPOSIT_AMOUNT);

        // bound rain roots reduce amount between 0 and the original user[1] rain roots
        amountOfRainRootsToReduce = bound(
            amountOfRainRootsToReduce,
            0,
            10004000000000000000000000000000
        );

        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        season.rainSunrise(); // start raining
        season.rainSunrise(); // sop

        // mow both deposit users to get rain roots
        bs.mow(users[1], BEAN);
        bs.mow(users[2], BEAN);
        bs.mow(users[3], BEAN);

        // roots before were 10008000000000000000000000000000
        // rain roots before were 10004000000000000000000000000000
        silo.reduceAccountRainRoots(users[1], amountOfRainRootsToReduce);

        // snapshot state before transfer
        uint256 user1RainRootsBefore = bs.balanceOfRainRoots(users[1]);
        uint256 user3RainRootsBefore = bs.balanceOfRainRoots(users[3]);
        uint256 user1RootsBefore = bs.balanceOfRoots(users[1]);
        uint256 user3RootsBefore = bs.balanceOfRoots(users[3]);
        // totals
        uint256 totalRainRootsBefore = bs.totalRainRoots();
        uint256 totalRootsBefore = bs.totalRoots();

        // transfer
        vm.prank(users[1]);
        bs.transferDeposit(users[1], users[3], BEAN, depositStemBean, amountToSend);
        bs.mow(users[1], BEAN);

        // re-fetch the state after transfer
        uint256 user1RootsAfter = bs.balanceOfRoots(users[1]);
        uint256 user3RootsAfter = bs.balanceOfRoots(users[3]);
        uint256 user1RainRootsAfter = bs.balanceOfRainRoots(users[1]);
        uint256 user3RainRootsAfter = bs.balanceOfRainRoots(users[3]);
        uint256 totalRainRootsAfter = bs.totalRainRoots();
        uint256 totalRootsAfter = bs.totalRoots();

        // total rain roots stay the same
        assertEq(totalRainRootsAfter, totalRainRootsBefore);

        // total roots stay the same
        assertEq(totalRootsAfter, totalRootsBefore);

        // the summation of the rain roots of these 3 accounts should be equal to the total rain roots before
        // (that are the same as after) since these are the only accounts that could have rain roots
        assertEq(
            bs.balanceOfRainRoots(users[1]) +
                bs.balanceOfRainRoots(users[2]) +
                bs.balanceOfRainRoots(users[3]),
            totalRainRootsBefore
        );

        // the summation of the rain roots of the transfer accounts
        // should be equal to the summation of their rain roots before the transfer
        assertEq(
            user1RainRootsBefore + user3RainRootsBefore,
            user1RainRootsAfter + user3RainRootsAfter
        );

        if (user1RainRootsBefore < user1RootsAfter) {
            // if the user sends less than half of his original 1000e6 bean deposit,
            // then he does not transfer any rain roots so balances stay the same as before snapshot
            assertEq(bs.balanceOfRainRoots(users[1]), user1RainRootsBefore);
            assertEq(bs.balanceOfRainRoots(users[3]), user3RainRootsBefore);
        } else {
            // if the user sends more than half of his original 1000e6 bean deposit,
            // then he transfers his difference of rain roots to the recipient
            uint256 deltaRoots = user1RainRootsBefore - user1RootsAfter;
            assertEq(bs.balanceOfRainRoots(users[1]), user1RainRootsBefore - deltaRoots);
            assertEq(bs.balanceOfRainRoots(users[3]), user3RainRootsBefore + deltaRoots);
        }
    }

    function testDoesNotBurnRainRootsUponTransferIfExtraRootsAvailable() public {
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        season.rainSunrise(); // start raining
        season.rainSunrise(); // sop

        bs.mow(users[1], BEAN);

        uint256 rainRoots = bs.balanceOfRainRoots(users[1]);

        assertEq(rainRoots, 10004000000000000000000000000000);

        // do another deposit
        vm.prank(users[1]);
        bs.deposit(BEAN, 1_000e6, 0);

        // pass germination
        season.siloSunrise(0);
        season.siloSunrise(0);

        // verify roots went up
        assertEq(bs.balanceOfRoots(users[1]), 20008000000000000000000000000000);

        // verify rain roots stayed the same
        assertEq(bs.balanceOfRainRoots(users[1]), 10004000000000000000000000000000);

        vm.prank(users[1]);
        bs.transferDeposit(users[1], users[3], BEAN, depositStemBean, 500e6);
        bs.mow(users[1], BEAN);

        // user should have full rain roots, since they had non-rain roots that could be removed before
        assertEq(bs.balanceOfRainRoots(users[1]), 10004000000000000000000000000000);
    }

    function testGerminationRainRoots() public {
        bean.mint(users[3], 50_000e6);
        vm.prank(users[3]);
        bean.approve(BEANSTALK, type(uint256).max);
        vm.prank(users[3]);
        bs.deposit(BEAN, 50_000e6, 0);

        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        season.rainSunrise();

        season.rainSunrise();
        bs.mow(users[3], BEAN);

        uint256 totalRainRoots = bs.totalRainRoots();
        uint256 userRainRoots = bs.balanceOfRainRoots(users[3]);
        // expect user rain roots to be less than total rain roots
        assertLt(userRainRoots, totalRainRoots);

        // also rain roots should be zero
        assertEq(userRainRoots, 0);
    }

    function testSecondGerminationRainRoots() public {
        // not raining

        season.rainSunrise(); // start raining

        uint256 totalRainRootsBefore = bs.totalRainRoots();

        bean.mint(users[3], 50_000e6);
        vm.prank(users[3]);
        bean.approve(BEANSTALK, type(uint256).max);
        vm.prank(users[3]);
        bs.deposit(BEAN, 50_000e6, 0);
        // set reserves so we'll sop
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        season.rainSunrise(); // sop
        bs.mow(users[3], BEAN);

        uint256 totalRainRootsAfter = bs.totalRainRoots();
        // rain roots before should equal rain roots after, anything deposited after raining doesn't count
        assertEq(
            totalRainRootsBefore,
            totalRainRootsAfter,
            "total rain roots before and after should be equal"
        );

        uint256 userRainRoots = bs.balanceOfRainRoots(users[3]);

        // assert that user rain roots are zero
        assertEq(userRainRoots, 0, "user rain roots should be zero");

        // shouldn't be a way for a user to get more rain roots than total rain roots
        // couldn't find a way to do lessThan without importing something else that supports BigNumber from chai
        assertLt(
            userRainRoots,
            totalRainRootsAfter,
            "user rain roots should be less than total rain roots"
        );
    }

    function testNotRaining() public view {
        Season memory s = seasonGetters.time();
        assertFalse(s.raining);
    }

    function testRaining() public {
        // verify the beanToMaxLpGpPerBdvRatio is not zero before raining
        assertGt(bs.getBeanToMaxLpGpPerBdvRatio(), 0);
        field.incrementTotalPodsE(1000e18, bs.activeField());
        season.rainSunrise();
        bs.mow(users[1], BEAN);

        Rain memory rain = seasonGetters.rain();
        Season memory s = seasonGetters.time();

        assertEq(s.rainStart, s.current);
        assertTrue(s.raining);
        assertEq(rain.pods, bs.totalPods(bs.activeField()));
        assertEq(rain.roots, 20008000e24);

        SiloGettersFacet.AccountSeasonOfPlenty memory sop = siloGetters.balanceOfSop(users[1]);

        assertEq(sop.lastRain, s.rainStart);
        assertEq(sop.roots, 10004000e24);

        // verify the beanToMaxLpGpPerBdvRatio is zero after rain starts
        assertEq(bs.getBeanToMaxLpGpPerBdvRatio(), 0);
    }

    function testStopsRaining() public {
        field.incrementTotalPodsE(1000e18, bs.activeField());
        season.rainSunrise();
        bs.mow(users[1], BEAN);

        season.droughtSunrise();
        bs.mow(users[1], BEAN);

        Season memory s = seasonGetters.time();
        assertEq(s.rainStart, s.current - 1);

        SiloGettersFacet.AccountSeasonOfPlenty memory sop = siloGetters.balanceOfSop(users[1]);
        assertEq(sop.lastRain, 0);
    }

    function testSopsWhenAtPeg() public {
        season.siloSunrise(25);
        Season memory s = seasonGetters.time();

        assertEq(s.lastSop, 0);
        assertEq(s.lastSopSeason, 0);
    }

    function testSopsBelowPeg() public {
        setDeltaBforWell(-1000e6, BEAN_ETH_WELL, WETH);
        season.siloSunrise(25);

        Season memory s = seasonGetters.time();
        assertEq(s.lastSop, 0);
        assertEq(s.lastSopSeason, 0);
    }

    function testOneSop() public {
        assertGt(bs.getBeanToMaxLpGpPerBdvRatio(), 0);

        address sopWell = BEAN_ETH_WELL;
        setReserves(sopWell, 1000000e6, 1100e18);

        // there's only one well, so sop amount into that well will be the current deltaB
        int256 currentDeltaB = bs.poolCurrentDeltaB(sopWell);

        // getSwapOut for how much Beanstalk will get for swapping this amount of beans
        uint256 amountOut = IWell(sopWell).getSwapOut(
            IERC20(BEAN),
            IERC20(WETH),
            uint256(currentDeltaB)
        );

        // take this amount out, multiply by sop precision then divide by rain roots (current roots)
        uint256 userCalcPlentyPerRoot = (amountOut * C.SOP_PRECISION) / bs.totalRoots(); // 2558534177813719812

        // user plenty will be plenty per root * user roots
        uint256 userCalcPlenty = (userCalcPlentyPerRoot * bs.balanceOfRoots(users[1])) /
            C.SOP_PRECISION; // 25595575914848452999

        season.rainSunrise();

        // verify the beanToMaxLpGpPerBdvRatio is zero after rain starts
        assertEq(bs.getBeanToMaxLpGpPerBdvRatio(), 0);

        bs.mow(users[1], BEAN);

        vm.expectEmit();
        emit SeasonOfPlentyField(0); // zero in this test since no beans in podline

        vm.expectEmit();
        emit SeasonOfPlentyWell(
            seasonGetters.time().current + 1, // flood will happen next season
            sopWell,
            WETH,
            51191151829696906017,
            48808848170
        );

        season.rainSunrise();

        Season memory s = seasonGetters.time();

        assertEq(s.lastSop, s.rainStart);
        assertEq(s.lastSopSeason, s.current);
        // check weth balance of beanstalk
        assertEq(IERC20(WETH).balanceOf(BEANSTALK), 51191151829696906017);
        // after the swap, the composition of the pools are
        uint256[] memory balances = IWell(sopWell).getReserves();
        assertEq(balances[0], 1048808848170);
        assertEq(balances[1], 1048808848170303093983);

        // tracks user plenty before update
        uint256 userPlenty = bs.balanceOfPlenty(users[1], sopWell);
        assertEq(userPlenty, userCalcPlenty);

        // tracks user plenty after update
        bs.mow(users[1], BEAN);

        SiloGettersFacet.AccountSeasonOfPlenty memory userSop = siloGetters.balanceOfSop(users[1]);
        assertEq(userSop.lastRain, 6);
        assertEq(userSop.lastSop, 6);
        assertEq(userSop.roots, 10004000e24);

        assertGt(userSop.farmerSops.length, 0);

        assertEq(userSop.farmerSops[0].well, sopWell);
        assertEq(userSop.farmerSops[0].wellsPlenty.plenty, userCalcPlenty);
        assertEq(userSop.farmerSops[0].wellsPlenty.plentyPerRoot, userCalcPlentyPerRoot);

        // each user should get half of the eth gained
        assertEq(bs.balanceOfPlenty(users[2], sopWell), userCalcPlenty);

        // tracks user2 plenty after update
        bs.mow(users[2], BEAN);
        userSop = siloGetters.balanceOfSop(users[2]);
        assertEq(userSop.lastRain, 6);
        assertEq(userSop.lastSop, 6);
        assertEq(userSop.roots, 10004000e24);
        assertEq(userSop.farmerSops[0].well, sopWell);
        assertEq(userSop.farmerSops[0].wellsPlenty.plenty, userCalcPlenty);
        assertEq(userSop.farmerSops[0].wellsPlenty.plentyPerRoot, userCalcPlentyPerRoot);

        // claims user plenty
        bs.mow(users[2], BEAN);
        vm.prank(users[2]);
        bs.claimPlenty(sopWell, 0);
        assertEq(bs.balanceOfPlenty(users[2], sopWell), 0);
        assertEq(IERC20(WETH).balanceOf(users[2]), userCalcPlenty);
    }

    function testMultipleSop() public {
        address sopWell = BEAN_ETH_WELL;
        setReserves(sopWell, 1000000e6, 1100e18);
        assertGt(bs.getBeanToMaxLpGpPerBdvRatio(), 0);

        season.rainSunrise();

        assertEq(bs.getBeanToMaxLpGpPerBdvRatio(), 0);
        bs.mow(users[2], BEAN);
        season.rainSunrise();
        season.droughtSunrise();

        setReserves(sopWell, 1048808848170, 1100e18);

        vm.expectEmit();
        emit SeasonOfPlentyField(0); // zero in this test since no beans in podline

        vm.expectEmit();
        emit SeasonOfPlentyWell(
            seasonGetters.time().current + 2, // flood will happen in two seasons
            sopWell,
            WETH,
            25900501355272002583,
            25290650473
        );

        season.rainSunrises(2);

        // sops p > 1
        Season memory s = seasonGetters.time();
        uint256[] memory reserves = IWell(sopWell).getReserves();

        assertEq(s.lastSop, s.rainStart);
        assertEq(s.lastSopSeason, s.current);
        assertEq(IERC20(WETH).balanceOf(BEANSTALK), 77091653184968908600);

        assertEq(reserves[0], 1074099498643);
        assertEq(reserves[1], 1074099498644727997417);

        // tracks user plenty before update
        uint256 userPlenty = bs.balanceOfPlenty(users[1], sopWell);
        assertEq(userPlenty, 38544532214605630101);

        // tracks user plenty after update
        bs.mow(users[1], sopWell);
        SiloGettersFacet.AccountSeasonOfPlenty memory userSop = siloGetters.balanceOfSop(users[1]);

        assertEq(userSop.lastRain, 9);
        assertEq(userSop.lastSop, 9);
        assertEq(userSop.roots, 10004000e24);
        assertEq(userSop.farmerSops[0].well, sopWell);
        assertEq(userSop.farmerSops[0].wellsPlenty.plenty, 38544532214605630101);
        assertEq(userSop.farmerSops[0].wellsPlenty.plentyPerRoot, 3852912056637907847);

        // tracks user2 plenty
        uint256 user2Plenty = bs.balanceOfPlenty(users[2], sopWell);
        assertEq(user2Plenty, 38547120970363278477);

        // tracks user2 plenty after update
        bs.mow(users[2], sopWell);
        userSop = siloGetters.balanceOfSop(users[2]);
        assertEq(userSop.lastRain, 9);
        assertEq(userSop.lastSop, 9);
        assertEq(userSop.roots, 10006000e24);
        assertEq(userSop.farmerSops[0].wellsPlenty.plenty, 38547120970363278477);
        assertEq(userSop.farmerSops[0].wellsPlenty.plentyPerRoot, 3852912056637907847);
    }

    function testWithCurrentBalances() public {
        address sopWell = BEAN_ETH_WELL;
        setReserves(sopWell, 1_000_000e6, 1_100e18);

        // set instantaneous reserves differently
        setInstantaneousReserves(sopWell, 900_000e6, 1_100e18);

        season.rainSunrise();
        bs.mow(users[2], sopWell);

        vm.expectEmit();
        emit SeasonOfPlentyField(0); // zero in this test since no beans in podline

        vm.expectEmit();
        emit SeasonOfPlentyWell(
            seasonGetters.time().current + 1, // flood will happen in two seasons
            sopWell,
            WETH,
            51191151829696906017,
            48808848170
        );

        season.rainSunrise();
        // end before each from hardhat test

        // sops p > 1
        Season memory s = seasonGetters.time();
        uint256[] memory reserves = IWell(sopWell).getReserves();

        assertEq(s.lastSop, s.rainStart);
        assertEq(s.lastSopSeason, s.current);
        assertEq(IERC20(WETH).balanceOf(BEANSTALK), 51191151829696906017);

        assertEq(reserves[0], 1048808848170);
        assertEq(reserves[1], 1048808848170303093983);

        // tracks user plenty before update
        uint256 userPlenty = bs.balanceOfPlenty(users[1], sopWell);
        assertEq(userPlenty, 25595575914848452999);

        // tracks user plenty after update
        bs.mow(users[1], BEAN);
        SiloGettersFacet.AccountSeasonOfPlenty memory userSop = siloGetters.balanceOfSop(users[1]);

        assertEq(userSop.lastRain, 6);
        assertEq(userSop.lastSop, 6);
        assertEq(userSop.roots, 10004000e24);
        assertEq(userSop.farmerSops[0].wellsPlenty.plenty, 25595575914848452999);
        assertEq(userSop.farmerSops[0].wellsPlenty.plentyPerRoot, 2558534177813719812);

        // tracks user2 plenty
        uint256 user2Plenty = bs.balanceOfPlenty(users[2], sopWell);
        assertEq(user2Plenty, 25595575914848452999);

        // tracks user2 plenty after update
        bs.mow(users[2], sopWell);
        userSop = siloGetters.balanceOfSop(users[2]);
        assertEq(userSop.lastRain, 6);
        assertEq(userSop.lastSop, 6);
        assertEq(userSop.roots, 10004000e24);
        assertEq(userSop.farmerSops[0].wellsPlenty.plenty, 25595575914848452999);
        assertEq(userSop.farmerSops[0].wellsPlenty.plentyPerRoot, 2558534177813719812);

        // claims user plenty
        bs.mow(users[2], sopWell);
        vm.prank(users[2]);
        bs.claimPlenty(sopWell, 0);
        assertEq(bs.balanceOfPlenty(users[2], sopWell), 0);
        assertEq(IERC20(WETH).balanceOf(users[2]), 25595575914848452999);
    }

    function testSopUsingRealSunrise() public {
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);
        setReserves(BEAN_WSTETH_WELL, 1000000e6, 1200e18);

        // mints beans to first test user
        uint256 beans = 1000000e6;
        bean.mint(users[1], beans * 1e5); // increase bean supply so that flood will mint something
        season.setSoilE(beans);
        // sows beans
        vm.prank(users[1]);
        bs.sow(beans, 1, 0);

        //
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise(); // not raining, caseId 108

        warpToNextSeasonAndUpdateOracles();
        bs.sunrise(); // start raining, caseId 114

        warpToNextSeasonAndUpdateOracles();

        uint256 totalHarvestableForActiveFieldBefore = bs.totalHarvestableForActiveField();

        bs.sunrise(); // sop, caseId 114

        uint256 totalHarvestableForActiveFieldAfter = bs.totalHarvestableForActiveField();

        uint256 amountMadeHarvestable = totalHarvestableForActiveFieldAfter -
            totalHarvestableForActiveFieldBefore;

        int256 totalDeltaB = bs.totalDeltaB();

        // it should have made more than capped deltaB harvestable, because we flooded
        assertGt(
            amountMadeHarvestable,
            uint256(totalDeltaB),
            "amountMadeHarvestable should be greater than totalDeltaB"
        );

        // check amount of soil issued
        uint256 initialSoil = bs.initialSoil();
        assertGt(initialSoil, 0, "soil should be issued because we flooded");

        uint256 floodHarvestablePods = bs.floodHarvestablePods();
        assertGt(
            floodHarvestablePods,
            0,
            "flood should have made some harvestable pods specifically from flooding"
        );

        IMockFBeanstalk.Season memory s = bs.time();
        // verify a sop a happened
        assertEq(s.lastSop, s.rainStart);
        assertEq(s.lastSopSeason, s.current);

        // call mow to update plenty amount for user
        bs.mow(users[1], BEAN);

        // test claimAllPlenty function
        vm.prank(users[1]);
        IMockFBeanstalk.ClaimPlentyData[] memory allPlenty = bs.claimAllPlenty(0);
        for (uint256 i = 0; i < allPlenty.length; i++) {
            require(allPlenty[i].plenty > 0, "No plenty found for token");
            address token = allPlenty[i].token;
            if (token == WSTETH) {
                assertEq(allPlenty[i].plenty, 52277442494667773084);
            }
            if (token == WETH) {
                assertEq(allPlenty[i].plenty, 25595575914848452999);
            }
        }
    }

    function testCalculateSopPerWell() public pure {
        LibFlood.WellDeltaB[] memory wellDeltaBs = new LibFlood.WellDeltaB[](3);
        wellDeltaBs[0].deltaB = 100;
        wellDeltaBs[1].deltaB = 100;
        wellDeltaBs[2].deltaB = -100;
        wellDeltaBs = calculateSopPerWellHelper(wellDeltaBs);
        assertEq(wellDeltaBs[0].deltaB, 50);
        assertEq(wellDeltaBs[1].deltaB, 50);
        assertEq(wellDeltaBs[2].deltaB, -100);

        wellDeltaBs = new LibFlood.WellDeltaB[](4);
        wellDeltaBs[0].deltaB = 90;
        wellDeltaBs[1].deltaB = 80;
        wellDeltaBs[2].deltaB = 20;
        wellDeltaBs[3].deltaB = -120;
        wellDeltaBs = calculateSopPerWellHelper(wellDeltaBs);
        assertEq(wellDeltaBs[0].deltaB, 40);
        assertEq(wellDeltaBs[1].deltaB, 30);
        assertEq(wellDeltaBs[2].deltaB, 0);
        assertEq(wellDeltaBs[3].deltaB, -120);

        wellDeltaBs = new LibFlood.WellDeltaB[](7);
        wellDeltaBs[0].deltaB = 90;
        wellDeltaBs[1].deltaB = 80;
        wellDeltaBs[2].deltaB = 70;
        wellDeltaBs[3].deltaB = 60;
        wellDeltaBs[4].deltaB = 50;
        wellDeltaBs[5].deltaB = 40;
        wellDeltaBs[6].deltaB = -120;
        wellDeltaBs = calculateSopPerWellHelper(wellDeltaBs);
        assertEq(wellDeltaBs[0].deltaB, 70);
        assertEq(wellDeltaBs[1].deltaB, 60);
        assertEq(wellDeltaBs[2].deltaB, 50);
        assertEq(wellDeltaBs[3].deltaB, 40);
        assertEq(wellDeltaBs[4].deltaB, 30);
        assertEq(wellDeltaBs[5].deltaB, 20);
        assertEq(wellDeltaBs[6].deltaB, -120);

        wellDeltaBs = new LibFlood.WellDeltaB[](4);
        wellDeltaBs[0].deltaB = 90;
        wellDeltaBs[1].deltaB = 80;
        wellDeltaBs[2].deltaB = -70;
        wellDeltaBs[3].deltaB = -200;
        wellDeltaBs = calculateSopPerWellHelper(wellDeltaBs);
        assertEq(wellDeltaBs[0].deltaB, 0);
        assertEq(wellDeltaBs[1].deltaB, 0);
        assertEq(wellDeltaBs[2].deltaB, -70);
        assertEq(wellDeltaBs[3].deltaB, -200);

        wellDeltaBs = new LibFlood.WellDeltaB[](1);
        wellDeltaBs[0].deltaB = 90;
        wellDeltaBs = calculateSopPerWellHelper(wellDeltaBs);
        assertEq(wellDeltaBs[0].deltaB, 90);

        // This can occur if the twaDeltaB is positive, but the instanteous deltaB is negative or 0
        // In this case, no reductions are needed.
        wellDeltaBs = new LibFlood.WellDeltaB[](2);
        wellDeltaBs[0].deltaB = 90;
        wellDeltaBs[1].deltaB = -100;
        wellDeltaBs = calculateSopPerWellHelper(wellDeltaBs);
        assertEq(wellDeltaBs[0].deltaB, 0);

        // test just 2 wells, all positive
        wellDeltaBs = new LibFlood.WellDeltaB[](2);
        wellDeltaBs[0].deltaB = 90;
        wellDeltaBs[1].deltaB = 80;
        wellDeltaBs = calculateSopPerWellHelper(wellDeltaBs);
        assertEq(wellDeltaBs[0].deltaB, 90);
        assertEq(wellDeltaBs[1].deltaB, 80);

        // test just 2 wells, one negative
        wellDeltaBs = new LibFlood.WellDeltaB[](2);
        wellDeltaBs[0].deltaB = 90;
        wellDeltaBs[1].deltaB = -80;
        wellDeltaBs = calculateSopPerWellHelper(wellDeltaBs);
        assertEq(wellDeltaBs[0].deltaB, 10);
        assertEq(wellDeltaBs[1].deltaB, -80);
    }

    function testSopAndDewhitelist() public {
        address sopWell = BEAN_ETH_WELL;
        setReserves(sopWell, 1000000e6, 1100e18);

        // there's only one well, so sop amount into that well will be the current deltaB
        int256 currentDeltaB = bs.poolCurrentDeltaB(sopWell);

        // getSwapOut for how much Beanstalk will get for swapping this amount of beans
        uint256 amountOut = IWell(sopWell).getSwapOut(
            IERC20(BEAN),
            IERC20(WETH),
            uint256(currentDeltaB)
        );

        // take this amount out, multiply by sop precision then divide by rain roots (current roots)
        uint256 userCalcPlentyPerRoot = (amountOut * C.SOP_PRECISION) / bs.totalRoots(); // 2558534177813719812

        // user plenty will be plenty per root * user roots
        uint256 userCalcPlenty = (userCalcPlentyPerRoot * bs.balanceOfRoots(users[1])) /
            C.SOP_PRECISION; // 25595575914848452999

        season.rainSunrise(); // start raining
        bs.mow(users[1], BEAN);

        vm.expectEmit();
        emit SeasonOfPlentyWell(
            seasonGetters.time().current + 1, // flood will happen next season
            sopWell,
            WETH,
            51191151829696906017,
            48808848170
        );

        season.rainSunrise(); // first sop

        // de-whitelist bean eth well
        vm.prank(BEANSTALK);
        bs.dewhitelistToken(BEAN_ETH_WELL);

        Season memory s = seasonGetters.time();

        assertEq(s.lastSop, s.rainStart);
        assertEq(s.lastSopSeason, s.current);
        // check weth balance of beanstalk
        assertEq(IERC20(WETH).balanceOf(BEANSTALK), 51191151829696906017);
        // after the swap, the composition of the pools are
        uint256[] memory balances = IWell(sopWell).getReserves();
        assertEq(balances[0], 1048808848170);
        assertEq(balances[1], 1048808848170303093983);

        // tracks user plenty before update
        uint256 userPlenty = bs.balanceOfPlenty(users[1], sopWell);
        assertEq(userPlenty, userCalcPlenty);

        // tracks user plenty after update
        bs.mow(users[1], BEAN);

        SiloGettersFacet.AccountSeasonOfPlenty memory userSop = siloGetters.balanceOfSop(users[1]);
        assertEq(userSop.lastRain, 6);
        assertEq(userSop.lastSop, 6);
        assertEq(userSop.roots, 10004000e24);

        assertGt(userSop.farmerSops.length, 0);

        assertEq(userSop.farmerSops[0].well, sopWell, "incorrect sop well");
        assertEq(userSop.farmerSops[0].wellsPlenty.plenty, userCalcPlenty, "incorrect plenty");
        assertEq(
            userSop.farmerSops[0].wellsPlenty.plentyPerRoot,
            userCalcPlentyPerRoot,
            "incorrect plenty per root"
        );

        // each user should get half of the eth gained
        assertEq(bs.balanceOfPlenty(users[2], sopWell), userCalcPlenty);

        // tracks user2 plenty after update
        bs.mow(users[2], BEAN);
        userSop = siloGetters.balanceOfSop(users[2]);
        assertEq(userSop.lastRain, 6);
        assertEq(userSop.lastSop, 6);
        assertEq(userSop.roots, 10004000e24);
        assertEq(userSop.farmerSops[0].well, sopWell);
        assertEq(userSop.farmerSops[0].wellsPlenty.plenty, userCalcPlenty);
        assertEq(userSop.farmerSops[0].wellsPlenty.plentyPerRoot, userCalcPlentyPerRoot);

        // claims user plenty
        bs.mow(users[2], BEAN);
        vm.prank(users[2]);
        bs.claimPlenty(sopWell, 0);
        assertEq(
            bs.balanceOfPlenty(users[2], sopWell),
            0,
            "balance of plenty not cleared after claim"
        );
        assertEq(
            IERC20(WETH).balanceOf(users[2]),
            userCalcPlenty,
            "user balance not correct after claim"
        );
    }

    function testDewhitelistAndMoreSops() public {
        address sopWell = BEAN_ETH_WELL;
        setReserves(sopWell, 1000000e6, 1100e18);

        // there's only one well, so sop amount into that well will be the current deltaB
        int256 currentDeltaB = bs.poolCurrentDeltaB(sopWell);

        // getSwapOut for how much Beanstalk will get for swapping this amount of beans
        uint256 amountOut = IWell(sopWell).getSwapOut(
            IERC20(BEAN),
            IERC20(WETH),
            uint256(currentDeltaB)
        );

        // take this amount out, multiply by sop precision then divide by rain roots (current roots)
        uint256 userCalcPlentyPerRoot = (amountOut * C.SOP_PRECISION) / bs.totalRoots(); // 2558534177813719812

        // user plenty will be plenty per root * user roots
        uint256 userCalcPlenty = (userCalcPlentyPerRoot * bs.balanceOfRoots(users[1])) /
            C.SOP_PRECISION; // 25595575914848452999

        season.rainSunrise(); // start raining
        bs.mow(users[1], BEAN);

        vm.expectEmit();
        emit SeasonOfPlentyWell(
            seasonGetters.time().current + 1, // flood will happen next season
            sopWell,
            WETH,
            51191151829696906017,
            48808848170
        );

        season.rainSunrise(); // first sop

        // de-whitelist bean eth well
        vm.prank(BEANSTALK);
        bs.dewhitelistToken(BEAN_ETH_WELL);

        // mow after dewhitelist
        bs.mow(users[1], BEAN);
        season.rainSunrise(); // sop one more after dewhitelist

        // get balance of plenty
        bs.balanceOfPlenty(users[1], sopWell);

        setReserves(sopWell, 1_000_000e6, 900e18);

        // stop sopping
        season.siloSunrise(0);
        season.siloSunrise(0);
        bs.mow(users[1], BEAN);

        setReserves(sopWell, 1_000_000e6, 1_100e18);
        // start sopping again
        season.rainSunrise();
        season.rainSunrise();

        // neither of these should revert
        bs.mow(users[1], BEAN);
        bs.balanceOfPlenty(users[1], sopWell);
    }

    // test making Beans harvestable
    function testHarvestablePodlineLessThanPointOnePercent(uint256 amount) public {
        setReserves(BEAN_ETH_WELL, 1000000e6, 1100e18);

        amount = bound(amount, 1, 1_000e6);

        // "buy" some pods
        bs.incrementTotalPodsE(bs.activeField(), amount);

        uint256 initialBeanSupply = bean.totalSupply();
        uint256 initialPodLine = bs.podIndex(bs.activeField());
        uint256 initialHarvestable = bs.totalHarvestableForActiveField();

        season.rainSunrise();
        bs.mow(users[1], BEAN);

        vm.expectEmit();

        emit SeasonOfPlentyField(amount);

        season.rainSunrise();

        uint256 newHarvestable = bs.totalHarvestableForActiveField();
        uint256 newBeanSupply = bean.totalSupply();
        uint256 newPodLine = bs.podIndex(bs.activeField());

        assertGt(newBeanSupply, initialBeanSupply); // Beans were minted
        assertEq(newHarvestable, initialPodLine); // Pods cleared to end of podline because podline was <0.1% of supply
        assertGt(initialPodLine, 0); // Start of test had a podline
        assertLe(newHarvestable, newPodLine); // All pods became harvestable, but nore more than the podline
        assertEq(initialHarvestable, 0); // Before flood, no pods were harvestable
    }

    function testHarvestablePodlineMoreThanPointOnePercent(uint256 amount) public {
        setReserves(BEAN_ETH_WELL, 1_000_000e6, 1_100e18);

        amount = bound(amount, 10_000e6, 100_000e6);

        bs.incrementTotalPodsE(bs.activeField(), amount);
        uint256 initialBeanSupply = bean.totalSupply();
        uint256 initialPodLine = bs.podIndex(bs.activeField());
        uint256 initialHarvestable = bs.totalHarvestableForActiveField();

        season.rainSunrise();
        bs.mow(users[1], BEAN);

        vm.expectEmit();
        emit SeasonOfPlentyField(initialBeanSupply / 1000);

        season.rainSunrise();

        uint256 newHarvestable = bs.totalHarvestableForActiveField();
        uint256 newBeanSupply = bean.totalSupply();
        uint256 newPodLine = bs.podIndex(bs.activeField());

        assertGt(newBeanSupply, initialBeanSupply); // Beans were minted
        assertLt(newHarvestable, newPodLine); // Pods didn't clear to end of podline because podline was >0.1% of supply
        assertGt(initialPodLine, 0); // Start of test had a podline
        assertEq(initialHarvestable, 0); // Before flood, no pods were harvestable
        assertApproxEqAbs(initialBeanSupply / 1000, newHarvestable, 1);
    }

    // TODO test with more wells?
    function testGetWellsByDeltaB() public {
        //set up wells to test
        addLiquidityToWell(BEAN_ETH_WELL, 13000e6, 10 ether);
        addLiquidityToWell(BEAN_WSTETH_WELL, 12000e6, 10 ether);

        (IMockFBeanstalk.WellDeltaB[] memory wells, , , ) = bs.getWellsByDeltaB();

        //verify wells are in descending deltaB
        for (uint256 i = 0; i < wells.length - 1; i++) {
            assertGt(wells[i].deltaB, wells[i + 1].deltaB);
        }
    }

    function testQuickSort() public pure {
        LibFlood.WellDeltaB[] memory wells = new LibFlood.WellDeltaB[](5);
        int right = int(wells.length - 1);
        wells[0] = LibFlood.WellDeltaB(address(0), 100);
        wells[1] = LibFlood.WellDeltaB(address(1), 200);
        wells[2] = LibFlood.WellDeltaB(address(2), -300);
        wells[3] = LibFlood.WellDeltaB(address(3), 400);
        wells[4] = LibFlood.WellDeltaB(address(4), 500);
        wells = LibFlood.quickSort(wells, 0, right);
        assertEq(wells[0].deltaB, 500);
        assertEq(wells[1].deltaB, 400);
        assertEq(wells[2].deltaB, 200);
        assertEq(wells[3].deltaB, 100);
        assertEq(wells[4].deltaB, -300);

        // these values are examples from the codehawks report
        wells[0] = LibFlood.WellDeltaB(address(0), 39);
        wells[1] = LibFlood.WellDeltaB(address(1), 6);
        wells[2] = LibFlood.WellDeltaB(address(2), 27);
        wells[3] = LibFlood.WellDeltaB(address(3), -14);
        wells[4] = LibFlood.WellDeltaB(address(4), 15);
        wells = LibFlood.quickSort(wells, 0, right);
        assertEq(wells[0].deltaB, 39);
        assertEq(wells[1].deltaB, 27);
        assertEq(wells[2].deltaB, 15);
        assertEq(wells[3].deltaB, 6);
        assertEq(wells[4].deltaB, -14);

        wells = new LibFlood.WellDeltaB[](2);
        right = int(wells.length - 1);
        wells[0] = LibFlood.WellDeltaB(address(0), 200);
        wells[1] = LibFlood.WellDeltaB(address(1), 100);
        wells = LibFlood.quickSort(wells, 0, right);
        assertEq(wells[0].deltaB, 200);
        assertEq(wells[1].deltaB, 100);

        wells[0] = LibFlood.WellDeltaB(address(0), 100);
        wells[1] = LibFlood.WellDeltaB(address(1), 200);
        wells = LibFlood.quickSort(wells, 0, right);
        assertEq(wells[0].deltaB, 200);
        assertEq(wells[1].deltaB, 100);

        wells = new LibFlood.WellDeltaB[](20);
        right = int(wells.length - 1);
        wells[0] = LibFlood.WellDeltaB(address(0), -1);
        wells[1] = LibFlood.WellDeltaB(address(1), 2);
        wells[2] = LibFlood.WellDeltaB(address(2), -3);
        wells[3] = LibFlood.WellDeltaB(address(3), 4);
        wells[4] = LibFlood.WellDeltaB(address(4), -5);
        wells[5] = LibFlood.WellDeltaB(address(5), 6);
        wells[6] = LibFlood.WellDeltaB(address(6), -7);
        wells[7] = LibFlood.WellDeltaB(address(7), 8);
        wells[8] = LibFlood.WellDeltaB(address(8), -9);
        wells[9] = LibFlood.WellDeltaB(address(9), 10);
        wells[10] = LibFlood.WellDeltaB(address(10), -11);
        wells[11] = LibFlood.WellDeltaB(address(11), 12);
        wells[12] = LibFlood.WellDeltaB(address(12), -13);
        wells[13] = LibFlood.WellDeltaB(address(13), 14);
        wells[14] = LibFlood.WellDeltaB(address(14), -15);
        wells[15] = LibFlood.WellDeltaB(address(15), 16);
        wells[16] = LibFlood.WellDeltaB(address(16), -17);
        wells[17] = LibFlood.WellDeltaB(address(17), 18);
        wells[18] = LibFlood.WellDeltaB(address(18), -19);
        wells[19] = LibFlood.WellDeltaB(address(19), 20);
        wells = LibFlood.quickSort(wells, 0, right);
        assertEq(wells[0].deltaB, 20);
        assertEq(wells[1].deltaB, 18);
        assertEq(wells[2].deltaB, 16);
        assertEq(wells[3].deltaB, 14);
        assertEq(wells[4].deltaB, 12);
        assertEq(wells[5].deltaB, 10);
        assertEq(wells[6].deltaB, 8);
        assertEq(wells[7].deltaB, 6);
        assertEq(wells[8].deltaB, 4);
        assertEq(wells[9].deltaB, 2);
        assertEq(wells[10].deltaB, -1);
        assertEq(wells[11].deltaB, -3);
        assertEq(wells[12].deltaB, -5);
        assertEq(wells[13].deltaB, -7);
        assertEq(wells[14].deltaB, -9);
        assertEq(wells[15].deltaB, -11);
        assertEq(wells[16].deltaB, -13);
        assertEq(wells[17].deltaB, -15);
        assertEq(wells[18].deltaB, -17);
        assertEq(wells[19].deltaB, -19);
    }

    function test_notGerminated() public {
        address customUser = address(1337);

        bean.mint(customUser, 10_000e6);
        vm.prank(customUser);
        bean.approve(BEANSTALK, type(uint256).max);
        vm.prank(customUser);
        bs.deposit(BEAN, 1000e6, 0);

        season.siloSunrise(0);
        season.siloSunrise(0);
        season.siloSunrise(0); // should be germinated by now, not mown though

        address sopWell = BEAN_ETH_WELL;
        setReserves(sopWell, 1000000e6, 1100e18);

        season.rainSunrise();
        season.rainSunrise();

        bs.mow(customUser, BEAN);

        uint256 balanceOfPlenty = bs.balanceOfPlenty(customUser, sopWell);
        // TODO: manually calculate this value to ensure it's correct
        assertEq(17059168165054954010, balanceOfPlenty);
    }

    function test_Germinated() public {
        address customUser = address(1337);

        bean.mint(customUser, 10_000e6);
        vm.prank(customUser);
        bean.approve(BEANSTALK, type(uint256).max);
        vm.prank(customUser);
        bs.deposit(BEAN, 1000e6, 0);

        season.siloSunrise(0);
        season.siloSunrise(0);
        season.siloSunrise(0); // should be germinated by now, not mown though

        address sopWell = BEAN_ETH_WELL;
        setReserves(sopWell, 1000000e6, 1100e18);

        bs.mow(customUser, BEAN);
        season.rainSunrise();
        season.rainSunrise();

        bs.mow(customUser, BEAN);

        uint256 balanceOfPlenty = bs.balanceOfPlenty(customUser, sopWell);
        // TODO: manually calculate this value to ensure it's correct
        // Note user has more plenty here than previous test because of the earlier mow, giving them more stalk
        assertEq(17065991377622017778, balanceOfPlenty);
    }

    //////////// Helpers ////////////

    /**
     * @dev Helper function to calculate totalPositiveDeltaB, totalNegativeDeltaB, positiveDeltaBCount
     * @param wellDeltaBs The deltaBs of all whitelisted wells in which to flood
     */
    function calculateSopPerWellHelper(
        LibFlood.WellDeltaB[] memory wellDeltaBs
    ) private pure returns (LibFlood.WellDeltaB[] memory) {
        uint256 totalPositiveDeltaB;
        uint256 totalNegativeDeltaB;
        uint256 positiveDeltaBCount;

        for (uint i = 0; i < wellDeltaBs.length; i++) {
            if (wellDeltaBs[i].deltaB > 0) {
                totalPositiveDeltaB += uint256(wellDeltaBs[i].deltaB);
                positiveDeltaBCount++;
            } else {
                totalNegativeDeltaB += uint256(-wellDeltaBs[i].deltaB);
            }
        }

        return
            LibFlood.calculateSopPerWell(
                wellDeltaBs,
                totalPositiveDeltaB,
                totalNegativeDeltaB,
                positiveDeltaBCount
            );
    }

    function depositBeansForUsers(
        address[] memory users,
        uint256 beansDeposit,
        uint256 beansMint,
        bool mow
    ) public {
        for (uint i = 0; i < users.length; i++) {
            bean.mint(users[i], beansMint);
            vm.prank(users[i]);
            bean.approve(BEANSTALK, type(uint256).max);
            vm.prank(users[i]);
            bs.deposit(BEAN, beansDeposit, 0);
        }

        // pass germination process
        season.siloSunrise(0);
        season.siloSunrise(0);

        if (mow) {
            for (uint i = 0; i < users.length; i++) {
                // mow, so that lastUpdated has been called at least once
                vm.prank(users[i]);
                bs.mow(users[i], BEAN);
            }
        }
    }

    function setInstantaneousReserves(address well, uint256 reserve0, uint256 reserve1) public {
        Call[] memory pumps = IWell(well).pumps();
        for (uint256 i = 0; i < pumps.length; i++) {
            address pump = pumps[i].target;
            // pass to the pump the reserves that we actually have in the well
            uint256[] memory reserves = new uint256[](2);
            reserves[0] = reserve0;
            reserves[1] = reserve1;

            MockPump(pump).setInstantaneousReserves(well, reserves);
        }
    }
}

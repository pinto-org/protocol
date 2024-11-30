// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer} from "test/foundry/utils/TestHelper.sol";
import {MockSiloFacet} from "contracts/mocks/mockFacets/MockSiloFacet.sol";
import {C} from "contracts/C.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {console} from "forge-std/console.sol";

/**
 * @title GerminationTest
 * @notice Test the germination of beans in the silo.
 * @dev Tests total/farmer values and validates the germination process.
 */
contract GerminationTest is TestHelper {
    // Interfaces.
    MockSiloFacet silo = MockSiloFacet(BEANSTALK);

    // test accounts
    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // mint 1000 beans to user 1 and user 2 (user 0 is the beanstalk deployer).
        farmers.push(users[1]);
        farmers.push(users[2]);
        mintTokensToUsers(farmers, BEAN, MAX_DEPOSIT_BOUND);
    }

    //////////// DEPOSITS ////////////

    /**
     * @notice verify that silo deposits correctly
     * germinating and update the state of the silo.
     */
    function test_depositGerminates(uint256 amount) public {
        // deposits bean into the silo.
        (amount, ) = setUpSiloDepositTest(amount, farmers);

        // verify new state of silo.
        checkSiloAndUser(users[1], 0, amount);
    }

    /**
     * @notice verify that silo deposits continue to germinate
     * After a season has elapsed.
     */
    function test_depositsContGerminating(uint256 amount) public {
        // deposits bean into the silo.
        (amount, ) = setUpSiloDepositTest(amount, farmers);

        // call sunrise.
        season.siloSunrise(0);

        // verify new state of silo.
        checkSiloAndUser(users[1], 0, amount);
    }

    /**
     * @notice verify that silo deposits continue to germinate
     * After a season.
     */
    function test_depositsEndGermination(uint256 amount) public {
        // deposits bean into the silo.
        (amount, ) = setUpSiloDepositTest(amount, farmers);

        // call sunrise twice.
        season.siloSunrise(0);
        season.siloSunrise(0);

        // verify new state of silo.
        checkSiloAndUser(users[1], amount, 0);
    }

    ////// WITHDRAWS //////

    /**
     * @notice verify that silo deposits can be withdrawn while germinating.
     */
    function test_withdrawGerminating(uint256 amount) public {
        // deposits bean into the silo.
        int96 stem;
        (amount, stem) = setUpSiloDepositTest(amount, farmers);

        // withdraw beans from silo from user 1 and 2.
        withdrawDepositForUsers(farmers, BEAN, stem, amount, LibTransfer.To.EXTERNAL);

        // verify silo/farmer states.
        // verify new state of silo.
        checkSiloAndUser(users[1], 0, 0);
    }

    /**
     * @notice verify that silo deposits continue to germinate
     * After a season has elapsed.
     */
    function test_withdrawGerminatingCont(uint256 amount) public {
        // deposits bean into the silo.
        int96 stem;
        (amount, stem) = setUpSiloDepositTest(amount, farmers);

        // call sunrise.
        season.siloSunrise(0);

        // withdraw beans from silo from user 1 and 2.
        withdrawDepositForUsers(farmers, BEAN, stem, amount, LibTransfer.To.EXTERNAL);

        // verify silo/farmer states.
        // verify new state of silo.
        checkSiloAndUser(users[1], 0, 0);
    }

    ////// TRANSFERS //////

    /**
     * @notice verify that silo deposits can be withdrawn while germinating.
     */
    function test_transferGerminating(uint256 amount) public {
        // deposits bean into the silo.
        int96 stem;
        (amount, stem) = setUpSiloDepositTest(amount, farmers);
        uint256 grownStalk = bs.balanceOfGrownStalk(users[1], BEAN);

        farmers.push(users[3]);
        farmers.push(users[4]);

        transferDepositFromUsersToUsers(farmers, stem, BEAN, amount);

        // verify silo/farmer states.
        // verify new state of silo.
        checkSiloAndUserWithGrownStalk(users[3], 0, amount, grownStalk);
    }

    /**
     * @notice verify that silo deposits continue to germinate
     * After a season has elapsed.
     */
    function test_transferGerminatingCont(uint256 amount) public {
        // deposits bean into the silo.
        int96 stem;
        (amount, stem) = setUpSiloDepositTest(amount, farmers);
        season.siloSunrise(0);
        farmers.push(users[3]);
        farmers.push(users[4]);

        uint256 grownStalk = bs.balanceOfGrownStalk(users[1], BEAN);

        transferDepositFromUsersToUsers(farmers, stem, BEAN, amount);

        // verify silo/farmer states.
        // verify new state of silo.
        checkSiloAndUserWithGrownStalk(users[3], 0, amount, grownStalk);
    }

    // The following two tests verify that germinating deposits do not gain signorage from earned beans.
    // however, there is an edge case where the first deposit of the beanstalk system will gain signorage.
    // due to how roots are initally issued. Thus, earned beans tests assume prior deposits.
    function test_NoEarnedBeans(uint256 amount, uint256 sunriseBeans) public {
        sunriseBeans = bound(sunriseBeans, 0, MAX_DEPOSIT_BOUND);

        // see {initZeroEarnedBeansTest} for details.
        uint256 _amount = initZeroEarnedBeansTest(amount, farmers, users[3]);

        // calls sunrise with some beans issued.
        season.siloSunrise(sunriseBeans);

        // verify silo/farmer states. Check user has no earned beans.
        assertEq(bs.totalStalk(), (2 * _amount + sunriseBeans) * C.STALK_PER_BEAN, "TotalStalk");
        assertEq(bs.balanceOfEarnedBeans(users[3]), 0, "balanceOfEarnedBeans");
        assertEq(bs.getTotalDeposited(BEAN), (2 * _amount + sunriseBeans), "TotalDeposited");
        assertEq(bs.getTotalDepositedBdv(BEAN), (2 * _amount + sunriseBeans), "TotalDepositedBdv");
        assertEq(bs.totalRoots(), 2 * _amount * C.STALK_PER_BEAN * C.getRootsBase(), "TotalRoots");
    }

    // Verify that when a user plants, the user skips the germination process.
    function test_plant_skip_germination() public {
        uint256 initialAmount = 1000e6;
        uint256 _amount;
        (_amount, ) = setUpSiloDepositTest(initialAmount, farmers);

        // call sunrise twice to finish the germination process.
        season.siloSunrise(0);
        season.siloSunrise(0);

        // get the users stalk, roots, and bdv.
        uint256 stalk = bs.balanceOfStalk(farmers[1]);
        uint256 roots = bs.balanceOfRoots(farmers[1]);

        // calls sunrise with some beans issued.
        season.siloSunrise(1000e6);

        // mow so that the user has no grown stalk.
        bs.mow(farmers[1], BEAN);

        // verify the user has no germinating stalk:
        assertEq(bs.balanceOfGerminatingStalk(farmers[1]), 0, "balanceOfGerminatingStalk");
        uint256 globalGerminatingStalk = bs.getTotalGerminatingStalk();

        // plant the beans.
        vm.prank(farmers[1]);
        (uint256 beans, int96 stem) = bs.plant();

        // verify the user has the correct amount of beans and stem.
        assertEq(beans, 1000e6 / 2, "Beans");
        // the stem of the deposit is the germinating stem - 1.
        int96 germinatingStem = bs.getGerminatingStem(BEAN);
        int96 highestNonGerminatingStem = bs.getHighestNonGerminatingStem(BEAN);
        assertEq(stem, highestNonGerminatingStem, "Stem");
        assertEq(germinatingStem, highestNonGerminatingStem + 1, "GerminatingStem");

        // calculate the users stalk at this point:
        // summation of:
        // - base stalk from initial deposit
        // - 3 seasons of stalk growth.
        // - base stalk from earned beans
        // - 1 season of stalk growth from the previous seeds + 1 micro seeds.
        // seeds are static at 2.
        uint256 calculatedUserStalk;
        uint256 calculatedUserRoots;
        {
            uint256 baseStalk = initialAmount * C.STALK_PER_BEAN;
            uint256 grownStalk = 3 * 2e6 * initialAmount;
            uint256 baseStalkFromEarnedBeans = beans * C.STALK_PER_BEAN;
            uint256 grownStalkFromEarnedBeans = beans * (2e6 + 1);
            calculatedUserStalk =
                baseStalk +
                grownStalk +
                baseStalkFromEarnedBeans +
                grownStalkFromEarnedBeans;
            //  roots are issued based on the stalk/root ratio.
            uint256 baseStalkRoots = (baseStalk * C.getRootsBase());

            uint256 totalStalkAfterEarnedBeans = 2 * baseStalk + 2 * baseStalkFromEarnedBeans;

            // see {LibSilo-mintActiveStalk} for details on how this is calculated.
            uint256 grownStalkRoots = (2 * baseStalkRoots * grownStalk) /
                totalStalkAfterEarnedBeans;

            // see {LibSilo-mintActiveStalk} for details on how this is calculated.
            uint256 grownStalkFromEarnedBeansRoots = ((2 * baseStalkRoots + grownStalkRoots) *
                grownStalkFromEarnedBeans) / (totalStalkAfterEarnedBeans + grownStalk);
            calculatedUserRoots = baseStalkRoots + grownStalkRoots + grownStalkFromEarnedBeansRoots;
        }

        // verify the users stalk and roots increased.
        assertEq(bs.balanceOfStalk(farmers[1]), calculatedUserStalk, "Stalk");
        assertEq(bs.balanceOfRoots(farmers[1]), calculatedUserRoots, "Roots");

        // verify the total germinating stalk is unchanged.
        assertEq(bs.getTotalGerminatingStalk(), globalGerminatingStalk, "TotalGerminatingStalk");

        // verify the user has no germinating stalk:
        assertEq(bs.balanceOfGerminatingStalk(farmers[1]), 0, "balanceOfGerminatingStalk");

        uint256 snapshot = vm.snapshot();

        // confirm that planting again does not issue any more beans.
        vm.prank(farmers[1]);
        uint256 newBeans;
        (newBeans, stem) = bs.plant();
        assertEq(newBeans, 0, "Beans");

        vm.revertTo(snapshot);

        ///// CONVERT //////

        // Initialize well to balances. (1000 BEAN/ETH)
        address well = BEAN_ETH_WELL;
        addLiquidityToWell(
            well,
            10000e6, // 10,000 Beans
            10 ether // 10 ether.
        );

        setDeltaBforWell(int256(1000e6), well, WETH);

        // verify that the user can convert their beans to a well.
        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // well
            beans, // amountIn
            0 // minOut
        );

        vm.prank(farmers[1]);
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = beans;
        // verify that the user can convert their newly earned beans.
        bs.convert(convertData, stems, amounts);

        ////// WITHDRAWALS //////
        vm.revertTo(snapshot);

        // verify that the user can withdraw their deposit.
        vm.prank(farmers[1]);
        bs.withdrawDeposit(BEAN, stem, beans, 0);

        // verify the user has the correct stalk and roots.
        assertEq(bs.balanceOfStalk(farmers[1]), 10006000000000000000, "Stalk");
        assertEq(bs.balanceOfRoots(farmers[1]), 6670666666666666666666666666667, "Roots");
    }

    ////// SILO TEST HELPERS //////

    /**
     * @notice Withdraw beans from the silo for multiple users.
     * @param users The users to withdraw beans from.
     * @param token The token to withdraw.
     * @param stem The stem tip for the deposited beans.
     * @param amount The amount of beans to withdraw.
     * @param mode The withdraw mode.
     */
    function withdrawDepositForUsers(
        address[] memory users,
        address token,
        int96 stem,
        uint256 amount,
        LibTransfer.To mode
    ) public {
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            silo.withdrawDeposit(token, stem, amount, mode);
        }
    }

    /**
     * @notice Transfer beans from the silo for multiple users.
     * @param users Users.
     * @param stem The stem tip for the deposited beans.
     * @param token The token to transfer.
     * @param amount The amount of beans to transfer
     * @dev This function transfers a deposit from user 'i' to
     * user 'i + 2'. Fails with invalid array input.
     */
    function transferDepositFromUsersToUsers(
        address[] memory users,
        int96 stem,
        address token,
        uint256 amount
    ) public {
        for (uint256 i = 0; i < users.length - 2; i++) {
            vm.prank(users[i]);
            silo.transferDeposit(users[i], users[i + 2], token, stem, amount);
        }
    }

    function initZeroEarnedBeansTest(
        uint256 amount,
        address[] memory initalFarmers,
        address newFarmer
    ) public returns (uint256 _amount) {
        // deposit 'amount' beans to the silo.
        (_amount, ) = setUpSiloDepositTest(amount, initalFarmers);

        // call sunrise twice to finish the germination process.
        season.siloSunrise(0);
        season.siloSunrise(0);

        address[] memory farmer = new address[](1);
        farmer[0] = newFarmer;
        // mint token to new farmer.
        mintTokensToUsers(farmer, BEAN, MAX_DEPOSIT_BOUND);

        // deposit into the silo.
        setUpSiloDepositTest(amount, farmer);
    }

    ////// ASSERTIONS //////

    /**
     * @notice Verifies the following parameters:
     * Total silo balances.
     * - total Stalk
     * - total Roots
     * - total deposited beans
     * - total deposited bdv
     * - total germinating stalk
     * - total germinating beans
     * - total germinating bdv
     */
    function checkSiloAndUser(address farmer, uint256 total, uint256 germTotal) public view {
        checkTotalSiloBalances(2 * total);
        checkFarmerSiloBalances(farmer, total);
        checkTotalGerminatingBalances(2 * germTotal);
        checkFarmerGerminatingBalances(users[1], germTotal);
    }

    /**
     * @notice checks silo balances, with grown stalk added.
     * @dev when a user interacts with the silo, mow() is called,
     * which credits the user with grown stalk. Tests which check
     * multi-season interactions should include the grown stalk.
     */
    function checkSiloAndUserWithGrownStalk(
        address farmer,
        uint256 total,
        uint256 germTotal,
        uint256 grownStalk
    ) public view {
        checkTotalSiloBalancesWithGrownStalk(2 * total, 2 * grownStalk);
        checkFarmerSiloBalancesWithGrownStalk(farmer, total, grownStalk);
        checkTotalGerminatingBalances(2 * germTotal);
        checkFarmerGerminatingBalances(farmer, germTotal);
    }

    function checkTotalSiloBalances(uint256 expected) public view {
        checkTotalSiloBalancesWithGrownStalk(expected, 0);
    }

    function checkTotalSiloBalancesWithGrownStalk(
        uint256 expected,
        uint256 grownStalk
    ) public view {
        assertEq(bs.totalStalk(), expected * C.STALK_PER_BEAN + grownStalk, "TotalStalk");
        assertEq(
            bs.totalRoots(),
            ((expected * C.STALK_PER_BEAN) + grownStalk) * C.getRootsBase(),
            "TotalRoots"
        );
        assertEq(bs.getTotalDeposited(BEAN), expected, "TotalDeposited");
        assertEq(bs.getTotalDepositedBdv(BEAN), expected, "TotalDepositedBdv");
    }

    function checkFarmerSiloBalances(address farmer, uint256 expected) public view {
        checkFarmerSiloBalancesWithGrownStalk(farmer, expected, 0);
    }

    function checkFarmerSiloBalancesWithGrownStalk(
        address farmer,
        uint256 expected,
        uint256 grownStalk
    ) public view {
        assertEq(
            bs.balanceOfStalk(farmer),
            (expected * C.STALK_PER_BEAN) + grownStalk,
            "FarmerStalk"
        );
        assertEq(
            bs.balanceOfRoots(farmer),
            ((expected * C.STALK_PER_BEAN) + grownStalk) * C.getRootsBase(),
            "FarmerRoots"
        );
    }

    function checkTotalGerminatingBalances(uint256 expected) public view {
        assertEq(
            bs.getTotalGerminatingStalk(),
            expected * C.STALK_PER_BEAN,
            "TotalGerminatingStalk"
        );
        assertEq(bs.getGerminatingTotalDeposited(BEAN), expected, "getGerminatingTotalDeposited");
        assertEq(
            bs.getGerminatingTotalDepositedBdv(BEAN),
            expected,
            "getGerminatingTotalDepositedBdv"
        );
    }

    function checkFarmerGerminatingBalances(address farmer, uint256 expected) public view {
        assertEq(
            bs.balanceOfGerminatingStalk(farmer),
            C.STALK_PER_BEAN * expected,
            "balanceOfGerminatingStalk"
        );
    }
}

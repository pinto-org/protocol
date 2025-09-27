// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TractorHelpers} from "contracts/ecosystem/TractorHelpers.sol";
import {SowBlueprintv0} from "contracts/ecosystem/SowBlueprintv0.sol";
import {PriceManipulation} from "contracts/ecosystem/PriceManipulation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TractorHelper} from "test/foundry/utils/TractorHelper.sol";
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {OperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {MowPlantHarvestBlueprint} from "contracts/ecosystem/MowPlantHarvestBlueprint.sol";
import "forge-std/console.sol";

contract MowPlantHarvestBlueprintTest is TractorHelper {
    address[] farmers;
    PriceManipulation priceManipulation;
    BeanstalkPrice beanstalkPrice;

    event Plant(address indexed account, uint256 beans);
    event Harvest(address indexed account, uint256 fieldId, uint256[] plots, uint256 beans);

    uint256 STALK_DECIMALS = 1e10;
    int256 DEFAULT_TIP_AMOUNT = 10e6; // 10 BEAN
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16

    struct TestState {
        address user;
        address operator;
        address beanToken;
        uint256 initialUserBeanBalance;
        uint256 initialOperatorBeanBalance;
        uint256 mintAmount;
        int256 mowTipAmount;
        int256 plantTipAmount;
        int256 harvestTipAmount;
    }

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        farmers = createUsers(2);
        vm.label(farmers[0], "Farmer 1");
        vm.label(farmers[1], "Farmer 2");

        // Deploy PriceManipulation (unused here but needed for TractorHelpers)
        priceManipulation = new PriceManipulation(address(bs));
        vm.label(address(priceManipulation), "PriceManipulation");

        // Deploy BeanstalkPrice (unused here but needed for TractorHelpers)
        beanstalkPrice = new BeanstalkPrice(address(bs));
        vm.label(address(beanstalkPrice), "BeanstalkPrice");

        // Deploy TractorHelpers with PriceManipulation address
        tractorHelpers = new TractorHelpers(
            address(bs),
            address(beanstalkPrice),
            address(this),
            address(priceManipulation)
        );
        vm.label(address(tractorHelpers), "TractorHelpers");

        // Deploy MowPlantHarvestBlueprint with TractorHelpers address
        mowPlantHarvestBlueprint = new MowPlantHarvestBlueprint(
            address(bs),
            address(this),
            address(tractorHelpers)
        );
        vm.label(address(mowPlantHarvestBlueprint), "MowPlantHarvestBlueprint");

        setTractorHelpers(address(tractorHelpers));
        setMowPlantHarvestBlueprint(address(mowPlantHarvestBlueprint));

        // Advance season to grow stalk
        advanceSeason();
    }

    /**
     * @notice Setup the test state for the MowPlantHarvestBlueprint test
     * @param setupPlant If true, setup the conditions for planting
     * @param setupHarvest If true, setup the conditions for harvesting
     * @param abovePeg If true, setup the conditions for above peg
     * @return TestState The test state
     */
    function setupMowPlantHarvestBlueprintTest(
        bool setupPlant,
        bool setupHarvest,
        bool abovePeg
    ) internal returns (TestState memory) {
        // Create test state
        TestState memory state;
        state.user = farmers[0];
        state.operator = address(this);
        state.beanToken = bs.getBeanToken();
        state.initialUserBeanBalance = IERC20(state.beanToken).balanceOf(state.user);
        state.initialOperatorBeanBalance = bs.getInternalBalance(state.operator, state.beanToken);
        state.mintAmount = 110000e6; // 100k for deposit, 10k for sow
        state.mowTipAmount = DEFAULT_TIP_AMOUNT; // 10 BEAN
        state.plantTipAmount = DEFAULT_TIP_AMOUNT;
        state.harvestTipAmount = DEFAULT_TIP_AMOUNT;

        // Mint 2x the amount to ensure we have enough for all test cases
        mintTokensToUser(state.user, state.beanToken, state.mintAmount);
        // Mint some to farmer 2 for plot tests
        mintTokensToUser(farmers[1], state.beanToken, 10000000e6);

        // Deposit beans for user
        vm.startPrank(state.user);
        IERC20(state.beanToken).approve(address(bs), type(uint256).max);
        bs.deposit(state.beanToken, state.mintAmount - 10000e6, uint8(LibTransfer.From.EXTERNAL));
        vm.stopPrank();

        // For farmer 1, deposit 1000e6 beans, and mint them 1000e6 beans
        mintTokensToUser(farmers[1], state.beanToken, 1000e6);
        vm.prank(farmers[1]);
        bs.deposit(state.beanToken, 1000e6, uint8(LibTransfer.From.EXTERNAL));

        // Set liquidity in the whitelisted wells to manipulate deltaB
        setPegConditions(abovePeg);

        if (setupPlant) skipGermination();

        if (setupHarvest) setHarvestConditions(state.user);

        return state;
    }

    /////////////////////////// TESTS ///////////////////////////

    function test_mowPlantHarvestBlueprint_smartMow() public {
        // Setup test state
        // setupPlant: false, setupHarvest: false, abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, false, true);

        // Advance season to grow stalk but not enough to plant
        advanceSeason();
        vm.warp(block.timestamp + 1 seconds);

        // get user state before mow
        uint256 userGrownStalk = bs.balanceOfGrownStalk(state.user, state.beanToken);
        // assert user has grown stalk
        assertGt(userGrownStalk, 0, "user should have grown stalk to mow");
        // get user total stalk before mow
        uint256 userTotalStalkBeforeMow = bs.balanceOfStalk(state.user);
        // assert totalDeltaB is greater than 0
        assertGt(bs.totalDeltaB(), 0, "totalDeltaB should be greater than 0");

        // Setup mowPlantHarvestBlueprint
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            type(uint256).max, // minPlantAmount
            type(uint256).max, // minHarvestAmount
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Try to execute before the last minutes of the season, expect revert
        vm.expectRevert("MowPlantHarvestBlueprint: None of the order conditions are met");
        executeRequisition(state.operator, req, address(bs));

        // Try to execute after in last minutes of the season
        vm.warp(bs.getNextSeasonStart() - 1 seconds);
        executeRequisition(state.operator, req, address(bs));

        // assert all grown stalk was mowed
        uint256 userGrownStalkAfterMow = bs.balanceOfGrownStalk(state.user, state.beanToken);
        assertEq(userGrownStalkAfterMow, 0);

        // get user total stalk after mow
        uint256 userTotalStalkAfterMow = bs.balanceOfStalk(state.user);
        // assert the user total stalk has increased
        assertGt(
            userTotalStalkAfterMow,
            userTotalStalkBeforeMow,
            "userTotalStalk should have increased"
        );
    }

    function test_mowPlantHarvestBlueprint_plant_revertWhenMinPlantAmountLessThanTip() public {
        // Setup test state for planting
        TestState memory state = setupMowPlantHarvestBlueprintTest(true, false, true);

        // assert that the user has earned beans
        assertGt(bs.balanceOfEarnedBeans(state.user), 0, "user should have earned beans to plant");

        // Setup blueprint with minPlantAmount less than plant tip amount
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            1e6, // minPlantAmount < 10e6 (plant tip amount)
            type(uint256).max, // minHarvestAmount
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect revert
        vm.expectRevert("Min plant amount must be greater than plant tip amount");
        executeRequisition(state.operator, req, address(bs));
    }

    function test_mowPlantHarvestBlueprint_plant_revertWhenInsufficientPlantableBeans() public {
        // Setup test state for planting
        TestState memory state = setupMowPlantHarvestBlueprintTest(true, false, true);

        // assert that the user has earned beans
        assertGt(bs.balanceOfEarnedBeans(state.user), 0, "user should have earned beans to plant");

        // Setup blueprint with minPlantAmount greater than total plantable beans
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            type(uint256).max, // minPlantAmount > (total plantable beans)
            type(uint256).max, // minHarvestAmount
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect revert
        vm.expectRevert("MowPlantHarvestBlueprint: None of the order conditions are met");
        executeRequisition(state.operator, req, address(bs));
    }

    function test_mowPlantHarvestBlueprint_plant_success() public {
        // Setup test state for planting
        TestState memory state = setupMowPlantHarvestBlueprintTest(true, false, true);

        // get user state before plant
        uint256 userTotalStalkBeforePlant = bs.balanceOfStalk(state.user);
        uint256 userTotalBdvBeforePlant = bs.balanceOfDepositedBdv(state.user, state.beanToken);

        // assert user has grown stalk and initial bdv
        assertGt(userTotalStalkBeforePlant, 0, "user should have grown stalk to plant");
        assertEq(userTotalBdvBeforePlant, 100000e6, "user should have the initial bdv");
        assertGt(bs.balanceOfEarnedBeans(state.user), 0, "user should have earned beans to plant");

        // Setup blueprint with valid minPlantAmount
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            11e6, // minPlantAmount > 10e6 (plant tip amount)
            type(uint256).max, // minHarvestAmount
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect plant event
        vm.expectEmit();
        emit Plant(state.user, 1933023687);
        executeRequisition(state.operator, req, address(bs));

        // Verify state changes after successful plant
        uint256 userTotalStalkAfterPlant = bs.balanceOfStalk(state.user);
        uint256 userTotalBdvAfterPlant = bs.balanceOfDepositedBdv(state.user, state.beanToken);

        assertGt(userTotalStalkAfterPlant, userTotalStalkBeforePlant, "userTotalStalk increase");
        assertGt(userTotalBdvAfterPlant, userTotalBdvBeforePlant, "userTotalBdv increase");
    }

    function test_mowPlantHarvestBlueprint_harvest_revertWhenMinHarvestAmountLessThanTip() public {
        // Setup test state for harvesting
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, true, true);

        // advance season to print beans
        advanceSeason();

        // assert user has harvestable pods
        (uint256 totalHarvestablePods, ) = _userHarvestablePods(state.user);
        assertGt(totalHarvestablePods, 0, "user should have harvestable pods to harvest");

        // Setup blueprint with minHarvestAmount less than harvest tip amount
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            11e6, // minPlantAmount
            1e6, // minHarvestAmount < 10e6 (harvest tip amount)
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect revert
        vm.expectRevert("Min harvest amount must be greater than harvest tip amount");
        executeRequisition(state.operator, req, address(bs));
    }

    function test_mowPlantHarvestBlueprint_harvest_partialHarvest() public {
        // Setup test state for harvesting
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, true, true);

        // advance season to print beans
        advanceSeason();

        // get user state before harvest
        uint256 userTotalBdvBeforeHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        (uint256 totalHarvestablePods, uint256[] memory harvestablePlots) = _userHarvestablePods(
            state.user
        );

        // assert initial conditions
        assertEq(userTotalBdvBeforeHarvest, 100000e6, "user should have the initial bdv");
        assertGt(totalHarvestablePods, 0, "user should have harvestable pods to harvest");

        // Setup blueprint for partial harvest
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            11e6, // minPlantAmount
            11e6, // minHarvestAmount > 10e6 (harvest tip amount)
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect harvest event
        vm.expectEmit();
        emit Harvest(state.user, bs.activeField(), harvestablePlots, 488088481);
        executeRequisition(state.operator, req, address(bs));

        // Verify state changes after partial harvest
        uint256 userTotalBdvAfterHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        assertGt(userTotalBdvAfterHarvest, userTotalBdvBeforeHarvest, "userTotalBdv increase");

        // assert user harvestable pods is 0 after harvest
        (
            uint256 totalHarvestablePodsAfterHarvest,
            uint256[] memory harvestablePlotsAfterHarvest
        ) = _userHarvestablePods(state.user);
        assertEq(totalHarvestablePodsAfterHarvest, 0, "harvestable pods after harvest");
        assertEq(harvestablePlotsAfterHarvest.length, 0, "harvestable plots after harvest");
    }

    function test_mowPlantHarvestBlueprint_harvest_fullHarvest() public {
        // Setup test state for harvesting
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, true, true);

        // add even more liquidity to well to print more beans and clear the podline
        addLiquidityToWell(BEAN_ETH_WELL, 10000e6, 20 ether);
        addLiquidityToWell(BEAN_WSTETH_WELL, 10000e6, 20 ether);

        // advance season to print beans
        advanceSeason();

        // get user state before harvest
        uint256 userTotalBdvBeforeHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        (, uint256[] memory harvestablePlots) = _userHarvestablePods(state.user);

        // assert user has 2 harvestable plots for full harvest
        assertEq(harvestablePlots.length, 2, "user should have 2 harvestable plots");

        // Setup blueprint for full harvest
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            11e6, // minPlantAmount
            11e6, // minHarvestAmount > 10e6 (harvest tip amount)
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect harvest event
        vm.expectEmit();
        emit Harvest(state.user, bs.activeField(), harvestablePlots, 1000100000);
        executeRequisition(state.operator, req, address(bs));

        // Verify state changes after full harvest
        uint256 userTotalBdvAfterHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        assertGt(
            userTotalBdvAfterHarvest,
            userTotalBdvBeforeHarvest,
            "userTotalBdv should increase"
        );

        // get user plots and verify all harvested
        IMockFBeanstalk.Plot[] memory plots = bs.getPlotsFromAccount(state.user, bs.activeField());
        assertEq(plots.length, 0, "user should have no plots left");

        // assert the user has no harvestable pods left
        (
            uint256 totalHarvestablePodsAfterHarvest,
            uint256[] memory harvestablePlotsAfterHarvest
        ) = _userHarvestablePods(state.user);
        assertEq(totalHarvestablePodsAfterHarvest, 0, "harvestable pods after harvest");
        assertEq(harvestablePlotsAfterHarvest.length, 0, "harvestable plots after harvest");
    }

    /////////////////////////// HELPER FUNCTIONS ///////////////////////////

    /// @dev Advance to the next season and update oracles
    function advanceSeason() internal {
        warpToNextSeasonTimestamp();
        bs.sunrise();
        updateAllChainlinkOraclesWithPreviousData();
    }

    /**
     * @notice Set the peg conditions for the whitelisted wells
     * @param abovePeg If true, set the conditions for above peg
     */
    function setPegConditions(bool abovePeg) internal {
        addLiquidityToWell(
            BEAN_ETH_WELL,
            abovePeg ? 10000e6 : 10010e6, // 10,000 Beans if above peg, 10,010 Beans if below peg
            abovePeg ? 11 ether : 10 ether // 11 eth if above peg, 10 ether. if below peg
        );
        addLiquidityToWell(
            BEAN_WSTETH_WELL,
            abovePeg ? 10000e6 : 10010e6, // 10,010 Beans if above peg, 10,000 Beans if below peg
            abovePeg ? 11 ether : 10 ether // 11 eth if above peg, 10 ether. if below peg
        );
    }

    /**
     * @notice Sows beans so that the tractor user can harvest later
     */
    function setHarvestConditions(address account) internal {
        // set soil to 1000e6
        bs.setSoilE(1000e6);
        // sow 1000e6 beans 2 times of 500e6 each
        vm.prank(account);
        bs.sow(500e6, 0, uint8(LibTransfer.From.EXTERNAL));
        vm.prank(account);
        bs.sow(500e6, 0, uint8(LibTransfer.From.EXTERNAL));
    }

    /**
     * @notice Skip the germination process by advancing season 2 times
     */
    function skipGermination() internal {
        advanceSeason();
        advanceSeason();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TractorHelpers} from "contracts/ecosystem/tractor/utils/TractorHelpers.sol";
import {SiloHelpers} from "contracts/ecosystem/tractor/utils/SiloHelpers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TractorTestHelper} from "test/foundry/utils/TractorTestHelper.sol";
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {MowPlantHarvestBlueprint} from "contracts/ecosystem/MowPlantHarvestBlueprint.sol";
import {GasCostCalculator} from "contracts/ecosystem/tractor/utils/GasCostCalculator.sol";
import "forge-std/console.sol";

contract MowPlantHarvestBlueprintTest is TractorTestHelper {
    address[] farmers;
    BeanstalkPrice beanstalkPrice;

    event Plant(address indexed account, uint256 beans);
    event Harvest(address indexed account, uint256 fieldId, uint256[] plots, uint256 beans);

    uint256 STALK_DECIMALS = 1e10;
    int256 DEFAULT_TIP_AMOUNT = 10e6; // 10 BEAN
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16
    uint256 UNEXECUTABLE_MIN_HARVEST_AMOUNT = 1_000_000_000e6; // 1B BEAN
    uint256 PODS_FIELD_0 = 1000100000;
    uint256 PODS_FIELD_1 = 250e6;

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

        // Deploy BeanstalkPrice (unused here but needed for TractorHelpers)
        beanstalkPrice = new BeanstalkPrice(address(bs));
        vm.label(address(beanstalkPrice), "BeanstalkPrice");

        // Deploy TractorHelpers (2 args: beanstalk, beanstalkPrice)
        tractorHelpers = new TractorHelpers(address(bs), address(beanstalkPrice));
        vm.label(address(tractorHelpers), "TractorHelpers");

        // Deploy SiloHelpers (3 args: beanstalk, tractorHelpers, priceManipulation)
        siloHelpers = new SiloHelpers(
            address(bs),
            address(tractorHelpers),
            address(0) // priceManipulation not needed for this test
        );
        vm.label(address(siloHelpers), "SiloHelpers");

        // Deploy GasCostCalculator
        GasCostCalculator gasCostCalculator = new GasCostCalculator(
            address(bs),
            address(this),
            50000 // baseGasOverhead
        );
        vm.label(address(gasCostCalculator), "GasCostCalculator");

        // Deploy MowPlantHarvestBlueprint with TractorHelpers, SiloHelpers and GasCostCalculator addresses
        mowPlantHarvestBlueprint = new MowPlantHarvestBlueprint(
            address(bs),
            address(this),
            address(tractorHelpers),
            address(gasCostCalculator),
            address(siloHelpers)
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
        bool twoFields,
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

        if (setupHarvest) setHarvestConditions(state.user, twoFields);

        return state;
    }

    /////////////////////////// TESTS ///////////////////////////

    function test_mowPlantHarvestBlueprint_Mow() public {
        // Setup test state
        // setupPlant: false, setupHarvest: false, abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, false, false, true);

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
            UNEXECUTABLE_MIN_HARVEST_AMOUNT, // minHarvestAmount (for all fields)
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Pre-calculate harvest data BEFORE expectRevert (to avoid consuming the expectation)
        IMockFBeanstalk.ContractData[] memory dynamicData = getHarvestDynamicDataForUser(
            state.user
        );

        // Try to execute before the last minutes of the season, expect revert
        vm.expectRevert("MowPlantHarvestBlueprint: None of the order conditions are met");
        executeRequisitionWithDynamicData(state.operator, req, address(bs), dynamicData);

        // Try to execute after in last minutes of the season
        vm.warp(bs.getNextSeasonStart() - 1 seconds);
        executeWithHarvestData(state.operator, state.user, req);

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

    function test_mowPlantHarvestBlueprint_plant_revertWhenInsufficientPlantableBeans() public {
        // Setup test state for planting
        // setupPlant: true, setupHarvest: false, twoFields: true, abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(true, false, false, true);

        // assert that the user has earned beans
        assertGt(bs.balanceOfEarnedBeans(state.user), 0, "user should have earned beans to plant");

        // Setup blueprint with minPlantAmount greater than total plantable beans
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            type(uint256).max, // minPlantAmount > (total plantable beans)
            UNEXECUTABLE_MIN_HARVEST_AMOUNT, // minHarvestAmount (for all fields)
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Pre-calculate harvest data BEFORE expectRevert
        IMockFBeanstalk.ContractData[] memory dynamicData = getHarvestDynamicDataForUser(
            state.user
        );

        // Execute requisition, expect revert
        vm.expectRevert("MowPlantHarvestBlueprint: None of the order conditions are met");
        executeRequisitionWithDynamicData(state.operator, req, address(bs), dynamicData);
    }

    function test_mowPlantHarvestBlueprint_plant_success() public {
        // Setup test state for planting
        // setupPlant: true, setupHarvest: false, twoFields: true, abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(true, false, true, true);

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
            UNEXECUTABLE_MIN_HARVEST_AMOUNT, // minHarvestAmount (for all fields)
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect plant event
        vm.expectEmit();
        emit Plant(state.user, 1933023687);
        executeWithHarvestData(state.operator, state.user, req);

        // Verify state changes after successful plant
        uint256 userTotalStalkAfterPlant = bs.balanceOfStalk(state.user);
        uint256 userTotalBdvAfterPlant = bs.balanceOfDepositedBdv(state.user, state.beanToken);

        assertGt(userTotalStalkAfterPlant, userTotalStalkBeforePlant, "userTotalStalk increase");
        assertGt(userTotalBdvAfterPlant, userTotalBdvBeforePlant, "userTotalBdv increase");
    }

    function test_mowPlantHarvestBlueprint_harvest_partialHarvest() public {
        // Setup test state for harvesting
        // setupPlant: false, setupHarvest: true, twoFields: true, abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, true, true, true);

        // advance season to print beans
        advanceSeason();

        // get user state before harvest
        uint256 userTotalBdvBeforeHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        (, uint256[] memory harvestablePlots) = assertAndGetHarvestablePods(
            state.user,
            DEFAULT_FIELD_ID,
            1, // expected plots
            488088481 // expected pods
        );

        // assert initial conditions
        assertEq(userTotalBdvBeforeHarvest, 100000e6, "user should have the initial bdv");

        // Setup blueprint for partial harvest
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            11e6, // minPlantAmount
            11e6, // minHarvestAmount > 10e6 (harvest tip amount) (for all fields)
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect harvest event
        vm.expectEmit();
        emit Harvest(state.user, bs.activeField(), harvestablePlots, 488088481);
        executeWithHarvestData(state.operator, state.user, req);

        // Verify state changes after partial harvest
        uint256 userTotalBdvAfterHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        assertGt(userTotalBdvAfterHarvest, userTotalBdvBeforeHarvest, "userTotalBdv increase");

        // assert user harvestable pods is 0 after harvest
        assertNoHarvestablePods(state.user, DEFAULT_FIELD_ID);
    }

    function test_mowPlantHarvestBlueprint_harvest_fullHarvest() public {
        // Setup test state for harvesting
        // setupPlant: false, setupHarvest: true, twoFields: false, abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, true, false, true);

        // add even more liquidity to well to print more beans and clear the podline
        addLiquidityToWell(BEAN_ETH_WELL, 10000e6, 20 ether);
        addLiquidityToWell(BEAN_WSTETH_WELL, 10000e6, 20 ether);

        // advance season to print beans
        advanceSeason();

        // get user state before harvest
        uint256 userTotalBdvBeforeHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        (, uint256[] memory harvestablePlots) = assertAndGetHarvestablePods(
            state.user,
            DEFAULT_FIELD_ID,
            2, // expected plots
            PODS_FIELD_0 // expected pods
        );

        // Setup blueprint for full harvest
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            11e6, // minPlantAmount
            11e6, // minHarvestAmount > 10e6 (harvest tip amount) (for all fields)
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect harvest event
        vm.expectEmit();
        emit Harvest(state.user, bs.activeField(), harvestablePlots, 1000100000);
        executeWithHarvestData(state.operator, state.user, req);

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
        assertNoHarvestablePods(state.user, DEFAULT_FIELD_ID);
    }

    function test_mowPlantHarvestBlueprint_harvest_fullHarvest_twoFields() public {
        // Setup test state for harvesting
        // setupPlant: false, setupHarvest: true, twoFields: true, abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, true, true, true);

        // add even more liquidity to well to print more beans and clear the podline at fieldId 0
        // note: field id 1 has had its harvestable index incremented already
        addLiquidityToWell(BEAN_ETH_WELL, 10000e6, 20 ether);
        addLiquidityToWell(BEAN_WSTETH_WELL, 10000e6, 20 ether);

        // advance season to print beans
        advanceSeason();

        // get user state before harvest for fieldId 0
        uint256 userTotalBdvBeforeHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        (, uint256[] memory field0HarvestablePlots) = assertAndGetHarvestablePods(
            state.user,
            DEFAULT_FIELD_ID,
            2, // expected plots
            PODS_FIELD_0 // expected pods
        );
        // get user state before harvest for fieldId 1
        (, uint256[] memory field1HarvestablePlots) = assertAndGetHarvestablePods(
            state.user,
            PAYBACK_FIELD_ID,
            1, // expected plots
            PODS_FIELD_1 // expected pods
        );

        // Setup blueprint for full harvest
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO, // sourceMode for tip
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            11e6, // minPlantAmount
            11e6, // minHarvestAmount > 10e6 (harvest tip amount) (for all fields)
            state.operator, // tipAddress
            state.mowTipAmount, // mowTipAmount
            state.plantTipAmount, // plantTipAmount
            state.harvestTipAmount, // harvestTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        // Execute requisition, expect harvest events for both fields
        vm.expectEmit();
        emit Harvest(state.user, DEFAULT_FIELD_ID, field0HarvestablePlots, 1000100000);
        emit Harvest(state.user, PAYBACK_FIELD_ID, field1HarvestablePlots, 250e6);
        executeWithHarvestData(state.operator, state.user, req);

        // Verify state changes after full harvest
        uint256 userTotalBdvAfterHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        assertGt(userTotalBdvAfterHarvest, userTotalBdvBeforeHarvest, "userTotalBdv increase");

        // get user plots and verify all harvested for fieldId 0
        IMockFBeanstalk.Plot[] memory plots = bs.getPlotsFromAccount(state.user, DEFAULT_FIELD_ID);
        assertEq(bs.getPlotsFromAccount(state.user, DEFAULT_FIELD_ID).length, 0, "no plots left");

        // assert the user has no harvestable pods left
        assertNoHarvestablePods(state.user, DEFAULT_FIELD_ID);

        // get user plots and verify all harvested for fieldId 1
        plots = bs.getPlotsFromAccount(state.user, PAYBACK_FIELD_ID);
        assertEq(plots.length, 0, "no plots left");

        // assert the user has no harvestable pods left
        assertNoHarvestablePods(state.user, PAYBACK_FIELD_ID);
    }

    /////////////////////////// HELPER FUNCTIONS ///////////////////////////

    /**
     * @notice Assert user has no harvestable pods remaining for a field
     */
    function assertNoHarvestablePods(address user, uint256 fieldId) internal {
        (uint256 totalPods, uint256[] memory plots) = _userHarvestablePods(user, fieldId);
        assertEq(totalPods, 0, "harvestable pods after harvest");
        assertEq(plots.length, 0, "harvestable plots after harvest");
    }

    /**
     * @notice Assert user has expected harvestable pods and return them
     */
    function assertAndGetHarvestablePods(
        address user,
        uint256 fieldId,
        uint256 expectedPlots,
        uint256 expectedPods
    ) internal returns (uint256 totalPods, uint256[] memory plots) {
        (totalPods, plots) = _userHarvestablePods(user, fieldId);
        assertEq(
            plots.length,
            expectedPlots,
            string.concat("harvestable plots for fieldId ", vm.toString(fieldId))
        );
        assertGt(
            totalPods,
            0,
            string.concat("harvestable pods for fieldId ", vm.toString(fieldId))
        );
        assertEq(totalPods, expectedPods, "harvestable pods for fieldId");
    }

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
     * Results in PODS_FIELD_0 for fieldId 0 and optionally PODS_FIELD_1 for fieldId 1
     */
    function setHarvestConditions(address account, bool twoFields) internal {
        //////  Set active field harvest by sowing //////
        // set soil to 1000e6
        bs.setSoilE(1000e6);
        // sow 1000e6 beans 2 times of 500e6 each
        vm.prank(account);
        bs.sow(500e6, 0, uint8(LibTransfer.From.EXTERNAL));
        vm.prank(account);
        bs.sow(500e6, 0, uint8(LibTransfer.From.EXTERNAL));
        /// Give the user pods in fieldId 1 and increment harvestable index ///
        if (twoFields) {
            bs.setUserPodsAtField(account, PAYBACK_FIELD_ID, 0, 250e6);
            bs.incrementTotalHarvestableE(PAYBACK_FIELD_ID, 250e6);
        }
    }

    /**
     * @notice Skip the germination process by advancing season 2 times
     */
    function skipGermination() internal {
        advanceSeason();
        advanceSeason();
    }

    /**
     * @notice Get harvest dynamic data for both fields
     * @dev Must be called BEFORE vm.expectRevert to avoid consuming the revert expectation
     */
    function getHarvestDynamicDataForUser(
        address user
    ) internal view returns (IMockFBeanstalk.ContractData[] memory) {
        uint256[] memory fieldIds = new uint256[](2);
        fieldIds[0] = DEFAULT_FIELD_ID;
        fieldIds[1] = PAYBACK_FIELD_ID;
        return createHarvestDynamicData(user, fieldIds);
    }

    /**
     * @notice Execute a requisition with harvest dynamic data for both fields
     * @dev Creates harvest data for DEFAULT_FIELD_ID (0) and PAYBACK_FIELD_ID (1)
     */
    function executeWithHarvestData(
        address operator,
        address user,
        IMockFBeanstalk.Requisition memory req
    ) internal {
        IMockFBeanstalk.ContractData[] memory dynamicData = getHarvestDynamicDataForUser(user);
        executeRequisitionWithDynamicData(operator, req, address(bs), dynamicData);
    }
}

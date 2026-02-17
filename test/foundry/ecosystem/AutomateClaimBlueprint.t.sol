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
import {AutomateClaimBlueprint, IBarnPaybackClaim} from "contracts/ecosystem/AutomateClaimBlueprint.sol";
import {BarnPayback} from "contracts/ecosystem/beanstalkShipments/barn/BarnPayback.sol";
import {BeanstalkFertilizer} from "contracts/ecosystem/beanstalkShipments/barn/BeanstalkFertilizer.sol";
import {SiloPayback} from "contracts/ecosystem/beanstalkShipments/SiloPayback.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "forge-std/console.sol";

contract AutomateClaimBlueprintTest is TractorTestHelper {
    address[] farmers;
    BeanstalkPrice beanstalkPrice;
    BarnPayback barnPayback;
    SiloPayback siloPaybackContract;

    event Plant(address indexed account, uint256 beans);
    event Harvest(address indexed account, uint256 fieldId, uint256[] plots, uint256 beans);
    event ClaimFertilizer(uint256[] ids, uint256 beans);
    event SiloPaybackRewardsClaimed(
        address indexed account,
        address indexed recipient,
        uint256 amount,
        LibTransfer.To toMode
    );

    uint256 STALK_DECIMALS = 1e10;
    int256 DEFAULT_TIP_AMOUNT = 10e6; // 10 BEAN
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16
    uint256 UNEXECUTABLE_MIN_HARVEST_AMOUNT = 1_000_000_000e6; // 1B BEAN
    uint256 UNEXECUTABLE_MIN_RINSE_AMOUNT = type(uint256).max;
    uint256 UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT = type(uint256).max;
    uint256 PODS_FIELD_0 = 1000100000;
    uint256 PODS_FIELD_1 = 250e6;

    // BarnPayback fertilizer constants
    uint128 constant INITIAL_BPF = 45e6;
    uint128 constant FERT_ID_1 = 50e6;
    uint128 constant FERT_ID_2 = 100e6;
    uint128 constant FERT_ID_3 = 150e6;

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

        // Deploy BarnPayback (proxy pattern)
        barnPayback = _deployBarnPayback();
        vm.label(address(barnPayback), "BarnPayback");

        // Deploy SiloPayback (proxy pattern)
        siloPaybackContract = _deploySiloPayback();
        vm.label(address(siloPaybackContract), "SiloPayback");

        // Deploy AutomateClaimBlueprint with TractorHelpers, SiloHelpers, BarnPayback and SiloPayback addresses
        automateClaimBlueprint = new AutomateClaimBlueprint(
            address(bs),
            address(this),
            address(tractorHelpers),
            address(siloHelpers),
            address(barnPayback),
            address(siloPaybackContract)
        );
        vm.label(address(automateClaimBlueprint), "AutomateClaimBlueprint");

        setTractorHelpers(address(tractorHelpers));
        setAutomateClaimBlueprint(address(automateClaimBlueprint));

        // Advance season to grow stalk
        advanceSeason();
    }

    /**
     * @notice Setup the test state for the AutomateClaimBlueprint test
     * @param setupPlant If true, setup the conditions for planting
     * @param setupHarvest If true, setup the conditions for harvesting
     * @param abovePeg If true, setup the conditions for above peg
     * @return TestState The test state
     */
    function setupAutomateClaimBlueprintTest(
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

    function test_automateClaimBlueprint_Mow() public {
        // Setup test state
        // setupPlant: false, setupHarvest: false, abovePeg: true
        TestState memory state = setupAutomateClaimBlueprintTest(false, false, false, true);

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

        // Setup automateClaimBlueprint
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: UNEXECUTABLE_MIN_RINSE_AMOUNT,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: 0,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Pre-calculate harvest data BEFORE expectRevert (to avoid consuming the expectation)
        IMockFBeanstalk.ContractData[] memory dynamicData = getHarvestDynamicDataForUser(
            state.user
        );

        // Try to execute before the last minutes of the season, expect revert
        vm.expectRevert("AutomateClaimBlueprint: None of the order conditions are met");
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

    function test_automateClaimBlueprint_plant_revertWhenInsufficientPlantableBeans() public {
        // Setup test state for planting
        // setupPlant: true, setupHarvest: false, twoFields: true, abovePeg: true
        TestState memory state = setupAutomateClaimBlueprintTest(true, false, false, true);

        // assert that the user has earned beans
        assertGt(bs.balanceOfEarnedBeans(state.user), 0, "user should have earned beans to plant");

        // Setup blueprint with minPlantAmount greater than total plantable beans
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: UNEXECUTABLE_MIN_RINSE_AMOUNT,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: 0,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Pre-calculate harvest data BEFORE expectRevert
        IMockFBeanstalk.ContractData[] memory dynamicData = getHarvestDynamicDataForUser(
            state.user
        );

        // Execute requisition, expect revert
        vm.expectRevert("AutomateClaimBlueprint: None of the order conditions are met");
        executeRequisitionWithDynamicData(state.operator, req, address(bs), dynamicData);
    }

    function test_automateClaimBlueprint_plant_success() public {
        // Setup test state for planting
        // setupPlant: true, setupHarvest: false, twoFields: true, abovePeg: true
        TestState memory state = setupAutomateClaimBlueprintTest(true, false, true, true);

        // get user state before plant
        uint256 userTotalStalkBeforePlant = bs.balanceOfStalk(state.user);
        uint256 userTotalBdvBeforePlant = bs.balanceOfDepositedBdv(state.user, state.beanToken);

        // assert user has grown stalk and initial bdv
        assertGt(userTotalStalkBeforePlant, 0, "user should have grown stalk to plant");
        assertEq(userTotalBdvBeforePlant, 100000e6, "user should have the initial bdv");
        assertGt(bs.balanceOfEarnedBeans(state.user), 0, "user should have earned beans to plant");

        // Setup blueprint with valid minPlantAmount
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: 11e6,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: UNEXECUTABLE_MIN_RINSE_AMOUNT,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: 0,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
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

    function test_automateClaimBlueprint_harvest_partialHarvest() public {
        // Setup test state for harvesting
        // setupPlant: false, setupHarvest: true, twoFields: true, abovePeg: true
        TestState memory state = setupAutomateClaimBlueprintTest(false, true, true, true);

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
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: 11e6,
                minHarvestAmount: 11e6,
                minRinseAmount: UNEXECUTABLE_MIN_RINSE_AMOUNT,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: 0,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
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

    function test_automateClaimBlueprint_harvest_fullHarvest() public {
        // Setup test state for harvesting
        // setupPlant: false, setupHarvest: true, twoFields: false, abovePeg: true
        TestState memory state = setupAutomateClaimBlueprintTest(false, true, false, true);

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
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: 11e6,
                minHarvestAmount: 11e6,
                minRinseAmount: UNEXECUTABLE_MIN_RINSE_AMOUNT,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: 0,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
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

    function test_automateClaimBlueprint_harvest_fullHarvest_twoFields() public {
        // Setup test state for harvesting
        // setupPlant: false, setupHarvest: true, twoFields: true, abovePeg: true
        TestState memory state = setupAutomateClaimBlueprintTest(false, true, true, true);

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
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: 11e6,
                minHarvestAmount: 11e6,
                minRinseAmount: UNEXECUTABLE_MIN_RINSE_AMOUNT,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: 0,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
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

    /**
     * @notice Execute a requisition with harvest and rinse dynamic data
     */
    function executeWithHarvestAndRinseData(
        address operator,
        address user,
        IMockFBeanstalk.Requisition memory req,
        uint256[] memory fertilizerIds
    ) internal {
        IMockFBeanstalk.ContractData[] memory harvestData = getHarvestDynamicDataForUser(user);
        IMockFBeanstalk.ContractData[] memory rinseData = createRinseDynamicData(fertilizerIds);
        IMockFBeanstalk.ContractData[] memory merged = mergeHarvestAndRinseDynamicData(
            harvestData,
            rinseData
        );
        executeRequisitionWithDynamicData(operator, req, address(bs), merged);
    }

    /////////////////////////// BARN PAYBACK HELPERS ///////////////////////////

    /**
     * @notice Deploy BarnPayback contract via proxy pattern (same as BarnPayback.t.sol)
     */
    function _deployBarnPayback() internal returns (BarnPayback) {
        BarnPayback implementation = new BarnPayback();

        BeanstalkFertilizer.InitSystemFertilizer
            memory initSystemFert = _createInitSystemFertilizerData();

        bytes memory data = abi.encodeWithSelector(
            BarnPayback.initialize.selector,
            address(BEAN),
            address(BEANSTALK),
            address(0), // contract distributor
            initSystemFert
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(this),
            data
        );

        return BarnPayback(address(proxy));
    }

    function _createInitSystemFertilizerData()
        internal
        pure
        returns (BeanstalkFertilizer.InitSystemFertilizer memory)
    {
        uint128[] memory fertilizerIds = new uint128[](3);
        fertilizerIds[0] = FERT_ID_1;
        fertilizerIds[1] = FERT_ID_2;
        fertilizerIds[2] = FERT_ID_3;

        uint256[] memory fertilizerAmounts = new uint256[](3);
        fertilizerAmounts[0] = 100;
        fertilizerAmounts[1] = 50;
        fertilizerAmounts[2] = 25;

        uint256 totalFertilizer = (FERT_ID_1 * 100) + (FERT_ID_2 * 50) + (FERT_ID_3 * 25);

        return
            BeanstalkFertilizer.InitSystemFertilizer({
                fertilizerIds: fertilizerIds,
                fertilizerAmounts: fertilizerAmounts,
                activeFertilizer: uint128(175),
                fertilizedIndex: uint128(0),
                unfertilizedIndex: uint128(totalFertilizer),
                fertilizedPaidIndex: uint128(0),
                fertFirst: FERT_ID_1,
                fertLast: FERT_ID_3,
                bpf: INITIAL_BPF,
                leftoverBeans: uint128(0)
            });
    }

    /**
     * @notice Mint fertilizers to a user and send rewards so they have claimable beans
     * @dev In the tractor context, BarnPayback's `transferToken` call routes through the
     * diamond which uses LibTractor._user() as the sender. This means the protocol pulls
     * beans from the tractor publisher's external balance instead of BarnPayback's.
     * To make this work, we fund the user's external balance with enough beans to cover
     * the claim amount. The user already has max approval on the diamond from test setup.
     */
    function _setupRinseConditions(address user) internal {
        // Mint fertilizers to the user
        BarnPayback.AccountFertilizerData[]
            memory accounts = new BarnPayback.AccountFertilizerData[](1);
        accounts[0] = BarnPayback.AccountFertilizerData({
            account: user,
            amount: 60,
            lastBpf: INITIAL_BPF
        });

        BarnPayback.Fertilizers[] memory fertData = new BarnPayback.Fertilizers[](1);
        fertData[0] = BarnPayback.Fertilizers({fertilizerId: FERT_ID_1, accountData: accounts});

        barnPayback.mintFertilizers(fertData);

        // Send rewards to create claimable beans
        uint256 rewardAmount = 100e6;
        deal(address(BEAN), address(deployer), rewardAmount);
        vm.prank(deployer);
        IERC20(address(BEAN)).transfer(address(barnPayback), rewardAmount);
        vm.prank(address(BEANSTALK));
        barnPayback.barnPaybackReceive(rewardAmount);

        // Fund user's external bean balance to cover claimFertilized via tractor.
        // In tractor context, the diamond's transferToken uses LibTractor._user() (the publisher)
        // as the sender, so the user needs external beans for the safeTransferFrom to succeed.
        uint256[] memory fertIds = new uint256[](1);
        fertIds[0] = FERT_ID_1;
        uint256 claimable = barnPayback.balanceOfFertilized(user, fertIds);
        mintTokensToUser(user, address(BEAN), claimable);
    }

    /**
     * @notice Setup rinse conditions with multiple fertilizer IDs (FERT_ID_1 and FERT_ID_2)
     */
    function _setupRinseConditionsMultipleIds(address user) internal {
        // Mint fertilizers from 2 different IDs to the user
        BarnPayback.AccountFertilizerData[]
            memory accounts = new BarnPayback.AccountFertilizerData[](1);
        accounts[0] = BarnPayback.AccountFertilizerData({
            account: user,
            amount: 30,
            lastBpf: INITIAL_BPF
        });

        BarnPayback.Fertilizers[] memory fertData = new BarnPayback.Fertilizers[](2);
        fertData[0] = BarnPayback.Fertilizers({fertilizerId: FERT_ID_1, accountData: accounts});
        fertData[1] = BarnPayback.Fertilizers({fertilizerId: FERT_ID_2, accountData: accounts});

        barnPayback.mintFertilizers(fertData);

        // Send rewards to create claimable beans
        uint256 rewardAmount = 200e6;
        deal(address(BEAN), address(deployer), rewardAmount);
        vm.prank(deployer);
        IERC20(address(BEAN)).transfer(address(barnPayback), rewardAmount);
        vm.prank(address(BEANSTALK));
        barnPayback.barnPaybackReceive(rewardAmount);

        // Fund user's external bean balance for both fert IDs
        uint256[] memory fertIds = new uint256[](2);
        fertIds[0] = FERT_ID_1;
        fertIds[1] = FERT_ID_2;
        uint256 claimable = barnPayback.balanceOfFertilized(user, fertIds);
        mintTokensToUser(user, address(BEAN), claimable);
    }

    /////////////////////////// RINSE TESTS ///////////////////////////

    function test_automateClaimBlueprint_rinse_multipleFertilizerIds() public {
        // Setup test state (no plant, no harvest, above peg)
        TestState memory state = setupAutomateClaimBlueprintTest(false, false, false, true);

        // Setup rinse conditions with multiple fertilizer IDs
        _setupRinseConditionsMultipleIds(state.user);

        // Get the fertilizer IDs for the user
        uint256[] memory fertIds = new uint256[](2);
        fertIds[0] = FERT_ID_1;
        fertIds[1] = FERT_ID_2;

        // Verify user has claimable fertilized beans for EACH fert ID individually
        uint256[] memory singleId1 = new uint256[](1);
        singleId1[0] = FERT_ID_1;
        assertGt(
            barnPayback.balanceOfFertilized(state.user, singleId1),
            0,
            "user should have claimable beans for FERT_ID_1"
        );
        uint256[] memory singleId2 = new uint256[](1);
        singleId2[0] = FERT_ID_2;
        assertGt(
            barnPayback.balanceOfFertilized(state.user, singleId2),
            0,
            "user should have claimable beans for FERT_ID_2"
        );

        // Get total claimable across both IDs
        uint256 totalClaimable = barnPayback.balanceOfFertilized(state.user, fertIds);
        assertGt(totalClaimable, 0, "user should have total claimable fertilized beans");

        // Get user BDV before rinse
        uint256 userTotalBdvBefore = bs.balanceOfDepositedBdv(state.user, state.beanToken);

        // Setup blueprint with rinse enabled (minRinseAmount = 1)
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: 1,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: DEFAULT_TIP_AMOUNT,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Execute with rinse data for multiple IDs
        vm.expectEmit();
        emit ClaimFertilizer(fertIds, totalClaimable);
        executeWithHarvestAndRinseData(state.operator, state.user, req, fertIds);

        // Verify ALL fertilizer IDs were claimed
        assertEq(
            barnPayback.balanceOfFertilized(state.user, singleId1),
            0,
            "FERT_ID_1 should be fully claimed"
        );
        assertEq(
            barnPayback.balanceOfFertilized(state.user, singleId2),
            0,
            "FERT_ID_2 should be fully claimed"
        );

        // Verify BDV increased
        uint256 userTotalBdvAfter = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        assertGt(userTotalBdvAfter, userTotalBdvBefore, "userTotalBdv should increase from rinse");
    }

    function test_automateClaimBlueprint_rinse_withHarvest() public {
        // Setup test state for harvesting (twoFields=true for deterministic field 1 harvest)
        TestState memory state = setupAutomateClaimBlueprintTest(false, true, true, true);

        // Also setup rinse conditions
        _setupRinseConditions(state.user);

        // Advance season to print beans for harvest
        advanceSeason();

        // Get user state before operations
        uint256 userTotalBdvBefore = bs.balanceOfDepositedBdv(state.user, state.beanToken);

        // Verify harvestable pods exist
        (uint256 harvestablePods, ) = _userHarvestablePods(state.user, DEFAULT_FIELD_ID);
        assertGt(harvestablePods, 0, "user should have harvestable pods");

        // Verify claimable rinse beans exist
        uint256[] memory fertIds = new uint256[](1);
        fertIds[0] = FERT_ID_1;
        uint256 claimableRinse = barnPayback.balanceOfFertilized(state.user, fertIds);
        assertGt(claimableRinse, 0, "user should have claimable fertilized beans");

        // Setup blueprint with both harvest and rinse enabled
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: 11e6,
                minRinseAmount: 1,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: DEFAULT_TIP_AMOUNT,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Execute with both harvest and rinse data
        executeWithHarvestAndRinseData(state.operator, state.user, req, fertIds);

        // Verify BDV increased (both harvested + rinsed beans deposited)
        uint256 userTotalBdvAfter = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        assertGt(
            userTotalBdvAfter,
            userTotalBdvBefore,
            "userTotalBdv should increase from harvest + rinse"
        );

        // Verify rinse fully claimed
        uint256 postClaimBalance = barnPayback.balanceOfFertilized(state.user, fertIds);
        assertEq(postClaimBalance, 0, "rinse should be fully claimed");

        // Verify harvest complete on field 0
        assertNoHarvestablePods(state.user, DEFAULT_FIELD_ID);
    }

    function test_automateClaimBlueprint_rinse_success() public {
        // Setup test state (no plant, no harvest, above peg)
        TestState memory state = setupAutomateClaimBlueprintTest(false, false, false, true);

        // Setup rinse conditions: mint fertilizers and send rewards
        _setupRinseConditions(state.user);

        // Get the fertilizer IDs for the user
        uint256[] memory fertIds = new uint256[](1);
        fertIds[0] = FERT_ID_1;

        // Verify user has claimable fertilized beans
        uint256 claimableAmount = barnPayback.balanceOfFertilized(state.user, fertIds);
        assertGt(claimableAmount, 0, "user should have claimable fertilized beans");

        // Get user BDV before rinse
        uint256 userTotalBdvBefore = bs.balanceOfDepositedBdv(state.user, state.beanToken);

        // Setup blueprint with rinse enabled (minRinseAmount = 1)
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: 1,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: DEFAULT_TIP_AMOUNT,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Execute with rinse data
        vm.expectEmit();
        emit ClaimFertilizer(fertIds, claimableAmount);
        executeWithHarvestAndRinseData(state.operator, state.user, req, fertIds);

        // Verify fertilized beans were claimed (balance should be 0 now)
        uint256 postClaimBalance = barnPayback.balanceOfFertilized(state.user, fertIds);
        assertEq(postClaimBalance, 0, "user should have no more claimable fertilized beans");

        // Verify BDV increased (rinsed beans deposited to silo)
        uint256 userTotalBdvAfter = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        assertGt(userTotalBdvAfter, userTotalBdvBefore, "userTotalBdv should increase from rinse");
    }

    function test_automateClaimBlueprint_rinse_belowMinimum() public {
        // Setup test state (no plant, no harvest, above peg)
        TestState memory state = setupAutomateClaimBlueprintTest(false, false, false, true);

        // Setup rinse conditions
        _setupRinseConditions(state.user);

        uint256[] memory fertIds = new uint256[](1);
        fertIds[0] = FERT_ID_1;

        // Verify user has claimable beans
        uint256 claimableAmount = barnPayback.balanceOfFertilized(state.user, fertIds);
        assertGt(claimableAmount, 0, "user should have claimable fertilized beans");

        // Setup blueprint with minRinseAmount higher than claimable (rinse skipped)
        // Also disable mow/plant/harvest so we expect a full revert
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: type(uint256).max,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: claimableAmount + 1,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: DEFAULT_TIP_AMOUNT,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Pre-calculate dynamic data BEFORE expectRevert
        IMockFBeanstalk.ContractData[] memory harvestData = getHarvestDynamicDataForUser(
            state.user
        );
        IMockFBeanstalk.ContractData[] memory rinseData = createRinseDynamicData(fertIds);
        IMockFBeanstalk.ContractData[] memory merged = mergeHarvestAndRinseDynamicData(
            harvestData,
            rinseData
        );

        // Execute - should revert since all conditions are skipped
        vm.expectRevert("AutomateClaimBlueprint: None of the order conditions are met");
        executeRequisitionWithDynamicData(state.operator, req, address(bs), merged);
    }

    function test_automateClaimBlueprint_rinse_noOperatorData() public {
        // Setup test state (no plant, no harvest, above peg)
        TestState memory state = setupAutomateClaimBlueprintTest(false, false, false, true);

        // Setup rinse conditions
        _setupRinseConditions(state.user);

        // Setup blueprint with rinse enabled but operator provides NO rinse data
        // Also disable mow/plant/harvest so we expect a full revert
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: type(uint256).max,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: 1,
                minUnripeClaimAmount: UNEXECUTABLE_MIN_UNRIPE_CLAIM_AMOUNT,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: DEFAULT_TIP_AMOUNT,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Pre-calculate dynamic data BEFORE expectRevert (harvest data only, no rinse data)
        IMockFBeanstalk.ContractData[] memory dynamicData = getHarvestDynamicDataForUser(
            state.user
        );

        // Execute without rinse data - should revert since all conditions are skipped
        vm.expectRevert("AutomateClaimBlueprint: None of the order conditions are met");
        executeRequisitionWithDynamicData(state.operator, req, address(bs), dynamicData);
    }

    /////////////////////////// SILO PAYBACK HELPERS ///////////////////////////

    /**
     * @notice Deploy SiloPayback contract via proxy pattern (same as BarnPayback)
     */
    function _deploySiloPayback() internal returns (SiloPayback) {
        SiloPayback implementation = new SiloPayback();
        bytes memory data = abi.encodeWithSelector(
            SiloPayback.initialize.selector,
            address(BEAN),
            address(BEANSTALK)
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(this),
            data
        );
        return SiloPayback(address(proxy));
    }

    /**
     * @notice Setup unripe claim conditions for a user
     * @dev Mints UnripeBDV tokens to the user, sends Pinto rewards to SiloPayback,
     * and funds the user's external bean balance to cover the claim via tractor.
     * Same external balance funding pattern as _setupRinseConditions.
     */
    function _setupUnripeClaimConditions(address user) internal {
        // Mint UnripeBDV tokens to the user
        SiloPayback.UnripeBdvTokenData[] memory data = new SiloPayback.UnripeBdvTokenData[](1);
        data[0] = SiloPayback.UnripeBdvTokenData({receipient: user, bdv: 1000e6});
        siloPaybackContract.batchMint(data);

        // Send Pinto rewards to SiloPayback to create earned rewards
        uint256 rewardAmount = 100e6;
        deal(address(BEAN), address(deployer), rewardAmount);
        vm.prank(deployer);
        IERC20(address(BEAN)).transfer(address(siloPaybackContract), rewardAmount);
        vm.prank(address(BEANSTALK));
        siloPaybackContract.siloPaybackReceive(rewardAmount);

        // Fund user's external bean balance to cover claim via tractor
        // (same pattern as _setupRinseConditions - transferToken uses tractor user as sender)
        uint256 earnedAmount = siloPaybackContract.earned(user);
        mintTokensToUser(user, address(BEAN), earnedAmount);
    }

    /////////////////////////// UNRIPE CLAIM TESTS ///////////////////////////

    function test_automateClaimBlueprint_unripeClaim_success() public {
        // Setup test state (no plant, no harvest, above peg)
        TestState memory state = setupAutomateClaimBlueprintTest(false, false, false, true);

        // Setup unripe claim conditions
        _setupUnripeClaimConditions(state.user);

        // Verify user has earned rewards
        uint256 earnedBefore = siloPaybackContract.earned(state.user);
        assertGt(earnedBefore, 0, "user should have earned unripe rewards");

        // Get user BDV before claim
        uint256 userTotalBdvBefore = bs.balanceOfDepositedBdv(state.user, state.beanToken);

        // Setup blueprint with unripe claim enabled (minUnripeClaimAmount = 1)
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: UNEXECUTABLE_MIN_RINSE_AMOUNT,
                minUnripeClaimAmount: 1,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: 0,
                unripeClaimTipAmount: DEFAULT_TIP_AMOUNT,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Execute with harvest data (unripe claim does not need dynamic data)
        vm.expectEmit();
        emit SiloPaybackRewardsClaimed(
            state.user,
            state.user,
            earnedBefore,
            LibTransfer.To.INTERNAL
        );
        executeWithHarvestData(state.operator, state.user, req);

        // Verify earned rewards are now 0
        uint256 earnedAfter = siloPaybackContract.earned(state.user);
        assertEq(earnedAfter, 0, "earned rewards should be 0 after claim");

        // Verify BDV increased (claimed beans deposited to silo)
        uint256 userTotalBdvAfter = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        assertGt(
            userTotalBdvAfter,
            userTotalBdvBefore,
            "userTotalBdv should increase from unripe claim"
        );
    }

    function test_automateClaimBlueprint_unripeClaim_belowMinimum() public {
        // Setup test state (no plant, no harvest, above peg)
        TestState memory state = setupAutomateClaimBlueprintTest(false, false, false, true);

        // Setup unripe claim conditions
        _setupUnripeClaimConditions(state.user);

        // Verify user has earned rewards
        uint256 earnedAmount = siloPaybackContract.earned(state.user);
        assertGt(earnedAmount, 0, "user should have earned unripe rewards");

        // Setup blueprint with minUnripeClaimAmount higher than earned (claim skipped)
        // Also disable mow/plant/harvest/rinse so we expect a full revert
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: type(uint256).max,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: UNEXECUTABLE_MIN_RINSE_AMOUNT,
                minUnripeClaimAmount: earnedAmount + 1,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: 0,
                unripeClaimTipAmount: DEFAULT_TIP_AMOUNT,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Pre-calculate dynamic data BEFORE expectRevert
        IMockFBeanstalk.ContractData[] memory dynamicData = getHarvestDynamicDataForUser(
            state.user
        );

        // Execute - should revert since all conditions are skipped
        vm.expectRevert("AutomateClaimBlueprint: None of the order conditions are met");
        executeRequisitionWithDynamicData(state.operator, req, address(bs), dynamicData);
    }

    function test_automateClaimBlueprint_unripeClaim_withHarvestAndRinse() public {
        // Setup test state for harvesting (twoFields=true for deterministic field 1 harvest)
        TestState memory state = setupAutomateClaimBlueprintTest(false, true, true, true);

        // Also setup rinse conditions
        _setupRinseConditions(state.user);

        // Also setup unripe claim conditions
        _setupUnripeClaimConditions(state.user);

        // Advance season to print beans for harvest
        advanceSeason();

        // Get user state before operations
        uint256 userTotalBdvBefore = bs.balanceOfDepositedBdv(state.user, state.beanToken);

        // Verify harvestable pods exist
        (uint256 harvestablePods, ) = _userHarvestablePods(state.user, DEFAULT_FIELD_ID);
        assertGt(harvestablePods, 0, "user should have harvestable pods");

        // Verify claimable rinse beans exist
        uint256[] memory fertIds = new uint256[](1);
        fertIds[0] = FERT_ID_1;
        uint256 claimableRinse = barnPayback.balanceOfFertilized(state.user, fertIds);
        assertGt(claimableRinse, 0, "user should have claimable fertilized beans");

        // Verify earned unripe rewards exist
        uint256 earnedBefore = siloPaybackContract.earned(state.user);
        assertGt(earnedBefore, 0, "user should have earned unripe rewards");

        // Fund extra external beans to cover both rinse and unripe claim via tractor.
        // Both operations pull from user's external balance (transferToken uses tractor user as sender).
        // Individual setup helpers fund their own amounts, but when combined we need the total.
        mintTokensToUser(state.user, state.beanToken, claimableRinse + earnedBefore);

        // Setup blueprint with harvest + rinse + unripe claim all enabled
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: 1 * STALK_DECIMALS,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: 11e6,
                minRinseAmount: 1,
                minUnripeClaimAmount: 1,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: DEFAULT_TIP_AMOUNT,
                unripeClaimTipAmount: DEFAULT_TIP_AMOUNT,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Execute with harvest and rinse data
        executeWithHarvestAndRinseData(state.operator, state.user, req, fertIds);

        // Verify BDV increased (harvested + rinsed + claimed beans deposited)
        uint256 userTotalBdvAfter = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        assertGt(
            userTotalBdvAfter,
            userTotalBdvBefore,
            "userTotalBdv should increase from harvest + rinse + unripe claim"
        );

        // Verify rinse fully claimed
        uint256 postRinseBalance = barnPayback.balanceOfFertilized(state.user, fertIds);
        assertEq(postRinseBalance, 0, "rinse should be fully claimed");

        // Verify harvest complete on field 0
        assertNoHarvestablePods(state.user, DEFAULT_FIELD_ID);

        // Verify unripe claim rewards are now 0
        uint256 earnedAfter = siloPaybackContract.earned(state.user);
        assertEq(earnedAfter, 0, "earned rewards should be 0 after claim");
    }

    function test_automateClaimBlueprint_unripeClaim_noBalance() public {
        // Setup test state (no plant, no harvest, above peg)
        TestState memory state = setupAutomateClaimBlueprintTest(false, false, false, true);

        // Do NOT setup unripe claim conditions (no UnripeBDV tokens)
        // Verify user has no earned rewards
        uint256 earnedAmount = siloPaybackContract.earned(state.user);
        assertEq(earnedAmount, 0, "user should have no earned unripe rewards");

        // Setup blueprint with minUnripeClaimAmount = 1 but user has 0 earned
        // Also disable mow/plant/harvest/rinse so we expect a full revert
        (IMockFBeanstalk.Requisition memory req, ) = setupAutomateClaimBlueprint(
            AutomateClaimSetupParams({
                account: state.user,
                sourceMode: SourceMode.PURE_PINTO,
                minMowAmount: type(uint256).max,
                minTwaDeltaB: 10e6,
                minPlantAmount: type(uint256).max,
                minHarvestAmount: UNEXECUTABLE_MIN_HARVEST_AMOUNT,
                minRinseAmount: UNEXECUTABLE_MIN_RINSE_AMOUNT,
                minUnripeClaimAmount: 1,
                tipAddress: state.operator,
                mowTipAmount: state.mowTipAmount,
                plantTipAmount: state.plantTipAmount,
                harvestTipAmount: state.harvestTipAmount,
                rinseTipAmount: 0,
                unripeClaimTipAmount: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV
            })
        );

        // Pre-calculate dynamic data BEFORE expectRevert
        IMockFBeanstalk.ContractData[] memory dynamicData = getHarvestDynamicDataForUser(
            state.user
        );

        // Execute - should revert since earned = 0 < minUnripeClaimAmount = 1
        vm.expectRevert("AutomateClaimBlueprint: None of the order conditions are met");
        executeRequisitionWithDynamicData(state.operator, req, address(bs), dynamicData);
    }
}

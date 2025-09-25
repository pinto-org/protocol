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
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16

    struct TestState {
        address user;
        address operator;
        address beanToken;
        uint256 initialUserBeanBalance;
        uint256 initialOperatorBeanBalance;
        uint256 mintAmount;
        int256 tipAmount;
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

    // Break out the setup into a separate function
    function setupMowPlantHarvestBlueprintTest(
        bool setupPlant, // if setupPlant, set up conditions for planting
        bool setupHarvest, // if setupHarvest, set up conditions for harvesting
        bool abovePeg // if above peg, set up conditions for above peg
    ) internal returns (TestState memory) {
        // Create test state
        TestState memory state;
        state.user = farmers[0];
        state.operator = address(this);
        state.beanToken = bs.getBeanToken();
        state.initialUserBeanBalance = IERC20(state.beanToken).balanceOf(state.user);
        state.initialOperatorBeanBalance = bs.getInternalBalance(state.operator, state.beanToken);
        state.mintAmount = 110000e6; // 100k for deposit, 10k for sow
        state.tipAmount = 10e6; // 10 BEAN

        // Mint 2x the amount to ensure we have enough for all test cases
        mintTokensToUser(state.user, state.beanToken, state.mintAmount);
        // Mint some to farmer 2 for plot tests
        mintTokensToUser(farmers[1], state.beanToken, 10000000e6);

        vm.prank(state.user);
        IERC20(state.beanToken).approve(address(bs), type(uint256).max);

        vm.prank(state.user);
        bs.deposit(state.beanToken, state.mintAmount - 10000e6, uint8(LibTransfer.From.EXTERNAL));

        // For farmer 1, deposit 1000e6 beans, and mint them 1000e6 beans
        mintTokensToUser(farmers[1], state.beanToken, 1000e6);
        vm.prank(farmers[1]);
        bs.deposit(state.beanToken, 1000e6, uint8(LibTransfer.From.EXTERNAL));

        // Add liquidity to manipulate deltaB
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

        if (setupPlant) {
            // advance season 2 times to get rid of germination
            advanceSeason();
            advanceSeason();
        }

        if (setupHarvest) {
            // set soil to 1000e6
            bs.setSoilE(1000e6);
            // sow 1000e6 beans 2 times of 500e6 each
            vm.prank(state.user);
            bs.sow(500e6, 0, uint8(LibTransfer.From.EXTERNAL));
            vm.prank(state.user);
            bs.sow(500e6, 0, uint8(LibTransfer.From.EXTERNAL));
            // print users plots
            IMockFBeanstalk.Plot[] memory plots = bs.getPlotsFromAccount(
                state.user,
                bs.activeField()
            );
        }

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
            state.tipAmount, // operatorTipAmount
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

    function test_mowPlantHarvestBlueprint_plant() public {
        // Setup test state
        // setupPlant: true, setupHarvest: false, abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(true, false, true);

        // get user total stalk before plant
        uint256 userTotalStalkBeforePlant = bs.balanceOfStalk(state.user);
        // assert user has grown stalk
        assertGt(userTotalStalkBeforePlant, 0, "user should have grown stalk to plant");
        // get user total bdv before plant
        uint256 userTotalBdvBeforePlant = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        // assert user has the initial bdv
        assertEq(userTotalBdvBeforePlant, 100000e6, "user should have the initial bdv");
        // assert that the user has earned beans
        assertGt(bs.balanceOfEarnedBeans(state.user), 0, "user should have earned beans to plant");

        // Case 1: minPlantAmount is less than operator tip amount, reverts
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
                state.user, // account
                SourceMode.PURE_PINTO, // sourceMode for tip
                1 * STALK_DECIMALS, // minMowAmount (1 stalk)
                10e6, // mintwaDeltaB
                1e6, // minPlantAmount < 10e6 (operator tip amount)
                type(uint256).max, // minHarvestAmount
                state.operator, // tipAddress
                state.tipAmount, // operatorTipAmount
                MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
            );

            // Execute requisition, expect revert
            vm.expectRevert("Min plant amount must be greater than operator tip amount");
            executeRequisition(state.operator, req, address(bs));
        }

        // Case 2: plantable beans is less than minPlantAmount, reverts
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
                state.user, // account
                SourceMode.PURE_PINTO, // sourceMode for tip
                1 * STALK_DECIMALS, // minMowAmount (1 stalk)
                10e6, // mintwaDeltaB
                type(uint256).max, // minPlantAmount > (total plantable beans)
                type(uint256).max, // minHarvestAmount
                state.operator, // tipAddress
                state.tipAmount, // operatorTipAmount
                MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
            );

            // Execute requisition, expect revert
            vm.expectRevert("MowPlantHarvestBlueprint: None of the order conditions are met");
            executeRequisition(state.operator, req, address(bs));
        }

        // Case 3: minPlantAmount is greater than operator tip amount, executes
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
                state.user, // account
                SourceMode.PURE_PINTO, // sourceMode for tip
                1 * STALK_DECIMALS, // minMowAmount (1 stalk)
                10e6, // mintwaDeltaB
                11e6, // minPlantAmount > 10e6 (operator tip amount)
                type(uint256).max, // minHarvestAmount
                state.operator, // tipAddress
                state.tipAmount, // operatorTipAmount
                MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
            );

            // Execute requisition, expect plant event
            vm.expectEmit();
            emit Plant(state.user, 1933023687);
            executeRequisition(state.operator, req, address(bs));

            // get user total stalk after plant
            uint256 userTotalStalkAfterPlant = bs.balanceOfStalk(state.user);
            // assert the user total stalk has increased from mowing and planting
            assertGt(
                userTotalStalkAfterPlant,
                userTotalStalkBeforePlant,
                "userTotalStalk should have increased"
            );

            // get user total bdv after plant
            uint256 userTotalBdvAfterPlant = bs.balanceOfDepositedBdv(state.user, state.beanToken);
            // assert the user total bdv has increased as a result of the yield
            assertGt(
                userTotalBdvAfterPlant,
                userTotalBdvBeforePlant,
                "userTotalBdv should have increased"
            );
        }
    }

    function test_mowPlantHarvestBlueprint_harvest() public {
        // Setup test state
        // setupPlant: false, setupHarvest: true, abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, true, true);

        // take snapshot to return on case 3
        uint256 snapshot = vm.snapshot();

        // advance season to print beans
        advanceSeason();

        // get user total bdv before harvest
        uint256 userTotalBdvBeforeHarvest = bs.balanceOfDepositedBdv(state.user, state.beanToken);
        // assert user has the initial bdv
        assertEq(userTotalBdvBeforeHarvest, 100000e6, "user should have the initial bdv");
        // assert user has harvestable pods
        (uint256 totalHarvestablePods, uint256[] memory harvestablePlots) = _userHarvestablePods(
            state.user
        );
        assertGt(totalHarvestablePods, 0, "user should have harvestable pods to harvest");

        // Case 1: minHarvestAmount is less than operator tip amount, reverts
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
                state.user, // account
                SourceMode.PURE_PINTO, // sourceMode for tip
                1 * STALK_DECIMALS, // minMowAmount (1 stalk)
                10e6, // mintwaDeltaB
                11e6, // minPlantAmount
                1e6, // minHarvestAmount < 10e6 (operator tip amount)
                state.operator, // tipAddress
                state.tipAmount, // operatorTipAmount
                MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
            );

            // Execute requisition, expect revert
            vm.expectRevert("Min harvest amount must be greater than operator tip amount");
            executeRequisition(state.operator, req, address(bs));
        }

        // Case 2: partial harvest of 1 plot
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
                state.user, // account
                SourceMode.PURE_PINTO, // sourceMode for tip
                1 * STALK_DECIMALS, // minMowAmount (1 stalk)
                10e6, // mintwaDeltaB
                11e6, // minPlantAmount
                11e6, // minHarvestAmount > 10e6 (operator tip amount)
                state.operator, // tipAddress
                state.tipAmount, // operatorTipAmount
                MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
            );

            // Execute requisition, expect harvest event
            vm.expectEmit();
            emit Harvest(state.user, bs.activeField(), harvestablePlots, 488088481);
            executeRequisition(state.operator, req, address(bs));

            // get user total bdv after harvest
            uint256 userTotalBdvAfterHarvest = bs.balanceOfDepositedBdv(
                state.user,
                state.beanToken
            );
            // assert the user total bdv has increased as a result of the harvest
            assertGt(
                userTotalBdvAfterHarvest,
                userTotalBdvBeforeHarvest,
                "userTotalBdv should have increased"
            );

            // assert user harvestable pods is 0
            (
                uint256 totalHarvestablePodsAfterHarvest,
                uint256[] memory harvestablePlotsAfterHarvest
            ) = _userHarvestablePods(state.user);

            assertEq(
                totalHarvestablePodsAfterHarvest,
                0,
                "user should have no harvestable pods after harvest"
            );
            assertEq(
                harvestablePlotsAfterHarvest.length,
                0,
                "user should have no harvestable plots after harvest"
            );
        }

        // revert to snapshot to original state
        vm.revertTo(snapshot);

        // // Case 3: full harvest of 2 plots
        {
            // add even more liquidity to well to print more beans and clear the podline
            addLiquidityToWell(BEAN_ETH_WELL, 10000e6, 20 ether);
            addLiquidityToWell(BEAN_WSTETH_WELL, 10000e6, 20 ether);

            // advance season to print beans
            advanceSeason();

            // assert user has harvestable pods
            (, uint256[] memory harvestablePlots) = _userHarvestablePods(state.user);
            assertEq(harvestablePlots.length, 2, "user should have 2 harvestable plots");

            // get user total bdv before harvest
            uint256 userTotalBdvBeforeHarvest = bs.balanceOfDepositedBdv(
                state.user,
                state.beanToken
            );

            (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
                state.user, // account
                SourceMode.PURE_PINTO, // sourceMode for tip
                1 * STALK_DECIMALS, // minMowAmount (1 stalk)
                10e6, // mintwaDeltaB
                11e6, // minPlantAmount
                11e6, // minHarvestAmount > 10e6 (operator tip amount)
                state.operator, // tipAddress
                state.tipAmount, // operatorTipAmount
                MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
            );

            // Execute requisition, expect harvest event
            vm.expectEmit();
            emit Harvest(state.user, bs.activeField(), harvestablePlots, 1000100000);
            executeRequisition(state.operator, req, address(bs));

            // get user total bdv after harvest
            uint256 userTotalBdvAfterHarvest = bs.balanceOfDepositedBdv(
                state.user,
                state.beanToken
            );
            // assert the user total bdv has decreased as a result of the harvest
            assertGt(
                userTotalBdvAfterHarvest,
                userTotalBdvBeforeHarvest,
                "userTotalBdv should have decreased"
            );

            // get user plots
            IMockFBeanstalk.Plot[] memory plots = bs.getPlotsFromAccount(
                state.user,
                bs.activeField()
            );
            // assert the user has no plots left
            assertEq(plots.length, 0, "user should have no plots left");
            // assert the user has no harvestable pods
            (
                uint256 totalHarvestablePodsAfterHarvest,
                uint256[] memory harvestablePlotsAfterHarvest
            ) = _userHarvestablePods(state.user);
            assertEq(
                totalHarvestablePodsAfterHarvest,
                0,
                "user should have no harvestable pods after harvest"
            );
            assertEq(
                harvestablePlotsAfterHarvest.length,
                0,
                "user should have no harvestable plots after harvest"
            );
            // assert the bdv of the user increased
            assertGt(
                bs.balanceOfDepositedBdv(state.user, state.beanToken),
                userTotalBdvBeforeHarvest,
                "userTotalBdv should have increased"
            );
        }
    }

    function test_mergeAdjacentPlotsSimple() public {
        // Setup test state
        // setupPlant: false, setupHarvest: false (dont sow default amounts), abovePeg: true
        TestState memory state = setupMowPlantHarvestBlueprintTest(false, false, true);

        uint256[] memory plotIndexes = setUpMultipleConsecutiveAccountPlots(state.user, 1000e6, 10); // 10 sows of 100 beans each at 1% temp
        IMockFBeanstalk.Plot[] memory plots = bs.getPlotsFromAccount(state.user, bs.activeField());
        uint256 totalPodsBeforeCombine = 0;
        for (uint256 i = 0; i < plots.length; i++) {
            totalPodsBeforeCombine += plots[i].pods;
        }
        assertEq(plots.length, 10, "user should have 10 plots");
        // combine all plots into one
        bs.combinePlots(state.user, bs.activeField(), plotIndexes);

        // assert user has 1 plot
        plots = bs.getPlotsFromAccount(state.user, bs.activeField());
        assertEq(plots.length, 1, "user should have 1 plot");
        assertEq(plots[0].index, 0, "plot index should be 0");
        assertEq(plots[0].pods, totalPodsBeforeCombine, "plot pods should be 1010e6");

        // assert plot indexes length is 1
        assertEq(
            bs.getPlotIndexesLengthFromAccount(state.user, bs.activeField()),
            1,
            "plot indexes length should be 1"
        );

        // assert plot indexes is 0
        uint256[] memory plotIndexesAfterCombine = bs.getPlotIndexesFromAccount(
            state.user,
            bs.activeField()
        );
        assertEq(plotIndexesAfterCombine.length, 1, "plot indexes length should be 1");
        assertEq(plotIndexesAfterCombine[0], 0, "plot index should be 0");

        // assert piIndex for combined plot is correct
        assertEq(
            bs.getPiIndexFromAccount(state.user, bs.activeField(), 0),
            0,
            "piIndex should be 0"
        );
    }

    function test_mergeAdjacentPlotsMultiple() public {
        // mint beans to farmers
        mintTokensToUser(farmers[0], BEAN, 10000000e6);
        mintTokensToUser(farmers[1], BEAN, 10000000e6);
        vm.prank(farmers[0]);
        IERC20(BEAN).approve(address(bs), type(uint256).max);
        vm.prank(farmers[1]);
        IERC20(BEAN).approve(address(bs), type(uint256).max);

        // setup non-adjacent plots for farmer 1
        uint256[] memory account1PlotIndexes = setUpNonAdjacentPlots(
            farmers[0],
            farmers[1],
            1000e6,
            true
        );
        uint256 totalPodsBefore = getTotalPodsFromAccount(farmers[0]);

        // try to combine plots, expect revert since plots are not adjacent
        uint256 activeField = bs.activeField();
        vm.expectRevert("Field: Plots to combine not adjacent");
        bs.combinePlots(farmers[0], activeField, account1PlotIndexes);

        // merge adjacent plots in pairs (indexes 1-3)
        uint256[] memory adjacentPlotIndexes = new uint256[](3);
        adjacentPlotIndexes[0] = account1PlotIndexes[0];
        adjacentPlotIndexes[1] = account1PlotIndexes[1];
        adjacentPlotIndexes[2] = account1PlotIndexes[2];
        bs.combinePlots(farmers[0], activeField, adjacentPlotIndexes);
        // assert user has 3 plots (1 from the 3 merged, 2 from the original)
        assertEq(
            bs.getPlotIndexesLengthFromAccount(farmers[0], activeField),
            3,
            "user should have 3 plots"
        );
        // assert first plot index is 0 after merge
        assertEq(
            bs.getPlotIndexesFromAccount(farmers[0], activeField)[0],
            0,
            "plot index should be 0"
        );
        // assert piIndex for first combined plot is correct
        assertEq(bs.getPiIndexFromAccount(farmers[0], activeField, 0), 0, "piIndex should be 0");

        // plots for farmer 2 should remain unchanged in the middle of the queue
        assertEq(
            bs.getPlotIndexesLengthFromAccount(farmers[1], activeField),
            2,
            "user should have 2 plots"
        );

        // merge adjacent plots in pairs (indexes 5-6)
        adjacentPlotIndexes = new uint256[](2);
        adjacentPlotIndexes[0] = account1PlotIndexes[3];
        adjacentPlotIndexes[1] = account1PlotIndexes[4];
        bs.combinePlots(farmers[0], activeField, adjacentPlotIndexes);
        // assert user has 2 plots (1 from the 2 merged, 1 from the 3 original merged)
        assertEq(
            bs.getPlotIndexesLengthFromAccount(farmers[0], activeField),
            2,
            "user should have 2 final plots"
        );
        // assert first plot index remains the same after 2nd merge
        assertEq(
            bs.getPlotIndexesFromAccount(farmers[0], activeField)[0],
            0,
            "plot index should be 0"
        );
        // final plot should start from the next to last previous plot index
        assertEq(
            bs.getPlotIndexesFromAccount(farmers[0], activeField)[1],
            5000500000,
            "final plot index"
        );
        // assert piIndex for both final plots are correct
        assertEq(
            bs.getPiIndexFromAccount(farmers[0], activeField, 0),
            0,
            "first piIndex should be 0"
        );
        assertEq(
            bs.getPiIndexFromAccount(farmers[0], activeField, 5000500000),
            1,
            "second piIndex should be 1"
        );

        // get total pods from account 1
        uint256 totalPodsAfter = getTotalPodsFromAccount(farmers[0]);
        // assert total pods after merge is the same as before merge
        assertEq(
            totalPodsAfter,
            totalPodsBefore,
            "total pods after merge should be the same as before merge"
        );
    }

    /////////////////////////// HELPER FUNCTIONS ///////////////////////////

    /**
     * @notice Helper function to get the total harvestable pods and plots for a user
     * @param account The address of the user
     * @return totalUserHarvestablePods The total amount of harvestable pods for the user
     * @return userHarvestablePlots The harvestable plot ids for the user
     */
    function _userHarvestablePods(
        address account
    )
        internal
        view
        returns (uint256 totalUserHarvestablePods, uint256[] memory userHarvestablePlots)
    {
        // get field info and plot count directly
        uint256 activeField = bs.activeField();
        uint256[] memory plotIndexes = bs.getPlotIndexesFromAccount(account, activeField);
        uint256 harvestableIndex = bs.harvestableIndex(activeField);

        if (plotIndexes.length == 0) return (0, new uint256[](0));

        // initialize array with full length
        userHarvestablePlots = new uint256[](plotIndexes.length);
        uint256 harvestableCount;

        // single loop to process all plot indexes directly
        for (uint256 i = 0; i < plotIndexes.length; i++) {
            uint256 startIndex = plotIndexes[i];
            uint256 plotPods = bs.plot(account, activeField, startIndex);

            if (startIndex + plotPods <= harvestableIndex) {
                // Fully harvestable
                userHarvestablePlots[harvestableCount] = startIndex;
                totalUserHarvestablePods += plotPods;
                harvestableCount++;
            } else if (startIndex < harvestableIndex) {
                // Partially harvestable
                userHarvestablePlots[harvestableCount] = startIndex;
                totalUserHarvestablePods += harvestableIndex - startIndex;
                harvestableCount++;
            }
        }
        // resize array to actual harvestable plots count
        assembly {
            mstore(userHarvestablePlots, harvestableCount)
        }
        return (totalUserHarvestablePods, userHarvestablePlots);
    }

    /**
     * @dev Creates multiple consecutive plots for an account of size totalSoil/sowCount
     */
    function setUpMultipleConsecutiveAccountPlots(
        address account,
        uint256 totalSoil,
        uint256 sowCount
    ) internal returns (uint256[] memory plotIndexes) {
        // set soil to totalSoil
        bs.setSoilE(totalSoil);
        // sow totalSoil beans sowCount times of totalSoil/sowCount each
        uint256 sowAmount = totalSoil / sowCount;
        for (uint256 i = 0; i < sowCount; i++) {
            vm.prank(account);
            bs.sow(sowAmount, 0, uint8(LibTransfer.From.EXTERNAL));
        }
        plotIndexes = bs.getPlotIndexesFromAccount(account, bs.activeField());
        return plotIndexes;
    }

    /**
     * @dev Creates non-adjacent plots by having account1 sow, then account2 sow in between
     * Finally, account1 harvests to disorder the plot indexes array
     */
    function setUpNonAdjacentPlots(
        address account1,
        address account2,
        uint256 sowAmount,
        bool partiallyHarvest
    ) internal returns (uint256[] memory plotIndexes) {
        // Account1 sows 3 consecutive plots
        bs.setSoilE(sowAmount * 3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(account1);
            bs.sow(sowAmount, 0, uint8(LibTransfer.From.EXTERNAL));
        }

        // Account2 sows 2 plots to create gaps in account1's sequence
        bs.setSoilE(sowAmount * 2);
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(account2);
            bs.sow(sowAmount, 0, uint8(LibTransfer.From.EXTERNAL));
        }

        // Account1 sows 2 more plots (now non-adjacent to first 3)
        bs.setSoilE(sowAmount * 2);
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(account1);
            bs.sow(sowAmount, 0, uint8(LibTransfer.From.EXTERNAL));
        }

        // Get plot indexes
        plotIndexes = bs.getPlotIndexesFromAccount(account1, bs.activeField());

        return plotIndexes;
    }

    function getTotalPodsFromAccount(address account) internal view returns (uint256 totalPods) {
        uint256[] memory plotIndexes = bs.getPlotIndexesFromAccount(account, bs.activeField());
        for (uint256 i = 0; i < plotIndexes.length; i++) {
            totalPods += bs.plot(account, bs.activeField(), plotIndexes[i]);
        }
        return totalPods;
    }

    /// @dev Advance to the next season and update oracles
    function advanceSeason() internal {
        warpToNextSeasonTimestamp();
        bs.sunrise();
        updateAllChainlinkOraclesWithPreviousData();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TractorHelpers} from "contracts/ecosystem/tractor/utils/TractorHelpers.sol";
import {SowBlueprint} from "contracts/ecosystem/tractor/blueprints/SowBlueprint.sol";
import {SowBlueprintBase} from "contracts/ecosystem/tractor/blueprints/SowBlueprintBase.sol";
import {BlueprintBase} from "contracts/ecosystem/BlueprintBase.sol";
import {PriceManipulation} from "contracts/ecosystem/tractor/utils/PriceManipulation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TractorTestHelper} from "test/foundry/utils/TractorTestHelper.sol";
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {OperatorWhitelist} from "contracts/ecosystem/tractor/utils/OperatorWhitelist.sol";
import {SiloHelpers} from "contracts/ecosystem/tractor/utils/SiloHelpers.sol";
import {GasCostCalculator} from "contracts/ecosystem/tractor/utils/GasCostCalculator.sol";
import {MockChainlinkAggregator} from "contracts/mocks/MockChainlinkAggregator.sol";
import "forge-std/console.sol";

contract GasCostCalculatorHarness is GasCostCalculator {
    constructor(
        address _beanstalk,
        address _owner,
        uint256 _baseGasOverhead
    ) GasCostCalculator(_beanstalk, _owner, _baseGasOverhead) {}

    function _getEthPintoRate() internal view override returns (uint256) {
        return 2000e6; // 2000 Pinto per ETH fixed rate for tests
    }
}

contract SowBlueprintTest is TractorTestHelper {
    address[] farmers;
    PriceManipulation priceManipulation;
    BeanstalkPrice beanstalkPrice;

    // Add constant for max grown stalk limit
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16

    struct TestState {
        address user;
        address operator;
        address beanToken;
        uint256 initialUserBeanBalance;
        uint256 initialOperatorBeanBalance;
        uint256 sowAmount;
        int256 tipAmount;
        uint256 initialSoil;
    }

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        farmers = createUsers(2);

        // Deploy PriceManipulation
        priceManipulation = new PriceManipulation(address(bs));
        vm.label(address(priceManipulation), "PriceManipulation");

        // Deploy BeanstalkPrice
        beanstalkPrice = new BeanstalkPrice(address(bs));
        vm.label(address(beanstalkPrice), "BeanstalkPrice");

        // Deploy TractorHelpers with PriceManipulation address
        tractorHelpers = new TractorHelpers(address(bs), address(beanstalkPrice));
        vm.label(address(tractorHelpers), "TractorHelpers");

        // Deploy SiloHelpers first
        siloHelpers = new SiloHelpers(
            address(bs),
            address(tractorHelpers),
            address(priceManipulation)
        );
        vm.label(address(siloHelpers), "SiloHelpers");

        // Deploy GasCostCalculator Harness
        GasCostCalculator gasCostCalculator = new GasCostCalculatorHarness(
            address(bs),
            address(this),
            50000
        );

        // Setup Mock Chainlink Oracle for ETH/USD (still needed if Harness called original functions, but strict override bypasses it)
        // Leaving it for completeness or if other tests rely on it (though existing logic bypassed)
        MockChainlinkAggregator ethUsdAggregator = new MockChainlinkAggregator();
        ethUsdAggregator.setDecimals(8);
        ethUsdAggregator.addRound(2000e8, block.timestamp, block.timestamp, 1); // $2000 ETH
        vm.etch(gasCostCalculator.ETH_USD_ORACLE(), address(ethUsdAggregator).code);
        MockChainlinkAggregator(gasCostCalculator.ETH_USD_ORACLE()).setDecimals(8);
        MockChainlinkAggregator(gasCostCalculator.ETH_USD_ORACLE()).addRound(2000e8, block.timestamp, block.timestamp, 1);

        // Deploy SowBlueprint with TractorHelpers and SiloHelpers addresses
        sowBlueprint = new SowBlueprint(
            address(bs),
            address(this),
            address(tractorHelpers),
            address(gasCostCalculator),
            address(siloHelpers)
        );
        vm.label(address(sowBlueprint), "SowBlueprint");

        setTractorHelpers(address(tractorHelpers));
        setSowBlueprintv0(address(sowBlueprint));
        setSiloHelpers(address(siloHelpers));

        addLiquidityToWell(
            BEAN_ETH_WELL,
            10000e6, // 10,000 Beans
            10 ether // 10 ether.
        );

        addLiquidityToWell(
            BEAN_WSTETH_WELL,
            10010e6, // 10,010 Beans
            10 ether // 10 ether.
        );
    }

    // Break out the setup into a separate function
    function setupSowBlueprintv0Test() internal returns (TestState memory) {
        TestState memory state;
        state.user = farmers[0];
        state.operator = address(this);
        state.beanToken = bs.getBeanToken();
        state.initialUserBeanBalance = IERC20(state.beanToken).balanceOf(state.user);
        state.initialOperatorBeanBalance = bs.getInternalBalance(state.operator, state.beanToken);
        state.sowAmount = 1000e6; // 1000 BEAN
        state.tipAmount = 10e6; // 10 BEAN
        state.initialSoil = 100000e6; // 100,000 BEAN

        // For test case 6, we need to deposit more than initialSoil
        uint256 extraAmount = state.initialSoil + 1e6;

        // Setup initial conditions with extra amount for test case 6
        // Mint 2x the amount to ensure we have enough for all test cases
        mintTokensToUser(state.user, state.beanToken, (extraAmount + uint256(state.tipAmount)) * 2);

        vm.prank(state.user);
        IERC20(state.beanToken).approve(address(bs), type(uint256).max);

        bs.setSoilE(state.initialSoil);

        vm.prank(state.user);
        bs.deposit(
            state.beanToken,
            extraAmount + uint256(state.tipAmount),
            uint8(LibTransfer.From.EXTERNAL)
        );

        // For farmer 1, deposit 1000e6 beans, and mint them 1000e6 beans
        mintTokensToUser(farmers[1], state.beanToken, 1000e6);
        vm.prank(farmers[1]);
        bs.deposit(state.beanToken, 1000e6, uint8(LibTransfer.From.EXTERNAL));

        return state;
    }

    function test_sowBlueprintv0General() public {
        TestState memory state = setupSowBlueprintv0Test();
        uint256 snapshot = vm.snapshot();

        // Test Case 1: PURE_PINTO mode with tip
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                state.user,
                SourceMode.PURE_PINTO,
                makeSowAmountsArray(state.sowAmount / 4, state.sowAmount / 4, type(uint256).max),
                0, // minTemp
                state.tipAmount,
                state.operator,
                type(uint256).max, // No podline length limit for this test
                MAX_GROWN_STALK_PER_BDV, // Use reasonable max grown stalk limit
                0 // No runBlocksAfterSunrise
            );

            // Expect the TractorExecutionBegan event to be emitted
            vm.expectEmit(true, true, true, false);
            emit IMockFBeanstalk.TractorExecutionBegan(
                state.operator,
                state.user,
                req.blueprintHash,
                0, // nonce
                gasleft()
            );

            // Expect the SowOrderComplete event to be emitted for complete order
            vm.expectEmit(true, true, true, true);
            emit SowBlueprintBase.SowOrderComplete(
                req.blueprintHash,
                state.user,
                state.sowAmount / 4,
                0 // No unfulfilled amount
            );

            // Expect the OperatorReward event to be emitted with correct parameters
            vm.expectEmit(true, true, true, true);
            emit TractorHelpers.OperatorReward(
                TractorHelpers.RewardType.ERC20,
                state.user,
                state.operator,
                state.beanToken,
                int256(state.tipAmount)
            );

            executeRequisition(state.operator, req, address(bs));

            assertEq(
                bs.totalSoil(),
                state.initialSoil - (state.sowAmount / 4),
                "Incorrect soil remaining after PURE_PINTO sow"
            );

            assertEq(
                bs.getInternalBalance(state.operator, state.beanToken),
                state.initialOperatorBeanBalance + uint256(state.tipAmount),
                "Operator did not receive correct tip amount"
            );
        }

        // Add new test case for podline length check
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                state.user,
                SourceMode.PURE_PINTO,
                makeSowAmountsArray(state.sowAmount / 4, state.sowAmount / 4, type(uint256).max),
                0, // minTemp
                state.tipAmount,
                state.operator,
                20e6, // Max podline length of 20 BEAN
                MAX_GROWN_STALK_PER_BDV, // Use reasonable max grown stalk limit
                0 // No runBlocksAfterSunrise
            );

            vm.prank(state.user);
            bs.publishRequisition(req);

            vm.expectRevert("Podline too long");
            vm.prank(state.operator);
            bs.tractor(
                IMockFBeanstalk.Requisition(req.blueprint, req.blueprintHash, req.signature),
                ""
            );
        }

        vm.revertTo(snapshot);
        snapshot = vm.snapshot();

        // Test Case 2: LOWEST_PRICE mode with tip
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                state.user,
                SourceMode.LOWEST_PRICE,
                makeSowAmountsArray(state.sowAmount / 4, state.sowAmount / 4, type(uint256).max),
                0, // minTemp
                state.tipAmount,
                state.operator,
                type(uint256).max, // No podline length limit for this test
                MAX_GROWN_STALK_PER_BDV, // Use reasonable max grown stalk limit
                0 // No runBlocksAfterSunrise
            );

            executeRequisition(state.operator, req, address(bs));

            assertEq(
                bs.totalSoil(),
                state.initialSoil - (state.sowAmount / 4),
                "Incorrect soil remaining after LOWEST_PRICE sow"
            );

            assertEq(
                bs.getInternalBalance(state.operator, state.beanToken),
                state.initialOperatorBeanBalance + uint256(state.tipAmount),
                "Operator did not receive correct tip amount"
            );
        }

        vm.revertTo(snapshot);
        snapshot = vm.snapshot();

        // Test Case 3: LOWEST_SEED mode with tip
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                state.user,
                SourceMode.LOWEST_SEED,
                makeSowAmountsArray(state.sowAmount / 4, state.sowAmount / 4, type(uint256).max),
                0, // minTemp
                state.tipAmount,
                state.operator,
                type(uint256).max, // No podline length limit for this test
                MAX_GROWN_STALK_PER_BDV, // Use reasonable max grown stalk limit
                0 // No runBlocksAfterSunrise
            );

            executeRequisition(state.operator, req, address(bs));

            assertEq(
                bs.totalSoil(),
                state.initialSoil - (state.sowAmount / 4),
                "Incorrect soil remaining after LOWEST_SEED sow"
            );

            assertEq(
                bs.getInternalBalance(state.operator, state.beanToken),
                state.initialOperatorBeanBalance + uint256(state.tipAmount),
                "Operator did not receive correct tip amount"
            );
        }

        vm.revertTo(snapshot);
        snapshot = vm.snapshot();

        // Test Case 5: Attempt to sow with zero address operator, it should tip the operator
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                state.user,
                SourceMode.PURE_PINTO,
                makeSowAmountsArray(state.sowAmount / 2, state.sowAmount / 2, type(uint256).max),
                0, // minTemp
                state.tipAmount,
                address(0),
                type(uint256).max, // No podline length limit for this test
                MAX_GROWN_STALK_PER_BDV, // Use reasonable max grown stalk limit
                0 // No runBlocksAfterSunrise
            );

            vm.prank(state.user);
            bs.publishRequisition(req);

            vm.prank(address(state.operator));
            bs.tractor(
                IMockFBeanstalk.Requisition(req.blueprint, req.blueprintHash, req.signature),
                ""
            );

            assertEq(
                bs.getInternalBalance(state.operator, state.beanToken),
                state.initialOperatorBeanBalance + uint256(state.tipAmount),
                "Operator did not receive correct tip amount when zero tip address"
            );
        }

        vm.revertTo(snapshot);

        // Test Case 6: Attempt to sow more than available soil
        {
            uint256 soilToSow = bs.totalSoil() + 1e6;

            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                state.user,
                SourceMode.PURE_PINTO,
                makeSowAmountsArray(soilToSow, soilToSow, soilToSow), // More than available soil
                0, // minTemp
                state.tipAmount,
                state.operator,
                type(uint256).max, // No podline length limit for this test
                MAX_GROWN_STALK_PER_BDV, // Use reasonable max grown stalk limit
                0 // No runBlocksAfterSunrise
            );

            vm.prank(state.user);
            bs.publishRequisition(req);

            vm.expectRevert("Not enough soil for min sow");
            vm.prank(state.operator);
            bs.tractor(
                IMockFBeanstalk.Requisition(req.blueprint, req.blueprintHash, req.signature),
                ""
            );
        }

        // Test Case 7: Test negative tip amount (operator pays user)
        {
            int256 negativeTipAmount = -10e6; // -10 BEAN tip (operator pays user)

            // First give the operator some beans to pay the tip
            mintTokensToUser(state.operator, state.beanToken, uint256(-negativeTipAmount));

            // Approve spending beans to the beanstalk contract
            vm.prank(state.operator);
            IERC20(state.beanToken).approve(address(bs), uint256(-negativeTipAmount));

            vm.prank(state.operator);
            // Transfer operator's beans to internal balance
            bs.transferToken(
                state.beanToken,
                state.operator,
                uint256(-negativeTipAmount),
                uint8(LibTransfer.From.EXTERNAL),
                uint8(LibTransfer.To.INTERNAL)
            );

            // Operator must approve allowing the publisher to spend the beans using approveToken
            vm.prank(state.operator);
            bs.approveToken(state.user, state.beanToken, uint256(-negativeTipAmount));

            uint256 userInitialBalance = bs.getInternalBalance(state.user, state.beanToken);
            uint256 operatorInitialBalance = bs.getInternalBalance(state.operator, state.beanToken);

            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                state.user,
                SourceMode.PURE_PINTO,
                makeSowAmountsArray(state.sowAmount / 4, state.sowAmount / 4, state.sowAmount),
                0, // minTemp
                negativeTipAmount,
                state.operator,
                type(uint256).max,
                MAX_GROWN_STALK_PER_BDV, // Use reasonable max grown stalk limit
                0 // No runBlocksAfterSunrise
            );

            // Expect the OperatorReward event to be emitted with negative tip amount
            vm.expectEmit(true, true, true, true);
            emit TractorHelpers.OperatorReward(
                TractorHelpers.RewardType.ERC20,
                state.user,
                state.operator,
                state.beanToken,
                negativeTipAmount
            );

            executeRequisition(state.operator, req, address(bs));

            // Verify operator paid the tip to the user
            assertEq(
                bs.getInternalBalance(state.user, state.beanToken),
                userInitialBalance + uint256(-negativeTipAmount),
                "User did not receive correct negative tip amount"
            );

            assertEq(
                bs.getInternalBalance(state.operator, state.beanToken),
                operatorInitialBalance - uint256(-negativeTipAmount),
                "Operator balance not reduced by correct tip amount"
            );
        }

        vm.revertTo(snapshot);

        // Test Case 8: Test maxAmountToSowPerSeason limit
        {
            uint256 maxPerSeason = 200e6; // 200 BEAN max per season
            uint256 attemptToSow = 500e6; // Try to sow 500 BEAN

            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                state.user,
                SourceMode.PURE_PINTO,
                makeSowAmountsArray(attemptToSow, 0, maxPerSeason),
                0, // minTemp
                state.tipAmount,
                state.operator,
                type(uint256).max,
                MAX_GROWN_STALK_PER_BDV,
                0 // No runBlocksAfterSunrise
            );

            // First sow should succeed but only sow maxPerSeason amount
            executeRequisition(state.operator, req, address(bs));
            assertEq(
                state.initialSoil - bs.totalSoil(),
                maxPerSeason,
                "Should only sow maxAmountToSowPerSeason"
            );

            // Try to sow again in same season - should revert or do nothing since we hit the per-season limit
            vm.expectRevert("Blueprint already executed this season");
            executeRequisition(state.operator, req, address(bs));

            // Advance to next season
            bs.siloSunrise(0);

            // Reset soil
            bs.setSoilE(state.initialSoil);

            // Verify totalSoil is equal to initialSoil
            assertEq(bs.totalSoil(), state.initialSoil, "totalSoil should be equal to initialSoil");

            // Should be able to sow again in new season
            executeRequisition(state.operator, req, address(bs));

            uint256 soilSown = state.initialSoil - bs.totalSoil();

            assertEq(soilSown, maxPerSeason, "Should sow maxAmountToSowPerSeason in new season");
        }

        vm.revertTo(snapshot);

        // Test Case 9: Test sowing with limited deposited beans
        {
            // Create blueprint with max 1200 and min 500 per season, but this user only has 1000e6 deposited
            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                farmers[1],
                SourceMode.PURE_PINTO,
                makeSowAmountsArray(1200e6, 500e6, 1200e6),
                0, // minTemp
                state.tipAmount,
                state.operator,
                type(uint256).max,
                MAX_GROWN_STALK_PER_BDV,
                0 // No runBlocksAfterSunrise
            );

            // Should succeed and sow all 1000 BEAN, minus the 10 tip
            executeRequisition(state.operator, req, address(bs));

            // Verify that all 990 BEAN were sown
            assertEq(
                state.initialSoil - bs.totalSoil(),
                1000e6 - uint256(state.tipAmount),
                "Should sow all available beans (1000 BEAN minus tip) "
            );

            // Verify the counter was updated correctly, there should be 210 left to sow, because we took the user's 1000 beans, sowed 990, tipped 10.
            assertEq(
                sowBlueprint.getPintosLeftToSow(req.blueprintHash),
                200e6 + uint256(state.tipAmount),
                "Counter not correct"
            );
        }

        vm.revertTo(snapshot);

        // Test case 10: sow 80 total with 40 min sow, but 60 soil available, after first run, it should emit SowOrderComplete event
        {
            (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
                state.user,
                SourceMode.PURE_PINTO,
                makeSowAmountsArray(80e6, 40e6, 80e6),
                0, // minTemp
                state.tipAmount,
                state.operator,
                type(uint256).max,
                MAX_GROWN_STALK_PER_BDV,
                0 // No runBlocksAfterSunrise
            );

            // Set soil to 60
            bs.setSoilE(60e6);

            // Expect the SowOrderComplete event to be emitted for complete order
            vm.expectEmit(true, true, true, true);
            emit SowBlueprintBase.SowOrderComplete(
                req.blueprintHash,
                state.user,
                60e6, // 60e6 sowed
                20e6 // 20e6 unfulfilled
            );

            executeRequisition(state.operator, req, address(bs));
        }
    }

    function test_sowBlueprintv0Counter() public {
        TestState memory state = setupSowBlueprintv0Test();

        // Set a smaller soil amount so we can test multiple sows
        uint256 smallerSoil = 500e6; // 500 BEAN
        bs.setSoilE(smallerSoil);

        // Try to sow more than available soil, but counter should track total amount sown
        uint256 totalAmountToSow = 1900e6; // 1900 BEAN (less than 4x the soil)
        uint256 tipAmount = 10e6; // 10 BEAN
        uint256 counter;

        // Create blueprint once and reuse it
        (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
            state.user,
            SourceMode.PURE_PINTO,
            makeSowAmountsArray(totalAmountToSow, 0, type(uint256).max),
            0, // no min temp
            int256(tipAmount),
            state.operator,
            type(uint256).max,
            MAX_GROWN_STALK_PER_BDV,
            0 // No runBlocksAfterSunrise
        );

        // First sow - should succeed and use up soil amount
        executeRequisition(state.operator, req, address(bs));

        // Get the blueprint hash from the mock beanstalk contract
        bytes32 orderHash = req.blueprintHash;

        // Verify first sow used the available soil and check counter
        assertEq(bs.totalSoil(), 0, "First sow should use all soil");
        counter = sowBlueprint.getPintosLeftToSow(orderHash);
        assertEq(counter, 1400e6, "Counter should be 1400 BEAN after first sow");

        // Verify the last executed season was recorded properly
        assertEq(
            sowBlueprint.getLastExecutedSeason(orderHash),
            bs.time().current,
            "Last executed season should be current season"
        );

        // Advance to next season
        bs.siloSunrise(0);

        // Refill soil for second sow
        bs.setSoilE(smallerSoil);

        // Second sow - should succeed but counter should be tracking
        executeRequisition(state.operator, req, address(bs));

        // Verify second sow used the available soil and check counter
        assertEq(bs.totalSoil(), 0, "Second sow should use all soil");
        counter = sowBlueprint.getPintosLeftToSow(orderHash);
        assertEq(counter, 900e6, "Counter should be 900 BEAN after second sow");

        // Verify the last executed season was updated
        assertEq(
            sowBlueprint.getLastExecutedSeason(orderHash),
            bs.time().current,
            "Last executed season should be updated to current season"
        );

        // Advance to next season
        bs.siloSunrise(0);

        // Refill soil for third sow
        bs.setSoilE(smallerSoil);

        // Third sow - should succeed but counter should be tracking
        executeRequisition(state.operator, req, address(bs));

        // Verify third sow used the available soil and check counter
        assertEq(bs.totalSoil(), 0, "Third sow should use all soil");
        counter = sowBlueprint.getPintosLeftToSow(orderHash);
        assertEq(counter, 400e6, "Counter should be 500 BEAN after third sow");

        // Advance to next season
        bs.siloSunrise(0);

        // Refill soil for fourth sow
        bs.setSoilE(smallerSoil);

        // Fourth sow - should succeed but counter should be tracking
        executeRequisition(state.operator, req, address(bs));

        // Verify fourth sow used the available soil and check counter
        assertEq(bs.totalSoil(), 100e6, "Fourth sow should use all soil except 100e6");
        counter = sowBlueprint.getPintosLeftToSow(orderHash);
        assertEq(counter, type(uint256).max, "Counter should be max uint256 after fourth sow");

        // Advance to next season
        bs.siloSunrise(0);

        // Refill soil for fifth sow
        bs.setSoilE(smallerSoil);

        // Check counter before attempting fifth sow
        counter = sowBlueprint.getPintosLeftToSow(orderHash);
        assertEq(
            counter,
            type(uint256).max,
            "Counter should still be max uint256 before fifth sow"
        );

        // Fifth sow - should revert as counter is used up (2000 BEAN total allowed)
        vm.expectRevert("Sow order already fulfilled");
        executeRequisition(state.operator, req, address(bs));
    }

    // Add a new test specifically for testing the OrderInfo struct functionality
    function test_orderInfoStruct() public {
        TestState memory state = setupSowBlueprintv0Test();

        // Create a blueprint
        (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
            state.user,
            SourceMode.PURE_PINTO,
            makeSowAmountsArray(1000e6, 100e6, 500e6),
            0, // no min temp
            10e6, // 10 BEAN tip
            state.operator,
            type(uint256).max,
            MAX_GROWN_STALK_PER_BDV,
            0 // No runBlocksAfterSunrise
        );

        // Execute the blueprint
        executeRequisition(state.operator, req, address(bs));

        bytes32 orderHash = req.blueprintHash;

        // Test that both counter and lastExecutedSeason are correctly stored and retrieved
        assertEq(
            sowBlueprint.getPintosLeftToSow(orderHash),
            500e6,
            "Counter should be 500e6 after first sow"
        );
        assertEq(
            sowBlueprint.getLastExecutedSeason(orderHash),
            bs.time().current,
            "Last executed season should be properly recorded"
        );

        // Try to execute again in same season - should fail
        vm.expectRevert("Blueprint already executed this season");
        executeRequisition(state.operator, req, address(bs));

        // Move to next season
        bs.siloSunrise(0);

        // Execute again should work
        executeRequisition(state.operator, req, address(bs));

        // Check lastExecutedSeason updated
        assertEq(
            sowBlueprint.getLastExecutedSeason(orderHash),
            bs.time().current,
            "Last executed season should be updated to new season"
        );

        // Test that both counter and lastExecutedSeason are correctly stored and retrieved
        assertEq(
            sowBlueprint.getPintosLeftToSow(orderHash),
            type(uint256).max,
            "Counter should be max uint256 after full sow"
        );
    }

    function makeSowAmountsArray(
        uint256 amountToSow,
        uint256 minAmountToSow,
        uint256 maxAmountToSowPerSeason
    ) internal pure returns (SowBlueprintBase.SowAmounts memory) {
        return
            SowBlueprintBase.SowAmounts({
                totalAmountToSow: amountToSow,
                minAmountToSowPerSeason: minAmountToSow,
                maxAmountToSowPerSeason: maxAmountToSowPerSeason
            });
    }

    function test_SowBlueprintv0_BlocksAfterSunrise() public {
        // Start at a safe block number to avoid underflow
        vm.roll(100);

        TestState memory state = setupSowBlueprintv0Test();

        // Setup mock data
        SowBlueprintBase.SowAmounts memory sowAmounts = SowBlueprintBase.SowAmounts({
            totalAmountToSow: 10000e6,
            minAmountToSowPerSeason: 1000e6,
            maxAmountToSowPerSeason: 1000e6
        });
        uint256 tipAmount = 10e6; // 10 BEAN

        // Mock the sunrise block to be 10 blocks ago
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IMockFBeanstalk.sunriseBlock.selector),
            abi.encode(block.number - 10)
        );

        // Should succeed when enough blocks have passed
        (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
            state.user,
            SourceMode.PURE_PINTO,
            sowAmounts,
            0, // minTemp
            int256(tipAmount),
            state.operator,
            type(uint256).max, // maxPodlineLength
            MAX_GROWN_STALK_PER_BDV,
            5 // require 5 blocks to have passed
        );
        executeRequisition(state.operator, req, address(bs));

        // Advance to next season
        bs.siloSunrise(0);

        // Now test with not enough blocks passed
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IMockFBeanstalk.sunriseBlock.selector),
            abi.encode(block.number - 3)
        );

        // Should revert when not enough blocks have passed
        (req, ) = setupSowBlueprintv0Blueprint(
            state.user,
            SourceMode.PURE_PINTO,
            sowAmounts,
            0, // minTemp
            int256(tipAmount),
            state.operator,
            type(uint256).max, // maxPodlineLength
            MAX_GROWN_STALK_PER_BDV,
            5 // require 5 blocks to have passed
        );
        vm.expectRevert("Not enough blocks since sunrise");
        executeRequisition(state.operator, req, address(bs));

        // Advance to next season
        bs.siloSunrise(0);

        // Test exact block requirement
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IMockFBeanstalk.sunriseBlock.selector),
            abi.encode(block.number - 5)
        );

        // Should succeed when exactly enough blocks have passed
        (req, ) = setupSowBlueprintv0Blueprint(
            state.user,
            SourceMode.PURE_PINTO,
            sowAmounts,
            0, // minTemp
            int256(tipAmount),
            state.operator,
            type(uint256).max, // maxPodlineLength
            MAX_GROWN_STALK_PER_BDV,
            5 // require 5 blocks to have passed
        );
        executeRequisition(state.operator, req, address(bs));
    }

    function test_SowBlueprintv0_BlocksAfterSunrise_Zero() public {
        // Start at a safe block number to avoid underflow
        vm.roll(100);

        TestState memory state = setupSowBlueprintv0Test();

        // Setup mock data
        SowBlueprintBase.SowAmounts memory sowAmounts = SowBlueprintBase.SowAmounts({
            totalAmountToSow: 1000e6,
            minAmountToSowPerSeason: 1000e6,
            maxAmountToSowPerSeason: type(uint256).max
        });
        uint256 tipAmount = 10e6; // 10 BEAN

        // Mock the sunrise block to be current block
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IMockFBeanstalk.sunriseBlock.selector),
            abi.encode(block.number)
        );

        // Should succeed when requirement is 0 blocks
        (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
            state.user,
            SourceMode.PURE_PINTO,
            sowAmounts,
            0, // minTemp
            int256(tipAmount),
            state.operator,
            type(uint256).max, // maxPodlineLength
            MAX_GROWN_STALK_PER_BDV,
            0 // require 0 blocks to have passed
        );
        executeRequisition(state.operator, req, address(bs));
    }

    function test_isOperatorWhitelisted() public {
        TestState memory state = setupSowBlueprintv0Test();

        // Deploy actual OperatorWhitelist contract
        OperatorWhitelist whitelist = new OperatorWhitelist(address(this));

        // Test Case 1: msg.sender is whitelisted (first operator in array)
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IBeanstalk.operator.selector),
            abi.encode(msg.sender)
        );

        (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
            farmers[0],
            SourceMode.PURE_PINTO,
            makeSowAmountsArray(1000e6, 100e6, 100e6),
            0, // minTemp
            int256(10e6), // tipAmount
            address(this),
            type(uint256).max, // maxPodlineLength
            MAX_GROWN_STALK_PER_BDV,
            0 // No runBlocksAfterSunrise
        );

        // Should succeed because msg.sender is whitelisted
        executeRequisition(msg.sender, req, address(bs));

        // Advance to next season (this blueprint can run once per season)
        bs.siloSunrise(0);

        // Test Case 2: tipAddress is whitelisted (second operator in array)
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IBeanstalk.operator.selector),
            abi.encode(address(this)) // tipAddress in our setup
        );

        (req, ) = setupSowBlueprintv0Blueprint(
            farmers[0],
            SourceMode.PURE_PINTO,
            makeSowAmountsArray(1000e6, 100e6, 100e6),
            0, // minTemp
            int256(10e6), // tipAmount
            address(this),
            type(uint256).max, // maxPodlineLength
            MAX_GROWN_STALK_PER_BDV,
            0 // No runBlocksAfterSunrise
        );

        // Should succeed because tipAddress is whitelisted
        executeRequisition(address(this), req, address(bs));

        // Advance to next season
        bs.siloSunrise(0);

        // Test Case 3: Non-whitelisted operator
        address nonWhitelistedOp = address(0x4);
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IBeanstalk.operator.selector),
            abi.encode(nonWhitelistedOp)
        );

        (req, ) = setupSowBlueprintv0Blueprint(
            farmers[0],
            SourceMode.PURE_PINTO,
            makeSowAmountsArray(1000e6, 100e6, 100e6),
            0, // minTemp
            int256(10e6), // tipAmount
            address(this),
            type(uint256).max, // maxPodlineLength
            MAX_GROWN_STALK_PER_BDV,
            0 // No runBlocksAfterSunrise
        );

        // Should revert because operator is not whitelisted
        vm.expectRevert("Operator not whitelisted");
        executeRequisition(nonWhitelistedOp, req, address(bs));
    }

    /**
     * @notice This test creates 8 requestions, 4 with valid temps and 4 invalid temps.
     * It then calls validateParamsAndReturnBeanstalkStateArray and verifies only the valid one are returned.
     */
    function test_validateParamsAndReturnBeanstalkStateArray() public {
        TestState memory state = setupSowBlueprintv0Test();

        // Deposit extra beans for user
        uint256 extraAmount = 10000000e6;
        mintTokensToUser(state.user, state.beanToken, extraAmount);
        vm.prank(state.user);
        bs.deposit(state.beanToken, extraAmount, uint8(LibTransfer.From.EXTERNAL));

        bs.setMaxTempE(100e6);

        // Array to hold requisitions
        IMockFBeanstalk.Requisition[] memory requisitions = new IMockFBeanstalk.Requisition[](8);
        SowBlueprint.SowBlueprintStruct[] memory params = new SowBlueprint.SowBlueprintStruct[](8);
        address[] memory blueprintPublishers = new address[](8);
        bytes32[] memory orderHashes = new bytes32[](8);

        // Make 4 valid requisitions
        for (uint256 i = 0; i < 4; i++) {
            (
                IMockFBeanstalk.Requisition memory req,
                SowBlueprint.SowBlueprintStruct memory paramStruct
            ) = setupSowBlueprintv0Blueprint(
                    state.user,
                    SourceMode.PURE_PINTO,
                    makeSowAmountsArray(
                        state.sowAmount / 4,
                        state.sowAmount / 4,
                        type(uint256).max
                    ),
                    i * 4e6, // minTemp
                    state.tipAmount,
                    state.operator,
                    type(uint256).max, // No podline length limit for this test
                    MAX_GROWN_STALK_PER_BDV, // Use reasonable max grown stalk limit
                    0 // No runBlocksAfterSunrise
                );
            requisitions[i] = req;
            params[i] = paramStruct;
            blueprintPublishers[i] = state.user;
            orderHashes[i] = req.blueprintHash;
        }

        // Make 4 invalid requisitions
        for (uint256 i = 0; i < 4; i++) {
            (
                IMockFBeanstalk.Requisition memory req,
                SowBlueprint.SowBlueprintStruct memory paramStruct
            ) = setupSowBlueprintv0Blueprint(
                    state.user,
                    SourceMode.PURE_PINTO,
                    makeSowAmountsArray(
                        state.sowAmount / 4,
                        state.sowAmount / 4,
                        type(uint256).max
                    ),
                    100000e6 + i * 4e6, // minTemp
                    state.tipAmount,
                    state.operator,
                    type(uint256).max, // No podline length limit for this test
                    MAX_GROWN_STALK_PER_BDV, // Use reasonable max grown stalk limit
                    0 // No runBlocksAfterSunrise
                );
            requisitions[i + 4] = req;
            params[i + 4] = paramStruct;
            blueprintPublishers[i + 4] = state.user;
            orderHashes[i + 4] = req.blueprintHash;
        }

        // Skip forward 10 minutes in time
        uint256 tenMinutesInSeconds = 10 * 60;
        vm.warp(block.timestamp + tenMinutesInSeconds); // Advance time by 10 minutes
        vm.roll(block.number + (10 * 60)); // Advance blocks (assuming ~1 block per second)

        bytes32[] memory validOrderHashes = sowBlueprint.validateParamsAndReturnBeanstalkStateArray(
            params,
            orderHashes,
            blueprintPublishers
        );

        assertEq(validOrderHashes.length, 4, "Expected 4 valid order hashes");
        for (uint256 i = 0; i < 4; i++) {
            assertEq(validOrderHashes[i], orderHashes[i], "Expected valid order hash");
        }
    }



    function createSowBlueprintStructWithDynamicFee(TestState memory state, uint256 baseTip) internal view returns (SowBlueprintBase.SowBlueprintStruct memory params) {
        // Create whitelisted operators array
        address[] memory whitelistedOperators = new address[](1);
        whitelistedOperators[0] = state.operator;
        
        // Define source token (BEAN)
        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = tractorHelpers.getTokenIndex(state.beanToken);

        return SowBlueprintBase.SowBlueprintStruct({
            sowParams: SowBlueprintBase.SowParams({
                sourceTokenIndices: sourceTokenIndices,
                sowAmounts: SowBlueprintBase.SowAmounts({
                    totalAmountToSow: state.sowAmount,
                    minAmountToSowPerSeason: state.sowAmount,
                    maxAmountToSowPerSeason: state.sowAmount
                }),
                minTemp: 0,
                maxPodlineLength: type(uint256).max,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                runBlocksAfterSunrise: 0,
                slippageRatio: 0.01e18
            }),
            opParams: BlueprintBase.OperatorParams({
                whitelistedOperators: whitelistedOperators,
                tipAddress: state.operator,
                operatorTipAmount: int256(baseTip),
                useDynamicFee: true,
                feeMarginBps: 0
            })
        });
    }

    function createDynamicFeeRequisition(TestState memory state, uint256 baseTip) internal returns (IMockFBeanstalk.Requisition memory req, SowBlueprintBase.SowBlueprintStruct memory params) {
        params = createSowBlueprintStructWithDynamicFee(state, baseTip);
        
        // Encode call structure using correct selector
        bytes memory callData = abi.encodeWithSelector(
            SowBlueprint.sowBlueprint.selector,
            params
        );

        // Create requisition
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(sowBlueprint),
            callData: callData,
            clipboard: hex"0000"
        });
        
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });
        
        // Manually construct and sign blueprint to match TractorTestHelper logic
        IMockFBeanstalk.Blueprint memory blueprint = IMockFBeanstalk.Blueprint({
            publisher: state.user,
            data: abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls),
            operatorPasteInstrs: new bytes32[](0),
            maxNonce: type(uint256).max,
            startTime: block.timestamp,
            endTime: type(uint256).max
        });

        bytes32 blueprintHash = bs.getBlueprintHash(blueprint);
        uint256 privateKey = getPrivateKey(state.user);
        bytes memory signature = signBlueprint(blueprintHash, privateKey);

        req = IMockFBeanstalk.Requisition({
            blueprint: blueprint,
            blueprintHash: blueprintHash,
            signature: signature
        });
        
        // Publish Requisition from user
        vm.prank(state.user);
        bs.publishRequisition(req);
    }

    function test_sowBlueprintv0_dynamicFee() public {
        TestState memory state = setupSowBlueprintv0Test();

        uint256 baseTip = 5e6; // 5 Beans base tip
        
        // 1. Setup Blueprint Params with useDynamicFee = true using helper
        (IMockFBeanstalk.Requisition memory req, ) = createDynamicFeeRequisition(state, baseTip);
        
        // Mock sunrise block (SowBlueprint checks it)
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IMockFBeanstalk.sunriseBlock.selector),
            abi.encode(block.number)
        );

        // Mock Price
        mockPrice(1e6); // 1.0

        // Set Gas Price: 10 gwei
        vm.txGasPrice(10 gwei); 
        
        // Execute Requisition
        uint256 startGas = gasleft();
        executeRequisition(state.operator, req, address(bs));
        uint256 endGas = gasleft();
        
        // Verify Tip
        uint256 finalBalance = bs.getInternalBalance(state.operator, state.beanToken);
        uint256 actualTip = finalBalance - state.initialOperatorBeanBalance;
        
        console.log("Actual Tip: %s", actualTip);
        console.log("Base Tip:   %s", baseTip);
        console.log("Gas Used:   %s", startGas - endGas);
        
        assertGt(actualTip, baseTip, "Tip should include dynamic fee");
        
        // With 10 gwei and 2000 Pinto/ETH, fee should be approx 2 Pinto per 1000 gas?
        // 1e15 wei * 2000e6 / 1e18 = 2e6. 
        // 100k gas * 10gwei = 1e15 wei. = 2e6 Pinto = 2 Beans.
        // It should be definitely noticeable.
        assertGt(actualTip - baseTip, 100000, "Dynamic fee should be non-trivial");
    }
}

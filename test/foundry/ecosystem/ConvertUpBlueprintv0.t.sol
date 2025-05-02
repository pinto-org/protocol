// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TractorHelpers} from "contracts/ecosystem/TractorHelpers.sol";
import {ConvertUpBlueprintv0} from "contracts/ecosystem/ConvertUpBlueprintv0.sol";
import {PriceManipulation} from "contracts/ecosystem/PriceManipulation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TractorTestHelper} from "test/foundry/utils/TractorTestHelper.sol";
import {BeanstalkPrice, ReservesType} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {OperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {IWell} from "contracts/interfaces/basin/IWell.sol";
import {console} from "forge-std/console.sol";

contract ConvertUpBlueprintv0Test is TractorTestHelper {
    address[] farmers;
    PriceManipulation priceManipulation;
    BeanstalkPrice beanstalkPrice;
    ConvertUpBlueprintv0 convertUpBlueprintv0;

    // Add constant for max grown stalk limit
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16

    struct TestState {
        address user;
        address operator;
        address beanToken;
        address wellToken;
        uint256 initialUserBeanBalance;
        uint256 initialOperatorBeanBalance;
        uint256 initialWellBalance;
        uint256 convertAmount;
        int256 tipAmount;
        uint256 currentPrice;
    }

    struct BlueprintParams {
        address user;
        uint8[] sourceTokenIndices;
        uint256 totalConvertPdv;
        uint256 minConvertPdvPerExecution;
        uint256 maxConvertPdvPerExecution;
        uint256 minTimeBetweenConverts;
        uint256 minConvertBonusCapacity;
        uint256 maxGrownStalkPerBdv;
        uint256 grownStalkPerBdvBonusThreshold;
        uint256 minPriceToConvertUp;
        uint256 maxPriceToConvertUp;
        uint256 maxGrownStalkPerPdvPenalty;
        uint256 slippageRatio;
        int256 tipAmount;
        address tipAddress;
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
        tractorHelpers = new TractorHelpers(
            address(bs),
            address(beanstalkPrice),
            address(this),
            address(priceManipulation)
        );
        vm.label(address(tractorHelpers), "TractorHelpers");

        // Deploy ConvertUpBlueprintv0 with TractorHelpers and BeanstalkPrice address
        convertUpBlueprintv0 = new ConvertUpBlueprintv0(
            address(bs),
            address(this),
            address(tractorHelpers),
            address(beanstalkPrice)
        );
        vm.label(address(convertUpBlueprintv0), "ConvertUpBlueprintv0");

        setTractorHelpers(address(tractorHelpers));

        // Add liquidity to wells for testing
        addLiquidityToWell(
            BEAN_ETH_WELL,
            10_000e6, // 10,000 Beans
            10 ether // 10 ether.
        );

        addLiquidityToWell(
            BEAN_WSTETH_WELL,
            10_000e6, // 10,000 Beans
            10 ether // 10 ether.
        );

        // Set price to be ~0.975
    }

    // Break out the setup into a separate function
    function setupConvertUpBlueprintv0Test() internal returns (TestState memory) {
        TestState memory state;
        state.user = farmers[0];
        state.operator = address(this);
        state.beanToken = bs.getBeanToken();
        state.wellToken = BEAN_ETH_WELL;
        state.initialUserBeanBalance = IERC20(state.beanToken).balanceOf(state.user);
        state.initialOperatorBeanBalance = bs.getInternalBalance(state.operator, state.beanToken);
        state.convertAmount = 100e6; // Amount to convert
        state.tipAmount = 10e6; // 10 BEAN

        // Store initial well balance for the user
        state.initialWellBalance = IERC20(state.wellToken).balanceOf(state.user);

        // Log reserves of both wells before test
        console.log(
            "BEAN_ETH_WELL reserves before test: %s, %s",
            IWell(BEAN_ETH_WELL).getReserves()[0],
            IWell(BEAN_ETH_WELL).getReserves()[1]
        );
        console.log(
            "BEAN_WSTETH_WELL reserves before test: %s, %s",
            IWell(BEAN_WSTETH_WELL).getReserves()[0],
            IWell(BEAN_WSTETH_WELL).getReserves()[1]
        );

        // For farmer 1, also mint and deposit LP
        mintAndDepositBeanETH(state.user, 500e6);

        // Log reserves of both wells before test
        console.log(
            "BEAN_ETH_WELL reserves after mintAndDepositBeanETH: %s, %s",
            IWell(BEAN_ETH_WELL).getReserves()[0],
            IWell(BEAN_ETH_WELL).getReserves()[1]
        );
        console.log(
            "BEAN_WSTETH_WELL reserves after mintAndDepositBeanETH: %s, %s",
            IWell(BEAN_WSTETH_WELL).getReserves()[0],
            IWell(BEAN_WSTETH_WELL).getReserves()[1]
        );

        // Make sure LP has germinated - already handled by mintAndDepositBeanETH which calls siloSunrise
        passGermination();

        return state;
    }

    function test_convertUpBlueprintv0_PurePintoWithTip() public {
        TestState memory state = setupConvertUpBlueprintv0Test();

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = getTokenIndex(state.wellToken);

        (IMockFBeanstalk.Requisition memory req, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: state.convertAmount,
                minConvertPdvPerExecution: state.convertAmount / 4,
                maxConvertPdvPerExecution: state.convertAmount,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                grownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_BDV,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Mock the price to be within the acceptable range
        mockPrice(0.95e6); // Price of 1.0

        // Execute the conversion
        executeRequisition(state.operator, req, address(bs));

        // Verify conversion worked
        uint256 beanBalance = bs.getInternalBalance(state.user, state.beanToken);
        assertTrue(beanBalance > 0, "User should have received beans from conversion");

        // Verify tip was sent
        uint256 operatorBalance = bs.getInternalBalance(state.operator, state.beanToken);
        assertEq(
            operatorBalance,
            state.initialOperatorBeanBalance + uint256(state.tipAmount),
            "Operator did not receive correct tip amount"
        );
    }

    function test_convertUpBlueprintv0_LowestPriceStrategy() public {
        TestState memory state = setupConvertUpBlueprintv0Test();

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = type(uint8).max; // LOWEST_PRICE_STRATEGY

        (IMockFBeanstalk.Requisition memory req, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: state.convertAmount,
                minConvertPdvPerExecution: state.convertAmount / 4,
                maxConvertPdvPerExecution: state.convertAmount,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                grownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_BDV,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Mock the price to be within the acceptable range
        mockPrice(0.95e6); // Price of 1.0

        // Execute the conversion
        executeRequisition(state.operator, req, address(bs));

        // Verify conversion worked
        uint256 beanBalance = bs.getInternalBalance(state.user, state.beanToken);
        assertTrue(beanBalance > 0, "User should have received beans from conversion");
    }

    function test_convertUpBlueprintv0_PriceOutOfRange() public {
        TestState memory state = setupConvertUpBlueprintv0Test();

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = getTokenIndex(state.wellToken);

        (IMockFBeanstalk.Requisition memory req, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: state.convertAmount,
                minConvertPdvPerExecution: state.convertAmount / 4,
                maxConvertPdvPerExecution: state.convertAmount,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                grownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.99e18,
                maxPriceToConvertUp: 1.01e18,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_BDV,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Mock the price to be outside the acceptable range
        mockPrice(1.02e18); // Price of 1.02, just outside max range

        // Should revert due to price being out of range
        vm.expectRevert("Current price above maximum price for convert up");
        executeRequisition(state.operator, req, address(bs));
    }

    function test_convertUpBlueprintv0_TimeConstraints() public {
        TestState memory state = setupConvertUpBlueprintv0Test();

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = getTokenIndex(state.wellToken);

        (IMockFBeanstalk.Requisition memory req, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: state.convertAmount,
                minConvertPdvPerExecution: state.convertAmount / 4,
                maxConvertPdvPerExecution: state.convertAmount,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                grownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_BDV,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Mock the price
        mockPrice(0.95e6);

        // Execute the first conversion
        executeRequisition(state.operator, req, address(bs));

        // Try to execute it again immediately, should revert due to time constraint
        vm.expectRevert("Too soon after last execution");
        executeRequisition(state.operator, req, address(bs));

        // Advance time beyond the constraint
        vm.warp(block.timestamp + 301); // 301 seconds later

        // Now it should work
        executeRequisition(state.operator, req, address(bs));
    }

    function test_convertUpBlueprintv0Counter() public {
        TestState memory state = setupConvertUpBlueprintv0Test();

        // Set a smaller amount to convert so we can test multiple conversions
        uint256 totalConvertPdv = 1900e6; // 1900 BEAN worth of PDV
        uint256 maxPerExecution = 500e6; // 500 BEAN per execution
        uint256 tipAmount = 10e6; // 10 BEAN
        uint256 counter;

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = getTokenIndex(state.wellToken);

        // Create blueprint once and reuse it
        (IMockFBeanstalk.Requisition memory req, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: totalConvertPdv,
                minConvertPdvPerExecution: maxPerExecution,
                maxConvertPdvPerExecution: maxPerExecution,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                grownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_BDV,
                slippageRatio: 0.01e18,
                tipAmount: int256(tipAmount),
                tipAddress: state.operator
            })
        );

        // Mock the price
        mockPrice(0.95e6);

        // Get the blueprint hash from the mock beanstalk contract
        bytes32 orderHash = req.blueprintHash;

        // First conversion - should succeed and use up to the max per execution
        executeRequisition(state.operator, req, address(bs));

        // Verify counter has been updated
        counter = convertUpBlueprintv0.getPdvLeftToConvert(orderHash);
        assertEq(
            counter,
            totalConvertPdv - maxPerExecution,
            "Counter should be reduced by maxPerExecution"
        );

        // Verify the last executed timestamp was recorded properly
        assertTrue(
            convertUpBlueprintv0.getLastExecutedTimestamp(orderHash) > 0,
            "Last executed timestamp should be set"
        );

        // Advance time for next conversion
        vm.warp(block.timestamp + 301); // 301 seconds later

        // Second conversion - should succeed
        executeRequisition(state.operator, req, address(bs));

        // Verify counter has been updated
        counter = convertUpBlueprintv0.getPdvLeftToConvert(orderHash);
        assertEq(
            counter,
            totalConvertPdv - (maxPerExecution * 2),
            "Counter should be reduced by 2x maxPerExecution"
        );

        // Advance time for next conversion
        vm.warp(block.timestamp + 301); // 301 seconds later

        // Third conversion - should succeed
        executeRequisition(state.operator, req, address(bs));

        // Verify counter has been updated
        counter = convertUpBlueprintv0.getPdvLeftToConvert(orderHash);
        assertEq(
            counter,
            totalConvertPdv - (maxPerExecution * 3),
            "Counter should be reduced by 3x maxPerExecution"
        );

        // Advance time for final conversion
        vm.warp(block.timestamp + 301); // 301 seconds later

        // Fourth conversion - should succeed and set counter to max to indicate completion
        executeRequisition(state.operator, req, address(bs));

        // Verify counter is set to max
        counter = convertUpBlueprintv0.getPdvLeftToConvert(orderHash);
        assertEq(counter, type(uint256).max, "Counter should be max uint256 after completion");

        // Advance time for attempting another conversion
        vm.warp(block.timestamp + 301); // 301 seconds later

        // Attempt another conversion - should revert as order is already complete
        vm.expectRevert("Not enough PDV left to convert");
        executeRequisition(state.operator, req, address(bs));
    }

    function test_operatorWhitelisting() public {
        TestState memory state = setupConvertUpBlueprintv0Test();

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = getTokenIndex(state.wellToken);

        address whitelistedOperator = address(this);
        address nonWhitelistedOperator = address(0x999);

        // Create blueprint with whitelisted operator
        (IMockFBeanstalk.Requisition memory req, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: state.convertAmount,
                minConvertPdvPerExecution: state.convertAmount / 4,
                maxConvertPdvPerExecution: state.convertAmount,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                grownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_BDV,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: whitelistedOperator
            })
        );

        // Mock the price
        mockPrice(0.975e6);

        // Should succeed with whitelisted operator
        executeRequisition(whitelistedOperator, req, address(bs));

        // Advance time
        vm.warp(block.timestamp + 301);

        // Mock operator call to come from non-whitelisted operator
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IBeanstalk.operator.selector),
            abi.encode(nonWhitelistedOperator)
        );

        // Should revert with non-whitelisted operator
        vm.expectRevert("Operator not whitelisted");
        executeRequisition(nonWhitelistedOperator, req, address(bs));
    }

    /**
     * @notice Sets up a blueprint for Convert Up operations
     */
    function setupConvertUpBlueprintBlueprint(
        BlueprintParams memory params
    )
        internal
        returns (
            IMockFBeanstalk.Requisition memory req,
            ConvertUpBlueprintv0.ConvertUpBlueprintStruct memory paramStruct
        )
    {
        // Create the ConvertUpParams struct
        ConvertUpBlueprintv0.ConvertUpParams memory convertUpParams = ConvertUpBlueprintv0
            .ConvertUpParams({
                sourceTokenIndices: params.sourceTokenIndices,
                totalConvertPdv: params.totalConvertPdv,
                minConvertPdvPerExecution: params.minConvertPdvPerExecution,
                maxConvertPdvPerExecution: params.maxConvertPdvPerExecution,
                minTimeBetweenConverts: params.minTimeBetweenConverts,
                minConvertBonusCapacity: params.minConvertBonusCapacity,
                maxGrownStalkPerBdv: params.maxGrownStalkPerBdv,
                grownStalkPerBdvBonusThreshold: params.grownStalkPerBdvBonusThreshold,
                maxPriceToConvertUp: params.maxPriceToConvertUp,
                minPriceToConvertUp: params.minPriceToConvertUp,
                maxGrownStalkPerPdvPenalty: params.maxGrownStalkPerPdvPenalty,
                slippageRatio: params.slippageRatio
            });

        // Create the operator whitelist array
        address[] memory whitelistedOperators = new address[](1);
        whitelistedOperators[0] = address(this); // Add the current contract as a whitelisted operator

        // Create the OperatorParams struct
        ConvertUpBlueprintv0.OperatorParams memory opParams = ConvertUpBlueprintv0.OperatorParams({
            whitelistedOperators: whitelistedOperators,
            tipAddress: params.tipAddress,
            operatorTipAmount: params.tipAmount
        });

        // Create the complete ConvertUpBlueprintStruct
        paramStruct = ConvertUpBlueprintv0.ConvertUpBlueprintStruct({
            convertUpParams: convertUpParams,
            opParams: opParams
        });

        // Create the pipe call data
        bytes memory pipeCallData = createConvertUpBlueprintv0CallData(paramStruct);

        // Create the requisition using the pipe call data
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            params.user,
            pipeCallData,
            address(bs)
        );

        // Publish the requisition
        vm.prank(params.user);
        bs.publishRequisition(req);

        return (req, paramStruct);
    }

    // Helper to create the calldata for convertUpBlueprintv0
    function createConvertUpBlueprintv0CallData(
        ConvertUpBlueprintv0.ConvertUpBlueprintStruct memory params
    ) internal view returns (bytes memory) {
        // Create the convertUpBlueprintv0 pipe call
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);

        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(convertUpBlueprintv0),
            callData: abi.encodeWithSelector(
                ConvertUpBlueprintv0.convertUpBlueprintv0.selector,
                params
            ),
            clipboard: hex"0000"
        });

        // Wrap the pipe calls in a farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        // Return the encoded farm call
        return abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);
    }

    // Helper function to get token index from token address
    function getTokenIndex(address token) internal view returns (uint8) {
        return tractorHelpers.getTokenIndex(token);
    }

    /**
     * @notice Mock the price by setting the reserves directly
     * @param targetPrice The desired price in 1e18 format (e.g., 0.95e18 for $0.95)
     */
    function mockPrice(uint256 targetPrice) internal {
        // Get the well address
        address well = BEAN_ETH_WELL;

        // Set reserves to achieve the target price
        // We'll maintain 10 ETH in reserves for consistency
        uint256 ethReserves = 10 ether;
        setReservesForPrice(well, targetPrice, ethReserves);

        // Also mock the BeanstalkPrice contract's price function to return the same value
        // This ensures both price sources are consistent
        BeanstalkPrice.Prices memory mockPrices;
        mockPrices.price = targetPrice;

        vm.mockCall(
            address(beanstalkPrice),
            abi.encodeWithSelector(
                bytes4(keccak256("price(uint8)")),
                ReservesType.INSTANTANEOUS_RESERVES
            ),
            abi.encode(mockPrices)
        );
    }
}

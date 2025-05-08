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
import "forge-std/console.sol";

contract ConvertUpBlueprintv0Test is TractorTestHelper {
    address[] farmers;
    PriceManipulation priceManipulation;
    BeanstalkPrice beanstalkPrice;
    ConvertUpBlueprintv0 convertUpBlueprintv0;

    // Add constant for max grown stalk limit
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16
    int256 constant MAX_GROWN_STALK_PER_PDV_PENALTY = 1e18;

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
        uint256 minGrownStalkPerBdvBonusThreshold;
        uint256 minPriceToConvertUp;
        uint256 maxPriceToConvertUp;
        int256 maxGrownStalkPerPdvPenalty;
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
    function setupConvertUpBlueprintv0Test(bool germinate) internal returns (TestState memory) {
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

        if (germinate) {
            // Make sure LP has germinated - already handled by mintAndDepositBeanETH which calls siloSunrise
            passGermination();
        }

        return state;
    }

    // Helper for when we need to pass germination
    function setupConvertUpBlueprintv0Test() internal returns (TestState memory) {
        TestState memory state = setupConvertUpBlueprintv0Test(true);
        return state;
    }

    function test_convertUpBlueprintv0_BasicTest() public {
        TestState memory state = setupConvertUpBlueprintv0Test();

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = getTokenIndex(state.wellToken);

        // Check that user has no Bean deposits before conversion
        uint256[] memory initialBeanDeposits = bs.getTokenDepositIdsForAccount(
            state.user,
            state.beanToken
        );
        assertEq(
            initialBeanDeposits.length,
            0,
            "User should not have Bean deposits before conversion"
        );

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
                minGrownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_PDV_PENALTY,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Mock the price to be within the acceptable range
        mockPrice(0.95e6); // Price of 0.95

        // Execute the conversion
        executeRequisition(state.operator, req, address(bs));

        // Verify conversion worked by checking for Bean deposits
        uint256[] memory finalBeanDeposits = bs.getTokenDepositIdsForAccount(
            state.user,
            state.beanToken
        );

        // Verify the user received exactly one deposit
        assertEq(
            finalBeanDeposits.length,
            1,
            "User should have received exactly one Bean deposit from conversion"
        );

        // Verify tip was sent
        uint256 operatorBalance = bs.getInternalBalance(state.operator, state.beanToken);
        assertEq(
            operatorBalance,
            state.initialOperatorBeanBalance + uint256(state.tipAmount),
            "Operator did not receive correct tip amount"
        );
    }

    /**
     * @notice Helper function to get deposit amounts for BEAN-ETH and BEAN-USDC wells
     * @param user The address of the user
     * @return beanEthAmount The amount of BEAN-ETH deposited
     * @return beanUsdcAmount The amount of BEAN-USDC deposited
     */
    function getWellDepositAmounts(
        address user
    ) internal view returns (uint256 beanEthAmount, uint256 beanUsdcAmount) {
        // Get BEAN-ETH deposit
        uint256[] memory beanEthDeposits = bs.getTokenDepositIdsForAccount(user, BEAN_ETH_WELL);
        if (beanEthDeposits.length > 0) {
            (uint256 stem, uint256 amount) = bs.getDeposit(
                user,
                BEAN_ETH_WELL,
                int96(uint96(beanEthDeposits[0]))
            );
            beanEthAmount = amount;
        }

        // Get BEAN-USDC deposit
        uint256[] memory beanUsdcDeposits = bs.getTokenDepositIdsForAccount(user, BEAN_USDC_WELL);
        if (beanUsdcDeposits.length > 0) {
            (uint256 stem, uint256 amount) = bs.getDeposit(
                user,
                BEAN_USDC_WELL,
                int96(uint96(beanUsdcDeposits[0]))
            );
            beanUsdcAmount = amount;
        }
    }

    function test_convertUpBlueprintv0_LowestPriceStrategy() public {
        deployExtraWells(true, true);

        addLiquidityToWell(
            BEAN_USDC_WELL,
            10_000e6, // 10,000 Beans
            10_000e6 // 10,000 USDC
        );

        whitelistLPWell(BEAN_USDC_WELL, USDC_USD_CHAINLINK_PRICE_AGGREGATOR);

        // Let a few seasons pass so Oracle gets setup
        bs.siloSunrise(0);
        bs.siloSunrise(0);

        TestState memory state = setupConvertUpBlueprintv0Test();

        // Mint and deposit 500e6 USDC
        mintAndDepositBeanUSDC(state.user, 500e6);

        // Get initial deposit amounts
        (uint256 initialBeanEthAmount, uint256 initialBeanUsdcAmount) = getWellDepositAmounts(
            state.user
        );

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = type(uint8).max; // LOWEST_PRICE_STRATEGY

        // Check that user has no Bean deposits before conversion
        uint256[] memory initialBeanDeposits = bs.getTokenDepositIdsForAccount(
            state.user,
            state.beanToken
        );
        assertEq(
            initialBeanDeposits.length,
            0,
            "User should not have Bean deposits before conversion"
        );

        state.convertAmount = 800e6;

        // Log token balances before conversion
        logTokenBalances(state.user);

        (IMockFBeanstalk.Requisition memory req, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: state.convertAmount,
                minConvertPdvPerExecution: 1, // this way we'll always convert whatever's left
                maxConvertPdvPerExecution: 100e6,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                minGrownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_PDV_PENALTY,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Mock the price to be within the acceptable range
        mockPrice(0.95e6); // Price of 0.95

        // Execute the conversion
        executeRequisition(state.operator, req, address(bs));

        // Log token balances after conversion
        logTokenBalances(state.user);

        // Verify conversion worked by checking for Bean deposits
        uint256[] memory finalBeanDeposits = bs.getTokenDepositIdsForAccount(
            state.user,
            state.beanToken
        );

        // Verify the user received exactly one deposit
        assertEq(
            finalBeanDeposits.length,
            1,
            "User should have received exactly one Bean deposit from conversion"
        );

        for (uint256 i = 0; i < 7; i++) {
            // Fast forward time
            vm.warp(block.timestamp + 301);

            // Execute the conversion again
            executeRequisition(state.operator, req, address(bs));
        }

        // Get final deposit amounts
        (uint256 finalBeanEthAmount, uint256 finalBeanUsdcAmount) = getWellDepositAmounts(
            state.user
        );

        // Verify that both amounts have decreased
        assertTrue(
            finalBeanEthAmount < initialBeanEthAmount,
            "BEAN-ETH deposit amount should have decreased"
        );
        assertTrue(
            finalBeanUsdcAmount < initialBeanUsdcAmount,
            "BEAN-USDC deposit amount should have decreased"
        );
    }

    /**
     * @notice Helper function to get a human-readable token name
     * @param tokenAddress The address of the token
     * @param fallbackName A fallback name if the token name cannot be identified
     * @return A string representing the token name
     */
    function getTokenName(
        address tokenAddress,
        string memory fallbackName
    ) internal view returns (string memory) {
        // Check against known token addresses
        if (tokenAddress == BEAN) {
            return "Bean";
        } else if (tokenAddress == BEAN_ETH_WELL) {
            return "BEAN-ETH Well";
        } else if (tokenAddress == BEAN_WSTETH_WELL) {
            return "BEAN-WSTETH Well";
        } else if (tokenAddress == BEAN_USDC_WELL) {
            return "BEAN-USDC Well";
        } else if (tokenAddress == WETH) {
            return "WETH";
        } else if (tokenAddress == WSTETH) {
            return "WSTETH";
        } else if (tokenAddress == USDC) {
            return "USDC";
        } else if (tokenAddress == USDT) {
            return "USDT";
        } else if (tokenAddress == WBTC) {
            return "WBTC";
        } else {
            // If we don't recognize the address, use the fallback name
            return fallbackName;
        }
    }

    function logTokenPrices() internal {
        try tractorHelpers.getTokensAscendingPrice() returns (
            uint8[] memory priceOrderedTokensAfter,
            uint256[] memory prices
        ) {
            console.log("------------ Token prices: ------------");
            // Log each token index
            for (uint8 i = 0; i < priceOrderedTokensAfter.length; i++) {
                try tractorHelpers.getWhitelistStatusAddresses() returns (
                    address[] memory tokenAddresses
                ) {
                    // Get token address
                    address tokenAddress = tokenAddresses[priceOrderedTokensAfter[i]];

                    // Get token name using the helper function
                    string memory tokenName = getTokenName(tokenAddress, "Unknown");

                    // Log token index, token name and price
                    console.log(
                        "Token index: %s, Token: %s Price: %s",
                        priceOrderedTokensAfter[i],
                        tokenName,
                        prices[i]
                    );
                } catch {
                    console.log(
                        "Token index: %s, Price: %s (Failed to get address)",
                        priceOrderedTokensAfter[i],
                        prices[i]
                    );
                }
            }
        } catch {
            console.log("Failed to get token prices");
        }
    }

    function logUsersDeposits(address user) internal {
        console.log("--------------------------------");

        // Log Bean deposits
        string memory beanName = getTokenName(BEAN, "Bean");
        console.log("BEAN (%s) deposits for user: %s", beanName, user);

        // Use try/catch for Bean deposits
        try tractorHelpers.getSortedDeposits(user, BEAN) returns (
            int96[] memory beanStems,
            uint256[] memory beanAmounts
        ) {
            for (uint256 i = 0; i < beanStems.length; i++) {
                console.log("Stem");
                console.logInt(beanStems[i]);
                console.log("Amount");
                console.logUint(beanAmounts[i]);
            }
        } catch {
            console.log("No Bean deposits found");
        }
        console.log("--------------------------------");

        // Log ETH well deposits
        string memory ethWellName = getTokenName(BEAN_ETH_WELL, "BEAN-ETH Well");
        console.log("ETH well (%s) deposits for user: %s", ethWellName, user);
        try tractorHelpers.getSortedDeposits(user, BEAN_ETH_WELL) returns (
            int96[] memory ethStems,
            uint256[] memory ethAmounts
        ) {
            for (uint256 i = 0; i < ethStems.length; i++) {
                console.log("Stem");
                console.logInt(ethStems[i]);
                console.log("Amount");
                console.logUint(ethAmounts[i]);
            }
        } catch {
            console.log("No ETH well deposits found");
        }
        console.log("--------------------------------");

        // Log WSTETH well deposits
        string memory wstethWellName = getTokenName(BEAN_WSTETH_WELL, "BEAN-WSTETH Well");
        console.log("WSTETH well (%s) deposits for user: %s", wstethWellName, user);
        try tractorHelpers.getSortedDeposits(user, BEAN_WSTETH_WELL) returns (
            int96[] memory wstethStems,
            uint256[] memory wstethAmounts
        ) {
            for (uint256 i = 0; i < wstethStems.length; i++) {
                console.log("Stem");
                console.logInt(wstethStems[i]);
                console.log("Amount");
                console.logUint(wstethAmounts[i]);
            }
        } catch {
            console.log("No WSTETH well deposits found");
        }
        console.log("--------------------------------");

        // Log USDC well deposits
        string memory usdcWellName = getTokenName(BEAN_USDC_WELL, "BEAN-USDC Well");
        console.log("USDC well (%s) deposits for user: %s", usdcWellName, user);
        try tractorHelpers.getSortedDeposits(user, BEAN_USDC_WELL) returns (
            int96[] memory usdcStems,
            uint256[] memory usdcAmounts
        ) {
            for (uint256 i = 0; i < usdcStems.length; i++) {
                console.log("Stem");
                console.logInt(usdcStems[i]);
                console.log("Amount");
                console.logUint(usdcAmounts[i]);
            }
        } catch {
            console.log("No USDC well deposits found");
        }
        console.log("--------------------------------");
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
                minGrownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.99e6,
                maxPriceToConvertUp: 1.01e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_PDV_PENALTY,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Mock the price to be outside the acceptable range
        mockPrice(1.02e6); // Price of 1.02, just outside max range

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
                maxConvertPdvPerExecution: state.convertAmount / 4,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 0,
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                minGrownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_PDV_PENALTY,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Mock the price
        mockPrice(0.95e6);

        console.log("Executing first conversion");

        // Execute the first conversion
        executeRequisition(state.operator, req, address(bs));

        console.log("First conversion executed");

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
        uint256 totalConvertPdv = 40e6; // 40 BEAN worth of PDV total
        uint256 maxPerExecution = 10e6; // 10 BEAN per execution
        uint256 tipAmount = 1e6; // 1 BEAN
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
                minGrownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_PDV_PENALTY,
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
        console.log("Counter after first conversion: %s", counter);
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

        console.log("Counter after time warp: %s", counter);

        // Log current price
        console.log(
            "Current price: %s",
            beanstalkPrice.price(ReservesType.INSTANTANEOUS_RESERVES).price
        );

        // Second conversion - should succeed
        executeRequisition(state.operator, req, address(bs));

        // Verify counter has been updated
        counter = convertUpBlueprintv0.getPdvLeftToConvert(orderHash);
        console.log("Counter after second conversion: %s", counter);
        assertEq(
            counter,
            totalConvertPdv - (maxPerExecution * 2),
            "Counter should be reduced by 2x maxPerExecution"
        );

        // Advance time for next conversion
        vm.warp(block.timestamp + 301); // 301 seconds later

        console.log("executing third conversion");

        // Third conversion - should succeed
        executeRequisition(state.operator, req, address(bs));

        // Verify counter has been updated
        counter = convertUpBlueprintv0.getPdvLeftToConvert(orderHash);
        console.log("Counter after third conversion: %s", counter);
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
        console.log("Counter after fourth conversion: %s", counter);
        assertEq(counter, type(uint256).max, "Counter should be max uint256 after completion");

        // Advance time for attempting another conversion
        vm.warp(block.timestamp + 301); // 301 seconds later

        // Attempt another conversion - should revert as order is already complete
        vm.expectRevert("Order has already been completed");
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
                minGrownStalkPerBdvBonusThreshold: 0,
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_PDV_PENALTY,
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
                minGrownStalkPerBdvBonusThreshold: params.minGrownStalkPerBdvBonusThreshold,
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
     * @notice Helper function to log token balances for a user
     * @param user The address of the user
     */
    function logTokenBalances(address user) internal {
        console.log("========== Token Balances for %s ==========", user);

        // Log Bean balance
        string memory beanName = getTokenName(BEAN, "Bean");
        uint256 beanBalance = IERC20(BEAN).balanceOf(user);
        uint256 beanInternalBalance = bs.getInternalBalance(user, BEAN);
        console.log("%s: %s (external), %s (internal)", beanName, beanBalance, beanInternalBalance);

        // Log BEAN-ETH Well LP token balance
        string memory ethWellName = getTokenName(BEAN_ETH_WELL, "BEAN-ETH Well");
        uint256 ethWellBalance = IERC20(BEAN_ETH_WELL).balanceOf(user);
        uint256 ethWellInternalBalance = bs.getInternalBalance(user, BEAN_ETH_WELL);
        console.log(
            "%s: %s (external), %s (internal)",
            ethWellName,
            ethWellBalance,
            ethWellInternalBalance
        );

        // Log BEAN-WSTETH Well LP token balance
        string memory wstethWellName = getTokenName(BEAN_WSTETH_WELL, "BEAN-WSTETH Well");
        uint256 wstethWellBalance = IERC20(BEAN_WSTETH_WELL).balanceOf(user);
        uint256 wstethWellInternalBalance = bs.getInternalBalance(user, BEAN_WSTETH_WELL);
        console.log(
            "%s: %s (external), %s (internal)",
            wstethWellName,
            wstethWellBalance,
            wstethWellInternalBalance
        );

        // Log BEAN-USDC Well LP token balance if it exists
        try IERC20(BEAN_USDC_WELL).balanceOf(user) returns (uint256 usdcWellBalance) {
            string memory usdcWellName = getTokenName(BEAN_USDC_WELL, "BEAN-USDC Well");
            uint256 usdcWellInternalBalance = bs.getInternalBalance(user, BEAN_USDC_WELL);
            console.log(
                "%s: %s (external), %s (internal)",
                usdcWellName,
                usdcWellBalance,
                usdcWellInternalBalance
            );
        } catch {
            // BEAN_USDC_WELL may not be deployed in all tests
        }

        console.log("===========================================");
    }

    function test_convertUpBlueprintv0_BonusCapacityCheck() public {
        TestState memory state = setupConvertUpBlueprintv0Test();

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = getTokenIndex(state.wellToken);

        // Mock getConvertBonusBdvAmountAndRemainingCapacity to return specific values
        // Returns 5e16 bonus stalk per BDV and 1000e6 remaining capacity
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(
                IBeanstalk.getConvertBonusBdvAmountAndRemainingCapacity.selector
            ),
            abi.encode(5e16, 1000e6)
        );

        // Create a blueprint requiring minimum bonus stalk per BDV of 6e16 (higher than available)
        (IMockFBeanstalk.Requisition memory failReqStalk, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: state.convertAmount,
                minConvertPdvPerExecution: state.convertAmount / 4,
                maxConvertPdvPerExecution: state.convertAmount,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 0, // No minimum capacity requirement
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                minGrownStalkPerBdvBonusThreshold: 6e16, // Higher than available 5e16
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_PDV_PENALTY,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Mock the price to be within acceptable range
        mockPrice(0.95e6);

        // Should revert due to insufficient bonus stalk per BDV
        vm.expectRevert("Convert bonus amount below threshold");
        executeRequisition(state.operator, failReqStalk, address(bs));

        // Create a blueprint requiring minimum capacity of 2000e6 (higher than available)
        (IMockFBeanstalk.Requisition memory failReqCapacity, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: state.convertAmount,
                minConvertPdvPerExecution: state.convertAmount / 4,
                maxConvertPdvPerExecution: state.convertAmount,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 2000e6, // Higher than available 1000e6
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                minGrownStalkPerBdvBonusThreshold: 0, // No minimum stalk per BDV requirement
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_PDV_PENALTY,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Should revert due to insufficient bonus capacity
        vm.expectRevert("Convert bonus capacity below minimum");
        executeRequisition(state.operator, failReqCapacity, address(bs));

        // Create a blueprint with acceptable bonus requirements
        (IMockFBeanstalk.Requisition memory successReq, ) = setupConvertUpBlueprintBlueprint(
            BlueprintParams({
                user: state.user,
                sourceTokenIndices: sourceTokenIndices,
                totalConvertPdv: state.convertAmount,
                minConvertPdvPerExecution: state.convertAmount / 4,
                maxConvertPdvPerExecution: state.convertAmount,
                minTimeBetweenConverts: 300,
                minConvertBonusCapacity: 500e6, // Lower than available 1000e6
                maxGrownStalkPerBdv: MAX_GROWN_STALK_PER_BDV,
                minGrownStalkPerBdvBonusThreshold: 4e16, // Lower than available 5e16
                minPriceToConvertUp: 0.94e6,
                maxPriceToConvertUp: 0.99e6,
                maxGrownStalkPerPdvPenalty: MAX_GROWN_STALK_PER_PDV_PENALTY,
                slippageRatio: 0.01e18,
                tipAmount: state.tipAmount,
                tipAddress: state.operator
            })
        );

        // Should succeed with acceptable bonus requirements
        executeRequisition(state.operator, successReq, address(bs));

        // Verify conversion succeeded by checking for Bean deposits
        uint256[] memory finalBeanDeposits = bs.getTokenDepositIdsForAccount(
            state.user,
            state.beanToken
        );

        // Verify the user received exactly one deposit
        assertEq(
            finalBeanDeposits.length,
            1,
            "User should have received exactly one Bean deposit from conversion"
        );
    }
}

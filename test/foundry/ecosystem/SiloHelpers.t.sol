// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {OracleFacet} from "contracts/beanstalk/facets/sun/OracleFacet.sol";
import {MockChainlinkAggregator} from "contracts/mocks/MockChainlinkAggregator.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {LSDChainlinkOracle} from "contracts/ecosystem/oracles/LSDChainlinkOracle.sol";
import {LibChainlinkOracle} from "contracts/libraries/Oracle/LibChainlinkOracle.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWell, Call} from "contracts/interfaces/basin/IWell.sol";
import {SiloHelpers} from "contracts/ecosystem/SiloHelpers.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {AdvancedFarmCall} from "contracts/libraries/LibFarm.sol";
import {IBeanstalkWellFunction} from "contracts/interfaces/basin/IBeanstalkWellFunction.sol";
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {P} from "contracts/ecosystem/price/P.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TractorHelper} from "test/foundry/utils/TractorHelper.sol";
import {SowBlueprintv0} from "contracts/ecosystem/SowBlueprintv0.sol";
import {console} from "forge-std/console.sol";
import {PriceManipulation} from "contracts/ecosystem/PriceManipulation.sol";
/**
 * @notice Tests the functionality of the Oracles.
 */
contract SiloHelpersTest is TractorHelper {
    address[] farmers;
    BeanstalkPrice beanstalkPrice;

    // Add constant for max grown stalk limit
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        farmers = createUsers(2);

        // Deploy BeanstalkPrice
        beanstalkPrice = new BeanstalkPrice(address(bs));
        vm.label(address(beanstalkPrice), "BeanstalkPrice");

        // Deploy PriceManipulation first
        PriceManipulation priceManipulationContract = new PriceManipulation(address(bs));
        vm.label(address(priceManipulationContract), "PriceManipulation");

        // Deploy SiloHelpers with PriceManipulation address
        siloHelpers = new SiloHelpers(
            address(bs),
            address(beanstalkPrice),
            address(this),
            address(priceManipulationContract)
        );
        vm.label(address(siloHelpers), "SiloHelpers");

        // Deploy SowBlueprintv0 with SiloHelpers address
        sowBlueprintv0 = new SowBlueprintv0(
            address(bs),
            address(beanstalkPrice),
            address(this),
            address(siloHelpers)
        );
        vm.label(address(sowBlueprintv0), "SowBlueprintv0");

        setSiloHelpers(address(siloHelpers));
        setSowBlueprintv0(address(sowBlueprintv0));

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

    function test_getDepositStemsAndAmountsToWithdraw() public {
        // setup multiple deposits in different seasons
        uint256 depositAmount = 1000e6;
        uint256 numDeposits = 50;

        for (uint256 i; i < numDeposits; i++) {
            mintTokensToUser(farmers[0], BEAN, depositAmount);
            vm.prank(farmers[0]);
            bs.deposit(BEAN, depositAmount, 0);
            bs.siloSunrise(0); // Move to next season to get different stems
        }

        // Get all deposits to find grown stalk values
        (int96[] memory allStems, ) = siloHelpers.getSortedDeposits(farmers[0], BEAN);

        // Get grown stalk per BDV for each deposit
        int96[] memory minStems = new int96[](3);
        minStems[0] = allStems[0]; // Newest deposit's stem
        minStems[1] = allStems[allStems.length / 2]; // Middle deposit's stem
        minStems[2] = allStems[allStems.length - 1]; // Oldest deposit's stem

        // Test cases
        uint256[] memory testAmounts = new uint256[](6);
        testAmounts[0] = 500e6; // Partial withdrawal from newest deposit
        testAmounts[1] = 1000e6; // Full withdrawal from one deposit
        testAmounts[2] = 2000e6; // 2 full deposits
        testAmounts[3] = 2500e6; // Withdrawal spanning multiple deposits
        testAmounts[4] = 3000e6; // 3 full withdrawal
        testAmounts[5] = 50000e6; // All 50 full withdrawal

        for (uint256 i; i < testAmounts.length; i++) {
            for (uint256 j; j < minStems.length; j++) {
                // Calculate total available amount for deposits with stems >= minStem
                uint256 totalAvailableForStem;
                for (uint256 k = 0; k < allStems.length; k++) {
                    if (allStems[k] >= minStems[j]) {
                        totalAvailableForStem += depositAmount;
                    }
                }

                (
                    int96[] memory stems,
                    uint256[] memory amounts,
                    uint256 availableAmount
                ) = siloHelpers.getDepositStemsAndAmountsToWithdraw(
                        farmers[0],
                        BEAN,
                        testAmounts[i],
                        minStems[j]
                    );

                // Count how many deposits were used (non-zero amounts)
                uint256 depositsUsed;
                uint256 totalAmount;
                for (uint256 k; k < amounts.length; k++) {
                    if (amounts[k] > 0) {
                        depositsUsed++;
                        totalAmount += amounts[k];
                    }
                }

                // Verify all stems correspond to deposits with stem >= minStem
                for (uint256 k; k < stems.length; k++) {
                    if (amounts[k] > 0) {
                        assertTrue(stems[k] >= minStems[j], "Stem below minimum");
                    }
                }

                // Verify availableAmount matches sum of amounts
                assertEq(
                    availableAmount,
                    totalAmount,
                    "Available amount doesn't match sum of amounts"
                );

                // For cases where we expect full amount to be available
                if (testAmounts[i] <= totalAvailableForStem) {
                    assertEq(availableAmount, testAmounts[i], "Should get full requested amount");
                }
                // For cases where we expect partial or no amount available
                else {
                    assertEq(
                        availableAmount,
                        totalAvailableForStem,
                        "Should get maximum available amount for stem"
                    );
                }
            }
        }

        // Test with non-existent account
        (int96[] memory noStems, uint256[] memory noAmounts, uint256 noAvailable) = siloHelpers
            .getDepositStemsAndAmountsToWithdraw(address(0x123), BEAN, 1000e6, 0);
        assertEq(noStems.length, 0, "Should return empty stems array for non-existent account");
        assertEq(noAmounts.length, 0, "Should return empty amounts array for non-existent account");
        assertEq(noAvailable, 0, "Should return 0 available for non-existent account");
    }

    /**
     * @notice Helper function to setup fork test environment
     */
    function setupForkTest()
        internal
        returns (address testWallet, address PINTO_DIAMOND, address PINTO)
    {
        testWallet = 0xFb94D3404c1d3D9D6F08f79e58041d5EA95AccfA;
        uint256 forkBlock = 25040000;
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock);

        PINTO_DIAMOND = address(0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f);
        PINTO = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;
        address BEANSTALK_PRICE = 0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E;

        // Deploy PriceManipulation first
        PriceManipulation priceManipulationContract = new PriceManipulation(PINTO_DIAMOND);
        vm.label(address(priceManipulationContract), "PriceManipulation");

        // Deploy SiloHelpers with PriceManipulation address
        siloHelpers = new SiloHelpers(
            PINTO_DIAMOND,
            BEANSTALK_PRICE,
            address(this),
            address(priceManipulationContract)
        );
        vm.label(address(siloHelpers), "SiloHelpers");

        // Deploy SowBlueprintv0 with SiloHelpers address
        sowBlueprintv0 = new SowBlueprintv0(
            PINTO_DIAMOND,
            BEANSTALK_PRICE,
            address(this),
            address(siloHelpers)
        );
        vm.label(address(sowBlueprintv0), "SowBlueprintv0");

        setSiloHelpers(address(siloHelpers));
        setSowBlueprintv0(address(sowBlueprintv0));

        return (testWallet, PINTO_DIAMOND, PINTO);
    }

    /**
     * @notice Tests by forking Base with an example account and verifies the function does not revert
     */
    function test_forkGetDepositStemsAndAmountsToWithdraw() public {
        (address testWallet, , address PINTO) = setupForkTest();

        uint256 requestAmount = 50000e6;
        // uint256 gasBefore = gasleft();

        // Get deposit stems and amounts to withdraw
        (int96[] memory stems, uint256[] memory amounts, uint256 availableAmount) = siloHelpers
            .getDepositStemsAndAmountsToWithdraw(testWallet, PINTO, requestAmount, 0);

        // uint256 gasUsed = gasBefore - gasleft();
        // console.log("Gas used for getDepositStemsAndAmountsToWithdraw:", gasUsed);

        // Basic validations
        assertTrue(stems.length == amounts.length, "Arrays should be same length");

        // Calculate total from amounts
        uint256 totalAmount;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
            if (amounts[i] > 0) {
                assertTrue(stems[i] >= 0, "Stem should be >= minStem");
            }
        }

        // Verify availableAmount matches sum of amounts
        assertEq(availableAmount, totalAmount, "Available amount should match sum of amounts");
        assertTrue(
            availableAmount <= requestAmount,
            "Available amount should not exceed requested"
        );
    }

    function test_getLPTokensToWithdrawForBeans() public {
        // Add liquidity to create a baseline price
        addLiquidityToWell(
            BEAN_ETH_WELL,
            1000e6, // 1000 Beans
            1 ether // 1 ETH
        );

        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 100e6; // 100 Beans
        testAmounts[1] = 500e6; // 500 Beans
        testAmounts[2] = 1000e6; // 1000 Beans

        for (uint256 i; i < testAmounts.length; i++) {
            uint256 lpNeeded = siloHelpers.getLPTokensToWithdrawForBeans(
                testAmounts[i],
                BEAN_ETH_WELL
            );

            // Verify we get exactly the requested amount of Beans
            uint256 beansOut = IWell(BEAN_ETH_WELL).getRemoveLiquidityOneTokenOut(
                lpNeeded,
                IERC20(BEAN)
            );

            assertEq(beansOut, testAmounts[i], "Bean amount mismatch");
        }
    }

    function test_withdrawBeansHelperMultipleLPDeposits() public {
        // Setup: Create multiple LP deposits over various seasons, deposit amounts 100, then 200, then 300, etc
        uint256 numDeposits = 10;
        uint256 depositAmount = 100e6;
        uint256 totalBeansToWithdraw = 0;
        for (uint256 i = 1; i < numDeposits + 1; i++) {
            mintAndDepositBeanETH(farmers[0], depositAmount * i);
            totalBeansToWithdraw += depositAmount * i;
        }

        // Get all deposits to find grown stalk values
        (int96[] memory allStems, uint256[] memory allAmounts) = siloHelpers.getSortedDeposits(
            farmers[0],
            BEAN_ETH_WELL
        );

        uint256 initialBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);

        // Setup a setupWithdrawBeansBlueprint to withdraw the total amount of beans
        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = siloHelpers.getTokenIndex(BEAN_ETH_WELL);
        IMockFBeanstalk.Requisition memory req = setupWithdrawBeansBlueprint(
            farmers[0],
            totalBeansToWithdraw,
            sourceTokenIndices,
            MAX_GROWN_STALK_PER_BDV,
            LibTransfer.To.EXTERNAL
        );

        // Execute the blueprint
        vm.prank(farmers[0]);
        bs.publishRequisition(req);
        executeRequisition(farmers[0], req, address(bs));

        assertEq(
            IERC20(BEAN).balanceOf(farmers[0]),
            initialBeanBalance + totalBeansToWithdraw,
            "Bean balance incorrect after withdrawal"
        );
    }

    function test_withdrawBeansHelper() public {
        // Setup: Create deposits in both Bean and LP tokens
        uint256 beanAmount = 1000e6;

        // Deposit Beans
        mintTokensToUser(farmers[0], BEAN, beanAmount * 2);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, beanAmount, 0);

        // Approve spending Bean to well
        vm.prank(farmers[0]);
        MockToken(BEAN).approve(BEAN_ETH_WELL, beanAmount);

        // Deposit LP tokens
        // add liquidity to well
        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = beanAmount;
        tokenAmountsIn[1] = 0;

        vm.prank(farmers[0]);
        uint256 lpAmountOut = IWell(BEAN_ETH_WELL).addLiquidity(
            tokenAmountsIn,
            0,
            farmers[0],
            type(uint256).max
        );

        // Approve spending LP tokens to well
        vm.prank(farmers[0]);
        MockToken(BEAN_ETH_WELL).approve(address(bs), lpAmountOut);

        vm.prank(farmers[0]);
        bs.deposit(BEAN_ETH_WELL, lpAmountOut, 0);

        // Skip germination
        bs.siloSunrise(0);
        bs.siloSunrise(0);

        uint256 snapshot = vm.snapshot();

        // Test Case 1: Withdraw Beans directly
        {
            uint256 withdrawAmount = 500e6;
            uint256 initialBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);

            // Create array with single index for Bean token
            uint8[] memory sourceTokenIndices = new uint8[](1);
            sourceTokenIndices[0] = siloHelpers.getTokenIndex(BEAN);

            // Setup and execute the blueprint
            IMockFBeanstalk.Requisition memory req = setupWithdrawBeansBlueprint(
                farmers[0],
                withdrawAmount,
                sourceTokenIndices,
                MAX_GROWN_STALK_PER_BDV,
                LibTransfer.To.EXTERNAL
            );
            vm.prank(farmers[0]);
            bs.publishRequisition(req);

            console.log("Executing requisition");

            executeRequisition(farmers[0], req, address(bs));
            console.log("Executed requisition");

            assertEq(
                IERC20(BEAN).balanceOf(farmers[0]),
                initialBeanBalance + withdrawAmount,
                "Bean balance incorrect after direct withdrawal"
            );
        }

        vm.revertTo(snapshot);
        snapshot = vm.snapshot();

        // Test Case 2: Withdraw Beans from LP tokens
        {
            uint256 withdrawAmount = 100e6;
            uint256 initialBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);
            uint256 initialLPBalance = IERC20(BEAN_ETH_WELL).balanceOf(farmers[0]);

            // Calculate expected LP tokens needed
            uint256 expectedLPAmount = siloHelpers.getLPTokensToWithdrawForBeans(
                withdrawAmount,
                BEAN_ETH_WELL
            );

            // Setup and execute the blueprint
            uint8[] memory sourceTokenIndices = new uint8[](1);
            sourceTokenIndices[0] = siloHelpers.getTokenIndex(BEAN_ETH_WELL);
            IMockFBeanstalk.Requisition memory req = setupWithdrawBeansBlueprint(
                farmers[0],
                withdrawAmount,
                sourceTokenIndices,
                MAX_GROWN_STALK_PER_BDV,
                LibTransfer.To.EXTERNAL
            );
            vm.prank(farmers[0]);
            bs.publishRequisition(req);

            executeRequisition(farmers[0], req, address(bs));

            assertGe(
                IERC20(BEAN).balanceOf(farmers[0]),
                initialBeanBalance + withdrawAmount,
                "Bean balance incorrect after LP withdrawal"
            );
            assertEq(
                IERC20(BEAN_ETH_WELL).balanceOf(farmers[0]),
                initialLPBalance,
                "LP balance should not change"
            );
        }

        vm.revertTo(snapshot);
        snapshot = vm.snapshot();

        // Test Case 3: Attempt to withdraw more Beans than available
        {
            uint256 withdrawAmount = 1000000e6; // 1M Beans (more than deposited)

            // Create array with single index for Bean token
            uint8[] memory sourceTokenIndices = new uint8[](1);
            sourceTokenIndices[0] = siloHelpers.getTokenIndex(BEAN);

            // Get withdrawal plan
            SiloHelpers.WithdrawalPlan memory plan = siloHelpers.getWithdrawalPlan(
                farmers[0],
                sourceTokenIndices,
                withdrawAmount,
                MAX_GROWN_STALK_PER_BDV
            );

            vm.expectRevert("Silo: Crate balance too low."); // NOTE: this test will be updated with the plan change
            siloHelpers.withdrawBeansFromSources(
                farmers[0],
                sourceTokenIndices,
                withdrawAmount,
                MAX_GROWN_STALK_PER_BDV,
                0.01e18, // 1%
                LibTransfer.To.EXTERNAL,
                plan
            );
        }

        // Test Case 4: Withdraw Beans from multiple sources
        {
            uint256 beanWithdrawAmount = 1000e6; // 1000 Beans directly
            uint256 lpBeanWithdrawAmount = 300e6; // 300 Beans from LP tokens
            uint256 totalWithdrawAmount = beanWithdrawAmount + lpBeanWithdrawAmount; // 1300 Beans total

            uint256 initialBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);
            uint256 initialLPBalance = IERC20(BEAN_ETH_WELL).balanceOf(farmers[0]);

            // Create array with both Bean and LP token indices
            uint8[] memory sourceTokenIndices = new uint8[](2);
            sourceTokenIndices[0] = siloHelpers.getTokenIndex(BEAN);
            sourceTokenIndices[1] = siloHelpers.getTokenIndex(BEAN_ETH_WELL);

            // Setup and execute the blueprint
            IMockFBeanstalk.Requisition memory req = setupWithdrawBeansBlueprint(
                farmers[0],
                totalWithdrawAmount,
                sourceTokenIndices,
                MAX_GROWN_STALK_PER_BDV,
                LibTransfer.To.EXTERNAL
            );

            vm.prank(farmers[0]);
            bs.publishRequisition(req);

            executeRequisition(farmers[0], req, address(bs));

            // Verify the total bean balance increased by the expected amount
            uint256 finalBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);
            assertGe(
                finalBeanBalance - initialBeanBalance,
                totalWithdrawAmount,
                "Bean balance did not increase by expected amount"
            );

            // LP balance should remain unchanged as the LP tokens were converted to Beans
            assertEq(
                IERC20(BEAN_ETH_WELL).balanceOf(farmers[0]),
                initialLPBalance,
                "LP balance should not change"
            );
        }
    }

    function test_getSortedWhitelistedTokensBySeeds() public {
        // Get sorted tokens and seeds
        (address[] memory tokens, uint256[] memory seeds) = siloHelpers
            .getSortedWhitelistedTokensBySeeds();

        // Verify arrays are same length and not empty
        assertGt(tokens.length, 0, "No tokens returned");
        assertEq(tokens.length, seeds.length, "Array lengths mismatch");

        // Verify tokens are sorted by seed value (highest to lowest)
        for (uint256 i = 1; i < seeds.length; i++) {
            assertGe(seeds[i - 1], seeds[i], "Seeds not properly sorted in descending order");
        }

        // Verify each token's seed value matches its position
        for (uint256 i = 0; i < tokens.length; i++) {
            IMockFBeanstalk.AssetSettings memory settings = bs.tokenSettings(tokens[i]);
            assertEq(settings.stalkEarnedPerSeason, seeds[i], "Seed value mismatch for token");
        }
    }

    function test_getHighestSeedToken() public {
        // Get highest seed token
        (address highestSeedToken, uint256 seedAmount) = siloHelpers.getHighestSeedToken();

        // Get all tokens and verify this is indeed the highest
        address[] memory tokens = bs.getWhitelistedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            IMockFBeanstalk.AssetSettings memory settings = bs.tokenSettings(tokens[i]);
            assertLe(
                settings.stalkEarnedPerSeason,
                seedAmount,
                "Found token with higher seed value"
            );
        }

        // Verify the returned seed amount matches the token's settings
        IMockFBeanstalk.AssetSettings memory highestSettings = bs.tokenSettings(highestSeedToken);
        assertEq(
            highestSettings.stalkEarnedPerSeason,
            seedAmount,
            "Returned seed amount doesn't match token settings"
        );
    }

    function test_getLowestSeedToken() public {
        // Get lowest seed token
        (address lowestSeedToken, uint256 seedAmount) = siloHelpers.getLowestSeedToken();

        // Get all tokens and verify this is indeed the lowest
        address[] memory tokens = bs.getWhitelistedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            IMockFBeanstalk.AssetSettings memory settings = bs.tokenSettings(tokens[i]);
            assertGe(
                settings.stalkEarnedPerSeason,
                seedAmount,
                "Found token with lower seed value"
            );
        }

        // Verify the returned seed amount matches the token's settings
        IMockFBeanstalk.AssetSettings memory lowestSettings = bs.tokenSettings(lowestSeedToken);
        assertEq(
            lowestSettings.stalkEarnedPerSeason,
            seedAmount,
            "Returned seed amount doesn't match token settings"
        );
    }

    function test_getUserDepositedTokens() public {
        address user = farmers[0];

        // Initially user should have no deposits
        address[] memory initialTokens = siloHelpers.getUserDepositedTokens(user);
        assertEq(initialTokens.length, 0, "User should have no deposits initially");

        // Setup deposits
        setupUserDeposits(user);

        // Get user's deposited tokens
        address[] memory depositedTokens = siloHelpers.getUserDepositedTokens(user);

        // Verify correct number of tokens
        assertEq(depositedTokens.length, 2, "User should have deposits in 2 tokens");

        // Verify the specific tokens are included
        bool foundBean = false;
        bool foundLP = false;
        for (uint256 i = 0; i < depositedTokens.length; i++) {
            if (depositedTokens[i] == BEAN) foundBean = true;
            if (depositedTokens[i] == BEAN_ETH_WELL) foundLP = true;
        }
        assertTrue(foundBean, "Bean deposit not found");
        assertTrue(foundLP, "LP deposit not found");
    }

    function test_getTokensAscendingSeeds() public {
        // Get sorted tokens
        (uint8[] memory tokenIndices, uint256[] memory seeds) = siloHelpers
            .getTokensAscendingSeeds();

        // Verify arrays are not empty and have same length
        assertGt(tokenIndices.length, 0, "Should have at least one token");
        assertEq(tokenIndices.length, seeds.length, "Arrays should have same length");

        // Verify arrays are sorted by seed value (ascending)
        for (uint256 i = 0; i < seeds.length - 1; i++) {
            assertTrue(seeds[i] <= seeds[i + 1], "Seeds should be sorted in ascending order");
        }

        // Verify indices correspond to whitelisted tokens
        address[] memory whitelistedTokens = bs.getWhitelistedTokens();
        assertEq(
            tokenIndices.length,
            whitelistedTokens.length,
            "Should return all whitelisted tokens"
        );

        // Verify seeds are non-zero
        for (uint256 i = 0; i < seeds.length; i++) {
            assertGt(seeds[i], 0, "Seeds should be non-zero");
        }
    }

    function test_getTokensAscendingPrice() public {
        // Call Price on beanstalkprice contract and verify it's not 0
        BeanstalkPrice.Prices memory price = beanstalkPrice.price();
        assertGt(price.price, 0, "Price should be non-zero");

        // Get sorted tokens
        (uint8[] memory tokenIndices, uint256[] memory prices) = siloHelpers
            .getTokensAscendingPrice();

        // Verify arrays are not empty and have same length
        assertGt(tokenIndices.length, 0, "Should have at least one token");
        assertEq(tokenIndices.length, prices.length, "Arrays should have same length");

        // Verify arrays are sorted by price (ascending)
        for (uint256 i = 0; i < prices.length - 1; i++) {
            assertTrue(prices[i] <= prices[i + 1], "Prices should be sorted in ascending order");
        }

        // Verify indices correspond to whitelisted tokens
        address[] memory whitelistedTokens = bs.getWhitelistedTokens();
        assertEq(
            tokenIndices.length,
            whitelistedTokens.length,
            "Should return all whitelisted tokens"
        );

        // Verify prices are non-zero
        for (uint256 i = 0; i < prices.length; i++) {
            assertGt(prices[i], 0, "Prices should be non-zero");
        }
    }

    /**
     * @notice Helper function to setup Bean and LP token deposits for a user
     * @param user The address to setup deposits for
     */
    function setupUserDeposits(address user) internal {
        uint256 depositAmount = 1000e6;

        // Deposit Bean
        mintTokensToUser(user, BEAN, depositAmount);
        vm.prank(user);
        bs.deposit(BEAN, depositAmount, 0);

        // Add liquidity and deposit LP tokens
        mintTokensToUser(user, BEAN, depositAmount);
        vm.prank(user);
        MockToken(BEAN).approve(BEAN_ETH_WELL, depositAmount);
        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = depositAmount;
        tokenAmountsIn[1] = 0;
        vm.prank(user);
        uint256 lpAmountOut = IWell(BEAN_ETH_WELL).addLiquidity(
            tokenAmountsIn,
            0,
            user,
            type(uint256).max
        );
        vm.prank(user);
        MockToken(BEAN_ETH_WELL).approve(address(bs), lpAmountOut);
        vm.prank(user);
        bs.deposit(BEAN_ETH_WELL, lpAmountOut, 0);
    }

    function test_getSortedDeposits() public {
        // setup multiple deposits in different seasons
        uint256 depositAmount = 1000e6;
        uint256 numDeposits = 5;

        // Create deposits in different seasons
        for (uint256 i; i < numDeposits; i++) {
            mintTokensToUser(farmers[0], BEAN, depositAmount);
            vm.prank(farmers[0]);
            bs.deposit(BEAN, depositAmount, 0);
            bs.siloSunrise(0); // Move to next season to get different stems
        }

        // Get sorted deposits
        (int96[] memory stems, uint256[] memory amounts) = siloHelpers.getSortedDeposits(
            farmers[0],
            BEAN
        );

        // Verify we got the right number of deposits
        assertEq(stems.length, numDeposits, "Wrong number of deposits returned");
        assertEq(amounts.length, numDeposits, "Wrong number of amounts returned");

        // Verify stems are in descending order (highest/newest first)
        for (uint256 i = 1; i < stems.length; i++) {
            assertTrue(stems[i - 1] > stems[i], "Stems not in descending order");
        }

        // Verify amounts match actual deposits
        for (uint256 i; i < stems.length; i++) {
            (uint256 actualAmount, ) = bs.getDeposit(farmers[0], BEAN, stems[i]);
            assertEq(amounts[i], actualAmount, "Amount mismatch");
        }

        // Test with zero deposits
        address emptyUser = address(0x123);
        vm.expectRevert("No deposits");
        siloHelpers.getSortedDeposits(emptyUser, BEAN);
    }

    function test_forkGetSortedDeposits() public {
        (address testWallet, address PINTO_DIAMOND, address PINTO) = setupForkTest();

        // Get sorted deposits
        (int96[] memory stems, uint256[] memory amounts) = siloHelpers.getSortedDeposits(
            testWallet,
            PINTO
        );

        // Verify stems are in descending order (highest/newest first)
        for (uint256 i = 1; i < stems.length; i++) {
            assertTrue(stems[i - 1] > stems[i], "Stems not in descending order");
        }

        // Verify amounts match actual deposits
        for (uint256 i; i < stems.length; i++) {
            (uint256 actualAmount, ) = IMockFBeanstalk(PINTO_DIAMOND).getDeposit(
                testWallet,
                PINTO,
                stems[i]
            );
            assertEq(amounts[i], actualAmount, "Amount mismatch");
        }
    }

    function test_getTokenIndex() public {
        // Test Bean token returns 0
        uint8 beanIndex = siloHelpers.getTokenIndex(BEAN);
        assertEq(beanIndex, 0, "Bean token should have index 0");

        // Test BEAN-ETH Well token returns correct index
        uint8 beanEthIndex = siloHelpers.getTokenIndex(BEAN_ETH_WELL);
        assertGt(beanEthIndex, 0, "BEAN-ETH Well token should have non-zero index");

        // Test non-existent token reverts
        vm.expectRevert("Token not found");
        siloHelpers.getTokenIndex(address(0x123));

        // Verify indices match whitelisted tokens array
        address[] memory whitelistedTokens = bs.getWhitelistedTokens();
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            uint8 index = siloHelpers.getTokenIndex(whitelistedTokens[i]);
            assertEq(index, uint8(i), "Index should match position in whitelisted tokens array");
        }
    }

    function test_withdrawBeansStrategies() public {
        // Setup: Create deposits in both Bean and LP tokens with different prices and seeds
        uint256 beanAmount = 1000e6;

        // Deposit Beans
        mintTokensToUser(farmers[0], BEAN, beanAmount * 2);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, beanAmount, 0);

        // Deposit LP tokens in BEAN_ETH_WELL
        vm.prank(farmers[0]);
        MockToken(BEAN).approve(BEAN_ETH_WELL, beanAmount);

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = beanAmount;
        tokenAmountsIn[1] = 0;

        vm.prank(farmers[0]);
        uint256 lpAmountOut = IWell(BEAN_ETH_WELL).addLiquidity(
            tokenAmountsIn,
            0,
            farmers[0],
            type(uint256).max
        );

        vm.prank(farmers[0]);
        MockToken(BEAN_ETH_WELL).approve(address(bs), lpAmountOut);

        vm.prank(farmers[0]);
        bs.deposit(BEAN_ETH_WELL, lpAmountOut, 0);

        // Skip germination
        bs.siloSunrise(0);
        bs.siloSunrise(0);

        uint256 snapshot = vm.snapshot();

        // Test Case 1: Ascending Price Strategy
        uint256 withdrawAmount = 500e6;
        uint8[] memory strategyIndices = new uint8[](1);
        strategyIndices[0] = type(uint8).max;

        uint256 initialBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);

        // Setup and execute the blueprint with ascending price strategy
        IMockFBeanstalk.Requisition memory req = setupWithdrawBeansBlueprint(
            farmers[0],
            withdrawAmount,
            strategyIndices,
            MAX_GROWN_STALK_PER_BDV,
            LibTransfer.To.EXTERNAL
        );

        vm.prank(farmers[0]);
        bs.publishRequisition(req);

        executeRequisition(farmers[0], req, address(bs));

        assertGe(
            IERC20(BEAN).balanceOf(farmers[0]),
            initialBeanBalance + withdrawAmount,
            "Bean balance incorrect after price strategy withdrawal"
        );

        vm.revertTo(snapshot);
        snapshot = vm.snapshot();

        // Test Case 2: Ascending Seeds Strategy
        strategyIndices[0] = type(uint8).max - 1;
        initialBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);

        // Setup and execute the blueprint with ascending seeds strategy
        req = setupWithdrawBeansBlueprint(
            farmers[0],
            withdrawAmount,
            strategyIndices,
            MAX_GROWN_STALK_PER_BDV,
            LibTransfer.To.EXTERNAL
        );

        vm.prank(farmers[0]);
        bs.publishRequisition(req);

        executeRequisition(farmers[0], req, address(bs));

        assertGe(
            IERC20(BEAN).balanceOf(farmers[0]),
            initialBeanBalance + withdrawAmount,
            "Bean balance incorrect after seeds strategy withdrawal"
        );
    }

    // This test sets up 1000 pure bean deposits and 1000 bean in LP deposits,
    // Then withdraws 1900 beans in total, 1000 beans from pure bean and 900 beans from LP
    function test_getWithdrawalPlan() public {
        uint256 beanAmount = 1000e6;

        // Deposit Beans
        mintTokensToUser(farmers[0], BEAN, beanAmount * 2);

        // Deposit LP tokens in BEAN_ETH_WELL
        vm.prank(farmers[0]);
        MockToken(BEAN).approve(BEAN_ETH_WELL, beanAmount);

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = beanAmount;
        tokenAmountsIn[1] = 0;

        vm.prank(farmers[0]);
        uint256 lpAmountOut = IWell(BEAN_ETH_WELL).addLiquidity(
            tokenAmountsIn,
            0,
            farmers[0],
            type(uint256).max
        );

        vm.prank(farmers[0]);
        MockToken(BEAN_ETH_WELL).approve(address(bs), lpAmountOut);

        for (int i = 0; i < 4; i++) {
            vm.prank(farmers[0]);
            bs.deposit(BEAN_ETH_WELL, lpAmountOut / 4, 0);

            vm.prank(farmers[0]);
            bs.deposit(BEAN, beanAmount / 4, 0);

            bs.siloSunrise(0);
        }

        //  Withdraw all 1000 beans from pure-bean and 900 from LP
        uint256 withdrawalAmount = 1900e6;
        uint8[] memory strategyIndices = new uint8[](2);
        strategyIndices[0] = 0;
        strategyIndices[1] = 1;

        SiloHelpers.WithdrawalPlan memory plan = siloHelpers.getWithdrawalPlan(
            farmers[0],
            strategyIndices,
            withdrawalAmount,
            MAX_GROWN_STALK_PER_BDV
        );

        // totalAvailableBeans should be 1900e6
        assertEq(plan.totalAvailableBeans, withdrawalAmount, "Total available beans incorrect");

        // sourceTokens should be BEAN and BEAN_ETH_WELL
        assertEq(plan.sourceTokens.length, 2, "Wrong number of source tokens");
        assertEq(plan.sourceTokens[0], BEAN, "First source token should be BEAN");
        assertEq(
            plan.sourceTokens[1],
            BEAN_ETH_WELL,
            "Second source token should be BEAN_ETH_WELL"
        );

        // availableBeans should be 1000e6 and 900e6
        assertEq(plan.availableBeans[0], 1000e6, "First available beans should be 1000e6");
        assertEq(plan.availableBeans[1], 900e6, "Second available beans should be 900e6");

        // Stems length should be 4 for each token type
        assertEq(plan.stems[0].length, 4, "First token should have 4 stems");
        assertEq(plan.stems[1].length, 4, "Second token should have 4 stems");

        // Loop through and log source tokens, available beans, and total available beans
        /*for (uint256 i = 0; i < plan.sourceTokens.length; i++) {
            console.log("Source token:", plan.sourceTokens[i]);
            console.log("Available beans:", plan.availableBeans[i]);

            // loop through and Log stems and amounts
            for (uint256 j = 0; j < plan.stems[i].length; j++) {
                console.log("Stem:", plan.stems[i][j]);
                console.log("Amount:", plan.amounts[i][j]);
            }
        }
        console.log("Total available beans:", plan.totalAvailableBeans);*/
    }
}

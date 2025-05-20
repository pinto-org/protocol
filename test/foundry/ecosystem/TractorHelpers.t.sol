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
import {TractorHelpers} from "contracts/ecosystem/TractorHelpers.sol";
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
import {PriceManipulation} from "contracts/ecosystem/PriceManipulation.sol";
import {LibTractorHelpers} from "contracts/libraries/Silo/LibTractorHelpers.sol";

/**
 * @notice Tests the functionality of the Oracles.
 */
contract TractorHelpersTest is TractorHelper {
    address[] farmers;
    BeanstalkPrice beanstalkPrice;
    PriceManipulation priceManipulation;
    SiloHelpers siloHelpers;

    // Add constant for max grown stalk limit
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        farmers = createUsers(2);

        // Deploy BeanstalkPrice
        beanstalkPrice = new BeanstalkPrice(address(bs));
        vm.label(address(beanstalkPrice), "BeanstalkPrice");

        // Deploy PriceManipulation first
        priceManipulation = new PriceManipulation(address(bs));
        vm.label(address(priceManipulation), "PriceManipulation");

        // Deploy TractorHelpers with PriceManipulation address
        tractorHelpers = new TractorHelpers(
            address(bs),
            address(beanstalkPrice),
            address(this),
            address(priceManipulation)
        );
        vm.label(address(tractorHelpers), "TractorHelpers");

        // Deploy SiloHelpers
        siloHelpers = new SiloHelpers(address(bs), address(this));
        vm.label(address(siloHelpers), "SiloHelpers");

        // Deploy SowBlueprintv0 with TractorHelpers address
        sowBlueprintv0 = new SowBlueprintv0(address(bs), address(this), address(tractorHelpers));
        vm.label(address(sowBlueprintv0), "SowBlueprintv0");

        setTractorHelpers(address(tractorHelpers));
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
        (int96[] memory allStems, ) = tractorHelpers.getSortedDeposits(farmers[0], BEAN);

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

        // Create empty plan
        LibTractorHelpers.WithdrawalPlan memory emptyPlan;

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
                ) = tractorHelpers.getDepositStemsAndAmountsToWithdraw(
                        farmers[0],
                        BEAN,
                        testAmounts[i],
                        minStems[j],
                        emptyPlan
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
        (int96[] memory noStems, uint256[] memory noAmounts, uint256 noAvailable) = tractorHelpers
            .getDepositStemsAndAmountsToWithdraw(address(0x123), BEAN, 1000e6, 0, emptyPlan);
        assertEq(noStems.length, 0, "Should return empty stems array for non-existent account");
        assertEq(noAmounts.length, 0, "Should return empty amounts array for non-existent account");
        assertEq(noAvailable, 0, "Should return 0 available for non-existent account");
    }

    /**
     * @notice Helper function to setup fork test environment
     * @param blockOverride Optional block number to fork from (uses default if not specified)
     */
    function setupForkTest(
        uint256 blockOverride
    ) internal returns (address testWallet, address PINTO_DIAMOND, address PINTO) {
        testWallet = 0xFb94D3404c1d3D9D6F08f79e58041d5EA95AccfA;
        uint256 forkBlock = blockOverride > 0 ? blockOverride : 25040000; // Use override if provided
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock);

        PINTO_DIAMOND = address(0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f);
        PINTO = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;
        address BEANSTALK_PRICE = 0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E;

        // Deploy PriceManipulation first
        priceManipulation = new PriceManipulation(PINTO_DIAMOND);
        vm.label(address(priceManipulation), "PriceManipulation");

        // Deploy TractorHelpers with PriceManipulation address
        tractorHelpers = new TractorHelpers(
            PINTO_DIAMOND,
            BEANSTALK_PRICE,
            address(this),
            address(priceManipulation)
        );
        vm.label(address(tractorHelpers), "TractorHelpers");

        // Deploy SowBlueprintv0 with TractorHelpers address
        sowBlueprintv0 = new SowBlueprintv0(PINTO_DIAMOND, address(this), address(tractorHelpers));
        vm.label(address(sowBlueprintv0), "SowBlueprintv0");

        setTractorHelpers(address(tractorHelpers));
        setSowBlueprintv0(address(sowBlueprintv0));

        return (testWallet, PINTO_DIAMOND, PINTO);
    }

    /**
     * @notice Overload for setupForkTest without a block number (uses default)
     */
    function setupForkTest()
        internal
        returns (address testWallet, address PINTO_DIAMOND, address PINTO)
    {
        return setupForkTest(0); // 0 indicates to use the default block
    }

    /**
     * @notice Tests by forking Base with an example account and verifies the function does not revert
     */
    function test_forkGetDepositStemsAndAmountsToWithdraw() public {
        (address testWallet, , address PINTO) = setupForkTest();

        uint256 requestAmount = 50000e6;
        // uint256 gasBefore = gasleft();

        // Create empty plan
        LibTractorHelpers.WithdrawalPlan memory emptyPlan;

        // Get deposit stems and amounts to withdraw
        (int96[] memory stems, uint256[] memory amounts, uint256 availableAmount) = tractorHelpers
            .getDepositStemsAndAmountsToWithdraw(testWallet, PINTO, requestAmount, 0, emptyPlan);

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
            uint256 lpNeeded = tractorHelpers.getLPTokensToWithdrawForBeans(
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
        (int96[] memory allStems, uint256[] memory allAmounts) = tractorHelpers.getSortedDeposits(
            farmers[0],
            BEAN_ETH_WELL
        );

        uint256 initialBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);

        // Setup a setupWithdrawBeansBlueprint to withdraw the total amount of beans
        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = tractorHelpers.getTokenIndex(BEAN_ETH_WELL);
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

    function test_withdrawBeansHelperMultipleLPDepositsExcludeExistingPlan() public {
        // Setup: Create multiple LP deposits over various seasons, deposit amounts 100, then 200, then 300, etc
        uint256 numDeposits = 10;
        uint256 depositAmount = 100e6;
        uint256 totalBeansToWithdraw = 0;
        for (uint256 i = 1; i < numDeposits + 1; i++) {
            mintAndDepositBeanETH(farmers[0], depositAmount * i);
            totalBeansToWithdraw += depositAmount * i;
        }

        // Get all deposits to find grown stalk values
        (int96[] memory allStems, uint256[] memory allAmounts) = tractorHelpers.getSortedDeposits(
            farmers[0],
            BEAN_ETH_WELL
        );

        uint256 initialBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);

        // Setup a setupWithdrawBeansBlueprint to withdraw the total amount of beans
        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = tractorHelpers.getTokenIndex(BEAN_ETH_WELL);

        // Create empty plan
        LibTractorHelpers.WithdrawalPlan memory emptyPlan;

        // Get the plan that we would use to withdraw the total amount of beans
        LibTractorHelpers.WithdrawalPlan memory plan = tractorHelpers.getWithdrawalPlan(
            farmers[0],
            sourceTokenIndices,
            totalBeansToWithdraw,
            MAX_GROWN_STALK_PER_BDV
        );

        // Now exclude that plan from the withdrawal, and get another plan
        LibTractorHelpers.WithdrawalPlan memory newPlan = tractorHelpers
            .getWithdrawalPlanExcludingPlan(
                farmers[0],
                sourceTokenIndices,
                totalBeansToWithdraw,
                MAX_GROWN_STALK_PER_BDV,
                plan
            );

        // Combine the plans and verify the result
        LibTractorHelpers.WithdrawalPlan[]
            memory plansToCombine = new LibTractorHelpers.WithdrawalPlan[](2);
        plansToCombine[0] = plan;
        plansToCombine[1] = newPlan;
        LibTractorHelpers.WithdrawalPlan memory combinedPlan = tractorHelpers
            .combineWithdrawalPlans(plansToCombine);

        // Verify the combined plan
        assertEq(combinedPlan.sourceTokens.length, 1, "Should have one source token");
        assertEq(
            combinedPlan.sourceTokens[0],
            BEAN_ETH_WELL,
            "Source token should be BEAN_ETH_WELL"
        );

        // Verify stems and amounts are combined correctly for each source token
        for (uint256 i = 0; i < 1; i++) {
            // Add safety checks for array lengths
            require(combinedPlan.stems[i].length > 0, "Stems array is empty");
            require(combinedPlan.amounts[i].length > 0, "Amounts array is empty");
            assertEq(
                combinedPlan.stems[i].length,
                combinedPlan.amounts[i].length,
                "Stems and amounts should have same length"
            );

            // Verify each stem's amount in combined plan matches sum of amounts in individual plans
            for (uint256 j = 0; j < combinedPlan.stems[i].length; j++) {
                int96 stem = combinedPlan.stems[i][j];
                uint256 combinedAmount = combinedPlan.amounts[i][j];
                uint256 expectedAmount = 0;

                // Find matching token in Plan 1
                for (uint256 k = 0; k < plan.sourceTokens.length; k++) {
                    if (plan.sourceTokens[k] == combinedPlan.sourceTokens[i]) {
                        for (uint256 l = 0; l < plan.stems[k].length; l++) {
                            if (plan.stems[k][l] == stem) {
                                expectedAmount += plan.amounts[k][l];
                            }
                        }
                    }
                }

                // Find matching token in Plan 2
                for (uint256 k = 0; k < newPlan.sourceTokens.length; k++) {
                    if (newPlan.sourceTokens[k] == combinedPlan.sourceTokens[i]) {
                        for (uint256 l = 0; l < newPlan.stems[k].length; l++) {
                            if (newPlan.stems[k][l] == stem) {
                                expectedAmount += newPlan.amounts[k][l];
                            }
                        }
                    }
                }

                assertEq(
                    combinedAmount,
                    expectedAmount,
                    string(
                        abi.encodePacked(
                            "Amount mismatch for stem ",
                            uint256(int256(stem)),
                            " in token ",
                            uint256(uint160(combinedPlan.sourceTokens[i]))
                        )
                    )
                );
            }
        }

        // Verify total available beans matches sum of individual plans
        assertEq(
            combinedPlan.totalAvailableBeans,
            plan.totalAvailableBeans + newPlan.totalAvailableBeans,
            "Total available beans should match sum of individual plans"
        );

        // Verify available beans for the source token matches the sum of available beans from both plans
        assertEq(
            combinedPlan.availableBeans[0],
            plan.availableBeans[0] + newPlan.availableBeans[0],
            "Available beans should match sum of individual plans"
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
            sourceTokenIndices[0] = tractorHelpers.getTokenIndex(BEAN);

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

            executeRequisition(farmers[0], req, address(bs));

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
            uint256 expectedLPAmount = tractorHelpers.getLPTokensToWithdrawForBeans(
                withdrawAmount,
                BEAN_ETH_WELL
            );

            // Setup and execute the blueprint
            uint8[] memory sourceTokenIndices = new uint8[](1);
            sourceTokenIndices[0] = tractorHelpers.getTokenIndex(BEAN_ETH_WELL);
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
            sourceTokenIndices[0] = tractorHelpers.getTokenIndex(BEAN);

            // Create empty plan
            LibTractorHelpers.WithdrawalPlan memory emptyPlan;

            // Get withdrawal plan
            LibTractorHelpers.WithdrawalPlan memory plan = tractorHelpers.getWithdrawalPlan(
                farmers[0],
                sourceTokenIndices,
                withdrawAmount,
                MAX_GROWN_STALK_PER_BDV
            );

            vm.expectRevert("Silo: Crate balance too low."); // NOTE: this test will be updated with the plan change
            tractorHelpers.withdrawBeansFromSources(
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
            sourceTokenIndices[0] = tractorHelpers.getTokenIndex(BEAN);
            sourceTokenIndices[1] = tractorHelpers.getTokenIndex(BEAN_ETH_WELL);

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
        (address[] memory tokens, uint256[] memory seeds) = tractorHelpers
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
        (address highestSeedToken, uint256 seedAmount) = tractorHelpers.getHighestSeedToken();

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
        (address lowestSeedToken, uint256 seedAmount) = tractorHelpers.getLowestSeedToken();

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
        address[] memory initialTokens = tractorHelpers.getUserDepositedTokens(user);
        assertEq(initialTokens.length, 0, "User should have no deposits initially");

        // Setup deposits
        setupUserDeposits(user);

        // Get user's deposited tokens
        address[] memory depositedTokens = tractorHelpers.getUserDepositedTokens(user);

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
        (uint8[] memory tokenIndices, uint256[] memory seeds) = tractorHelpers
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
        (uint8[] memory tokenIndices, uint256[] memory prices) = tractorHelpers
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

    function test_getAscendingPriceSeedsWithDewhitelistedTokens() public {
        // Deploy and set up a BEAN-USDC well to ensure more diversity in prices
        // Use the existing constant from Utils.sol
        deployExtraWells(true, true);

        addLiquidityToWell(
            BEAN_USDC_WELL,
            10_000e6, // 10,000 Beans
            10_000e6 // 10,000 USDC
        );

        whitelistLPWell(BEAN_USDC_WELL, USDC_USD_CHAINLINK_PRICE_AGGREGATOR);

        address beanstalkOwner = bs.owner();

        // Create a snapshot before any state changes
        // Create a snapshot before any state changes
        uint256 snapshot = vm.snapshot();

        // Verify we have at least 3 whitelisted wells before dewhitelisting
        address[] memory whitelistedWellsBefore = bs.getWhitelistedWellLpTokens();
        assertGe(
            whitelistedWellsBefore.length,
            3,
            "Need at least 3 whitelisted wells for this test"
        );

        // Use BEAN_ETH_WELL as the token to dewhitelist
        address tokenToDewhitelist = BEAN_ETH_WELL;

        {
            // Before dewhitelisting, get price and seed ordered tokens
            (uint8[] memory priceOrderedTokensBefore, ) = tractorHelpers.getTokensAscendingPrice();
            (uint8[] memory seedOrderedTokensBefore, ) = tractorHelpers.getTokensAscendingSeeds();

            // Get the token addresses for easier debugging
            address[] memory tokenAddresses = tractorHelpers.getWhitelistStatusAddresses();

            // Verify the arrays have the expected length
            assertEq(
                priceOrderedTokensBefore.length,
                bs.getWhitelistedTokens().length,
                "Price ordered tokens should match whitelisted token count before dewhitelisting"
            );

            assertEq(
                seedOrderedTokensBefore.length,
                bs.getWhitelistedTokens().length,
                "Seed ordered tokens should match whitelisted token count before dewhitelisting"
            );

            // Require that the order of both is 2, 0, 1, 3
            assertEq(priceOrderedTokensBefore[0], 2);
            assertEq(priceOrderedTokensBefore[1], 0);
            assertEq(priceOrderedTokensBefore[2], 1);
            assertEq(priceOrderedTokensBefore[3], 3);
        }

        // Dewhitelist the token
        vm.stopPrank();
        vm.prank(beanstalkOwner);
        bs.dewhitelistToken(tokenToDewhitelist);
        vm.startPrank(address(this));

        {
            // After dewhitelisting, get price and seed ordered tokens
            (uint8[] memory priceOrderedTokensAfter, ) = tractorHelpers.getTokensAscendingPrice();
            (uint8[] memory seedOrderedTokensAfter, ) = tractorHelpers.getTokensAscendingSeeds();

            // Get only the whitelisted token addresses (excluding dewhitelisted tokens)
            address[] memory whitelistedTokenAddresses = bs.getWhitelistedTokens();
            address[] memory allTokenAddresses = tractorHelpers.getWhitelistStatusAddresses();

            // Check lengths match
            assertEq(
                priceOrderedTokensAfter.length,
                whitelistedTokenAddresses.length,
                "Price ordered tokens should match whitelisted token count"
            );

            assertEq(
                seedOrderedTokensAfter.length,
                whitelistedTokenAddresses.length,
                "Seed ordered tokens should match whitelisted token count"
            );

            // Verify the dewhitelisted token is not in the whitelisted addresses
            for (uint256 i = 0; i < whitelistedTokenAddresses.length; i++) {
                assertNotEq(
                    whitelistedTokenAddresses[i],
                    tokenToDewhitelist,
                    "Dewhitelisted token should not be in whitelisted tokens list"
                );
            }

            // Verify all tokens in the price array are in the whitelisted addresses
            for (uint256 i = 0; i < priceOrderedTokensAfter.length; i++) {
                uint8 index = priceOrderedTokensAfter[i];
                address token = allTokenAddresses[index];

                bool found = false;
                for (uint256 j = 0; j < whitelistedTokenAddresses.length; j++) {
                    if (whitelistedTokenAddresses[j] == token) {
                        found = true;
                        break;
                    }
                }
                assertTrue(found, "Token in price array not found in whitelisted tokens");
            }

            // Verify all tokens in the seed array are in the whitelisted addresses
            for (uint256 i = 0; i < seedOrderedTokensAfter.length; i++) {
                uint8 index = seedOrderedTokensAfter[i];
                address token = allTokenAddresses[index];

                bool found = false;
                for (uint256 j = 0; j < whitelistedTokenAddresses.length; j++) {
                    if (whitelistedTokenAddresses[j] == token) {
                        found = true;
                        break;
                    }
                }
                assertTrue(found, "Token in seed array not found in whitelisted tokens");
            }

            // Require that the order after is 2, 0, 3 (1 got removed)
            assertEq(priceOrderedTokensAfter[0], 2);
            assertEq(priceOrderedTokensAfter[1], 0);
            assertEq(priceOrderedTokensAfter[2], 3);
        }

        // Restore the state to before any dewhitelisting occurred
        vm.revertTo(snapshot);
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
        (int96[] memory stems, uint256[] memory amounts) = tractorHelpers.getSortedDeposits(
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
        tractorHelpers.getSortedDeposits(emptyUser, BEAN);
    }

    function test_forkGetSortedDeposits() public {
        (address testWallet, address PINTO_DIAMOND, address PINTO) = setupForkTest();

        // Get sorted deposits
        (int96[] memory stems, uint256[] memory amounts) = tractorHelpers.getSortedDeposits(
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
        uint8 beanIndex = tractorHelpers.getTokenIndex(BEAN);
        assertEq(beanIndex, 0, "Bean token should have index 0");

        // Test BEAN-ETH Well token returns correct index
        uint8 beanEthIndex = tractorHelpers.getTokenIndex(BEAN_ETH_WELL);
        assertGt(beanEthIndex, 0, "BEAN-ETH Well token should have non-zero index");

        // Test non-existent token reverts
        vm.expectRevert("Token not found");
        tractorHelpers.getTokenIndex(address(0x123));

        // Verify indices match whitelisted tokens array
        address[] memory whitelistedTokens = bs.getWhitelistedTokens();
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            uint8 index = tractorHelpers.getTokenIndex(whitelistedTokens[i]);
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

        // Create empty plan
        LibTractorHelpers.WithdrawalPlan memory emptyPlan;

        LibTractorHelpers.WithdrawalPlan memory plan = tractorHelpers.getWithdrawalPlan(
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

    function test_withdrawBeansHelperMultipleTokensExcludeExistingPlan() public {
        // Setup: Create deposits in both Bean and LP tokens
        uint256 beanAmount = 1000e6;
        uint256 numDeposits = 5;

        // Deposit Beans
        mintTokensToUser(farmers[0], BEAN, beanAmount * 2);
        for (uint256 i = 0; i < numDeposits; i++) {
            vm.prank(farmers[0]);
            bs.deposit(BEAN, beanAmount / numDeposits, 0);
            bs.siloSunrise(0);
        }

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
        for (uint256 i = 0; i < numDeposits; i++) {
            vm.prank(farmers[0]);
            bs.deposit(BEAN_ETH_WELL, lpAmountOut / numDeposits, 0);
            bs.siloSunrise(0);
        }

        // Deposit LP tokens in BEAN_WSTETH_WELL
        mintTokensToUser(farmers[0], BEAN, beanAmount * 2); // Mint more beans for WSTETH well
        vm.prank(farmers[0]);
        MockToken(BEAN).approve(BEAN_WSTETH_WELL, beanAmount);
        vm.prank(farmers[0]);
        lpAmountOut = IWell(BEAN_WSTETH_WELL).addLiquidity(
            tokenAmountsIn,
            0,
            farmers[0],
            type(uint256).max
        );
        vm.prank(farmers[0]);
        MockToken(BEAN_WSTETH_WELL).approve(address(bs), lpAmountOut);
        for (uint256 i = 0; i < numDeposits; i++) {
            vm.prank(farmers[0]);
            bs.deposit(BEAN_WSTETH_WELL, lpAmountOut / numDeposits, 0);
            bs.siloSunrise(0);
        }

        uint256 initialBeanBalance = IERC20(BEAN).balanceOf(farmers[0]);

        // Setup withdrawal with multiple source tokens
        uint8[] memory sourceTokenIndices = new uint8[](3);
        sourceTokenIndices[0] = tractorHelpers.getTokenIndex(BEAN);
        sourceTokenIndices[1] = tractorHelpers.getTokenIndex(BEAN_ETH_WELL);
        sourceTokenIndices[2] = tractorHelpers.getTokenIndex(BEAN_WSTETH_WELL);

        // Create empty plan
        LibTractorHelpers.WithdrawalPlan memory emptyPlan;

        // Get the first plan for a smaller amount
        LibTractorHelpers.WithdrawalPlan memory plan = tractorHelpers.getWithdrawalPlan(
            farmers[0],
            sourceTokenIndices,
            (beanAmount * 1.2e6) / 1e6,
            MAX_GROWN_STALK_PER_BDV
        );

        // Get the second plan excluding the first plan
        LibTractorHelpers.WithdrawalPlan memory newPlan = tractorHelpers
            .getWithdrawalPlanExcludingPlan(
                farmers[0],
                sourceTokenIndices,
                (beanAmount * 1.2e6) / 1e6,
                MAX_GROWN_STALK_PER_BDV,
                plan
            );

        // Combine the plans and verify the result
        LibTractorHelpers.WithdrawalPlan[]
            memory plansToCombine = new LibTractorHelpers.WithdrawalPlan[](2);
        plansToCombine[0] = plan;
        plansToCombine[1] = newPlan;
        LibTractorHelpers.WithdrawalPlan memory combinedPlan = tractorHelpers
            .combineWithdrawalPlans(plansToCombine);

        // Verify the combined plan has all source tokens
        assertEq(combinedPlan.sourceTokens.length, 3, "Should have three source tokens");
        assertEq(combinedPlan.sourceTokens[0], BEAN, "First source token should be BEAN");
        assertEq(
            combinedPlan.sourceTokens[1],
            BEAN_ETH_WELL,
            "Second source token should be BEAN_ETH_WELL"
        );
        assertEq(
            combinedPlan.sourceTokens[2],
            BEAN_WSTETH_WELL,
            "Third source token should be BEAN_WSTETH_WELL"
        );

        // Verify stems and amounts are combined correctly for each source token
        for (uint256 i = 0; i < 3; i++) {
            // Add safety checks for array lengths
            require(combinedPlan.stems[i].length > 0, "Stems array is empty");
            require(combinedPlan.amounts[i].length > 0, "Amounts array is empty");
            assertEq(
                combinedPlan.stems[i].length,
                combinedPlan.amounts[i].length,
                "Stems and amounts should have same length"
            );

            // Verify each stem's amount in combined plan matches sum of amounts in individual plans
            for (uint256 j = 0; j < combinedPlan.stems[i].length; j++) {
                int96 stem = combinedPlan.stems[i][j];
                uint256 combinedAmount = combinedPlan.amounts[i][j];
                uint256 expectedAmount = 0;

                // Find matching token in Plan 1
                for (uint256 k = 0; k < plan.sourceTokens.length; k++) {
                    if (plan.sourceTokens[k] == combinedPlan.sourceTokens[i]) {
                        for (uint256 l = 0; l < plan.stems[k].length; l++) {
                            if (plan.stems[k][l] == stem) {
                                expectedAmount += plan.amounts[k][l];
                            }
                        }
                    }
                }

                // Find matching token in Plan 2
                for (uint256 k = 0; k < newPlan.sourceTokens.length; k++) {
                    if (newPlan.sourceTokens[k] == combinedPlan.sourceTokens[i]) {
                        for (uint256 l = 0; l < newPlan.stems[k].length; l++) {
                            if (newPlan.stems[k][l] == stem) {
                                expectedAmount += newPlan.amounts[k][l];
                            }
                        }
                    }
                }

                assertEq(
                    combinedAmount,
                    expectedAmount,
                    string(
                        abi.encodePacked(
                            "Amount mismatch for stem ",
                            uint256(int256(stem)),
                            " in token ",
                            uint256(uint160(combinedPlan.sourceTokens[i]))
                        )
                    )
                );
            }
        }

        // Verify total available beans matches sum of individual plans
        assertEq(
            combinedPlan.totalAvailableBeans,
            plan.totalAvailableBeans + newPlan.totalAvailableBeans,
            "Total available beans should match sum of individual plans"
        );

        // Verify available beans for each source token matches the sum from both plans
        for (uint256 i = 0; i < 3; i++) {
            // Find the corresponding indices in the individual plans
            uint256 planIndex = 0;
            uint256 newPlanIndex = 0;
            bool foundInPlan1 = false;
            bool foundInPlan2 = false;

            // Find matching token in Plan 1
            for (uint256 j = 0; j < plan.sourceTokens.length; j++) {
                if (plan.sourceTokens[j] == combinedPlan.sourceTokens[i]) {
                    planIndex = j;
                    foundInPlan1 = true;
                    break;
                }
            }

            // Find matching token in Plan 2
            for (uint256 j = 0; j < newPlan.sourceTokens.length; j++) {
                if (newPlan.sourceTokens[j] == combinedPlan.sourceTokens[i]) {
                    newPlanIndex = j;
                    foundInPlan2 = true;
                    break;
                }
            }

            // Only sum available beans if we found the token in both plans
            uint256 expectedSum = 0;
            if (foundInPlan1) {
                expectedSum += plan.availableBeans[planIndex];
            }
            if (foundInPlan2) {
                expectedSum += newPlan.availableBeans[newPlanIndex];
            }

            assertEq(
                combinedPlan.availableBeans[i],
                expectedSum,
                string(
                    abi.encodePacked(
                        "Available beans mismatch for token ",
                        combinedPlan.sourceTokens[i]
                    )
                )
            );
        }
    }

    function test_withdrawBeansWithWellSync() public {
        // Setup: Create deposits in both Bean and LP tokens
        uint256 beanAmount = 1000e6;

        // Deposit Beans - mint double the amount needed to have enough for deposit and LP creation
        mintTokensToUser(farmers[0], BEAN, beanAmount * 2);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, beanAmount, 0);

        // Approve spending Bean to well
        vm.prank(farmers[0]);
        MockToken(BEAN).approve(BEAN_ETH_WELL, beanAmount);

        // Add liquidity to well
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

        // Approve spending LP tokens to Beanstalk
        vm.prank(farmers[0]);
        MockToken(BEAN_ETH_WELL).approve(address(bs), lpAmountOut);

        // Deposit LP tokens
        vm.prank(farmers[0]);
        bs.deposit(BEAN_ETH_WELL, lpAmountOut, 0);

        // Skip germination
        bs.siloSunrise(0);
        bs.siloSunrise(0);

        // Send a small amount of extra tokens directly to the well to trigger sync
        // Using a much smaller amount to avoid triggering price manipulation detection
        uint256 extraBeanAmount = 50e6;
        mintTokensToUser(address(this), BEAN, extraBeanAmount);
        MockToken(BEAN).transfer(BEAN_ETH_WELL, extraBeanAmount);

        // Advance a few blocks to allow oracle to update
        vm.roll(block.number + 5);

        // Set up withdrawal
        uint256 withdrawAmount = 100e6;
        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = tractorHelpers.getTokenIndex(BEAN_ETH_WELL);

        // Create a tractor blueprint instead of calling directly
        IMockFBeanstalk.Requisition memory req = setupWithdrawBeansBlueprint(
            farmers[0],
            withdrawAmount,
            sourceTokenIndices,
            MAX_GROWN_STALK_PER_BDV,
            LibTransfer.To.EXTERNAL
        );

        // Check bean balance before the withdrawal
        uint256 farmerBeanBalanceBefore = IERC20(BEAN).balanceOf(farmers[0]);

        // Check specifically for the Transfer event from address(0) (minting) to Beanstalk during sync
        // We only care about the from and to addresses, not the exact value
        vm.expectEmit(true, true, false, false);
        emit IERC20.Transfer(address(0), address(bs), 0);

        // Execute the requisition through the tractor system
        executeRequisition(farmers[0], req, address(bs));

        // Check bean balance after the withdrawal
        uint256 farmerBeanBalanceAfter = IERC20(BEAN).balanceOf(farmers[0]);
        uint256 amountWithdrawn = farmerBeanBalanceAfter - farmerBeanBalanceBefore;

        // Verify withdrawal was successful
        assertEq(amountWithdrawn, withdrawAmount, "Incorrect amount withdrawn");
    }

    function test_sortDepositsWithEmptyDeposits() public {
        // Test with address that has no deposits
        address emptyUser = address(0x123);
        vm.prank(emptyUser);
        address[] memory result = siloHelpers.sortDeposits(emptyUser);

        // Verify empty array is returned
        assertEq(result.length, 0, "Should return empty array for user with no deposits");
    }

    /**
     * @notice Tests the sortDeposits function on a mainnet fork with a real user's deposits
     */
    function test_forkSortDeposits() public {
        // Set up the fork and get test wallet and contract addresses with a newer block
        uint256 newBlockNumber = 29413000; // Newer block to test with
        (address testWallet, address PINTO_DIAMOND, address PINTO) = setupForkTest(newBlockNumber);

        // Deploy SiloHelpers specifically for this test
        SiloHelpers forkSiloHelpers = new SiloHelpers(PINTO_DIAMOND, address(this));
        vm.label(address(forkSiloHelpers), "ForkSiloHelpers");

        // Get the tokens that the user has deposits for
        address[] memory depositedTokens = forkSiloHelpers.getUserDepositedTokens(testWallet);

        // Skip the test if the user has no deposits
        if (depositedTokens.length == 0) {
            return;
        }

        // For each token, get the deposit IDs before sorting
        uint256[][] memory originalDepositIds = new uint256[][](depositedTokens.length);
        bool needsSorting = false;

        for (uint256 i = 0; i < depositedTokens.length; i++) {
            originalDepositIds[i] = IMockFBeanstalk(PINTO_DIAMOND).getTokenDepositIdsForAccount(
                testWallet,
                depositedTokens[i]
            );

            // console.log("Token", i, "has", originalDepositIds[i].length, "deposits");

            // Check if deposits are already sorted
            bool alreadySorted = true;
            for (uint256 j = 1; j < originalDepositIds[i].length; j++) {
                (, int96 stem1) = forkSiloHelpers.getAddressAndStem(originalDepositIds[i][j - 1]);
                (, int96 stem2) = forkSiloHelpers.getAddressAndStem(originalDepositIds[i][j]);

                if (stem1 > stem2) {
                    alreadySorted = false;
                    needsSorting = true;
                    break;
                }
            }
        }

        // Call sortDeposits
        vm.prank(testWallet);
        address[] memory updatedTokens = forkSiloHelpers.sortDeposits(testWallet);

        // Verify the returned array matches what we expect
        assertEq(
            updatedTokens.length,
            depositedTokens.length,
            "Should return all tokens that had deposits"
        );

        // For each token, get the deposit IDs after sorting and verify they're properly sorted
        for (uint256 i = 0; i < depositedTokens.length; i++) {
            uint256[] memory sortedDepositIds = IMockFBeanstalk(PINTO_DIAMOND)
                .getTokenDepositIdsForAccount(testWallet, depositedTokens[i]);

            // Verify sorted arrays have the same length as original
            assertEq(
                sortedDepositIds.length,
                originalDepositIds[i].length,
                "Sorted deposit IDs should have same length as original"
            );

            // Verify sorted in ascending order by stem
            for (uint256 j = 1; j < sortedDepositIds.length; j++) {
                (, int96 prevStem) = forkSiloHelpers.getAddressAndStem(sortedDepositIds[j - 1]);
                (, int96 currStem) = forkSiloHelpers.getAddressAndStem(sortedDepositIds[j]);

                assertTrue(prevStem < currStem, "Deposit IDs not properly sorted by stem");
            }

            // Verify all original deposit IDs are present in the sorted array
            for (uint256 j = 0; j < originalDepositIds[i].length; j++) {
                bool found = false;
                for (uint256 k = 0; k < sortedDepositIds.length; k++) {
                    if (originalDepositIds[i][j] == sortedDepositIds[k]) {
                        found = true;
                        break;
                    }
                }
                assertTrue(found, "Original deposit ID not found in sorted array");
            }
        }
    }
}

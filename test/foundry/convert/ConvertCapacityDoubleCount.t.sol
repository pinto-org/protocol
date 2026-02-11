// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {MockPump} from "contracts/mocks/well/MockPump.sol";
import {IWell, Call} from "contracts/interfaces/basin/IWell.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {MockPipelineConvertFacet, AdvancedPipeCall} from "contracts/mocks/mockFacets/MockPipelineConvertFacet.sol";
import "forge-std/Test.sol";

/**
 * @title ConvertCapacityDoubleCountTest
 * @notice Test that convert capacity is not double-counted when multiple converts occur in the same block.
 * @dev This test verifies the fix for the bug where calculateConvertCapacityPenalty() returned
 * cumulative values that applyStalkPenalty() added to storage again, causing double-counting.
 */
contract ConvertCapacityDoubleCountTest is TestHelper {
    using LibRedundantMath256 for uint256;

    MockPipelineConvertFacet pipelineConvert = MockPipelineConvertFacet(BEANSTALK);
    address beanEthWell = BEAN_ETH_WELL;

    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // Initialize farmers
        farmers.push(users[1]);
        farmers.push(users[2]);
        farmers.push(users[3]);

        // Add initial liquidity to bean eth well
        vm.prank(users[0]);
        addLiquidityToWell(
            beanEthWell,
            10_000e6, // 10,000 bean
            10 ether // 10 WETH
        );

        // Mint beans to farmers
        mintTokensToUsers(farmers, BEAN, MAX_DEPOSIT_BOUND);
    }

    /**
     * @notice Test that sequential converts in the same block consume capacity linearly.
     * @dev Before the fix, the second convert would consume more capacity than the first
     * due to double-counting (storage = old + (old + delta) instead of storage = old + delta).
     *
     * Example with bug:
     * - 1st convert of 50: storage = 0 + (0 + 50) = 50 ✓
     * - 2nd convert of 50: storage = 50 + (50 + 50) = 150 ✗ (should be 100)
     *
     * After fix, both should consume equal capacity for equal amounts.
     */
    function test_sameBlockMultipleConverts_capacityNotDoubleCount() public {
        vm.pauseGasMetering();

        uint256 convertAmount = 500e6; // 500 beans per convert

        // Set deltaB high enough to allow multiple converts without hitting capacity
        setDeltaBforWell(5000e6, beanEthWell, WETH);

        // Deposit beans for all farmers and pass germination
        int96 stem1 = depositBeanAndPassGermination(convertAmount, farmers[0]);
        int96 stem2 = depositBeanAndPassGermination(convertAmount, farmers[1]);
        int96 stem3 = depositBeanAndPassGermination(convertAmount, farmers[2]);

        // Get initial capacity
        uint256 initialCapacity = bs.getOverallConvertCapacity();
        assertGt(initialCapacity, 0, "Initial capacity should be > 0");

        // Perform first convert
        beanToLPDoConvert(convertAmount, stem1, farmers[0]);
        uint256 capacityAfter1 = bs.getOverallConvertCapacity();
        uint256 usedByConvert1 = initialCapacity - capacityAfter1;

        // Perform second convert in same block
        beanToLPDoConvert(convertAmount, stem2, farmers[1]);
        uint256 capacityAfter2 = bs.getOverallConvertCapacity();
        uint256 usedByConvert2 = capacityAfter1 - capacityAfter2;

        // Perform third convert in same block
        beanToLPDoConvert(convertAmount, stem3, farmers[2]);
        uint256 capacityAfter3 = bs.getOverallConvertCapacity();
        uint256 usedByConvert3 = capacityAfter2 - capacityAfter3;

        vm.resumeGasMetering();

        // Log capacity usage for comparison with fork test
        console.log("Capacity used by convert 1:", usedByConvert1);
        console.log("Capacity used by convert 2:", usedByConvert2);
        console.log("Capacity used by convert 3:", usedByConvert3);
        if (usedByConvert1 > 0) {
            console.log("Ratio (convert2/convert1):", (usedByConvert2 * 100) / usedByConvert1, "%");
            console.log("Ratio (convert3/convert1):", (usedByConvert3 * 100) / usedByConvert1, "%");
        }

        // Assert: All three converts should use approximately the same capacity
        // Allow 15% tolerance for slippage from BDV calculations as pool reserves change
        // Before the fix, the ratio would be 2x or more due to double-counting
        assertApproxEqRel(
            usedByConvert1, usedByConvert2, 0.15e18, "Convert 1 and 2 should use approximately equal capacity"
        );
        assertApproxEqRel(
            usedByConvert2, usedByConvert3, 0.15e18, "Convert 2 and 3 should use approximately equal capacity"
        );

        // Also verify total capacity used is approximately 3x the first convert
        // Before the fix: total would be 50 + 150 + 350 = 550 instead of 150
        uint256 totalUsed = initialCapacity - capacityAfter3;
        assertApproxEqRel(
            totalUsed,
            usedByConvert1 * 3,
            0.2e18,
            "Total capacity used should be ~3x single convert (not exponentially increasing)"
        );
    }

    /**
     * @notice Test per-well capacity is not double-counted for sequential converts.
     */
    function test_sameBlockMultipleConverts_perWellCapacityNotDoubleCount() public {
        vm.pauseGasMetering();

        uint256 convertAmount = 500e6;

        // Set deltaB high enough
        setDeltaBforWell(5000e6, beanEthWell, WETH);

        // Deposit beans for farmers
        int96 stem1 = depositBeanAndPassGermination(convertAmount, farmers[0]);
        int96 stem2 = depositBeanAndPassGermination(convertAmount, farmers[1]);

        // Get initial per-well capacity
        uint256 initialWellCapacity = bs.getWellConvertCapacity(beanEthWell);
        assertGt(initialWellCapacity, 0, "Initial well capacity should be > 0");

        // Perform first convert
        beanToLPDoConvert(convertAmount, stem1, farmers[0]);
        uint256 wellCapacityAfter1 = bs.getWellConvertCapacity(beanEthWell);
        uint256 wellUsedByConvert1 = initialWellCapacity - wellCapacityAfter1;

        // Perform second convert in same block
        beanToLPDoConvert(convertAmount, stem2, farmers[1]);
        uint256 wellCapacityAfter2 = bs.getWellConvertCapacity(beanEthWell);
        uint256 wellUsedByConvert2 = wellCapacityAfter1 - wellCapacityAfter2;

        vm.resumeGasMetering();

        // Assert: Both converts should use approximately the same per-well capacity
        assertApproxEqRel(
            wellUsedByConvert1, wellUsedByConvert2, 0.05e18, "Per-well capacity should be consumed linearly"
        );
    }

    // Helper functions

    function depositBeanAndPassGermination(uint256 amount, address user) internal returns (int96 stem) {
        vm.pauseGasMetering();
        bean.mint(user, amount);

        address[] memory userArr = new address[](1);
        userArr[0] = user;

        (amount, stem) = setUpSiloDepositTest(amount, userArr);

        passGermination();
    }

    function beanToLPDoConvert(uint256 amount, int96 stem, address user)
        internal
        returns (int96 outputStem, uint256 outputAmount)
    {
        int96[] memory stems = new int96[](1);
        stems[0] = stem;

        AdvancedPipeCall[] memory beanToLPPipeCalls = createBeanToLPPipeCalls(amount, new AdvancedPipeCall[](0));

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.resumeGasMetering();
        vm.prank(user);
        (outputStem, outputAmount,,,) =
            pipelineConvert.pipelineConvert(BEAN, stems, amounts, beanEthWell, beanToLPPipeCalls);
    }

    function createBeanToLPPipeCalls(uint256 beanAmount, AdvancedPipeCall[] memory extraPipeCalls)
        internal
        view
        returns (AdvancedPipeCall[] memory pipeCalls)
    {
        pipeCalls = new AdvancedPipeCall[](2 + extraPipeCalls.length);

        bytes memory approveWell = abi.encodeWithSelector(IERC20.approve.selector, beanEthWell, beanAmount);
        pipeCalls[0] = AdvancedPipeCall(BEAN, approveWell, abi.encode(0));

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = beanAmount;
        tokenAmountsIn[1] = 0;

        bytes memory addBeans = abi.encodeWithSelector(
            IWell(beanEthWell).addLiquidity.selector, tokenAmountsIn, 0, PIPELINE, type(uint256).max
        );
        pipeCalls[1] = AdvancedPipeCall(beanEthWell, addBeans, abi.encode(0));

        for (uint256 i = 0; i < extraPipeCalls.length; i++) {
            pipeCalls[2 + i] = extraPipeCalls[i];
        }
    }
}

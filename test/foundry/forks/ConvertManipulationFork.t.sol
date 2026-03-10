// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import "forge-std/console.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWell} from "contracts/interfaces/basin/IWell.sol";

/**
 * @title ConvertManipulationFork
 * @notice Tests that convert penalty calculations resist spot oracle manipulation attacks
 *
 * @dev Attack Vector:
 * An attacker could attempt to preserve more grown stalk during converts by:
 * 1. Flash loan assets to manipulate spot price (push toward peg)
 * 2. Execute pipelineConvert while spot oracle shows favorable deltaB
 * 3. Reverse the manipulation, paying only swap fees
 *
 * The Shadow DeltaB mechanism should prevent this by using time-weighted values
 * instead of instantaneous spot prices for penalty calculations.
 *
 * This test verifies that flash loan manipulation does not provide
 * advantage in preserving grown stalk during Bean -> LP converts.
 */
contract ConvertManipulationFork is TestHelper {
    // Base Mainnet Well addresses
    address constant PINTO_USDC_WELL = 0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1;
    address constant PINTO_CBETH_WELL = 0x3e111115A82dF6190e36ADf0d552880663A4dBF1;

    // Base Mainnet token addresses
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;

    // Pipeline address for convert operations
    address constant BASE_PIPELINE = 0xb1bE0001f5a373b69b1E132b420e6D9687155e80;

    address user;

    function setUp() public {
        uint256 forkBlock = 40729500;
        forkMainnetAndUpgradeAllFacets(
            forkBlock,
            vm.envString("BASE_RPC"),
            PINTO,
            "",
            new bytes(0)
        );
        bs = IMockFBeanstalk(PINTO);
        updateOracleTimeouts(L2_PINTO, false);

        user = makeAddr("user");
    }

    /**
     * @notice Verifies that spot oracle manipulation does not provide advantage
     *
     * Test methodology:
     * 1. Create a Pinto deposit with accumulated grown stalk
     * 2. Measure grown stalk preserved after normal convert (no manipulation)
     * 3. Measure grown stalk preserved after manipulated convert (spot pushed above peg)
     * 4. Assert manipulation does not preserve more grown stalk
     *
     * The manipulation simulates a flash loan attack where an attacker swaps
     * large amounts into Pinto across multiple wells to push spot price above peg,
     * executes a convert, then reverses the swaps.
     */
    function test_forkBase_spotManipulationResistance() public {
        uint256 depositAmount = 1000e6;

        int96 stem = _depositAndAccumulateGrownStalk(depositAmount);
        uint256 initialGrownStalk = bs.grownStalkForDeposit(user, L2_PINTO, stem);
        require(initialGrownStalk > 0, "Should have grown stalk");

        console.log("=== SPOT ORACLE MANIPULATION RESISTANCE TEST ===");
        console.log("Initial deltaB:", _formatSigned(bs.overallCurrentDeltaB()));
        console.log("Grown stalk before convert:", initialGrownStalk);

        uint256 snapshotId = vm.snapshot();

        // Execute convert without manipulation (baseline)
        (, uint256 grownStalkNormal) = _executeConvert(
            user,
            L2_PINTO,
            stem,
            depositAmount,
            PINTO_USDC_WELL
        );
        console.log("Grown stalk after normal convert:", grownStalkNormal);

        vm.revertTo(snapshotId);

        // Simulate flash loan manipulation: swap into Pinto to push spot above peg
        _manipulateSpotPrice();

        console.log("DeltaB after manipulation:", _formatSigned(bs.overallCurrentDeltaB()));

        // Execute convert with manipulated spot price
        (, uint256 grownStalkManipulated) = _executeConvert(
            user,
            L2_PINTO,
            stem,
            depositAmount,
            PINTO_USDC_WELL
        );
        console.log("Grown stalk after manipulated convert:", grownStalkManipulated);

        // Verify manipulation does not provide any advantage
        console.log("");
        console.log("=== RESULTS ===");
        console.log("Grown stalk (normal):     ", grownStalkNormal);
        console.log("Grown stalk (manipulated):", grownStalkManipulated);

        assertLe(
            grownStalkManipulated,
            grownStalkNormal,
            "Manipulation should not preserve more grown stalk"
        );
        console.log("=== TEST PASSED ===");
    }

    /**
     * @notice Deposits Pinto and advances seasons to accumulate grown stalk
     * @param amount Amount of Pinto to deposit
     * @return stem The stem of the created deposit
     */
    function _depositAndAccumulateGrownStalk(uint256 amount) internal returns (int96 stem) {
        deal(L2_PINTO, user, amount);

        vm.startPrank(user);
        IERC20(L2_PINTO).approve(address(bs), amount);
        (, , stem) = bs.deposit(L2_PINTO, amount, uint8(LibTransfer.From.EXTERNAL));
        vm.stopPrank();

        bs.farmSunrises(100);
    }

    /**
     * @notice Simulates flash loan manipulation by swapping into Pinto on multiple wells
     * @dev Pushes spot deltaB from negative (below peg) to positive (above peg)
     */
    function _manipulateSpotPrice() internal {
        uint256 usdcAmount = 1_000_000e6;
        uint256 cbethAmount = 300 ether;

        deal(BASE_USDC, user, usdcAmount);
        deal(BASE_CBETH, user, cbethAmount);

        vm.startPrank(user);

        IERC20(BASE_USDC).approve(PINTO_USDC_WELL, usdcAmount);
        IWell(PINTO_USDC_WELL).swapFrom(
            IERC20(BASE_USDC),
            IERC20(L2_PINTO),
            usdcAmount,
            0,
            user,
            block.timestamp
        );

        IERC20(BASE_CBETH).approve(PINTO_CBETH_WELL, cbethAmount);
        IWell(PINTO_CBETH_WELL).swapFrom(
            IERC20(BASE_CBETH),
            IERC20(L2_PINTO),
            cbethAmount,
            0,
            user,
            block.timestamp
        );

        vm.stopPrank();
    }

    /**
     * @notice Executes a pipelineConvert and returns the resulting grown stalk
     */
    function _executeConvert(
        address account,
        address inputToken,
        int96 stem,
        uint256 amount,
        address outputToken
    ) internal returns (int96 newStem, uint256 grownStalk) {
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(account);
        (newStem, , , , ) = bs.pipelineConvert(
            inputToken,
            stems,
            amounts,
            outputToken,
            _buildPipelineCalls(inputToken, outputToken, amount)
        );

        grownStalk = bs.grownStalkForDeposit(account, outputToken, newStem);
    }

    /**
     * @notice Builds pipeline calls for Bean -> LP conversion via addLiquidity
     */
    function _buildPipelineCalls(
        address inputToken,
        address outputToken,
        uint256 amount
    ) internal pure returns (IMockFBeanstalk.AdvancedPipeCall[] memory) {
        IMockFBeanstalk.AdvancedPipeCall[] memory calls = new IMockFBeanstalk.AdvancedPipeCall[](2);

        address targetWell = inputToken == L2_PINTO ? outputToken : inputToken;

        bytes memory approveData = abi.encodeWithSelector(
            IERC20.approve.selector,
            targetWell,
            type(uint256).max
        );
        calls[0] = IMockFBeanstalk.AdvancedPipeCall(inputToken, approveData, abi.encode(0));

        uint256[] memory tokenAmounts = new uint256[](2);
        tokenAmounts[0] = amount;
        tokenAmounts[1] = 0;
        bytes memory addLiquidityData = abi.encodeWithSelector(
            IWell.addLiquidity.selector,
            tokenAmounts,
            0,
            BASE_PIPELINE,
            type(uint256).max
        );
        calls[1] = IMockFBeanstalk.AdvancedPipeCall(targetWell, addLiquidityData, abi.encode(0));

        return calls;
    }

    function _formatSigned(int256 value) internal pure returns (string memory) {
        if (value >= 0) {
            return string(abi.encodePacked("+", vm.toString(uint256(value))));
        } else {
            return string(abi.encodePacked("-", vm.toString(uint256(-value))));
        }
    }
}

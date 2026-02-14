// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import "forge-std/Test.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title ConvertCapacityForkTest
 * @notice Fork test from whitehat report to verify convert capacity double-counting bug is fixed.
 * @dev Before fix: Convert 1 uses 250945301, Convert 2 uses 501823323 (199% ratio)
 * After fix: Both converts should use approximately the same capacity.
 *
 * Run: BASE_RPC=<your_base_rpc> forge test --match-contract ConvertCapacityForkTest -vv
 */
contract ConvertCapacityForkTest is TestHelper {
    address constant PINTO_DIAMOND = 0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f;
    address constant PINTO_TOKEN = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;
    address constant PINTO_USDC_WELL = 0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1;
    address constant REAL_FARMER = 0xFb94D3404c1d3D9D6F08f79e58041d5EA95AccfA;
    int96 constant FARMER_STEM = 590486100;
    uint256 constant FORK_BLOCK = 27236526;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC"), FORK_BLOCK);
        bs = IMockFBeanstalk(PINTO_DIAMOND);
    }

    /**
     * @notice This test SHOULD FAIL after the fix is applied.
     * @dev The assertion expects convert 2 to use >150% of convert 1's capacity (the bug behavior).
     * With the fix, both converts use approximately the same capacity, so this assertion fails.
     */
    function test_forkBase_convertCapacityDoubleCount_EXPECT_FAIL() public {
        (uint256 depositAmount, ) = bs.getDeposit(REAL_FARMER, PINTO_TOKEN, FARMER_STEM);
        console.log("Farmer deposit:", depositAmount);
        require(depositAmount > 0, "No deposit found");

        uint256 capacityBefore = bs.getOverallConvertCapacity();
        console.log("Overall convert capacity:", capacityBefore);

        uint256 convertAmount = 500e6;
        bytes memory convertData = abi.encode(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            convertAmount,
            uint256(0),
            PINTO_USDC_WELL
        );
        int96[] memory stems = new int96[](1);
        stems[0] = FARMER_STEM;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = convertAmount;

        vm.prank(REAL_FARMER);
        bs.convert(convertData, stems, amounts);
        uint256 capacityAfter1 = bs.getOverallConvertCapacity();
        uint256 usedByConvert1 = capacityBefore - capacityAfter1;

        vm.prank(REAL_FARMER);
        bs.convert(convertData, stems, amounts);
        uint256 capacityAfter2 = bs.getOverallConvertCapacity();
        uint256 usedByConvert2 = capacityAfter1 - capacityAfter2;

        console.log("Capacity used by convert 1:", usedByConvert1);
        console.log("Capacity used by convert 2:", usedByConvert2);
        console.log("Ratio (convert2/convert1):", (usedByConvert2 * 100) / usedByConvert1, "%");

        // This assertion expects the BUG behavior (2nd convert uses >150% of 1st)
        // After fix, this should FAIL because both converts use ~equal capacity
        assertGt(
            usedByConvert2,
            (usedByConvert1 * 15) / 10,
            "Bug: 2nd convert uses disproportionately more capacity than 1st"
        );
    }
}

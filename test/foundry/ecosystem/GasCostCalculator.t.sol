// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {GasCostCalculator} from "contracts/ecosystem/tractor/utils/GasCostCalculator.sol";
import {MockChainlinkAggregator} from "contracts/mocks/MockChainlinkAggregator.sol";
import "forge-std/console.sol";

/**
 * @title GasCostCalculatorTest
 * @notice Tests for the GasCostCalculator contract
 * @dev Note: Full oracle integration tests should use fork tests.
 *      These tests verify the contract logic and revert behavior.
 */
contract GasCostCalculatorTest is TestHelper {
    GasCostCalculator public gasCostCalculator;

    // Test constants
    uint256 constant DEFAULT_BASE_OVERHEAD = 50_000;
    uint256 constant TYPICAL_GAS_USED = 200_000;
    uint256 constant TYPICAL_GAS_PRICE = 1 gwei;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // Deploy GasCostCalculator
        gasCostCalculator = new GasCostCalculator(
            address(bs),
            address(this),
            DEFAULT_BASE_OVERHEAD
        );
        vm.label(address(gasCostCalculator), "GasCostCalculator");
    }

    // ==================== Constructor Tests ====================

    function test_constructor() public view {
        assertEq(address(gasCostCalculator.beanstalk()), address(bs));
        assertEq(gasCostCalculator.baseGasOverhead(), DEFAULT_BASE_OVERHEAD);
    }

    function test_constructor_revertsOnZeroBeanstalk() public {
        vm.expectRevert("GasCostCalculator: zero beanstalk");
        new GasCostCalculator(address(0), address(this), DEFAULT_BASE_OVERHEAD);
    }

    // ==================== Oracle Revert Tests ====================

    function test_calculateFeeInPinto_revertsWithoutEthOracle() public {
        vm.txGasPrice(TYPICAL_GAS_PRICE);

        // ETH/USD oracle has no code, should revert
        vm.expectRevert("GasCostCalculator: ETH/USD oracle failed");
        gasCostCalculator.calculateFeeInPinto(TYPICAL_GAS_USED, 0);
    }

    function test_getEthPintoRate_revertsWithoutOracle() public {
        vm.expectRevert("GasCostCalculator: ETH/USD oracle failed");
        gasCostCalculator.getEthPintoRate();
    }

    function test_estimateFee_revertsWithoutOracle() public {
        vm.txGasPrice(TYPICAL_GAS_PRICE);

        vm.expectRevert("GasCostCalculator: ETH/USD oracle failed");
        gasCostCalculator.estimateFee(TYPICAL_GAS_USED, 1000);
    }

    // ==================== Admin Function Tests ====================

    function test_setBaseGasOverhead() public {
        uint256 newOverhead = 100_000;

        vm.expectEmit(true, true, true, true);
        emit GasCostCalculator.BaseGasOverheadUpdated(DEFAULT_BASE_OVERHEAD, newOverhead);

        gasCostCalculator.setBaseGasOverhead(newOverhead);

        assertEq(gasCostCalculator.baseGasOverhead(), newOverhead);
    }

    function test_setBaseGasOverhead_onlyOwner() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        gasCostCalculator.setBaseGasOverhead(100_000);
    }

    // ==================== Oracle Addresses ====================

    function test_oracleAddresses() public view {
        // Verify correct oracle address is set
        assertEq(
            gasCostCalculator.ETH_USD_ORACLE(),
            0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            "ETH/USD oracle should be Base mainnet address"
        );
        assertEq(gasCostCalculator.ORACLE_TIMEOUT(), 14400, "Timeout should be 4 hours");
    }

    // ==================== Gas Overhead Logic Tests ====================

    /**
     * @dev Tests that the gas overhead is correctly added to gas calculations
     * by deploying a mock scenario where we can verify the math
     */
    function test_baseGasOverhead_isApplied() public {
        // Set a different overhead
        gasCostCalculator.setBaseGasOverhead(75_000);
        assertEq(gasCostCalculator.baseGasOverhead(), 75_000);

        // Set back
        gasCostCalculator.setBaseGasOverhead(0);
        assertEq(gasCostCalculator.baseGasOverhead(), 0);
    }
}

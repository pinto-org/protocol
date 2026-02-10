// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {GasCostCalculator} from "contracts/ecosystem/tractor/utils/GasCostCalculator.sol";
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {MockChainlinkAggregator} from "contracts/mocks/MockChainlinkAggregator.sol";

/**
 * @title GasCostCalculatorTest
 * @notice Tests for the GasCostCalculator contract
 * @dev Note: Full oracle integration tests should use fork tests.
 *      These tests verify the contract logic and revert behavior.
 */
contract GasCostCalculatorTest is TestHelper {
    GasCostCalculator public gasCostCalculator;
    BeanstalkPrice public beanstalkPrice;

    // Test constants
    uint256 constant DEFAULT_BASE_OVERHEAD = 50_000;
    uint256 constant TYPICAL_GAS_USED = 200_000;
    uint256 constant TYPICAL_GAS_PRICE = 1 gwei;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        beanstalkPrice = new BeanstalkPrice(address(bs));
        vm.label(address(beanstalkPrice), "BeanstalkPrice");

        gasCostCalculator = new GasCostCalculator(
            address(beanstalkPrice),
            address(this),
            DEFAULT_BASE_OVERHEAD
        );
        vm.label(address(gasCostCalculator), "GasCostCalculator");
    }

    function test_constructor_revertsOnZeroBeanstalkPrice() public {
        vm.expectRevert("GasCostCalculator: zero beanstalkPrice");
        new GasCostCalculator(address(0), address(this), DEFAULT_BASE_OVERHEAD);
    }

    function test_calculateFeeInBeanWithMeasuredOracle_revertsOnExcessiveMargin() public {
        vm.expectRevert("GasCostCalculator: margin exceeds max");
        gasCostCalculator.calculateFeeInBeanWithMeasuredOracle(
            TYPICAL_GAS_USED,
            500_000,
            10001
        );
    }

    function test_calculateFeeInBeanWithMeasuredOracle_revertsWithoutEthOracle() public {
        vm.txGasPrice(TYPICAL_GAS_PRICE);

        vm.expectRevert("GasCostCalculator: ETH/USD oracle failed");
        gasCostCalculator.calculateFeeInBeanWithMeasuredOracle(TYPICAL_GAS_USED, 500_000, 0);
    }

    function test_getEthBeanRate_revertsWithoutOracle() public {
        vm.expectRevert("GasCostCalculator: ETH/USD oracle failed");
        gasCostCalculator.getEthBeanRate();
    }

    function test_setBaseGasOverhead_onlyOwner() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        gasCostCalculator.setBaseGasOverhead(100_000);
    }

    function test_baseGasOverhead_isApplied() public {
        gasCostCalculator.setBaseGasOverhead(75_000);
        assertEq(gasCostCalculator.baseGasOverhead(), 75_000);

        gasCostCalculator.setBaseGasOverhead(0);
        assertEq(gasCostCalculator.baseGasOverhead(), 0);
    }
}

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

    function test_constructor() public view {
        assertEq(address(gasCostCalculator.beanstalkPrice()), address(beanstalkPrice));
        assertEq(gasCostCalculator.baseGasOverhead(), DEFAULT_BASE_OVERHEAD);
    }

    function test_constructor_revertsOnZeroBeanstalkPrice() public {
        vm.expectRevert("GasCostCalculator: zero beanstalkPrice");
        new GasCostCalculator(address(0), address(this), DEFAULT_BASE_OVERHEAD);
    }

    function test_calculateFeeInBean_revertsOnExcessiveMargin() public {
        vm.txGasPrice(TYPICAL_GAS_PRICE);

        // Margin > 10000 bps (100%) should revert
        vm.expectRevert("GasCostCalculator: margin exceeds max");
        gasCostCalculator.calculateFeeInBeanWithGasPrice(
            TYPICAL_GAS_USED,
            TYPICAL_GAS_PRICE,
            10001
        );
    }

    function test_calculateFeeInBean_maxMarginAllowed() public {
        // Max margin (10000 bps = 100%) should not revert on validation
        // Will still revert on oracle, but not on margin check
        vm.expectRevert("GasCostCalculator: ETH/USD oracle failed");
        gasCostCalculator.calculateFeeInBeanWithGasPrice(
            TYPICAL_GAS_USED,
            TYPICAL_GAS_PRICE,
            10000
        );
    }

    function test_calculateFeeInBean_revertsWithoutEthOracle() public {
        vm.txGasPrice(TYPICAL_GAS_PRICE);

        // ETH/USD oracle has no code, should revert
        vm.expectRevert("GasCostCalculator: ETH/USD oracle failed");
        gasCostCalculator.calculateFeeInBean(TYPICAL_GAS_USED, 0);
    }

    function test_getEthBeanRate_revertsWithoutOracle() public {
        vm.expectRevert("GasCostCalculator: ETH/USD oracle failed");
        gasCostCalculator.getEthBeanRate();
    }

    function test_estimateFee_revertsWithoutOracle() public {
        vm.txGasPrice(TYPICAL_GAS_PRICE);

        vm.expectRevert("GasCostCalculator: ETH/USD oracle failed");
        gasCostCalculator.estimateFee(TYPICAL_GAS_USED, 1000);
    }

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

    function test_constants() public view {
        // Verify correct oracle address is set
        assertEq(
            gasCostCalculator.ETH_USD_ORACLE(),
            0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            "ETH/USD oracle should be Base mainnet address"
        );
        assertEq(gasCostCalculator.ORACLE_TIMEOUT(), 14400, "Timeout should be 4 hours");
        assertEq(gasCostCalculator.MAX_MARGIN_BPS(), 10000, "Max margin should be 100%");
    }

    function test_baseGasOverhead_isApplied() public {
        gasCostCalculator.setBaseGasOverhead(75_000);
        assertEq(gasCostCalculator.baseGasOverhead(), 75_000);

        gasCostCalculator.setBaseGasOverhead(0);
        assertEq(gasCostCalculator.baseGasOverhead(), 0);
    }
}

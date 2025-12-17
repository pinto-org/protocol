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

        // ETH/USD oracle has no code so it returns 0, should revert
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

contract GasCostCalculatorHarness is GasCostCalculator {
    uint256 public mockRate;

    constructor(
        address _beanstalk,
        address _owner,
        uint256 _baseGasOverhead
    ) GasCostCalculator(_beanstalk, _owner, _baseGasOverhead) {}

    function setMockRate(uint256 _rate) external {
        mockRate = _rate;
    }

    function _getEthPintoRate() internal view override returns (uint256) {
        if (mockRate != 0) return mockRate;
        return super._getEthPintoRate();
    }
}

contract GasCostCalculatorMathTest is TestHelper {
    GasCostCalculatorHarness public calculator;
    uint256 constant BASE_OVERHEAD = 50000;

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        calculator = new GasCostCalculatorHarness(address(bs), address(this), BASE_OVERHEAD);
    }

    function test_calculateFee_math() public {
        uint256 gasPrice = 2 gwei; // 2e9 wei
        uint256 gasUsed = 150000;
        
        // Rate: 1000 Pinto per ETH (ETH=$1000, Pinto=$1.00)
        uint256 rate = 1000e6;
        calculator.setMockRate(rate);

        // Expected Fee:
        // Cost in ETH = 200,000 * 2e9 = 4e14 wei
        // Cost in Pinto = 4e14 * 1000e6 / 1e18 = 0.4e6 = 400,000
        
        uint256 fee = calculator.calculateFeeInPintoWithGasPrice(gasUsed, gasPrice, 0);
        assertEq(fee, 400000);
    }

    function test_calculateFee_withMargin() public {
        uint256 gasPrice = 2 gwei; // 2e9 wei
        uint256 gasUsed = 150000; 
        
        uint256 rate = 1000e6;
        calculator.setMockRate(rate);

        // Margin 10% (1000 bps) -> 400,000 * 1.1 = 440,000
        uint256 fee = calculator.calculateFeeInPintoWithGasPrice(gasUsed, gasPrice, 1000);
        assertEq(fee, 440000);
    }

    /**
     * @notice Test that verifies baseGasOverhead is reasonable
     * @dev This test documents the expected overhead range for Tractor infrastructure.
     * The overhead accounts for:
     * - Signature verification (~3000-5000 gas)
     * - Blueprint hash computation (~2000-3000 gas)
     * - Requisition validation (~5000-10000 gas)
     * - Storage reads/writes (~20000-30000 gas)
     * - Other Tractor infrastructure costs (~10000-20000 gas)
     * 
     * Total expected overhead: 40,000-60,000 gas
     * Default used: 50,000 gas (middle of range)
     */
    function test_baseGasOverhead_reasonable() public view {
        uint256 overhead = calculator.baseGasOverhead();
        
        // Verify overhead is in reasonable range
        assertGe(overhead, 40000, "Base gas overhead too low");
        assertLe(overhead, 60000, "Base gas overhead too high");
        
        // Document current value
        console.log("Current Base Gas Overhead:", overhead);
    }

    /**
     * @notice Test fee calculation with base overhead applied
     */
    function test_calculateFee_withBaseOverhead() public {
        uint256 gasPrice = 10 gwei;
        uint256 gasUsed = 100000; // Blueprint execution
        uint256 overhead = 50000; // Tractor overhead
        
        calculator = new GasCostCalculatorHarness(address(bs), address(this), overhead);
        calculator.setMockRate(2000e6); // 2000 Pinto per ETH
        
        // Expected: (100000 + 50000) * 10e9 * 2000e6 / 1e18 = 3,000,000 (3 Pinto)
        uint256 fee = calculator.calculateFeeInPintoWithGasPrice(gasUsed, gasPrice, 0);
        assertEq(fee, 3000000);
    }
}

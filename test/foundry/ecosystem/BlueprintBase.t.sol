// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {BlueprintBase} from "contracts/ecosystem/tractor/blueprints/BlueprintBase.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";

/**
 * @title BlueprintBaseHarness
 * @notice Test harness that exposes internal functions from BlueprintBase
 */
contract BlueprintBaseHarness is BlueprintBase {
    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers,
        address _gasCostCalculator,
        address _siloHelpers
    ) BlueprintBase(_beanstalk, _owner, _tractorHelpers, _gasCostCalculator, _siloHelpers) {}

    function exposed_addDynamicFee(
        int256 currentTip,
        uint256 dynamicFee
    ) external pure returns (int256) {
        return _addDynamicFee(currentTip, dynamicFee);
    }

    function exposed_validateBlueprint(bytes32 orderHash, uint32 currentSeason) external view {
        _validateBlueprint(orderHash, currentSeason);
    }

    function exposed_validateSourceTokens(uint8[] calldata sourceTokenIndices) external pure {
        _validateSourceTokens(sourceTokenIndices);
    }

    function exposed_resolveTipAddress(address providedTipAddress) external view returns (address) {
        return _resolveTipAddress(providedTipAddress);
    }

    function exposed_updateLastExecutedSeason(bytes32 orderHash, uint32 season) external {
        _updateLastExecutedSeason(orderHash, season);
    }
}

/**
 * @title BlueprintBaseTest
 * @notice Unit tests for BlueprintBase internal functions
 */
contract BlueprintBaseTest is TestHelper {
    BlueprintBaseHarness public harness;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        harness = new BlueprintBaseHarness(
            address(bs),
            address(this),
            address(0),
            address(0),
            address(0)
        );
    }

    function test_addDynamicFee_addsCorrectly() public view {
        int256 result = harness.exposed_addDynamicFee(100e6, 50e6);
        assertEq(result, 150e6);
    }

    function test_addDynamicFee_worksWithNegativeTip() public view {
        int256 result = harness.exposed_addDynamicFee(-100e6, 150e6);
        assertEq(result, 50e6);
    }

    function test_addDynamicFee_revertsOnOverflow() public {
        vm.expectRevert("BlueprintBase: tip + fee overflow");
        harness.exposed_addDynamicFee(type(int256).max - 100, 200);
    }

    function test_addDynamicFee_worksAtExactLimit() public view {
        int256 result = harness.exposed_addDynamicFee(type(int256).max - 100, 100);
        assertEq(result, type(int256).max);
    }

    function test_validateBlueprint_revertsOnZeroOrderHash() public {
        vm.expectRevert("No active blueprint, function must run from Tractor");
        harness.exposed_validateBlueprint(bytes32(0), 1);
    }

    function test_validateBlueprint_revertsOnSameSeasonExecution() public {
        bytes32 orderHash = keccak256("test-order");
        harness.exposed_updateLastExecutedSeason(orderHash, 5);

        vm.expectRevert("Blueprint already executed this season");
        harness.exposed_validateBlueprint(orderHash, 5);
    }

    function test_validateSourceTokens_revertsOnEmptyArray() public {
        uint8[] memory emptyArray = new uint8[](0);

        vm.expectRevert("Must provide at least one source token");
        harness.exposed_validateSourceTokens(emptyArray);
    }

    function test_resolveTipAddress_returnsProvidedAddress() public view {
        address result = harness.exposed_resolveTipAddress(address(0x1234));
        assertEq(result, address(0x1234));
    }

    function test_resolveTipAddress_returnsOperatorWhenZero() public {
        vm.mockCall(
            address(bs),
            abi.encodeWithSelector(IBeanstalk.operator.selector),
            abi.encode(address(0x5678))
        );

        address result = harness.exposed_resolveTipAddress(address(0));
        assertEq(result, address(0x5678));
    }

    function test_updateLastExecutedSeason_updatesCorrectly() public {
        bytes32 orderHash = keccak256("test-order");
        harness.exposed_updateLastExecutedSeason(orderHash, 10);
        assertEq(harness.orderLastExecutedSeason(orderHash), 10);
    }
}

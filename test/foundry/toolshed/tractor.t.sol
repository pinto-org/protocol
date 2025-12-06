// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {TractorTestHelper} from "test/foundry/utils/TractorTestHelper.sol";
import {MockERC1271} from "contracts/mocks/ERC/MockERC1271.sol";
import {MockTractorBlueprint} from "contracts/mocks/MockTractorBlueprint.sol";
import {C} from "contracts/C.sol";
import {console} from "forge-std/console.sol";

/**
 * @notice A significant amount of tests for tractor are located at `tractor.test.js`.
 */
contract TractorTest is TestHelper, TractorTestHelper {
    // Test accounts.
    address[] farmers;

    // Mock blueprint for dynamic data testing.
    MockTractorBlueprint mockBlueprint;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // Initializes farmers from farmers (farmer0 == diamond deployer).
        farmers.push(users[1]);
        farmers.push(users[2]);

        // Max approve.
        maxApproveBeanstalk(farmers);

        // Create a MockTractorBlueprint to test dynamic data injections.
        mockBlueprint = new MockTractorBlueprint(address(bs));
    }

    //////////////// Helper Functions ////////////////

    /**
     * @notice Generic helper to create requisition data for any target and callData.
     * @param target The target address for the pipe call
     * @param callData The encoded callData to execute
     * @return data Encoded data for requisition
     */
    function createRequisitionData(
        address target,
        bytes memory callData
    ) internal pure returns (bytes memory) {
        // Create pipe call.
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: target,
            callData: callData,
            clipboard: hex"0000"
        });

        // Wrap in farm call.
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        return abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);
    }

    /**
     * @notice Helper to create multiple dynamic data entries for fuzz testing.
     * @param count Number of dynamic data entries to create (1-25)
     * @return pipes Array of pipe calls
     * @return dynamicData Array of contract data entries
     */
    function createDynamicDataArray(
        uint256 count
    )
        internal
        view
        returns (
            IMockFBeanstalk.AdvancedPipeCall[] memory pipes,
            IMockFBeanstalk.ContractData[] memory dynamicData
        )
    {
        pipes = new IMockFBeanstalk.AdvancedPipeCall[](count);
        dynamicData = new IMockFBeanstalk.ContractData[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 key = i + 100; // Use keys starting from 100 to avoid conflicts.
            uint256 testValue = (i + 1) * 1000; // Sequential test values.

            pipes[i] = IMockFBeanstalk.AdvancedPipeCall({
                target: address(mockBlueprint),
                callData: abi.encodeWithSelector(MockTractorBlueprint.processUint256.selector, key),
                clipboard: hex"0000"
            });

            dynamicData[i] = IMockFBeanstalk.ContractData({key: key, value: abi.encode(testValue)});
        }
    }

    //////////////// ERC1271 ////////////////

    /**
     * @notice Test that a valid ERC1271 signature allows tractor execution.
     */
    function test_ERC1271_ValidSignature() public {
        // Deploy MockERC1271 contract with valid signature state.
        MockERC1271 mockContract = new MockERC1271(true);

        // Create requisition data calling season() view function.
        bytes memory data = createRequisitionData(
            address(bs),
            abi.encodeWithSelector(IMockFBeanstalk.season.selector)
        );

        // Create requisition with MockERC1271 as publisher.
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // Verify the mock contract is set to return valid signature.
        assertTrue(mockContract.getIsValidSignature(), "Mock should be set to valid");

        // Execute tractor with valid signature - should succeed.
        vm.expectEmit(true, true, true, false);
        emit IMockFBeanstalk.TractorExecutionBegan(
            address(this),
            address(mockContract),
            req.blueprintHash,
            0,
            0
        );

        // expect tractor to succeed
        // vm.expectEmit(true, true, true, false);
        // emit IMockFBeanstalk.Tractor(addiress(), address(mockContract), req.blueprintHash, 0, 0);
        bytes[] memory results = bs.tractor(req, "");

        // Verify execution completed successfully.
        assertEq(results.length, 1, "Should return one result");
    }

    /**
     * @notice Test that an invalid ERC1271 signature reverts tractor execution.
     */
    function test_ERC1271_InvalidSignature() public {
        // Deploy MockERC1271 contract with invalid signature state.
        MockERC1271 mockContract = new MockERC1271(false);

        // Create requisition data calling season() view function.
        bytes memory data = createRequisitionData(
            address(bs),
            abi.encodeWithSelector(IMockFBeanstalk.season.selector)
        );

        // Create requisition with MockERC1271 as publisher.
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // Verify the mock contract is set to return invalid signature.
        assertFalse(mockContract.getIsValidSignature(), "Mock should be set to invalid");

        // Execute tractor with invalid signature - should revert.
        vm.expectRevert("TractorFacet: invalid signature");
        vm.prank(farmers[0]);
        bs.tractor(req, "");
    }

    /**
     * @notice Test signature validation toggle behavior.
     * @dev Tests that signature state changes are properly respected
     */
    function test_ERC1271_SignatureToggle() public {
        // Deploy MockERC1271 contract with valid signature state.
        MockERC1271 mockContract = new MockERC1271(true);

        // Create requisition data calling season() view function.
        bytes memory data = createRequisitionData(
            address(bs),
            abi.encodeWithSelector(IMockFBeanstalk.season.selector)
        );

        // Create requisition with MockERC1271 as publisher.
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // First execution with valid signature - should succeed.
        assertTrue(mockContract.getIsValidSignature(), "Mock should start as valid");
        vm.prank(farmers[0]);
        bytes[] memory results1 = bs.tractor(req, "");
        assertEq(results1.length, 1, "First execution should succeed");

        // Toggle to invalid signature.
        mockContract.setIsValidSignature(false);
        assertFalse(mockContract.getIsValidSignature(), "Mock should now be invalid");

        // Create new requisition with new blueprint hash (due to nonce increment).
        IMockFBeanstalk.Requisition memory req2 = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // Second execution with invalid signature - should revert.
        vm.expectRevert("TractorFacet: invalid signature");
        vm.prank(farmers[0]);
        bs.tractor(req2, "");

        // Toggle back to valid signature.
        mockContract.setIsValidSignature(true);
        assertTrue(mockContract.getIsValidSignature(), "Mock should be valid again");

        // Create third requisition.
        IMockFBeanstalk.Requisition memory req3 = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // Third execution with valid signature - should succeed.
        vm.prank(farmers[0]);
        bytes[] memory results3 = bs.tractor(req3, "");
        assertEq(results3.length, 1, "Third execution should succeed");
    }

    /**
     * @notice Fuzz test tractorDynamicData with valid data injection.
     * @dev Tests EIP-1153 transient storage injection and abi.decode of uint256 data in blueprint execution
     */
    function testFuzz_DynamicData_ValidUint256(uint256 testValue) public {
        bytes memory data = createRequisitionData(
            address(mockBlueprint),
            abi.encodeWithSelector(MockTractorBlueprint.processUint256.selector, 1)
        );

        // Create requisition.
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Create dynamic data with fuzzed value.
        IMockFBeanstalk.ContractData[] memory dynamicData = new IMockFBeanstalk.ContractData[](1);
        dynamicData[0] = IMockFBeanstalk.ContractData({key: 1, value: abi.encode(testValue)});

        // Execute with dynamic data.
        vm.prank(farmers[0]);
        bytes[] memory results = bs.tractorDynamicData(req, "", dynamicData);

        // Verify execution succeeded.
        assertEq(results.length, 1, "Should return one result");
        assertEq(mockBlueprint.processedValue(), testValue, "Should have processed uint256 value");
        assertTrue(mockBlueprint.operationSuccess(), "Operation should have succeeded");
    }

    /**
     * @notice Test tractorDynamicData with address data injection.
     * @dev Tests transient storage with address type encoding/decoding through getTractorData interface
     */
    function test_DynamicData_ValidAddress() public {
        bytes memory data = createRequisitionData(
            address(mockBlueprint),
            abi.encodeWithSelector(MockTractorBlueprint.processAddress.selector, 2)
        );

        // Create requisition.
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Create dynamic data with test address.
        address testAddress = farmers[1];
        IMockFBeanstalk.ContractData[] memory dynamicData = new IMockFBeanstalk.ContractData[](1);
        dynamicData[0] = IMockFBeanstalk.ContractData({key: 2, value: abi.encode(testAddress)});

        // Execute with dynamic data.
        vm.prank(farmers[0]);
        bytes[] memory results = bs.tractorDynamicData(req, "", dynamicData);

        // Verify execution succeeded.
        assertEq(results.length, 1, "Should return one result");
        assertEq(
            mockBlueprint.processedAddress(),
            testAddress,
            "Should have processed address value"
        );
        assertTrue(mockBlueprint.operationSuccess(), "Operation should have succeeded");
    }

    /**
     * @notice Test tractorDynamicData with non-existent key.
     * @dev Tests getTractorData returns empty bytes for missing keys without reverting
     */
    function test_DynamicData_NonExistentKey() public {
        bytes memory data = createRequisitionData(
            address(mockBlueprint),
            abi.encodeWithSelector(MockTractorBlueprint.processUint256.selector, 999)
        );

        // Create requisition.
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Create empty dynamic data array (no key 999).
        IMockFBeanstalk.ContractData[] memory dynamicData = new IMockFBeanstalk.ContractData[](0);

        // Execute with no dynamic data.
        vm.prank(farmers[0]);
        bytes[] memory results = bs.tractorDynamicData(req, "", dynamicData);

        // Verify execution succeeded and processUint256 handled empty data gracefully (no decode, no state change).
        assertEq(results.length, 1, "Should return one result");
        assertEq(mockBlueprint.processedValue(), 0, "Should not have processed any value");
        assertFalse(mockBlueprint.operationSuccess(), "Operation should not have set success flag");
    }

    /**
     * @notice Test tractorDynamicData with corrupted data that should revert.
     * @dev Tests abi.decode revert propagation when blueprint processes malformed bytes from transient storage
     */
    function test_DynamicData_CorruptedData() public {
        bytes memory data = createRequisitionData(
            address(mockBlueprint),
            abi.encodeWithSelector(MockTractorBlueprint.processUint256.selector, 3)
        );

        // Create requisition.
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Create corrupted data (incomplete uint256 encoding).
        IMockFBeanstalk.ContractData[] memory dynamicData = new IMockFBeanstalk.ContractData[](1);
        dynamicData[0] = IMockFBeanstalk.ContractData({
            key: 3,
            value: hex"1234" // Invalid bytes for uint256 decoding.
        });

        // Execute with corrupted data - should revert during decoding.
        vm.prank(farmers[0]);
        vm.expectRevert();
        bs.tractorDynamicData(req, "", dynamicData);
    }

    /**
     * @notice Fuzz test tractorDynamicData with multiple dynamic data entries (1-25).
     * @dev Tests transient storage with variable number of concurrent key-value pairs
     */
    function testFuzz_DynamicData_MultipleEntries(uint256 entryCount) public {
        // Bound to reasonable range for gas efficiency and coverage.
        entryCount = bound(entryCount, 1, 25);

        // Create dynamic arrays using helper.
        (
            IMockFBeanstalk.AdvancedPipeCall[] memory pipes,
            IMockFBeanstalk.ContractData[] memory dynamicData
        ) = createDynamicDataArray(entryCount);

        // Wrap in farm call.
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create requisition.
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Execute with dynamic data.
        vm.prank(farmers[0]);
        bytes[] memory results = bs.tractorDynamicData(req, "", dynamicData);

        // Verify execution succeeded.
        assertEq(results.length, 1, "Should return one result");

        // Verify all values were processed correctly.
        for (uint256 i = 0; i < entryCount; i++) {
            uint256 expectedValue = (i + 1) * 1000;
            assertEq(
                mockBlueprint.processedValues(i),
                expectedValue,
                "Each value should be processed correctly"
            );
        }

        // Verify operation succeeded.
        assertTrue(mockBlueprint.operationSuccess(), "Operation should have succeeded");
    }
}

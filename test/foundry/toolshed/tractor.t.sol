// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {TractorTestHelper} from "test/foundry/utils/TractorTestHelper.sol";
import {MockERC1271} from "contracts/mocks/ERC/MockERC1271.sol";
import {MockTractorBlueprint} from "contracts/mocks/MockTractorBlueprint.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {C} from "contracts/C.sol";
import {console} from "forge-std/console.sol";

/**
 * @notice a significant amount of tests for tractor can are located at `tractor.test.js`.
 */
contract TractorTest is TestHelper, TractorTestHelper {
    // test accounts
    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // initializes farmers from farmers (farmer0 == diamond deployer)
        farmers.push(users[1]);
        farmers.push(users[2]);

        // max approve.
        maxApproveBeanstalk(farmers);
    }

    //////////////// ERC1271 ////////////////

    /**
     * @notice Test that a valid ERC1271 signature allows tractor execution
     */
    function test_ERC1271_ValidSignature() public {
        // Deploy MockERC1271 contract with valid signature state
        MockERC1271 mockContract = new MockERC1271(true);

        // Create a minimal pipe call that calls the season() view function
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(bs),
            callData: abi.encodeWithSelector(IMockFBeanstalk.season.selector),
            clipboard: hex"0000"
        });

        // Wrap the pipe call in a farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        // Encode the advancedFarm call
        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create requisition with MockERC1271 as publisher
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // Verify the mock contract is set to return valid signature
        assertTrue(mockContract.getIsValidSignature(), "Mock should be set to valid");

        // Execute tractor with valid signature - should succeed
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

        // Verify execution completed successfully
        assertEq(results.length, 1, "Should return one result");
    }

    /**
     * @notice Test that an invalid ERC1271 signature reverts tractor execution
     */
    function test_ERC1271_InvalidSignature() public {
        // Deploy MockERC1271 contract with invalid signature state
        MockERC1271 mockContract = new MockERC1271(false);

        // Create a minimal pipe call that calls the season() view function
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(bs),
            callData: abi.encodeWithSelector(IMockFBeanstalk.season.selector),
            clipboard: hex"0000"
        });

        // Wrap the pipe call in a farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        // Encode the advancedFarm call
        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create requisition with MockERC1271 as publisher
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // Verify the mock contract is set to return invalid signature
        assertFalse(mockContract.getIsValidSignature(), "Mock should be set to invalid");

        // Execute tractor with invalid signature - should revert
        vm.expectRevert("TractorFacet: invalid signature");
        vm.prank(farmers[0]);
        bs.tractor(req, "");
    }

    /**
     * @notice Test signature validation toggle behavior
     * @dev Tests that signature state changes are properly respected
     */
    function test_ERC1271_SignatureToggle() public {
        // Deploy MockERC1271 contract with valid signature state
        MockERC1271 mockContract = new MockERC1271(true);

        // Create a minimal pipe call that calls the season() view function
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(bs),
            callData: abi.encodeWithSelector(IMockFBeanstalk.season.selector),
            clipboard: hex"0000"
        });

        // Wrap the pipe call in a farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        // Encode the advancedFarm call
        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create requisition with MockERC1271 as publisher
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // First execution with valid signature - should succeed
        assertTrue(mockContract.getIsValidSignature(), "Mock should start as valid");
        vm.prank(farmers[0]);
        bytes[] memory results1 = bs.tractor(req, "");
        assertEq(results1.length, 1, "First execution should succeed");

        // Toggle to invalid signature
        mockContract.setIsValidSignature(false);
        assertFalse(mockContract.getIsValidSignature(), "Mock should now be invalid");

        // Create new requisition with new blueprint hash (due to nonce increment)
        IMockFBeanstalk.Requisition memory req2 = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // Second execution with invalid signature - should revert
        vm.expectRevert("TractorFacet: invalid signature");
        vm.prank(farmers[0]);
        bs.tractor(req2, "");

        // Toggle back to valid signature
        mockContract.setIsValidSignature(true);
        assertTrue(mockContract.getIsValidSignature(), "Mock should be valid again");

        // Create third requisition
        IMockFBeanstalk.Requisition memory req3 = createRequisitionWithPipeCallERC1271(
            address(mockContract),
            data,
            address(bs)
        );

        // Third execution with valid signature - should succeed
        vm.prank(farmers[0]);
        bytes[] memory results3 = bs.tractor(req3, "");
        assertEq(results3.length, 1, "Third execution should succeed");
    }

    /**
     * @notice Test tractorDynamicData with valid data injection
     * @dev Tests EIP-1153 transient storage injection and abi.decode of uint256 data in blueprint execution
     */
    function test_DynamicData_ValidUint256() public {
        MockTractorBlueprint mockBlueprint = new MockTractorBlueprint(address(bs));

        // Create pipe call to processUint256 function
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(mockBlueprint),
            callData: abi.encodeWithSelector(MockTractorBlueprint.processUint256.selector, 1),
            clipboard: hex"0000"
        });

        // Wrap in farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create requisition
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Create dynamic data
        IMockFBeanstalk.ContractData[] memory dynamicData = new IMockFBeanstalk.ContractData[](1);
        dynamicData[0] = IMockFBeanstalk.ContractData({
            key: 1,
            value: abi.encode(uint256(12345))
        });

        // Execute with dynamic data
        vm.prank(farmers[0]);
        bytes[] memory results = bs.tractorDynamicData(req, "", dynamicData);

        // Verify execution succeeded
        assertEq(results.length, 1, "Should return one result");
        assertEq(mockBlueprint.processedValue(), 12345, "Should have processed uint256 value");
        assertTrue(mockBlueprint.operationSuccess(), "Operation should have succeeded");
    }

    /**
     * @notice Test tractorDynamicData with address data injection
     * @dev Tests transient storage with address type encoding/decoding through getTractorData interface
     */
    function test_DynamicData_ValidAddress() public {
        MockTractorBlueprint mockBlueprint = new MockTractorBlueprint(address(bs));

        // Create pipe call to processAddress function
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(mockBlueprint),
            callData: abi.encodeWithSelector(MockTractorBlueprint.processAddress.selector, 2),
            clipboard: hex"0000"
        });

        // Wrap in farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create requisition
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Create dynamic data with test address
        address testAddress = farmers[1];
        IMockFBeanstalk.ContractData[] memory dynamicData = new IMockFBeanstalk.ContractData[](1);
        dynamicData[0] = IMockFBeanstalk.ContractData({
            key: 2,
            value: abi.encode(testAddress)
        });

        // Execute with dynamic data
        vm.prank(farmers[0]);
        bytes[] memory results = bs.tractorDynamicData(req, "", dynamicData);

        // Verify execution succeeded
        assertEq(results.length, 1, "Should return one result");
        assertEq(mockBlueprint.processedAddress(), testAddress, "Should have processed address value");
        assertTrue(mockBlueprint.operationSuccess(), "Operation should have succeeded");
    }

    /**
     * @notice Test tractorDynamicData with non-existent key
     * @dev Tests getTractorData returns empty bytes for missing keys without reverting
     */
    function test_DynamicData_NonExistentKey() public {
        MockTractorBlueprint mockBlueprint = new MockTractorBlueprint(address(bs));

        // Create pipe call to processNonExistent function
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(mockBlueprint),
            callData: abi.encodeWithSelector(MockTractorBlueprint.processNonExistent.selector, 999),
            clipboard: hex"0000"
        });

        // Wrap in farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create requisition
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Create empty dynamic data array (no key 999)
        IMockFBeanstalk.ContractData[] memory dynamicData = new IMockFBeanstalk.ContractData[](0);

        // Execute with no dynamic data
        vm.prank(farmers[0]);
        bytes[] memory results = bs.tractorDynamicData(req, "", dynamicData);

        // Verify execution succeeded and handled empty data gracefully
        assertEq(results.length, 1, "Should return one result");
        assertTrue(mockBlueprint.operationSuccess(), "Should handle non-existent key gracefully");
    }

    /**
     * @notice Test tractorDynamicData with corrupted data that should revert
     * @dev Tests abi.decode revert propagation when blueprint processes malformed bytes from transient storage
     */
    function test_DynamicData_CorruptedData() public {
        MockTractorBlueprint mockBlueprint = new MockTractorBlueprint(address(bs));

        // Create pipe call to processCorrupted function
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(mockBlueprint),
            callData: abi.encodeWithSelector(MockTractorBlueprint.processCorrupted.selector, 3),
            clipboard: hex"0000"
        });

        // Wrap in farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create requisition
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Create corrupted data (incomplete uint256 encoding)
        IMockFBeanstalk.ContractData[] memory dynamicData = new IMockFBeanstalk.ContractData[](1);
        dynamicData[0] = IMockFBeanstalk.ContractData({
            key: 3,
            value: hex"1234" // Invalid bytes for uint256 decoding
        });

        // Execute with corrupted data - should revert during decoding
        vm.prank(farmers[0]);
        vm.expectRevert();
        bs.tractorDynamicData(req, "", dynamicData);
    }

    /**
     * @notice Test tractorDynamicData with multiple data entries
     * @dev Tests concurrent transient storage key-value pairs with different data types in single execution
     */
    function test_DynamicData_MultipleEntries() public {
        MockTractorBlueprint mockBlueprint = new MockTractorBlueprint(address(bs));

        // Create pipe calls to process both uint256 and address
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](2);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(mockBlueprint),
            callData: abi.encodeWithSelector(MockTractorBlueprint.processUint256.selector, 10),
            clipboard: hex"0000"
        });
        pipes[1] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(mockBlueprint),
            callData: abi.encodeWithSelector(MockTractorBlueprint.processAddress.selector, 20),
            clipboard: hex"0000"
        });

        // Wrap in farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create requisition
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            farmers[0],
            data,
            address(bs)
        );

        // Create multiple dynamic data entries
        address testAddress = farmers[1];
        IMockFBeanstalk.ContractData[] memory dynamicData = new IMockFBeanstalk.ContractData[](2);
        dynamicData[0] = IMockFBeanstalk.ContractData({
            key: 10,
            value: abi.encode(uint256(54321))
        });
        dynamicData[1] = IMockFBeanstalk.ContractData({
            key: 20,
            value: abi.encode(testAddress)
        });

        // Execute with multiple data entries
        vm.prank(farmers[0]);
        bytes[] memory results = bs.tractorDynamicData(req, "", dynamicData);

        // Verify both operations succeeded
        assertEq(results.length, 1, "Should return one result");
        assertEq(mockBlueprint.processedValue(), 54321, "Should have processed uint256 value");
        assertEq(mockBlueprint.processedAddress(), testAddress, "Should have processed address value");
        assertTrue(mockBlueprint.operationSuccess(), "Operation should have succeeded");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";

/**
 * @title MockTractorBlueprint
 * @notice Simple mock blueprint for testing tractorDynamicData functionality
 * @dev Tests generic bytes injection and processing
 */
contract MockTractorBlueprint {
    // Beanstalk address for accessing tractor data
    address public beanstalk;

    // Simple state to verify data was processed
    uint256 public processedValue;
    address public processedAddress;
    bool public operationSuccess;

    constructor(address _beanstalk) {
        beanstalk = _beanstalk;
    }

    /**
     * @notice Process uint256 data from transient storage
     * @param key Key to retrieve data
     */
    function processUint256(uint256 key) external {
        bytes memory data = IMockFBeanstalk(beanstalk).getTractorData(key);

        if (data.length > 0) {
            processedValue = abi.decode(data, (uint256));
            operationSuccess = true;
        }
    }

    /**
     * @notice Process address data from transient storage
     * @param key Key to retrieve data
     */
    function processAddress(uint256 key) external {
        bytes memory data = IMockFBeanstalk(beanstalk).getTractorData(key);

        if (data.length > 0) {
            processedAddress = abi.decode(data, (address));
            operationSuccess = true;
        }
    }

    /**
     * @notice Attempt to process corrupted data (should revert)
     * @param key Key containing invalid bytes
     */
    function processCorrupted(uint256 key) external {
        bytes memory data = IMockFBeanstalk(beanstalk).getTractorData(key);

        if (data.length > 0) {
            // This will revert if bytes are corrupted
            processedValue = abi.decode(data, (uint256));
            operationSuccess = true;
        }
    }

    /**
     * @notice Process non-existent key (should handle gracefully)
     * @param key Non-existent key
     */
    function processNonExistent(uint256 key) external {
        bytes memory data = IMockFBeanstalk(beanstalk).getTractorData(key);

        // Should be empty - set success flag to verify this
        operationSuccess = (data.length == 0);
    }

    // Reset for clean test state
    function reset() external {
        processedValue = 0;
        processedAddress = address(0);
        operationSuccess = false;
    }
}

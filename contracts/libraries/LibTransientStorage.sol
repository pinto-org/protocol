/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {TransientContext} from "transience/src/TransientContext.sol";
import {TransientContextBytes} from "transience/src/TransientContextBytes.sol";

/**
 * @title LibTransientStorage
 * @notice Beanstalk standardized transient storage library
 * @dev Built on ethereum-optimism/transience for reentrancy-safe transient storage
 *
 * This library provides a protocol-wide standard for managing transient storage
 * across the Beanstalk ecosystem. It wraps the transience library to provide:
 *
 * - Gas-efficient temporary storage (EIP-1153 TSTORE/TLOAD)
 * - Reentrancy protection through call depth isolation
 * - Protocol-consistent interface and naming conventions
 * - Type-safe storage operations for common data types
 *
 * Usage patterns:
 * 1. Set temporary values at function entry
 * 2. Access values across contract calls within the same transaction
 * 3. Values automatically cleared at transaction end
 */
library LibTransientStorage {
    // ======================
    // Protocol Slot Constants
    // ======================

    /// @dev Base slot for transient storage
    /// keccak256("transient.storage")
    bytes32 internal constant TRANSIENT_BASE_SLOT =
        0x21694268a7c5ac77b6d1b5484e2e3fdb32f6630b751d62167b57a3cddc7dd1b5;

    /// @dev Slot offset for different data types to avoid collisions
    uint256 internal constant UINT256_OFFSET = 0;
    uint256 internal constant BYTES32_OFFSET = 1000;
    uint256 internal constant ADDRESS_OFFSET = 2000;
    uint256 internal constant BYTES_OFFSET = 3000;

    // ======================
    // Core Storage Functions
    // ======================

    // uint256 Operations
    /**
     * @notice Set a uint256 value in transient storage
     * @param key Unique identifier for the stored value
     * @param value The uint256 value to store
     */
    function setUint256(uint256 key, uint256 value) internal {
        bytes32 slot = _generateSlot(UINT256_OFFSET, key);
        TransientContext.set(slot, value);
    }

    /**
     * @notice Clear a uint256 value from transient storage
     * @dev This is optional since transient storage
     * auto-clears at transaction end
     * @param key Unique identifier for the value to clear
     */
    function clearUint256(uint256 key) internal {
        setUint256(key, 0);
    }

    /**
     * @notice Get a uint256 value from transient storage
     * @param key Unique identifier for the stored value
     * @return value The retrieved uint256 value (0 if not set)
     */
    function getUint256(uint256 key) internal view returns (uint256 value) {
        bytes32 slot = _generateSlot(UINT256_OFFSET, key);
        return TransientContext.get(slot);
    }

    // bytes32 Operations
    /**
     * @notice Set a bytes32 value in transient storage
     * @param key Unique identifier for the stored value
     * @param value The bytes32 value to store
     */
    function setBytes32(uint256 key, bytes32 value) internal {
        bytes32 slot = _generateSlot(BYTES32_OFFSET, key);
        TransientContext.set(slot, uint256(value));
    }

    /**
     * @notice Clear a bytes32 value from transient storage
     * @param key Unique identifier for the value to clear
     */
    function clearBytes32(uint256 key) internal {
        setBytes32(key, 0);
    }

    /**
     * @notice Get a bytes32 value from transient storage
     * @param key Unique identifier for the stored value
     * @return value The retrieved bytes32 value (bytes32(0) if not set)
     */
    function getBytes32(uint256 key) internal view returns (bytes32 value) {
        bytes32 slot = _generateSlot(BYTES32_OFFSET, key);
        return bytes32(TransientContext.get(slot));
    }

    // address Operations
    /**
     * @notice Set an address value in transient storage
     * @param key Unique identifier for the stored value
     * @param value The address value to store
     */
    function setAddress(uint256 key, address value) internal {
        bytes32 slot = _generateSlot(ADDRESS_OFFSET, key);
        TransientContext.set(slot, uint256(uint160(value)));
    }

    /**
     * @notice Clear an address value from transient storage
     * @param key Unique identifier for the value to clear
     */
    function clearAddress(uint256 key) internal {
        setAddress(key, address(0));
    }

    /**
     * @notice Get an address value from transient storage
     * @param key Unique identifier for the stored value
     * @return value The retrieved address value (address(0) if not set)
     */
    function getAddress(uint256 key) internal view returns (address value) {
        bytes32 slot = _generateSlot(ADDRESS_OFFSET, key);
        return address(uint160(TransientContext.get(slot)));
    }

    // bytes Operations
    /**
     * @notice Set arbitrary bytes data in transient storage
     * @param key Unique identifier for the stored value
     * @param value The bytes data to store
     */
    function setBytes(uint256 key, bytes memory value) internal {
        bytes32 slot = _generateSlot(BYTES_OFFSET, key);
        TransientContextBytes.set(slot, value);
    }

    /**
     * @notice Clear bytes data from transient storage
     * @param key Unique identifier for the value to clear
     */
    function clearBytes(uint256 key) internal {
        setBytes(key, "");
    }

    /**
     * @notice Get arbitrary bytes data from transient storage
     * @param key Unique identifier for the stored value
     * @return value The retrieved bytes data (empty bytes if not set)
     */
    function getBytes(uint256 key) internal view returns (bytes memory value) {
        bytes32 slot = _generateSlot(BYTES_OFFSET, key);
        return TransientContextBytes.get(slot);
    }

    // ======================
    // Utility Functions
    // ======================

    /**
     * @notice Get current call depth from transience library
     * @return Current reentrancy call depth
     */
    function getCallDepth() internal view returns (uint256) {
        return TransientContext.callDepth();
    }

    /**
     * @notice Generate a unique storage slot for a key and offset
     * @param offset Offset for data type separation
     * @param key User-provided key
     * @return slot Unique storage slot
     */
    function _generateSlot(uint256 offset, uint256 key) private pure returns (bytes32 slot) {
        return keccak256(abi.encode(TRANSIENT_BASE_SLOT, offset, key));
    }
}

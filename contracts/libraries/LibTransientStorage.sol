/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {TransientContext} from "transience/src/TransientContext.sol";

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
     * @notice Get a uint256 value from transient storage
     * @param key Unique identifier for the stored value
     * @return value The retrieved uint256 value (0 if not set)
     */
    function getUint256(uint256 key) internal view returns (uint256 value) {
        bytes32 slot = _generateSlot(UINT256_OFFSET, key);
        return TransientContext.get(slot);
    }

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
     * @notice Get a bytes32 value from transient storage
     * @param key Unique identifier for the stored value
     * @return value The retrieved bytes32 value (bytes32(0) if not set)
     */
    function getBytes32(uint256 key) internal view returns (bytes32 value) {
        bytes32 slot = _generateSlot(BYTES32_OFFSET, key);
        return bytes32(TransientContext.get(slot));
    }

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
     * @notice Get an address value from transient storage
     * @param key Unique identifier for the stored value
     * @return value The retrieved address value (address(0) if not set)
     */
    function getAddress(uint256 key) internal view returns (address value) {
        bytes32 slot = _generateSlot(ADDRESS_OFFSET, key);
        return address(uint160(TransientContext.get(slot)));
    }

    /**
     * @notice Set arbitrary bytes data in transient storage
     * @dev For bytes data, we store length in one slot and data in subsequent slots
     * @param key Unique identifier for the stored value
     * @param value The bytes data to store
     */
    function setBytes(uint256 key, bytes memory value) internal {
        bytes32 lengthSlot = _generateSlot(BYTES_OFFSET, key);
        TransientContext.set(lengthSlot, value.length);

        // Store data in 32-byte chunks
        uint256 chunks = (value.length + 31) / 32;
        for (uint256 i = 0; i < chunks; i++) {
            bytes32 dataSlot = _generateSlot(BYTES_OFFSET, key + i + 1);
            bytes32 chunk;
            assembly ("memory-safe") {
                chunk := mload(add(add(value, 0x20), mul(i, 0x20)))
            }
            TransientContext.set(dataSlot, uint256(chunk));
        }
    }

    /**
     * @notice Get arbitrary bytes data from transient storage
     * @param key Unique identifier for the stored value
     * @return value The retrieved bytes data (empty bytes if not set)
     */
    function getBytes(uint256 key) internal view returns (bytes memory value) {
        bytes32 lengthSlot = _generateSlot(BYTES_OFFSET, key);
        uint256 length = TransientContext.get(lengthSlot);

        if (length == 0) return value; // Return empty bytes

        value = new bytes(length);
        uint256 chunks = (length + 31) / 32;

        for (uint256 i = 0; i < chunks; i++) {
            bytes32 dataSlot = _generateSlot(BYTES_OFFSET, key + i + 1);
            bytes32 chunk = bytes32(TransientContext.get(dataSlot));
            assembly ("memory-safe") {
                mstore(add(add(value, 0x20), mul(i, 0x20)), chunk)
            }
        }
    }

    /**
     * @notice Clear a value from transient storage (sets to 0)
     * @dev This is optional since transient storage auto-clears at transaction end
     * @param key Unique identifier for the value to clear
     */
    function clearUint256(uint256 key) internal {
        bytes32 slot = _generateSlot(UINT256_OFFSET, key);
        TransientContext.set(slot, 0);
    }

    /**
     * @notice Clear a bytes32 value from transient storage
     * @param key Unique identifier for the value to clear
     */
    function clearBytes32(uint256 key) internal {
        bytes32 slot = _generateSlot(BYTES32_OFFSET, key);
        TransientContext.set(slot, 0);
    }

    /**
     * @notice Clear an address value from transient storage
     * @param key Unique identifier for the value to clear
     */
    function clearAddress(uint256 key) internal {
        bytes32 slot = _generateSlot(ADDRESS_OFFSET, key);
        TransientContext.set(slot, 0);
    }

    /**
     * @notice Clear bytes data from transient storage
     * @param key Unique identifier for the value to clear
     */
    function clearBytes(uint256 key) internal {
        bytes32 lengthSlot = _generateSlot(BYTES_OFFSET, key);
        uint256 length = TransientContext.get(lengthSlot);
        TransientContext.set(lengthSlot, 0);

        // Clear data chunks
        uint256 chunks = (length + 31) / 32;
        for (uint256 i = 0; i < chunks; i++) {
            bytes32 dataSlot = _generateSlot(BYTES_OFFSET, key + i + 1);
            TransientContext.set(dataSlot, 0);
        }
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

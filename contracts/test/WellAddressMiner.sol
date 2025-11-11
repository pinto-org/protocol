// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAquifer} from "../interfaces/basin/IAquifer.sol";

/**
 * @title WellAddressMiner
 * @notice Helper contract to batch predictWellAddress calls for faster vanity address mining
 * @dev Used to mine CREATE2 salts for wells with desired address prefixes
 */
contract WellAddressMiner {
    /**
     * @notice Result of a successful mining attempt
     * @param salt The salt that produced the matching address
     * @param wellAddress The resulting well address
     * @param iterations Number of iterations performed before finding match
     */
    struct MiningResult {
        bytes32 salt;
        address wellAddress;
        uint256 iterations;
    }

    /**
     * @notice Batch mine well addresses by incrementing salt
     * @param aquifer The Aquifer contract to call predictWellAddress on
     * @param implementation The well implementation address
     * @param immutableData The encoded immutable data for the well
     * @param startSalt The starting salt value
     * @param prefixMask Bitmask for the prefix we're looking for (e.g., 0xBEA0000000000000000000000000000000000000)
     * @param prefixTarget Target prefix value after masking (e.g., 0xBEA0000000000000000000000000000000000000)
     * @param batchSize Number of iterations to try (default: 20)
     * @return result The mining result containing salt, address, and iteration count
     * @dev Reverts if no match is found in the batch
     */
    function batchMineAddress(
        IAquifer aquifer,
        address implementation,
        bytes calldata immutableData,
        bytes32 startSalt,
        uint160 prefixMask,
        uint160 prefixTarget,
        uint256 batchSize
    ) external view returns (MiningResult memory result) {
        bytes32 currentSalt = startSalt;

        for (uint256 i = 0; i < batchSize; i++) {
            // Predict well address with current salt
            address predictedAddress = aquifer.predictWellAddress(implementation, immutableData, currentSalt);

            // Check if address matches prefix
            if (uint160(predictedAddress) & prefixMask == prefixTarget) {
                return MiningResult({salt: currentSalt, wellAddress: predictedAddress, iterations: i + 1});
            }

            // Increment salt by 1 for next iteration
            currentSalt = bytes32(uint256(currentSalt) + 1);
        }

        // No match found in this batch
        revert("No matching address found in batch");
    }

    /**
     * @notice Batch mine well addresses with case-insensitive prefix matching
     * @param aquifer The Aquifer contract to call predictWellAddress on
     * @param implementation The well implementation address
     * @param immutableData The encoded immutable data for the well
     * @param startSalt The starting salt value
     * @param prefixBytes The desired prefix as bytes (e.g., hex"bea" for 0xBea...)
     * @param batchSize Number of iterations to try (default: 20)
     * @return result The mining result containing salt, address, and iteration count
     * @dev Reverts if no match is found in the batch
     * @dev Case-insensitive matching: compares lowercase versions of address and prefix
     */
    function batchMineAddressCaseInsensitive(
        IAquifer aquifer,
        address implementation,
        bytes calldata immutableData,
        bytes32 startSalt,
        bytes memory prefixBytes,
        uint256 batchSize
    ) external view returns (MiningResult memory result) {
        require(prefixBytes.length > 0 && prefixBytes.length <= 20, "Invalid prefix length");

        bytes32 currentSalt = startSalt;

        for (uint256 i = 0; i < batchSize; i++) {
            // Predict well address with current salt
            address predictedAddress = aquifer.predictWellAddress(implementation, immutableData, currentSalt);

            // Check if address matches prefix (case-insensitive)
            if (matchesPrefix(predictedAddress, prefixBytes)) {
                return MiningResult({salt: currentSalt, wellAddress: predictedAddress, iterations: i + 1});
            }

            // Increment salt by 1 for next iteration
            currentSalt = bytes32(uint256(currentSalt) + 1);
        }

        // No match found in this batch
        revert("No matching address found in batch");
    }

    /**
     * @notice Check if an address matches a prefix (case-insensitive)
     * @param addr The address to check
     * @param prefixBytes The prefix bytes to match against
     * @return True if the address starts with the prefix
     */
    function matchesPrefix(address addr, bytes memory prefixBytes) internal pure returns (bool) {
        bytes20 addrBytes = bytes20(addr);

        for (uint256 i = 0; i < prefixBytes.length; i++) {
            bytes1 addrByte = addrBytes[i];
            bytes1 prefixByte = prefixBytes[i];

            // Convert both to lowercase for comparison
            bytes1 addrLower = toLowerCase(addrByte);
            bytes1 prefixLower = toLowerCase(prefixByte);

            if (addrLower != prefixLower) {
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Convert a hex character byte to lowercase
     * @param b The byte to convert
     * @return The lowercase version of the byte
     */
    function toLowerCase(bytes1 b) internal pure returns (bytes1) {
        // If uppercase letter (A-F), convert to lowercase (a-f)
        if (b >= 0x41 && b <= 0x46) {
            return bytes1(uint8(b) + 32);
        }
        return b;
    }
}

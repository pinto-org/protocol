/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

/**
 * @title LibTractorStorage
 * @notice Provides access to Tractor's storage structure and state management.
 **/
library LibTractorStorage {
    /**
     * @title TractorStorage
     * @notice Contains all state for the Tractor system.
     * @param blueprintNonce Number of times each blueprint has been run.
     * @param blueprintCounters Publisher address to counter id to counter value mapping.
     * @param activePublisher Publisher of current operations. Set to address(1) when no active publisher.
     * @param version Version of Tractor. Only Blueprints using current Version can run.
     * @param currentBlueprintHash Hash of currently executing blueprint.
     * @param operator Address of the currently executing operator.
     */
    struct TractorStorage {
        mapping(bytes32 => uint256) blueprintNonce;
        mapping(address => mapping(bytes32 => uint256)) blueprintCounters;
        address payable activePublisher;
        string version;
        bytes32 currentBlueprintHash;
        address operator;
    }

    /**
     * @notice Get tractor storage from storage.
     * @return ts Storage object containing tractor data
     */
    function tractorStorage() internal pure returns (TractorStorage storage ts) {
        assembly {
            ts.slot := 0x7efbaaac9214ca1879e26b4df38e29a72561affb741bba775ce66d5bb6a82a07 // keccak256("diamond.storage.tractor")
        }
    }
}
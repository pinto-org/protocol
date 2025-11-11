// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Implementation} from "contracts/beanstalk/storage/System.sol";

/**
 * @title LibImplementation
 * @notice library helper for Implementation struct
 * @dev `Implementation` should be used for calls (static or non static)
 * that MAY require data from the context which it was invoked from.
 * In the case where Implementations have different variants, this library
 * standardizes the call pattern.
 */
library LibImplementation {
    /**
     * @notice Makes a staticcall using Implementation struct
     * @dev Silently fails to prevent reverts, returns empty bytes on failure
     * @param impl The Implementation struct containing target, selector, encodeType, and data
     * @return bytes The return data from the call, or empty bytes if failed
     */
    function staticcall(Implementation memory impl) internal view returns (bytes memory) {
        // TODO: Implement logic based on encodeType
        // For now, stub returns empty bytes
        return new bytes(0);
    }

    /**
     * @notice Makes a call using Implementation struct with additional system data
     * @dev Silently fails to prevent reverts, returns empty bytes on failure
     * @param impl The Implementation struct containing target, selector, encodeType, and data
     * @param sysData Additional system data to be passed in the call
     * @return bytes The return data from the call, or empty bytes if failed
     */
    function call(
        Implementation memory impl,
        bytes memory sysData
    ) internal returns (bytes memory) {
        // TODO: Implement logic based on encodeType and sysData
        // For now, stub returns empty bytes
        return new bytes(0);
    }
}

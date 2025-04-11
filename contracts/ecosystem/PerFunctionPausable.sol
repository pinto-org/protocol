// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PerFunctionPausable
 * @notice Abstract contract that implements per-function pausing functionality
 * @dev Inherit from this contract to add per-function pausing capabilities
 */
abstract contract PerFunctionPausable is Ownable {
    // Function pause flags
    mapping(bytes4 => bool) public functionPaused;

    event FunctionPaused(bytes4 indexed functionSelector, bool isPaused);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Pauses a specific function
     * @param functionSelector The selector of the function to pause
     * @dev Can only be called by owner
     */
    function pauseFunction(bytes4 functionSelector) external onlyOwner {
        functionPaused[functionSelector] = true;
        emit FunctionPaused(functionSelector, true);
    }

    /**
     * @notice Unpauses a specific function
     * @param functionSelector The selector of the function to unpause
     * @dev Can only be called by owner
     */
    function unpauseFunction(bytes4 functionSelector) external onlyOwner {
        functionPaused[functionSelector] = false;
        emit FunctionPaused(functionSelector, false);
    }

    /**
     * @notice Modifier to check if a specific function is paused
     */
    modifier whenFunctionNotPaused() {
        require(!functionPaused[msg.sig], "Function is paused");
        _;
    }
}

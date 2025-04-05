// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OperatorWhitelist
 * @author FordPinto
 * @notice Contract to manage a whitelist of operators
 */

interface IOperatorWhitelist {
    function addOperator(address operator) external;
    function removeOperator(address operator) external;
    function checkOperatorWhitelist(address operator) external view returns (bool);
    function getWhitelistedOperators() external view returns (address[] memory);
}

contract OperatorWhitelist is Ownable, IOperatorWhitelist {
    // Mapping to track whitelisted operators
    mapping(address => bool) public whitelistedOperators;
    // Array to track all whitelisted operators for enumeration
    address[] private operators;

    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Adds an operator to the whitelist
     * @param operator The address to add to the whitelist
     */
    function addOperator(address operator) external onlyOwner {
        require(operator != address(0), "Cannot whitelist zero address");
        require(!whitelistedOperators[operator], "Operator already whitelisted");

        whitelistedOperators[operator] = true;
        operators.push(operator);

        emit OperatorAdded(operator);
    }

    /**
     * @notice Removes an operator from the whitelist
     * @param operator The address to remove from the whitelist
     */
    function removeOperator(address operator) external onlyOwner {
        require(whitelistedOperators[operator], "Operator not whitelisted");

        whitelistedOperators[operator] = false;

        // Remove operator from array by swapping with last element and popping
        for (uint256 i = 0; i < operators.length; i++) {
            if (operators[i] == operator) {
                operators[i] = operators[operators.length - 1];
                operators.pop();
                break;
            }
        }

        emit OperatorRemoved(operator);
    }

    /**
     * @notice Checks if an operator is whitelisted
     * @param operator The address to check
     * @return True if the operator is whitelisted, false otherwise
     */
    function checkOperatorWhitelist(address operator) external view returns (bool) {
        return whitelistedOperators[operator];
    }

    /**
     * @notice Gets all whitelisted operators
     * @return Array of whitelisted operator addresses
     */
    function getWhitelistedOperators() external view returns (address[] memory) {
        return operators;
    }
}

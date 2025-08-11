//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// This is the interface for the fertilizer payback contract.
// It is used to get the remaining fertilizer debt.
interface IBarnPayback {
    // The amount of Bean remaining to pay back barn.
    function barnRemaining() external view returns (uint256);

    // Receive Pinto rewards from shipments
    function barnPaybackReceive(uint256 amount) external;
}

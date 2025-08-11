//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// This is the interface for the unripe silo distributor payback contract.
// It is used to get the remaining silo debt.
interface ISiloPayback {
    // The amount of Bean remaining to pay back silo.
    function siloRemaining() external view returns (uint256);

    // Receive Pinto rewards from shipments
    function siloPaybackReceive(uint256 amount) external;
}

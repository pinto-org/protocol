//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


// Note: Old Assumption that the Payback contract is just one
interface IPayback {
    // The amount of Bean remaining to pay back silo.
    function siloRemaining() external view returns (uint256);

    // The amount of Bean remaining to pay back barn.
    function barnRemaining() external view returns (uint256);
}

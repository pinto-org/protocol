// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface IContractPaybackDistributor {
    function claimDirect(address receiver) external;
    function claimFromL1Message(address caller, address receiver) external;
}
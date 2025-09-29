// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";

interface IContractPaybackDistributor {
    function claimDirect(address receiver, LibTransfer.To siloPaybackToMode) external;
    function claimFromL1Message(address caller, address receiver, LibTransfer.To siloPaybackToMode) external;
}

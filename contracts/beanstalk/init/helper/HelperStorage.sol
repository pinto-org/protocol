/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import {IHelperStorage} from "contracts/interfaces/IHelperStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title HelperStorage
 * @notice A helper contract for diamond initialization.
 * @dev EIP-2535 Diamonds allow for a delegate call from an arbitary contract to be invoked during initialization.
 * There are instances where values are not immediately available, nor able to be fetched on-chain.
 * This contract allows for data to be stored prior to a diamondCut.
 * protocols that ultilize this contract implicitly trust 1) the owner of the contract, and 2) the values set.
 **/
contract HelperStorage is Ownable, IHelperStorage {
    constructor() Ownable(msg.sender) {}
    mapping(uint256 key => bytes value) public helperStorage;

    event ValueSet(uint256 indexed key, bytes value);

    function setValue(uint256 key, bytes memory value) external onlyOwner {
        helperStorage[key] = value;
        emit ValueSet(key, value);
    }

    function getValue(uint256 key) external view returns (bytes memory) {
        return helperStorage[key];
    }
}

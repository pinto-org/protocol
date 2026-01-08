/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

/**
 * @title IHelperStorage
 * @notice An interface for a helper contract for Diamond initialization.
 * @dev EIP-2535 Diamonds allow for a delegate call from an arbitrary contract to be invoked during initialization.
 * There are instances where values are not immediately available, nor able to be fetched on-chain.
 * This interface provides a standard way to set and get values prior to a diamondCut.
 **/
interface IHelperStorage {
    function setValue(uint256 key, bytes memory value) external;
    function getValue(uint256 key) external view returns (bytes memory);
}

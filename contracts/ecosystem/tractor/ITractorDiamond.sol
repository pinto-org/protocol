// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITractorDiamond {
    event TractorDataPublished(uint8 version, bytes data);
    event MultiTractorDataPublished(uint8 version, bytes[] data);
    /**
     * @notice Publish Tractor data
     * @param version The version of the Tractor data
     * @param data The Tractor data
     */
    function publishTractorData(uint8 version, bytes calldata data) external;

    /**
     * @notice Publish multiple Tractor data
     * @param version The version of the Tractor data
     * @param data The Tractor data array
     */
    function publishMultiTractorData(uint8 version, bytes[] calldata data) external;
}

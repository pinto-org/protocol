// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title MockERC1271
 * @notice Mock contract for testing EIP-1271 signature validation in Tractor
 * @dev Implements IERC1271 with a state-managed boolean to control signature validation
 */
contract MockERC1271 is IERC1271 {
    // Magic value as defined in EIP-1271
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    // State variable to control signature validation
    bool private isValidSig;

    /**
     * @notice Constructor to set initial validation state
     * @param _isValid Initial signature validation state
     */
    constructor(bool _isValid) {
        isValidSig = _isValid;
    }

    /**
     * @notice Validates signatures according to EIP-1271
     * @param hash Hash of the data to be signed
     * @param signature Signature byte array
     * @return magicValue Returns magic value if signature is valid, otherwise returns invalid value
     */
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override
        returns (bytes4 magicValue)
    {
        // Return magic value if valid, otherwise return invalid bytes4
        return isValidSig ? MAGICVALUE : bytes4(0xffffffff);
    }

    /**
     * @notice Setter to control signature validation state
     * @param _isValid New validation state
     */
    function setIsValidSignature(bool _isValid) external {
        isValidSig = _isValid;
    }

    /**
     * @notice Getter to check current validation state
     * @return Current validation state
     */
    function getIsValidSignature() external view returns (bool) {
        return isValidSig;
    }
}

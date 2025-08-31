
/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

/**
 * checks if an account is a contract using assembly
 */
contract MockIsContract {
    /**
     * @notice Checks if an account is a contract.
     */
    function isContract(address account) public view returns (bool) {
        uint size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}
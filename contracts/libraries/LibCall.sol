// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LibCall
 * @notice library helper for IWell.Call
 */
library LibCall {
    // note: silently fails to prevent reverts
    function staticcall(Call memory c) internal view returns (bytes memory) {
        (bool success, bytes memory output) = c.target.staticcall(c.data);
        if (success) {
            return output;
        } else {
            return new bytes();
        }
    }

    // note: silently fails to prevent reverts
    function call(Call memory c) internal returns (bytes memory) {
        (bool success, bytes memory output) = c.target.staticcall(c.data);
        if (success) {
            return output;
        } else {
            return new bytes();
        }
    }
}

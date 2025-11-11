// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Call} from "contracts/interfaces/basin/IWell.sol";

/**
 * @title LibCall
 * @notice library helper for IWell.Call
 * @dev `Call` should be used for internal/external calls that MUST NOT require additional data
 * from the protocol itself. In other words, `Call.data` is always static.
 */
library LibCall {
    // note: silently fails to prevent reverts
    function staticcall(Call memory c) internal view returns (bytes memory) {
        (bool success, bytes memory output) = c.target.staticcall(c.data);
        if (success) {
            return output;
        } else {
            return new bytes(0);
        }
    }

    // note: silently fails to prevent reverts
    function call(Call memory c) internal returns (bytes memory) {
        (bool success, bytes memory output) = c.target.call(c.data);
        if (success) {
            return output;
        } else {
            return new bytes(0);
        }
    }
}

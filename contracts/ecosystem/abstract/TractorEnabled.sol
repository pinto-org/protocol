// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";

/**
 * @title TractorEnabled
 * @notice Enables any contract to allow for tractor functionality by exposing the necessary shared state and functions
 * If a contract wants to allow a function to be called by a tractor operator on behalf of a blueprint publisher,
 * It should simply perform a call to _getBeanstalkFarmer() and use the returned address as the msg.sender
 */
abstract contract TractorEnabled {
    /// @dev All contracts using tractor must call the diamond to get the active user
    IBeanstalk public pintoProtocol;

    /**
     * @notice Gets the active user account from the diamond tractor storage
     * The account returned is either msg.sender or an active tractor publisher
     * Since msg.sender for the external call is the caller contract, we need to adjust
     * it to the actual function caller
     */
    function _getBeanstalkFarmer() internal view returns (address) {
        address tractorAccount = pintoProtocol.tractorUser();
        return tractorAccount == address(this) ? msg.sender : tractorAccount;
    }
}

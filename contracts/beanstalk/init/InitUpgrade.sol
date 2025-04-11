/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import {AppStorage, LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {ShipmentRoute, ShipmentRecipient} from "contracts/beanstalk/storage/System.sol";

/**
 * @title InitEmpty is used for creating empty BIPs on test networks
 **/
contract InitUpgrade {
    AppStorage internal s;

    function init() external {}
}

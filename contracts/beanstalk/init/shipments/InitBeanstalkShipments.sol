/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import "contracts/libraries/LibAppStorage.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {ShipmentRoute} from "contracts/beanstalk/storage/System.sol";

/**
 * @title InitBeanstalkShipments modifies the existing routes to split the payback shipments into 2 routes.
 * The first route is the silo payback contract and the second route is the barn payback contract.
 **/
contract InitBeanstalkShipments {

    event ShipmentRoutesSet(ShipmentRoute[] newRoutes);

    function init(ShipmentRoute[] calldata newRoutes) external {
        // set the shipment routes, replaces the entire set of routes
        _setShipmentRoutes(newRoutes);
    }

    /**
     * @notice Replaces the entire set of ShipmentRoutes with a new set. (from Distribution.sol)
     * @dev Solidity does not support direct assignment of array structs to Storage.
     */
    function _setShipmentRoutes(ShipmentRoute[] calldata newRoutes) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        delete s.sys.shipmentRoutes;
        for (uint256 i; i < newRoutes.length; i++) {
            s.sys.shipmentRoutes.push(newRoutes[i]);
        }
        emit ShipmentRoutesSet(newRoutes);
    }
}

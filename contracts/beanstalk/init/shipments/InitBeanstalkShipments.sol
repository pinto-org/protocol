/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import "contracts/libraries/LibAppStorage.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {ShipmentPlanner} from "contracts/ecosystem/ShipmentPlanner.sol";
import {ShipmentRoute} from "contracts/beanstalk/storage/System.sol";

/**
 * @title InitBeanstalkShipments modifies the existing routes to split the payback shipments into 2 routes.
 * The first route is the silo payback contract and the second route is the barn payback contract.
 **/
contract InitBeanstalkShipments {
    function init(ShipmentRoute[] calldata routes) external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // deploy the new shipment planner
        address shipmentPlanner = address(new ShipmentPlanner(address(this), s.sys.bean));

        // set the shipment routes
        _resetShipmentRoutes(shipmentPlanner, routes);
    }

    /**
     * @notice Sets the shipment routes to the field, silo and dev budget.
     * @dev Solidity does not support direct assignment of array structs to Storage.
     */
    function _resetShipmentRoutes(
        address shipmentPlanner,
        ShipmentRoute[] calldata routes
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // pop all the old routes that use the old shipment planner
        while (s.sys.shipmentRoutes.length > 0) {
            s.sys.shipmentRoutes.pop();
        }
        // push the new routes that use the new shipment planner
        for (uint256 i; i < routes.length; i++) {
            s.sys.shipmentRoutes.push(routes[i]);
        }
    }
}

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

    uint256 constant REPAYMENT_FIELD_ID = 1;
    /// @dev total length of the podline. The largest index in beanstalk_field.json incremented by the amount.
    uint256 constant REPAYMENT_FIELD_PODS = 919768387056514;

    event ShipmentRoutesSet(ShipmentRoute[] newRoutes);
    event FieldAdded(uint256 fieldId);

    function init(ShipmentRoute[] calldata newRoutes) external {
        // set the shipment routes, replaces the entire set of routes
        _setShipmentRoutes(newRoutes);
        // create the repayment field
        _initReplaymentField();
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

    /**
     * @notice Create new field, mimics the addField function in FieldFacet.sol
     */
    function _initReplaymentField() internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(s.sys.fieldCount == 1, "Repayment field already exists");
        uint256 fieldId = s.sys.fieldCount;
        s.sys.fieldCount++;
        // init global state for new field, 
        // harvestable and harvested vars are 0 since we shifted all plots in the data to start from 0
        s.sys.fields[REPAYMENT_FIELD_ID].pods = REPAYMENT_FIELD_PODS;
        emit FieldAdded(fieldId);
    }
}

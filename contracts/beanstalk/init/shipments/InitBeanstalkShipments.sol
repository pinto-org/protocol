/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import "contracts/libraries/LibAppStorage.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {ShipmentRoute} from "contracts/beanstalk/storage/System.sol";
import {Implementation} from "contracts/beanstalk/storage/System.sol";
import {ISiloPayback} from "contracts/interfaces/ISiloPayback.sol";
import {LibTokenHook} from "contracts/libraries/Token/LibTokenHook.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";

/**
 * @title InitBeanstalkShipments modifies the existing routes to split the payback shipments into 2 routes.
 * The first route is the silo payback contract and the second route is the barn payback contract.
 **/
contract InitBeanstalkShipments {
    uint256 constant REPAYMENT_FIELD_ID = 1;

    /// @dev total length of the podline.
    // The largest index in beanstalk_field.json incremented by the corresponding amount.
    uint256 constant REPAYMENT_FIELD_PODS = 919768387056514;

    function init(ShipmentRoute[] calldata newRoutes, address siloPayback) external {
        // set the shipment routes, replaces the entire set of routes
        IBeanstalk(address(this)).setShipmentRoutes(newRoutes);
        // create the repayment field
        _initRepaymentField();
        // add the pre-transfer hook for silo payback
        _addSiloPaybackHook(siloPayback);
    }

    /**
     * @notice Create new field and initialize it with the Beanstalk Podline data.
     */
    function _initRepaymentField() internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        IBeanstalk(address(this)).addField();
        // harvestable and harvested vars are 0 since all plots in the data were shifted to start from 0
        s.sys.fields[REPAYMENT_FIELD_ID].pods = REPAYMENT_FIELD_PODS;
    }

    /**
     * @notice Adds the internal pre-transfer hook to sync state on the silo payback contract between internal transfers.
     */
    function _addSiloPaybackHook(address siloPayback) internal {
        LibTokenHook.addTokenHook(
            siloPayback,
            Implementation({
                target: address(siloPayback),
                selector: ISiloPayback.protocolUpdate.selector,
                encodeType: 0x00,
                data: "" // data is unused here
            })
        );
    }
}

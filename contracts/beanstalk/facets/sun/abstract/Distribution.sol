// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {ShipmentRoute} from "contracts/beanstalk/storage/System.sol";
import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";

/**
 * @title Distribution
 * @notice Handles shipping of new Bean mints.
 */
abstract contract Distribution is ReentrancyGuard {
    using SafeCast for uint256;

    /**
     * @notice Emitted when the shipment routes in storage are replaced with a new set of routes.
     * @param newShipmentRoutes New set of ShipmentRoutes.
     */
    event ShipmentRoutesSet(ShipmentRoute[] newShipmentRoutes);

    //////////////////// REWARD BEANS ////////////////////

    /**
     * @notice Gets the current set of ShipmentRoutes.
     */
    function getShipmentRoutes() external view returns (ShipmentRoute[] memory) {
        return s.sys.shipmentRoutes;
    }

    /**
     * @notice Replaces the entire set of ShipmentRoutes with a new set.
     * If the planContract is set to address(0), the target is set as the diamond itself.
     * @dev Changes take effect immediately and will be seen at the next sunrise mint.
     */
    function setShipmentRoutes(ShipmentRoute[] memory shipmentRoutes) external {
        LibDiamond.enforceIsOwnerOrContract();
        delete s.sys.shipmentRoutes;
        for (uint256 i; i < shipmentRoutes.length; i++) {
            shipmentRoutes[i].planContract == address(0)
                ? shipmentRoutes[i].planContract = address(this)
                : shipmentRoutes[i].planContract;
            s.sys.shipmentRoutes.push(shipmentRoutes[i]);
        }
        emit ShipmentRoutesSet(shipmentRoutes);
    }
}

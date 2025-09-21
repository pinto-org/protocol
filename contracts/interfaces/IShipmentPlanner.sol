// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ShipmentPlan} from "contracts/ecosystem/tractor/blueprints/ShipmentPlanner.sol";

interface IShipmentPlanner {
    function getFieldPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan);

    function getSiloPlan(bytes memory) external pure returns (ShipmentPlan memory shipmentPlan);

    function getBudgetPlan(bytes memory) external view returns (ShipmentPlan memory shipmentPlan);

    function getPaybackFieldPlan(
        bytes memory data
    ) external pure returns (ShipmentPlan memory shipmentPlan);

    function getPaybackPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShipmentPlan, IBeanstalk} from "contracts/ecosystem/tractor/blueprints/ShipmentPlanner.sol";

/**
 * @title ShipmentPlanner
 * @notice Same as standard Shipment planner, but implements two Fields with different points.
 */
contract MockShipmentPlanner {
    uint256 constant SILO_POINTS = 5_000_000_000_000_000;
    uint256 constant FIELD_1_POINTS = 5_000_000_000_000_000;
    uint256 constant FIELD_0_POINTS = FIELD_1_POINTS / 5;

    IBeanstalk beanstalk;
    IERC20 bean;

    constructor(address beanstalkAddress, address beanAddress) {
        beanstalk = IBeanstalk(beanstalkAddress);
        bean = IERC20(beanAddress);
    }

    function getSiloPlan(bytes memory) external pure returns (ShipmentPlan memory shipmentPlan) {
        return ShipmentPlan({points: SILO_POINTS, cap: type(uint256).max});
    }

    function getFieldPlanMulti(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan) {
        uint256 fieldId = abi.decode(data, (uint256));
        require(fieldId < beanstalk.fieldCount(), "Field does not exist");
        if (!beanstalk.isHarvesting(fieldId)) return shipmentPlan;
        uint256 points;
        if (fieldId == 0) points = FIELD_0_POINTS;
        else if (fieldId == 1) points = FIELD_1_POINTS;
        else revert("Field plan does not exist");
        return ShipmentPlan({points: points, cap: beanstalk.totalUnharvestable(fieldId)});
    }
}

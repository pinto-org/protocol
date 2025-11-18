/**
 * SPDX-License-Identifier: MIT
 **/
pragma solidity ^0.8.20;
pragma abicoder v2;

import {IMockFBeanstalk as IBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {MockPayback} from "contracts/mocks/MockPayback.sol";
import {MockBudget} from "contracts/mocks/MockBudget.sol";
import {Utils, console} from "test/foundry/utils/Utils.sol";
import {C} from "contracts/C.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {MockShipmentPlanner} from "contracts/mocks/MockShipmentPlanner.sol";

// Extend the interface to support Fields with different points.
interface IMockShipmentPlanner is IMockFBeanstalk {
    function getFieldPlanMulti(bytes memory data) external view returns (ShipmentPlan memory);
    function getPaybackPlan(bytes memory data) external view returns (ShipmentPlan memory);
}

/**
 * @title ShipmentDeployer
 * @notice Test helper contract to deploy ShipmentPlanner and set Routes.
 */
contract ShipmentDeployer is Utils {
    // address(0) == address(this) == ShipmentPlannerFacet
    address defaultShipmentPlanner;
    // Mock external contract to test decoupling from ShipmentPlannerFacet
    address mockShipmentPlanner;

    // Deploy fake budget address.
    address budget;
    // Deploy fake payback contract.
    address payback;

    function initShipping(bool verbose) internal {
        bs = IBeanstalk(BEANSTALK);

        // Create Field, set active, and initialize Temperature.
        vm.prank(deployer);
        bs.addField();
        vm.prank(deployer);
        bs.setActiveField(0, 1e6);

        // Deploy fake budget address.
        budget = address(new MockBudget());
        // Deploy fake payback contract.
        payback = address(new MockPayback(BEAN));

        // Deploy the planner, which will determine points and caps of each route.
        defaultShipmentPlanner = address(0);
        mockShipmentPlanner = address(new MockShipmentPlanner(BEANSTALK, BEAN));

        // TODO: Update this with new routes.
        // Set up two routes: the Silo and a Field.
        setRoutes_siloAndField();
    }

    /**
     * @notice Set the shipment routes to only the Silo. It will receive 100% of Mints.
     */
    function setRoutes_silo() internal {
        IBeanstalk.ShipmentRoute[] memory shipmentRoutes = new IBeanstalk.ShipmentRoute[](1);
        shipmentRoutes[0] = IBeanstalk.ShipmentRoute({
            planContract: defaultShipmentPlanner,
            planSelector: IMockFBeanstalk.getSiloPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.SILO,
            data: abi.encode("")
        });
        vm.prank(deployer);
        bs.setShipmentRoutes(shipmentRoutes);
    }

    /**
     * @notice Set the shipment routes to the Silo and 1 Field. Each will receive 1/2 of Mints.
     * @dev Need to add Fields before calling.
     */
    function setRoutes_siloAndField() internal {
        IBeanstalk.ShipmentRoute[] memory shipmentRoutes = new IBeanstalk.ShipmentRoute[](2);
        shipmentRoutes[0] = IBeanstalk.ShipmentRoute({
            planContract: defaultShipmentPlanner,
            planSelector: IMockFBeanstalk.getSiloPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.SILO,
            data: abi.encode("")
        });
        shipmentRoutes[1] = IBeanstalk.ShipmentRoute({
            planContract: defaultShipmentPlanner,
            planSelector: IMockFBeanstalk.getFieldPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.FIELD,
            data: abi.encode(uint256(0))
        });
        vm.prank(deployer);
        bs.setShipmentRoutes(shipmentRoutes);
    }

    function setRoutes_siloAndFields() internal {
        uint256 fieldCount = IBeanstalk(BEANSTALK).fieldCount();
        IBeanstalk.ShipmentRoute[] memory shipmentRoutes = new IBeanstalk.ShipmentRoute[](
            1 + fieldCount
        );
        shipmentRoutes[0] = IBeanstalk.ShipmentRoute({
            planContract: defaultShipmentPlanner,
            planSelector: IMockFBeanstalk.getSiloPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.SILO,
            data: abi.encode("")
        });
        for (uint256 i = 0; i < fieldCount; i++) {
            shipmentRoutes[i + 1] = IBeanstalk.ShipmentRoute({
                planContract: defaultShipmentPlanner,
                planSelector: IMockFBeanstalk.getFieldPlan.selector,
                recipient: IBeanstalk.ShipmentRecipient.FIELD,
                data: abi.encode(i)
            });
        }
        vm.prank(deployer);
        bs.setShipmentRoutes(shipmentRoutes);
    }

    /**
     * @notice Set the shipment routes to the Silo, one active Field, and one reduced Field.
     *         Mints are split 5/5/1, respectively.
     * @dev Need to add Fields before calling.
     */
    function setRoutes_siloAndTwoFields() internal {
        uint256 fieldCount = IBeanstalk(BEANSTALK).fieldCount();
        require(fieldCount == 2, "Must have 2 Fields to set routes");
        IBeanstalk.ShipmentRoute[] memory shipmentRoutes = new IBeanstalk.ShipmentRoute[](
            1 + fieldCount
        );
        shipmentRoutes[0] = IBeanstalk.ShipmentRoute({
            planContract: mockShipmentPlanner,
            planSelector: IMockFBeanstalk.getSiloPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.SILO,
            data: abi.encodePacked("")
        });
        // MockShipmentPlanner
        shipmentRoutes[1] = IBeanstalk.ShipmentRoute({
            planContract: mockShipmentPlanner,
            planSelector: IMockShipmentPlanner.getFieldPlanMulti.selector,
            recipient: IBeanstalk.ShipmentRecipient.FIELD,
            data: abi.encodePacked(uint256(0))
        });
        shipmentRoutes[2] = IBeanstalk.ShipmentRoute({
            planContract: mockShipmentPlanner,
            planSelector: IMockShipmentPlanner.getFieldPlanMulti.selector,
            recipient: IBeanstalk.ShipmentRecipient.FIELD,
            data: abi.encodePacked(uint256(1))
        });
        vm.prank(deployer);
        bs.setShipmentRoutes(shipmentRoutes);
    }

    /**
     * @notice Set the shipment routes to the Silo, one active Field, one reduced Field,
     *         the budget and payback contracts.
     *         Mints are split 50/50/1/3/2, respectively.
     * @dev Need to add Fields before calling.
     */
    function setRoutes_all() internal {
        uint256 fieldCount = IBeanstalk(BEANSTALK).fieldCount();
        require(fieldCount == 2, "Must have 2 Fields to set routes");
        require(IBeanstalk(BEANSTALK).activeField() == 0, "Acive field must be 0");
        IBeanstalk.ShipmentRoute[] memory shipmentRoutes = new IBeanstalk.ShipmentRoute[](5);

        // Silo.
        shipmentRoutes[0] = IBeanstalk.ShipmentRoute({
            planContract: defaultShipmentPlanner,
            planSelector: IMockFBeanstalk.getSiloPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.SILO,
            data: abi.encode("")
        });
        // Active Field.
        shipmentRoutes[1] = IBeanstalk.ShipmentRoute({
            planContract: defaultShipmentPlanner,
            planSelector: IMockFBeanstalk.getFieldPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.FIELD,
            data: abi.encode(uint256(0))
        });
        // Second Field (1/3 of payback).
        shipmentRoutes[2] = IBeanstalk.ShipmentRoute({
            planContract: defaultShipmentPlanner,
            planSelector: IMockFBeanstalk.getPaybackFieldPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.FIELD,
            data: abi.encode(uint256(1), payback)
        });
        // Budget.
        shipmentRoutes[3] = IBeanstalk.ShipmentRoute({
            planContract: defaultShipmentPlanner,
            planSelector: IMockFBeanstalk.getBudgetPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.INTERNAL_BALANCE,
            data: abi.encode(budget)
        });
        // Payback.
        shipmentRoutes[4] = IBeanstalk.ShipmentRoute({
            planContract: defaultShipmentPlanner,
            planSelector: IMockShipmentPlanner.getPaybackPlan.selector,
            recipient: IBeanstalk.ShipmentRecipient.EXTERNAL_BALANCE,
            data: abi.encode(payback) // sends to payback contract
        });

        vm.prank(deployer);
        bs.setShipmentRoutes(shipmentRoutes);
    }
}

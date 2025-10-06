// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISiloPayback} from "contracts/interfaces/ISiloPayback.sol";
import {IBarnPayback} from "contracts/interfaces/IBarnPayback.sol";
import {LibAppStorage, AppStorage} from "contracts/libraries/LibAppStorage.sol";

/**
 * @notice Constraints of how many Beans to send to a given route at the current time.
 * @param points Weight of this shipment route relative to all routes. Expects precision of 1e18.
 * @param cap Maximum Beans that can be received by this stream at this time.
 */
struct ShipmentPlan {
    uint256 points;
    uint256 cap;
}

/**
 * @title ShipmentPlannerFacet
 * @notice Contains getters for retrieving ShipmentPlans for various Beanstalk components.
 * @dev Called via staticcall. New plan getters must be view/pure functions.
 */
contract ShipmentPlannerFacet {
    uint256 internal constant PRECISION = 1e18;

    uint256 constant FIELD_POINTS = 48_500_000_000_000_000; // 48.5%
    uint256 constant SILO_POINTS = 48_500_000_000_000_000; // 48.5%
    uint256 constant BUDGET_POINTS = 3_000_000_000_000_000; // 3%
    // Individual payback points
    uint256 constant PAYBACK_FIELD_POINTS = 1_000_000_000_000_000; // 1%
    uint256 constant PAYBACK_SILO_POINTS = 1_000_000_000_000_000; // 1%
    uint256 constant PAYBACK_BARN_POINTS = 1_000_000_000_000_000; // 1%
    // Payback points with inactive routes
    uint256 constant PAYBACK_SILO_POINTS_NO_BARN = 1_500_000_000_000_000; // 1.5%
    uint256 constant PAYBACK_FIELD_POINTS_NO_BARN = 1_500_000_000_000_000; // 1.5%
    uint256 constant PAYBACK_FIELD_POINTS_ONLY_FIELD = 3_000_000_000_000_000; // 3%

    uint256 constant SUPPLY_BUDGET_FLIP = 1_000_000_000e6;

    /**
     * @notice Get the current points and cap for Field shipments.
     * @dev The Field cap is the amount of outstanding Pods unharvestable pods.
     * @param data Encoded uint256 containing the index of the Field to receive the Beans.
     */
    function getFieldPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 fieldId = abi.decode(data, (uint256));
        require(fieldId < s.sys.fieldCount, "Field does not exist");
        uint256 unharvestable = totalUnharvestable(fieldId);
        if (unharvestable == 0) return shipmentPlan;
        return ShipmentPlan({points: FIELD_POINTS, cap: unharvestable});
    }

    /**
     * @notice Get the current points and cap for Silo shipments.
     * @dev The Silo has no cap.
     * @dev data param is unused data to configure plan details.
     */
    function getSiloPlan(bytes memory) external pure returns (ShipmentPlan memory shipmentPlan) {
        return ShipmentPlan({points: SILO_POINTS, cap: type(uint256).max});
    }

    /**
     * @notice Get the current points and cap for budget shipments.
     * @dev data param is unused data to configure plan details.
     * @dev Reverts if the Bean supply is greater than the flipping point.
     * @dev Has a hard cap of 3% of the current season standard minted Beans.
     */
    function getBudgetPlan(bytes memory) external view returns (ShipmentPlan memory shipmentPlan) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 budgetRatio = budgetMintRatio();
        require(
            budgetRatio > 0,
            "ShipmentPlanner: Supply above flipping point, no budget allocation"
        );
        uint256 points = (BUDGET_POINTS * budgetRatio) / PRECISION;
        uint256 cap = (s.sys.season.standardMintedBeans * 3) / 100;
        return ShipmentPlan({points: points, cap: cap});
    }

    /**
     * @notice Get the current points and cap for the Field portion of payback shipments.
     * @dev data here in addition to the payback coontracts, contains the payback field id endoded as the third parameter.
     */
    function getPaybackFieldPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 paybackRatio = calcAndEnforceActivePayback();
        // since payback is active, fetch the remaining payback amounts
        (uint256 siloRemaining, uint256 barnRemaining) = paybacksRemaining(data);

        // get field id from data (third encoded parameter)
        (, , uint256 fieldId) = abi.decode(data, (address, address, uint256));

        // Add strict % limits.
        // Order of payback based on size of debt is:
        // 1. Barn: fert will be paid off first
        // 2. Silo: silo will be paid off second
        // 3. Field: field will be paid off last
        uint256 points;
        uint256 maxCap;
        // silo is second thing to be paid off so if remaining is 0 then all points go to field
        if (siloRemaining == 0) {
            points = PAYBACK_FIELD_POINTS_ONLY_FIELD;
            maxCap = (s.sys.season.standardMintedBeans * 3) / 100; // 3%
        } else if (barnRemaining == 0) {
            // if barn remaining is 0 then 1.5% of all mints goes to silo and 1.5% goes to the field
            points = PAYBACK_FIELD_POINTS_NO_BARN;
            maxCap = (s.sys.season.standardMintedBeans * 15) / 1000; // 1.5%
        } else {
            // else, all are active and 1% of all mints goes to field, 1% goes to silo, 1% goes to fert
            points = PAYBACK_FIELD_POINTS;
            maxCap = s.sys.season.standardMintedBeans / 100; // 1%
        }
        // the absolute cap of all mints is the remaining field debt
        uint256 cap = min(totalUnharvestable(fieldId), maxCap);

        // Scale points by distance to threshold.
        points = (points * paybackRatio) / PRECISION;

        return ShipmentPlan({points: points, cap: cap});
    }

    /**
     * @notice Get the current points and cap for the Silo portion of payback shipments.
     * @dev data param contains the silo and barn payback contract addresses to get the remaining paybacks.
     * @dev The silo is the second payback to be paid off.
     */
    function getPaybackSiloPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // calculate the payback ratio and enforce that payback is active
        uint256 paybackRatio = calcAndEnforceActivePayback();
        // since payback is active, fetch the remaining paybacks
        (uint256 siloRemaining, uint256 barnRemaining) = paybacksRemaining(data);

        // if silo is paid off, no need to send pinto to it.
        if (siloRemaining == 0) return ShipmentPlan({points: 0, cap: siloRemaining});

        uint256 points;
        uint256 maxCap;
        // if silo is not paid off and fert is paid off then we need to increase the
        // the points that should go to the silo to 1,5% (finalAllocation = 1,5% to silo, 1,5% to field)
        if (barnRemaining == 0) {
            // half of the paid off fert points go to silo
            points = PAYBACK_SILO_POINTS_NO_BARN; // 1.5%
            maxCap = (s.sys.season.standardMintedBeans * 15) / 1000; // 1.5%
        } else {
            // if silo is not paid off and fert is not paid off then just assign the regular 1% points
            points = PAYBACK_SILO_POINTS;
            maxCap = s.sys.season.standardMintedBeans / 100; // 1%
        }
        // the absolute cap of all mints is the remaining silo debt
        uint256 cap = min(siloRemaining, maxCap);

        // Scale the points by the payback ratio
        points = (points * paybackRatio) / PRECISION;
        return ShipmentPlan({points: points, cap: cap});
    }

    /**
     * @notice Get the current points and cap for the Barn portion of payback shipments.
     * @dev data param contains the silo and barn payback contract addresses to get the remaining paybacks.
     * @dev The barn is the first payback to be paid off.
     */
    function getPaybackBarnPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // calculate the payback ratio and enforce that payback is active
        uint256 paybackRatio = calcAndEnforceActivePayback();
        // since payback is active, fetch the remaining barn debt
        (, uint256 barnRemaining) = paybacksRemaining(data);

        uint256 points;
        uint256 cap;
        if (barnRemaining == 0) {
            // if fert is paid off, no need to send pintos to it.
            return ShipmentPlan({points: 0, cap: 0}); // 0% to barn
        } else {
            points = PAYBACK_BARN_POINTS; // 1% to barn, 2% to the rest
            // the absolute cap of all mints is the remaining barn debt
            cap = min(barnRemaining, s.sys.season.standardMintedBeans / 100);
        }

        // Scale the points by the payback ratio
        points = (points * paybackRatio) / PRECISION;
        return ShipmentPlan({points: points, cap: cap});
    }

    /**
     * @notice Returns a ratio to scale the seasonal mints between budget and payback.
     */
    function budgetMintRatio() private view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 beanSupply = IERC20(s.sys.bean).totalSupply();
        uint256 seasonalMints = s.sys.season.standardMintedBeans;

        // 0% to budget.
        if (beanSupply > SUPPLY_BUDGET_FLIP + seasonalMints) {
            return 0;
        }
        // 100% to budget.
        else if (beanSupply + seasonalMints <= SUPPLY_BUDGET_FLIP) {
            return PRECISION;
        }
        // Partial budget allocation.
        else {
            uint256 remainingBudget = SUPPLY_BUDGET_FLIP - (beanSupply - seasonalMints);
            return (remainingBudget * PRECISION) / seasonalMints;
        }
    }

    /**
     * @notice Returns the remaining pinto to be paid off for the silo and barn payback contracts.
     * @dev When encoding shipment routes for payback contracts, care must be taken to ensure
     * the silo and barn payback contract addresses are encoded first in `data` in the correct order.
     * @return siloRemaining The remaining pinto to be paid off for the silo payback contract.
     * @return barnRemaining The remaining pinto to be paid off for the barn payback contract.
     */
    function paybacksRemaining(
        bytes memory data
    ) private view returns (uint256 siloRemaining, uint256 barnRemaining) {
        (address siloPaybackContract, address barnPaybackContract) = abi.decode(
            data,
            (address, address)
        );
        siloRemaining = ISiloPayback(siloPaybackContract).siloRemaining();
        barnRemaining = IBarnPayback(barnPaybackContract).barnRemaining();
    }

    /**
     * @notice Calculates the payback ratio and enforces that payback is active, above the specified supply threshold.
     * @return paybackRatio The ratio to allocate new mints to beanstalk payback.
     */
    function calcAndEnforceActivePayback() private view returns (uint256 paybackRatio) {
        paybackRatio = PRECISION - budgetMintRatio();
        require(
            paybackRatio > 0,
            "ShipmentPlanner: Supply above flipping point, no payback allocation"
        );
    }

    /**
     * @notice Returns the number of Pods that are not yet Harvestable. Also known as the Pod Line.
     * @param fieldId The index of the Field to query.
     */
    function totalUnharvestable(uint256 fieldId) private view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.sys.fields[fieldId].pods - s.sys.fields[fieldId].harvestable;
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

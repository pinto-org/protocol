// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Season} from "contracts/beanstalk/storage/System.sol";
import {IBudget} from "contracts/interfaces/IBudget.sol";
import {ISiloPayback} from "contracts/interfaces/ISiloPayback.sol";
import {IBarnPayback} from "contracts/interfaces/IBarnPayback.sol";

/**
 * @notice Constraints of how many Beans to send to a given route at the current time.
 * @param points Weight of this shipment route relative to all routes. Expects precision of 1e18.
 * @param cap Maximum Beans that can be received by this stream at this time.
 */
struct ShipmentPlan {
    uint256 points;
    uint256 cap;
}

interface IBeanstalk {
    function isHarvesting(uint256 fieldId) external view returns (bool);

    function totalUnharvestable(uint256 fieldId) external view returns (uint256);

    function fieldCount() external view returns (uint256);

    function time() external view returns (Season memory);
}

/**
 * @title ShipmentPlanner
 * @notice Contains getters for retrieving ShipmentPlans for various Beanstalk components.
 * @dev Lives as a standalone immutable contract. Updating shipment plans requires deploying
 * a new instance and updating the ShipmentRoute planContract addresses help in AppStorage.
 * @dev Called via staticcall. New plan getters must be view/pure functions.
 */
contract ShipmentPlanner {
    uint256 internal constant PRECISION = 1e18;

    uint256 constant FIELD_POINTS = 48_500_000_000_000_000; // 48.5%
    uint256 constant SILO_POINTS = 48_500_000_000_000_000; // 48.5%
    uint256 constant BUDGET_POINTS = 3_000_000_000_000_000; // 3%
    uint256 constant PAYBACK_FIELD_POINTS = 1_000_000_000_000_000; // 1%
    uint256 constant PAYBACK_SILO_POINTS = 1_000_000_000_000_000; // 1%
    uint256 constant PAYBACK_BARN_POINTS = 1_000_000_000_000_000; // 1%

    uint256 constant SUPPLY_BUDGET_FLIP = 1_000_000_000e6;

    IBeanstalk immutable beanstalk;
    IERC20 immutable bean;

    constructor(address beanstalkAddress, address beanAddress) {
        beanstalk = IBeanstalk(beanstalkAddress);
        bean = IERC20(beanAddress);
    }

    /**
     * @notice Get the current points and cap for Field shipments.
     * @dev The Field cap is the amount of outstanding Pods unharvestable pods.
     * @param data Encoded uint256 containing the index of the Field to receive the Beans.
     */
    function getFieldPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan) {
        uint256 fieldId = abi.decode(data, (uint256));
        require(fieldId < beanstalk.fieldCount(), "Field does not exist");
        if (!beanstalk.isHarvesting(fieldId)) return shipmentPlan;
        return ShipmentPlan({points: FIELD_POINTS, cap: beanstalk.totalUnharvestable(fieldId)});
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
        uint256 budgetRatio = budgetMintRatio();
        require(
            budgetRatio > 0,
            "ShipmentPlanner: Supply above flipping point, no budget allocation"
        );
        uint256 points = (BUDGET_POINTS * budgetRatio) / PRECISION;
        uint256 cap = (beanstalk.time().standardMintedBeans * 3) / 100;
        return ShipmentPlan({points: points, cap: cap});
    }

    /**
     * @notice Get the current points and cap for the Field portion of payback shipments.
     * @dev data here in addition to the payback coontracts, contains the payback field id endoded as the third parameter.
     */
    function getPaybackFieldPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan) {
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
            points = PAYBACK_FIELD_POINTS + PAYBACK_SILO_POINTS + PAYBACK_BARN_POINTS;
            maxCap = (beanstalk.time().standardMintedBeans * 3) / 100; // 3%
        } else if (barnRemaining == 0) {
            // if barn remaining is 0 then 1.5% of all mints goes to silo and 1.5% goes to the field
            points = PAYBACK_FIELD_POINTS + (PAYBACK_SILO_POINTS + PAYBACK_BARN_POINTS) / 4;
            maxCap = (beanstalk.time().standardMintedBeans * 15) / 1000; // 1.5%
        } else {
            // else, all are active and 1% of all mints goes to field, 1% goes to silo, 1% goes to fert
            points = PAYBACK_FIELD_POINTS;
            maxCap = beanstalk.time().standardMintedBeans / 100; // 1%
        }
        // the absolute cap of all mints is the remaining field debt
        uint256 cap = min(beanstalk.totalUnharvestable(fieldId), maxCap);

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
            points = PAYBACK_SILO_POINTS + (PAYBACK_BARN_POINTS / 2); // 1.5%
            maxCap = (beanstalk.time().standardMintedBeans * 15) / 1000; // 1.5%
        } else {
            // if silo is not paid off and fert is not paid off then just assign the regular 1% points
            points = PAYBACK_SILO_POINTS;
            maxCap = beanstalk.time().standardMintedBeans / 100; // 1%
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
        // calculate the payback ratio and enforce that payback is active
        uint256 paybackRatio = calcAndEnforceActivePayback();
        // since payback is active, fetch the remaining payback amounts
        (uint256 siloRemaining, uint256 barnRemaining) = paybacksRemaining(data);

        // if fert is paid off, no need to send pintos to it.
        if (barnRemaining == 0) return ShipmentPlan({points: 0, cap: barnRemaining});

        uint256 points;
        uint256 maxCap;
        // if fert is not paid off and silo is paid off then we need to increase the
        // the points that should go to the fert to 1,5% (finalAllocation = 1,5% to barn, 1,5% to field)
        if (siloRemaining == 0) {
            // half of the paid off silo points go to fert
            points = PAYBACK_BARN_POINTS + (PAYBACK_SILO_POINTS / 2); // 1.5%
            maxCap = (beanstalk.time().standardMintedBeans * 15) / 100; // 1.5%
        } else {
            // if fert is not paid off and silo is not paid off then just assign the regular 1% points
            points = PAYBACK_BARN_POINTS;
            maxCap = beanstalk.time().standardMintedBeans / 100; // 1%
        }
        // the absolute cap of all mints is the remaining barn debt
        uint256 cap = min(barnRemaining, maxCap);

        // Scale the points by the payback ratio
        points = (points * paybackRatio) / PRECISION;
        return ShipmentPlan({points: points, cap: cap});
    }

    /**
     * @notice Returns a ratio to scale the seasonal mints between budget and payback.
     */
    function budgetMintRatio() private view returns (uint256) {
        uint256 beanSupply = bean.totalSupply();
        uint256 seasonalMints = beanstalk.time().standardMintedBeans;

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

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

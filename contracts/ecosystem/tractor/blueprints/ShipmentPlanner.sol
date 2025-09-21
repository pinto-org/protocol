// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Season} from "contracts/beanstalk/storage/System.sol";
import {IPayback} from "contracts/interfaces/IPayback.sol";
import {IBudget} from "contracts/interfaces/IBudget.sol";

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

    uint256 constant FIELD_POINTS = 48_500_000_000_000_000;
    uint256 constant SILO_POINTS = 48_500_000_000_000_000;
    uint256 constant BUDGET_POINTS = 3_000_000_000_000_000;
    uint256 constant PAYBACK_FIELD_POINTS = 1_000_000_000_000_000;
    uint256 constant PAYBACK_CONTRACT_POINTS = 2_000_000_000_000_000;

    uint256 constant SUPPLY_BUDGET_FLIP = 1_000_000_000e6;

    IBeanstalk beanstalk;
    IERC20 bean;

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
        require(budgetRatio > 0);
        uint256 points = (BUDGET_POINTS * budgetRatio) / PRECISION;
        uint256 cap = (beanstalk.time().standardMintedBeans * 3) / 100;
        return ShipmentPlan({points: points, cap: cap});
    }

    /**
     * @notice Get the current points and cap for the Field portion of payback shipments.
     * @dev data param is unused data to configure plan details.
     */
    function getPaybackFieldPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan) {
        uint256 paybackRatio = PRECISION - budgetMintRatio();
        require(paybackRatio > 0);

        (uint256 fieldId, address paybackContract) = abi.decode(data, (uint256, address));
        (bool success, uint256 siloRemaining, uint256 barnRemaining) = paybacksRemaining(
            paybackContract
        );
        // If the contract does not exist yet.
        if (!success) {
            return
                ShipmentPlan({
                    points: PAYBACK_FIELD_POINTS,
                    cap: beanstalk.totalUnharvestable(fieldId)
                });
        }

        // Add strict % limits. Silo will be paid off first.
        uint256 points;
        uint256 cap = beanstalk.totalUnharvestable(fieldId);
        if (barnRemaining == 0) {
            points = PAYBACK_FIELD_POINTS + PAYBACK_CONTRACT_POINTS;
            cap = min(cap, (beanstalk.time().standardMintedBeans * 3) / 100); // 3%
        } else if (siloRemaining == 0) {
            points = PAYBACK_FIELD_POINTS + (PAYBACK_CONTRACT_POINTS * 1) / 4;
            cap = min(cap, (beanstalk.time().standardMintedBeans * 15) / 1000); // 1.5%
        } else {
            points = PAYBACK_FIELD_POINTS;
            cap = min(cap, (beanstalk.time().standardMintedBeans * 1) / 100); // 1%
        }

        // Scale points by distance to threshold.
        points = (points * paybackRatio) / PRECISION;

        return ShipmentPlan({points: points, cap: cap});
    }

    /**
     * @notice Get the current points and cap for payback shipments.
     * @dev data param is unused data to configure plan details.
     * @dev If the payback contract does not yet exist, mints are still allocated to it.
     */
    function getPaybackPlan(
        bytes memory data
    ) external view returns (ShipmentPlan memory shipmentPlan) {
        uint256 paybackRatio = PRECISION - budgetMintRatio();
        require(paybackRatio > 0);

        address paybackContract = abi.decode(data, (address));
        (bool success, uint256 siloRemaining, uint256 barnRemaining) = paybacksRemaining(
            paybackContract
        );
        // If the contract does not exist yet, no cap.
        if (!success) {
            return ShipmentPlan({points: PAYBACK_CONTRACT_POINTS, cap: type(uint256).max});
        }

        uint256 points;
        uint256 cap = siloRemaining + barnRemaining;
        // Add strict % limits. Silo will be paid off first.
        if (siloRemaining == 0) {
            points = (PAYBACK_CONTRACT_POINTS * 3) / 4;
            cap = min(cap, (beanstalk.time().standardMintedBeans * 15) / 1000); // 1.5%
        } else {
            points = PAYBACK_CONTRACT_POINTS;
            cap = min(cap, (beanstalk.time().standardMintedBeans * 2) / 100); // 2%
        }

        // Scale points by distance to threshold.
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

    function paybacksRemaining(
        address paybackContract
    ) private view returns (bool totalSuccess, uint256 siloRemaining, uint256 barnRemaining) {
        (bool success, bytes memory returnData) = paybackContract.staticcall(
            abi.encodeWithSelector(IPayback.siloRemaining.selector)
        );
        totalSuccess = success;
        siloRemaining = success ? abi.decode(returnData, (uint256)) : 0;
        (success, returnData) = paybackContract.staticcall(
            abi.encodeWithSelector(IPayback.barnRemaining.selector)
        );
        totalSuccess = totalSuccess && success;
        barnRemaining = success ? abi.decode(returnData, (uint256)) : 0;
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

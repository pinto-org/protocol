// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {FieldFacet} from "contracts/beanstalk/facets/field/FieldFacet.sol";

/**
 * @title TempRepaymentFieldFacet
 * @notice Temporary facet to re-initialize the repayment field with data from the Beanstalk Podline.
 * Upon deployment of the beanstalkShipments, a new field will be created in
 */
contract TempRepaymentFieldFacet is ReentrancyGuard {
    address public constant REPAYMENT_FIELD_POPULATOR = 0xc4c66c8b199443a8deA5939ce175C3592e349791;
    uint256 public constant REPAYMENT_FIELD_ID = 1;

    event ReplaymentPlotAdded(address indexed account, uint256 indexed plotIndex, uint256 pods);

    struct Plot {
        uint256 podIndex;
        uint256 podAmounts;
    }

    struct ReplaymentPlotData {
        address account;
        Plot[] plots;
    }

    /**
     * @notice Re-initializes the repayment field using data from the Beanstalk Podline.
     * @dev This function is only callable by the repayment field populator.
     * @param accountPlots the plot for each account
     */
    function initializeReplaymentPlots(
        ReplaymentPlotData[] calldata accountPlots
    ) external nonReentrant {
        require(
            msg.sender == REPAYMENT_FIELD_POPULATOR,
            "Only the repayment field populator can call this function"
        );
        AppStorage storage s = LibAppStorage.diamondStorage();
        for (uint i; i < accountPlots.length; i++) {
            for (uint j; j < accountPlots[i].plots.length; j++) {
                uint256 podIndex = accountPlots[i].plots[j].podIndex;
                uint256 podAmount = accountPlots[i].plots[j].podAmounts;
                s.accts[accountPlots[i].account].fields[REPAYMENT_FIELD_ID].plots[
                    podIndex
                ] = podAmount;
                s.accts[accountPlots[i].account].fields[REPAYMENT_FIELD_ID].plotIndexes.push(
                    podIndex
                );
                // Set the plot index after the push to ensure length is > 0.
                s.accts[accountPlots[i].account].fields[REPAYMENT_FIELD_ID].piIndex[podIndex] =
                    s.accts[accountPlots[i].account].fields[REPAYMENT_FIELD_ID].plotIndexes.length -
                    1;
                emit ReplaymentPlotAdded(accountPlots[i].account, podIndex, podAmount);
            }
        }
    }
}

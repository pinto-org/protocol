// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {LibAppStorage} from "contracts/libraries/LibAppStorage.sol";

/**
 * @title TempRepaymentFieldFacet
 * @notice Temporary facet to re-initialize the repayment field with data from the Beanstalk Podline.
 * Upon deployment of the beanstalkShipments, a new field will be created and initialized here.
 * The result will be a mirror of the Beanstalk Podline at a new field Id.
 * After the initialization is complete, this facet will be removed.
 */
contract TempRepaymentFieldFacet is ReentrancyGuard {
    address public constant REPAYMENT_FIELD_POPULATOR = 0x00000015EE13a3C1fD0e8Dc2e8C2c8590D5B440B;
    uint256 public constant REPAYMENT_FIELD_ID = 1;

    event RepaymentPlotAdded(address indexed account, uint256 indexed plotIndex, uint256 pods);

    struct Plot {
        uint256 podIndex;
        uint256 podAmounts;
    }

    struct RepaymentPlotData {
        address account;
        Plot[] plots;
    }

    /**
     * @notice Re-initializes the repayment field using data from the Beanstalk Podline.
     * @dev This function is only callable by the repayment field populator.
     * @param accountPlots the plot for each account
     */
    function initializeRepaymentPlots(
        RepaymentPlotData[] calldata accountPlots
    ) external nonReentrant {
        require(
            msg.sender == REPAYMENT_FIELD_POPULATOR,
            "Only the repayment field populator can call this function"
        );
        AppStorage storage s = LibAppStorage.diamondStorage();
        for (uint i; i < accountPlots.length; i++) {
            // cache the account and length of the plot indexes array
            address account = accountPlots[i].account;
            uint256 len = s.accts[account].fields[REPAYMENT_FIELD_ID].plotIndexes.length;
            for (uint j; j < accountPlots[i].plots.length; j++) {
                uint256 podIndex = accountPlots[i].plots[j].podIndex;
                uint256 podAmount = accountPlots[i].plots[j].podAmounts;
                s.accts[account].fields[REPAYMENT_FIELD_ID].plots[podIndex] = podAmount;
                s.accts[account].fields[REPAYMENT_FIELD_ID].plotIndexes.push(podIndex);
                s.accts[account].fields[REPAYMENT_FIELD_ID].piIndex[podIndex] = len + j;
                emit RepaymentPlotAdded(account, podIndex, podAmount);
            }
        }
    }
}

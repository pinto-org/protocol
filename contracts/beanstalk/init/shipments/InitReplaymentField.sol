/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import "contracts/libraries/LibAppStorage.sol";

/**
 * @title InitReplaymentField
 * @dev Initializes the beanstalk repayment field
 **/
contract InitReplaymentField {
    uint256 constant REPAYMENT_FIELD_ID = 1;

    event FieldAdded(uint256 fieldId);
    event ReplaymentPlotAdded(address indexed account, uint256 indexed plotIndex, uint256 pods);

    struct Plot {
        uint256 podIndex;
        uint256 podAmounts;
    }
    struct ReplaymentPlotData {
        address account;
        Plot[] plots;
    }

    function init(ReplaymentPlotData[] calldata accountPlots) external {
        // create new field
        initReplaymentField();
        // populate the field to recreate the beanstalk podline
        initReplaymentPlots(accountPlots);
    }

    /**
     * @notice Create new field, mimics the addField function in FieldFacet.sol
     * @dev Harvesting is handled in LibReceiving.sol
     */
    function initReplaymentField() internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // make sure this is only called once to create the beanstalk field
        if (s.sys.fieldCount == 2) return;
        uint256 fieldId = s.sys.fieldCount;
        s.sys.fieldCount++;
        emit FieldAdded(fieldId);
    }

    /**
     * @notice Re-initializes the repayment field with a reconstructed Beanstalk Podline.
     * @param accountPlots the plots for each account
     */
    function initReplaymentPlots(ReplaymentPlotData[] calldata accountPlots) internal {
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

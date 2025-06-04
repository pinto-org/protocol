// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {IOperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";

/**
 * @title LibTractorHelpers
 * @author FordPinto
 * @notice Library with helper functions for Silo operations
 */
library LibTractorHelpers {
    struct WithdrawalPlan {
        address[] sourceTokens;
        int96[][] stems;
        uint256[][] amounts;
        uint256[] availableBeans;
        uint256 totalAvailableBeans;
    }

    // Struct to hold variables for the combineWithdrawalPlans function
    struct CombineWithdrawalPlansStruct {
        address[] tempSourceTokens;
        int96[][] tempStems;
        uint256[][] tempAmounts;
        uint256[] tempAvailableBeans;
        uint256 totalSourceTokens;
        address token;
        int96[] stems;
        uint256[] amounts;
    }

    /**
     * @notice Combines multiple withdrawal plans into a single plan
     * @dev This function aggregates the amounts used from each deposit across all plans
     * @param plans Array of withdrawal plans to combine
     * @return combinedPlan A single withdrawal plan that represents the total usage across all input plans
     */
    function combineWithdrawalPlans(
        WithdrawalPlan[] memory plans,
        IBeanstalk beanstalk
    ) external view returns (WithdrawalPlan memory combinedPlan) {
        if (plans.length == 0) {
            return combinedPlan;
        }

        IBeanstalk.WhitelistStatus[] memory whitelistStatuses = beanstalk.getWhitelistStatuses();

        // Initialize the struct with shared variables
        CombineWithdrawalPlansStruct memory vars;

        // Initialize arrays for the combined plan with maximum possible size
        vars.tempSourceTokens = new address[](whitelistStatuses.length);
        vars.tempStems = new int96[][](whitelistStatuses.length);
        vars.tempAmounts = new uint256[][](whitelistStatuses.length);
        vars.tempAvailableBeans = new uint256[](whitelistStatuses.length);
        vars.totalSourceTokens = 0;

        // Initialize total available beans
        combinedPlan.totalAvailableBeans = 0;

        // Process each whitelisted token
        for (uint256 i = 0; i < whitelistStatuses.length; i++) {
            vars.token = whitelistStatuses[i].token;

            // Calculate maximum possible stems for this token
            uint256 maxPossibleStems = 0;
            for (uint256 j = 0; j < plans.length; j++) {
                for (uint256 k = 0; k < plans[j].sourceTokens.length; k++) {
                    if (plans[j].sourceTokens[k] == vars.token) {
                        maxPossibleStems += plans[j].stems[k].length;
                    }
                }
            }

            // Skip tokens with no stems
            if (maxPossibleStems == 0) {
                continue;
            }

            // Create arrays with maximum possible size
            vars.stems = new int96[](maxPossibleStems);
            vars.amounts = new uint256[](maxPossibleStems);
            uint256 seenStemsCount = 0;

            // Initialize availableBeans for this token
            vars.tempAvailableBeans[vars.totalSourceTokens] = 0;

            // Sum up amounts for each stem across all plans and calculate availableBeans
            for (uint256 j = 0; j < plans.length; j++) {
                for (uint256 k = 0; k < plans[j].sourceTokens.length; k++) {
                    if (plans[j].sourceTokens[k] == vars.token) {
                        // Add to availableBeans for this token
                        vars.tempAvailableBeans[vars.totalSourceTokens] += plans[j].availableBeans[
                            k
                        ];

                        // Process stems
                        for (uint256 l = 0; l < plans[j].stems[k].length; l++) {
                            int96 stem = plans[j].stems[k][l];
                            uint256 amount = plans[j].amounts[k][l];

                            // Find if we've seen this stem before
                            bool found = false;
                            for (uint256 m = 0; m < seenStemsCount; m++) {
                                if (vars.stems[m] == stem) {
                                    vars.amounts[m] += amount;
                                    found = true;
                                    break;
                                }
                            }

                            if (!found) {
                                vars.stems[seenStemsCount] = stem;
                                vars.amounts[seenStemsCount] = amount;
                                seenStemsCount++;
                            }
                        }
                    }
                }
            }

            // Skip tokens with no stems after processing
            if (seenStemsCount == 0) {
                continue;
            }

            // Sort stems in descending order
            for (uint256 j = 0; j < seenStemsCount - 1; j++) {
                for (uint256 k = 0; k < seenStemsCount - j - 1; k++) {
                    if (vars.stems[k] < vars.stems[k + 1]) {
                        (vars.stems[k], vars.stems[k + 1]) = (vars.stems[k + 1], vars.stems[k]);
                        (vars.amounts[k], vars.amounts[k + 1]) = (
                            vars.amounts[k + 1],
                            vars.amounts[k]
                        );
                    }
                }
            }

            // Update array lengths
            // Create local variables for assembly block
            int96[] memory stemsArray = vars.stems;
            uint256[] memory amountsArray = vars.amounts;

            assembly {
                mstore(stemsArray, seenStemsCount)
                mstore(amountsArray, seenStemsCount)
            }

            // Update the struct with the modified arrays
            vars.stems = stemsArray;
            vars.amounts = amountsArray;

            // Store token and its data
            vars.tempSourceTokens[vars.totalSourceTokens] = vars.token;
            vars.tempStems[vars.totalSourceTokens] = vars.stems;
            vars.tempAmounts[vars.totalSourceTokens] = vars.amounts;

            // Add to total available beans
            combinedPlan.totalAvailableBeans += vars.tempAvailableBeans[vars.totalSourceTokens];

            vars.totalSourceTokens++;
        }

        // Create the final arrays with the exact size needed
        combinedPlan.sourceTokens = new address[](vars.totalSourceTokens);
        combinedPlan.stems = new int96[][](vars.totalSourceTokens);
        combinedPlan.amounts = new uint256[][](vars.totalSourceTokens);
        combinedPlan.availableBeans = new uint256[](vars.totalSourceTokens);

        // Copy data to the final arrays
        for (uint256 i = 0; i < vars.totalSourceTokens; i++) {
            combinedPlan.sourceTokens[i] = vars.tempSourceTokens[i];
            combinedPlan.stems[i] = vars.tempStems[i];
            combinedPlan.amounts[i] = vars.tempAmounts[i];
            combinedPlan.availableBeans[i] = vars.tempAvailableBeans[i];
        }

        return combinedPlan;
    }

    /**
     * @notice Checks if the current operator is whitelisted
     * @param whitelistedOperators Array of whitelisted operator addresses
     * @param beanstalk The Beanstalk contract instance
     * @return isWhitelisted Whether the current operator is whitelisted
     */
    function isOperatorWhitelisted(
        address[] calldata whitelistedOperators,
        IBeanstalk beanstalk
    ) external view returns (bool) {
        // If there are no whitelisted operators, pass in, accept any operator
        if (whitelistedOperators.length == 0) {
            return true;
        }

        address currentOperator = beanstalk.operator();
        for (uint256 i = 0; i < whitelistedOperators.length; i++) {
            address checkAddress = whitelistedOperators[i];
            if (checkAddress == currentOperator) {
                return true;
            } else {
                // Skip if address is a precompiled contract (address < 0x20)
                if (uint160(checkAddress) <= 0x20) continue;

                // Check if the address is a contract before attempting staticcall
                uint256 size;
                assembly {
                    size := extcodesize(checkAddress)
                }

                if (size > 0) {
                    try
                        IOperatorWhitelist(checkAddress).checkOperatorWhitelist(currentOperator)
                    returns (bool success) {
                        if (success) {
                            return true;
                        }
                    } catch {
                        // If the call fails, continue to the next address
                        continue;
                    }
                }
            }
        }
        return false;
    }

    function sortTokens(
        address[] memory tokens,
        uint256[] memory index
    ) external pure returns (address[] memory, uint256[] memory) {
        for (uint256 i = 0; i < tokens.length - 1; i++) {
            for (uint256 j = 0; j < tokens.length - i - 1; j++) {
                uint256 j1 = j + 1;
                if (index[j] < index[j1]) {
                    // Swap index
                    (index[j], index[j1]) = (index[j1], index[j]);

                    // Swap corresponding tokens
                    (tokens[j], tokens[j1]) = (tokens[j1], tokens[j]);
                }
            }
        }
        return (tokens, index);
    }

    function sortTokenIndices(
        uint8[] memory tokenIndices,
        uint256[] memory index
    ) external pure returns (uint8[] memory, uint256[] memory) {
        for (uint256 i = 0; i < tokenIndices.length - 1; i++) {
            for (uint256 j = 0; j < tokenIndices.length - i - 1; j++) {
                uint256 j1 = j + 1;
                if (index[j] > index[j1]) {
                    // Swap index
                    (index[j], index[j1]) = (index[j1], index[j]);

                    // Swap token indices
                    (tokenIndices[j], tokenIndices[j1]) = (tokenIndices[j1], tokenIndices[j]);
                }
            }
        }
        return (tokenIndices, index);
    }
}

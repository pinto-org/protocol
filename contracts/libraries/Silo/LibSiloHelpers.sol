// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";

/**
 * @title LibTractorHelpers
 * @author FordPinto, Frijo
 * @notice Library with helper functions for Silo operations
 */
library LibSiloHelpers {
    enum LowStalkDepositUse {
        USE,      // 0 - use low stalk deposits
        OMIT,     // 1 - omit low stalk deposits
        USE_LAST  // 2 - use low stalk deposits last
    }

    // Legacy constants for backward compatibility
    uint8 internal constant USE_LOW_STALK_DEPOSITS = 0;
    uint8 internal constant DO_NOT_USE_LOW_STALK_DEPOSITS = 1;
    uint8 internal constant USE_LOW_STALK_DEPOSITS_LAST = 2;

    struct WithdrawalPlan {
        address[] sourceTokens;
        int96[][] stems;
        uint256[][] amounts;
        uint256[] availableBeans;
        uint256 totalAvailableBeans;
    }

    /**
     * @notice Filter parameters for deposits
     * @param maxGrownStalkPerBdv The maximum amount of grown stalk allowed to be used for the withdrawal, per bdv
     * @param minStem The minimum stem value to consider for withdrawal. Stems smaller than this are considered "high stalk" deposits and cannot be used.
     * @param excludeGerminatingDeposits Whether to exclude germinating deposits
     * @param excludeBean Whether to exclude beans
     * @param lowStalkDepositUse how low stalk deposits are processed. USE (0), OMIT (1), USE_LAST (2).
     * @param lowGrownStalkPerBdv amount of grown stalk per bdv such that the deposit considered a "low stalk" deposit.
     * @param maxStem The maximum stem value to consider for withdrawal. Stems larger than this are considered "low stalk" deposits.
     * @dev lowStalkDepositUse needed a way to handle low stalk deposits last for the convert bonus.
     */
    struct FilterParams {
        uint256 maxGrownStalkPerBdv;
        int96 minStem;
        bool excludeGerminatingDeposits;
        bool excludeBean;
        LowStalkDepositUse lowStalkDepositUse;
        uint256 lowGrownStalkPerBdv;
        int96 maxStem;
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
     * @notice Returns a deposit filter with no exclusions
     * @return FilterParams The default deposit filter parameters
     */
    function getDefaultFilterParams() public pure returns (FilterParams memory) {
        return
            FilterParams({
                maxGrownStalkPerBdv: uint256(int256(type(int96).max)), // any amount of grown stalk per bdv is allowed. Maximum set at int96, as this is used to derive the minStem.
                minStem: type(int96).min, // include all stems
                lowGrownStalkPerBdv: 0, // no minimum grown stalk per bdv
                maxStem: type(int96).max, // include all stems
                excludeGerminatingDeposits: false, // no germinating deposits are excluded
                excludeBean: false, // beans are included in the set of deposits.
                lowStalkDepositUse: LowStalkDepositUse.USE // the contract will use the smallest stalk deposits normally
            });
    }

    /**
     * @notice Checks if a deposit is already in an existing plan
     * @param token The token of the deposit
     * @param stem The stem of the deposit
     * @param amount The amount of the deposit
     * @param excludingPlan The plan to check against
     */
    function checkDepositInExistingPlan(
        address token,
        int96 stem,
        uint256 amount,
        WithdrawalPlan memory excludingPlan
    ) internal pure returns (uint256) {
        uint256 remainingAmount = amount;
        for (uint256 i; i < excludingPlan.sourceTokens.length; i++) {
            if (excludingPlan.sourceTokens[i] == token) {
                for (uint256 j; j < excludingPlan.stems[i].length; j++) {
                    if (excludingPlan.stems[i][j] == stem) {
                        // If the deposit was fully used in the existing plan, skip it
                        if (excludingPlan.amounts[i][j] >= amount) {
                            remainingAmount = 0;
                            break;
                        } else {
                            // Otherwise, subtract the used amount from the remaining amount
                            remainingAmount = amount - excludingPlan.amounts[i][j];
                            break;
                        }
                    }
                }
                if (remainingAmount == 0) return 0;
            }
        }
        return remainingAmount;
    }
}

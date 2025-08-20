// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {PerFunctionPausable} from "./PerFunctionPausable.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {Call, IWell, IERC20} from "../interfaces/basin/IWell.sol";
import {TractorHelpers} from "./TractorHelpers.sol";
import {PriceManipulation} from "./PriceManipulation.sol";

/**
 * @title SiloHelpers
 * @author FordPinto, Frijo
 * @notice Helper contract for Silo operations related to sorting deposits and managing their order
 */
contract SiloHelpers is PerFunctionPausable {
    // Special token index values for withdrawal strategies
    uint8 internal constant LOWEST_PRICE_STRATEGY = type(uint8).max;
    uint8 internal constant LOWEST_SEED_STRATEGY = type(uint8).max - 1;

    IBeanstalk immutable beanstalk;
    TractorHelpers immutable tractorHelpers;
    PriceManipulation immutable priceManipulation;

    struct WithdrawLocalVars {
        address[] whitelistedTokens;
        address beanToken;
        uint256 remainingBeansNeeded;
        uint256 amountWithdrawn;
        int96[] stems;
        uint256[] amounts;
        uint256 availableAmount;
        uint256 lpNeeded;
        uint256 beansOut;
        // For valid source tracking
        address[] validSourceTokens;
        int96[][] validStems;
        uint256[][] validAmounts;
        uint256[] validAvailableBeans;
        uint256 validSourceCount;
        uint256 totalAvailableBeans;
        int96 minStem;
    }

    struct WithdrawBeansLocalVars {
        uint256 amountWithdrawn;
        address beanToken;
        address sourceToken;
        address nonBeanToken;
        uint256 totalLPAmount;
        uint256 i;
        uint256 j;
    }

    struct GetDepositStemsAndAmountsVars {
        uint256[] depositIds;
        int96 highestNonGerminatingStem;
        uint256 remainingBeansNeeded;
        uint256 currentIndex;
        uint256 availableAmount;
        address token;
        int96 stem;
        uint256 depositAmount;
        uint256 remainingAmount;
        uint256 amountFromDeposit;
        int96[] lowStalkStems;
        uint256[] lowStalkAmounts;
        uint256 lowStalkCount;
    }

    constructor(
        address _beanstalk,
        address _tractorHelpers,
        address _priceManipulation,
        address _owner
    ) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
        tractorHelpers = TractorHelpers(_tractorHelpers);
        priceManipulation = PriceManipulation(_priceManipulation);
    }

    /**
     * @notice Sorts all deposits for every token the user has and updates the sorted lists in Beanstalk
     * @param account The address of the account that owns the deposits
     * @return updatedTokens Array of tokens that had their sorted deposit lists updated
     */
    function sortDeposits(
        address account
    ) external whenFunctionNotPaused returns (address[] memory updatedTokens) {
        // Get all tokens the user has deposited
        address[] memory depositedTokens = getUserDepositedTokens(account);
        if (depositedTokens.length == 0) return new address[](0);

        updatedTokens = new address[](depositedTokens.length);

        // Process each token
        for (uint256 i = 0; i < depositedTokens.length; i++) {
            address token = depositedTokens[i];

            // Get deposit IDs for this token
            uint256[] memory depositIds = beanstalk.getTokenDepositIdsForAccount(account, token);
            if (depositIds.length == 0) continue;

            // Sort deposits by stem in ascending order (required for updateSortedDepositIds)
            for (uint256 j = 0; j < depositIds.length - 1; j++) {
                for (uint256 k = 0; k < depositIds.length - j - 1; k++) {
                    (, int96 stem1) = getAddressAndStem(depositIds[k]);
                    (, int96 stem2) = getAddressAndStem(depositIds[k + 1]);

                    if (stem1 > stem2) {
                        // Swap deposit IDs
                        uint256 temp = depositIds[k];
                        depositIds[k] = depositIds[k + 1];
                        depositIds[k + 1] = temp;
                    }
                }
            }

            // Update the sorted list in Beanstalk
            beanstalk.updateSortedDepositIds(account, token, depositIds);
            updatedTokens[i] = token;
        }

        return updatedTokens;
    }

    /**
     * @notice Gets the list of tokens that a user has deposited in the silo
     * @param account The address of the user
     * @return depositedTokens Array of token addresses that the user has deposited
     */
    function getUserDepositedTokens(
        address account
    ) public view returns (address[] memory depositedTokens) {
        address[] memory allWhitelistedTokens = getWhitelistStatusAddresses();

        // First, get the mow status for all tokens to check which ones have deposits
        IBeanstalk.MowStatus[] memory mowStatuses = beanstalk.getMowStatus(
            account,
            allWhitelistedTokens
        );

        // Count how many tokens have deposits (bdv > 0)
        uint256 depositedTokenCount = 0;
        for (uint256 i = 0; i < mowStatuses.length; i++) {
            if (mowStatuses[i].bdv > 0) {
                depositedTokenCount++;
            }
        }

        // Create array of the right size for deposited tokens
        depositedTokens = new address[](depositedTokenCount);

        // Fill the array with tokens that have deposits
        uint256 index = 0;
        for (uint256 i = 0; i < mowStatuses.length; i++) {
            if (mowStatuses[i].bdv > 0) {
                depositedTokens[index] = allWhitelistedTokens[i];
                index++;
            }
        }

        return depositedTokens;
    }

    /**
     * @notice Returns a plan for withdrawing beans from multiple sources
     * @param account The account to withdraw from
     * @param tokenIndices Array of indices corresponding to whitelisted tokens to try as sources.
     * Special cases when array length is 1:
     * - If value is LOWEST_PRICE_STRATEGY (uint8.max): Use tokens in ascending price order
     * - If value is LOWEST_SEED_STRATEGY (uint8.max - 1): Use tokens in ascending seed order
     * @param targetAmount The total amount of beans to withdraw
     * @param filterParams Contains minStem, excludeGerminatingDeposits, lowPriorityStemThreshold, excludeBean, and maxGrownStalkPerBdv
     * @param excludingPlan Optional plan containing deposits that have been partially used. The function will account for remaining amounts in these deposits.
     * @return plan The withdrawal plan containing source tokens, stems, amounts, and available beans
     */
    function getWithdrawalPlanExcludingPlan(
        address account,
        uint8[] memory tokenIndices,
        uint256 targetAmount,
        LibSiloHelpers.FilterParams memory filterParams,
        LibSiloHelpers.WithdrawalPlan memory excludingPlan
    ) public view returns (LibSiloHelpers.WithdrawalPlan memory plan) {
        require(tokenIndices.length > 0, "Must provide at least one source token");
        require(targetAmount > 0, "Must withdraw non-zero amount");

        WithdrawLocalVars memory vars;
        vars.whitelistedTokens = getWhitelistStatusAddresses();
        vars.beanToken = beanstalk.getBeanToken();
        vars.remainingBeansNeeded = targetAmount;

        // Handle strategy cases when array length is 1
        if (tokenIndices.length == 1) {
            if (tokenIndices[0] == LOWEST_PRICE_STRATEGY) {
                // Use ascending price strategy
                (tokenIndices, ) = tractorHelpers.getTokensAscendingPrice(filterParams.excludeBean);
            } else if (tokenIndices[0] == LOWEST_SEED_STRATEGY) {
                // Use ascending seeds strategy
                (tokenIndices, ) = tractorHelpers.getTokensAscendingSeeds(filterParams.excludeBean);
            }
        }

        vars.validSourceTokens = new address[](tokenIndices.length);
        vars.validStems = new int96[][](tokenIndices.length);
        vars.validAmounts = new uint256[][](tokenIndices.length);
        vars.validAvailableBeans = new uint256[](tokenIndices.length);
        vars.validSourceCount = 0;
        vars.totalAvailableBeans = 0;

        // Try each source token in order until we fulfill the target amount
        for (uint256 i = 0; i < tokenIndices.length && vars.remainingBeansNeeded > 0; i++) {
            require(tokenIndices[i] < vars.whitelistedTokens.length, "Invalid token index");

            address sourceToken = vars.whitelistedTokens[tokenIndices[i]];

            int96 stemTip = beanstalk.stemTipForToken(sourceToken);
            // Calculate minimum stem tip from grown stalk for this token.
            // note: in previous version, `maxGrownStalkPerBdv` assumed that 1 BDV = 1e6.
            // This is not correct and should be noted if UIs uses previous blueprint functions.
            filterParams.minStem = stemTip - int96(int256(filterParams.maxGrownStalkPerBdv));
            filterParams.maxStem = stemTip - int96(int256(filterParams.lowGrownStalkPerBdv));

            // If source is bean token, calculate direct withdrawal
            if (sourceToken == vars.beanToken) {
                (
                    vars.stems,
                    vars.amounts,
                    vars.availableAmount
                ) = getDepositStemsAndAmountsToWithdraw(
                    account,
                    sourceToken,
                    vars.remainingBeansNeeded,
                    filterParams,
                    excludingPlan
                );

                // Skip if no beans available from this source
                if (vars.availableAmount == 0) continue;

                // Update remainingBeansNeeded based on the amount available
                vars.remainingBeansNeeded = vars.remainingBeansNeeded - vars.availableAmount;

                // Add to valid sources
                vars.validSourceTokens[vars.validSourceCount] = sourceToken;
                vars.validStems[vars.validSourceCount] = vars.stems;
                vars.validAmounts[vars.validSourceCount] = vars.amounts;
                vars.validAvailableBeans[vars.validSourceCount] = vars.availableAmount;
                vars.totalAvailableBeans += vars.availableAmount;
                vars.validSourceCount++;
            } else {
                // For LP tokens, first check how many beans we could get
                vars.lpNeeded = tractorHelpers.getLPTokensToWithdrawForBeans(
                    vars.remainingBeansNeeded,
                    sourceToken
                );

                // Get available LP tokens
                (
                    vars.stems,
                    vars.amounts,
                    vars.availableAmount
                ) = getDepositStemsAndAmountsToWithdraw(
                    account,
                    sourceToken,
                    vars.lpNeeded,
                    filterParams,
                    excludingPlan
                );

                // Skip if no LP available from this source
                if (vars.availableAmount == 0) continue;

                uint256 beansAvailable;

                // If not enough LP to fulfill the full amount, see how many beans we can get
                if (vars.availableAmount < vars.lpNeeded) {
                    // Calculate how many beans we can get from the available LP tokens
                    beansAvailable = IWell(sourceToken).getRemoveLiquidityOneTokenOut(
                        vars.availableAmount,
                        IERC20(vars.beanToken)
                    );
                } else {
                    // If enough LP was available, it means there was enough to fulfill the full amount
                    beansAvailable = vars.remainingBeansNeeded;
                }

                vars.remainingBeansNeeded = vars.remainingBeansNeeded - beansAvailable;

                // Add to valid sources
                vars.validSourceTokens[vars.validSourceCount] = sourceToken;
                vars.validStems[vars.validSourceCount] = vars.stems;
                vars.validAmounts[vars.validSourceCount] = vars.amounts;
                vars.validAvailableBeans[vars.validSourceCount] = beansAvailable;
                vars.totalAvailableBeans += beansAvailable;
                vars.validSourceCount++;
            }
        }

        require(vars.totalAvailableBeans != 0, "No beans available");

        // Now create the final plan with correctly sized arrays
        plan.sourceTokens = new address[](vars.validSourceCount);
        plan.stems = new int96[][](vars.validSourceCount);
        plan.amounts = new uint256[][](vars.validSourceCount);
        plan.availableBeans = new uint256[](vars.validSourceCount);
        plan.totalAvailableBeans = vars.totalAvailableBeans;

        // Copy valid sources to the final plan
        for (uint256 i = 0; i < vars.validSourceCount; i++) {
            plan.sourceTokens[i] = vars.validSourceTokens[i];
            plan.stems[i] = vars.validStems[i];
            plan.amounts[i] = vars.validAmounts[i];
            plan.availableBeans[i] = vars.validAvailableBeans[i];
        }

        return plan;
    }

    /**
     * @notice Returns a plan for withdrawing beans from multiple sources
     * @param account The account to withdraw from
     * @param tokenIndices Array of indices corresponding to whitelisted tokens to try as sources.
     * Special cases when array length is 1:
     * - If value is LOWEST_PRICE_STRATEGY (uint8.max): Use tokens in ascending price order
     * - If value is LOWEST_SEED_STRATEGY (uint8.max - 1): Use tokens in ascending seed order
     * @param targetAmount The total amount of beans to withdraw
     * @param filterParams Contains minStem, excludeGerminatingDeposits, lowPriorityStemThreshold, excludeBean, and maxGrownStalkPerBdv
     * @return plan The withdrawal plan containing source tokens, stems, amounts, and available beans
     */
    function getWithdrawalPlan(
        address account,
        uint8[] memory tokenIndices,
        uint256 targetAmount,
        LibSiloHelpers.FilterParams memory filterParams
    ) public view returns (LibSiloHelpers.WithdrawalPlan memory plan) {
        LibSiloHelpers.WithdrawalPlan memory emptyPlan;
        return
            getWithdrawalPlanExcludingPlan(
                account,
                tokenIndices,
                targetAmount,
                filterParams,
                emptyPlan
            );
    }

    /**
     * @notice Withdraws beans from multiple sources in order until the target amount is fulfilled
     * @param account The account to withdraw from
     * @param tokenIndices Array of indices corresponding to whitelisted tokens to try as sources.
     * Special cases when array length is 1:
     * - If value is LOWEST_PRICE_STRATEGY (uint8.max): Use tokens in ascending price order
     * - If value is LOWEST_SEED_STRATEGY (uint8.max - 1): Use tokens in ascending seed order
     * @param targetAmount The total amount of beans to withdraw
     * @param filterParams Contains minStem, excludeGerminatingDeposits, lowPriorityStemThreshold, excludeBean, and maxGrownStalkPerBdv
     * @param slippageRatio The price slippage ratio for a lp token withdrawal, between the instantaneous price and the current price
     * @param mode The transfer mode for sending tokens back to user
     * @param plan The withdrawal plan to use, or null to generate one
     * @return amountWithdrawn The total amount of beans withdrawn
     */
    function withdrawBeansFromSources(
        address account,
        uint8[] memory tokenIndices,
        uint256 targetAmount,
        LibSiloHelpers.FilterParams memory filterParams,
        uint256 slippageRatio,
        LibTransfer.To mode,
        LibSiloHelpers.WithdrawalPlan memory plan
    ) external payable whenFunctionNotPaused returns (uint256) {
        WithdrawBeansLocalVars memory vars;

        // If passed in plan is empty, get one
        if (plan.sourceTokens.length == 0) {
            plan = getWithdrawalPlan(account, tokenIndices, targetAmount, filterParams);
        }

        vars.amountWithdrawn = 0;
        vars.beanToken = beanstalk.getBeanToken();

        // Execute withdrawal plan
        for (vars.i = 0; vars.i < plan.sourceTokens.length; vars.i++) {
            vars.sourceToken = plan.sourceTokens[vars.i];

            // Skip Bean token for price manipulation check since it's not a Well
            if (vars.sourceToken != vars.beanToken) {
                // Check for price manipulation in the Well
                (vars.nonBeanToken, ) = IBeanstalk(beanstalk).getNonBeanTokenAndIndexFromWell(
                    vars.sourceToken
                );
                require(
                    priceManipulation.isValidSlippage(
                        IWell(vars.sourceToken),
                        IERC20(vars.nonBeanToken),
                        slippageRatio
                    ),
                    "Price manipulation detected"
                );
            }

            // If source is bean token, withdraw directly
            if (vars.sourceToken == vars.beanToken) {
                beanstalk.withdrawDeposits(
                    vars.sourceToken,
                    plan.stems[vars.i],
                    plan.amounts[vars.i],
                    mode
                );
                vars.amountWithdrawn += plan.availableBeans[vars.i];
            } else {
                // For LP tokens, first withdraw LP tokens to the user's internal balance
                beanstalk.withdrawDeposits(
                    vars.sourceToken,
                    plan.stems[vars.i],
                    plan.amounts[vars.i],
                    LibTransfer.To.INTERNAL
                );

                // Calculate total amount of LP tokens to transfer
                vars.totalLPAmount = 0;
                for (vars.j = 0; vars.j < plan.amounts[vars.i].length; vars.j++) {
                    vars.totalLPAmount += plan.amounts[vars.i][vars.j];
                }

                // Transfer LP tokens to this contract's external balance
                beanstalk.transferInternalTokenFrom(
                    IERC20(vars.sourceToken),
                    account,
                    address(this),
                    vars.totalLPAmount, // Use the total sum of all amounts
                    LibTransfer.To.EXTERNAL
                );

                // Then remove liquidity to get Beans
                IERC20(vars.sourceToken).approve(vars.sourceToken, vars.totalLPAmount);
                IWell(vars.sourceToken).removeLiquidityOneToken(
                    vars.totalLPAmount,
                    IERC20(vars.beanToken),
                    plan.availableBeans[vars.i],
                    address(this),
                    type(uint256).max
                );

                // Transfer from this contract's external balance to the user's internal/external balance depending on mode
                if (mode == LibTransfer.To.INTERNAL) {
                    // approve spending of Beans from this contract's external balance
                    IERC20(vars.beanToken).approve(address(beanstalk), plan.availableBeans[vars.i]);
                    beanstalk.sendTokenToInternalBalance(
                        vars.beanToken,
                        account,
                        plan.availableBeans[vars.i]
                    );
                } else {
                    IERC20(vars.beanToken).transfer(account, plan.availableBeans[vars.i]);
                }
                vars.amountWithdrawn += plan.availableBeans[vars.i];
            }
        }

        return vars.amountWithdrawn;
    }

    /**
     * @notice Returns arrays of stems and amounts for all deposits, sorted by stem in descending order
     * @dev Convenience function that uses default filter parameters (no exclusions, all deposits high priority)
     * @param account The address of the account that owns the deposits
     * @param token The token to get deposits for
     * @param amount The amount of tokens to withdraw
     * @param minStem The minimum stem value to consider for withdrawal
     * @return stems Array of stems in descending order
     * @return amounts Array of corresponding amounts for each stem
     * @return availableAmount The total amount available to withdraw (may be less than requested amount)
     */
    function getDepositStemsAndAmountsToWithdraw(
        address account,
        address token,
        uint256 amount,
        int96 minStem
    )
        public
        view
        returns (int96[] memory stems, uint256[] memory amounts, uint256 availableAmount)
    {
        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams();
        filterParams.minStem = minStem;
        LibSiloHelpers.WithdrawalPlan memory emptyPlan;
        return getDepositStemsAndAmountsToWithdraw(account, token, amount, filterParams, emptyPlan);
    }

    /**
     * @notice Returns arrays of stems and amounts for all deposits, with priority-based ordering
     * @dev Processes high priority deposits first (stem <= lowPriorityStemThreshold), then low priority deposits
     * @param account The address of the account that owns the deposits
     * @param token The token to get deposits for
     * @param amount The amount of tokens to withdraw
     * @param filterParams Contains minStem, excludeGerminatingDeposits, lowPriorityStemThreshold, excludeBean, and maxGrownStalkPerBdv
     * @param excludingPlan Optional plan containing deposits that have been partially used. The function will account for remaining amounts in these deposits.
     * @return stems Array of stems in priority order (high priority first, then low priority, both in descending order)
     * @return amounts Array of corresponding amounts for each stem
     * @return availableAmount The total amount available to withdraw (may be less than requested amount)
     */
    function getDepositStemsAndAmountsToWithdraw(
        address account,
        address token,
        uint256 amount,
        LibSiloHelpers.FilterParams memory filterParams,
        LibSiloHelpers.WithdrawalPlan memory excludingPlan
    )
        public
        view
        returns (int96[] memory stems, uint256[] memory amounts, uint256 availableAmount)
    {
        GetDepositStemsAndAmountsVars memory vars;
        vars.token = token;
        vars.depositIds = beanstalk.getTokenDepositIdsForAccount(account, token);
        if (vars.depositIds.length == 0) return (new int96[](0), new uint256[](0), 0);

        // Get the highest non-germinating stem for the token if needed
        if (filterParams.excludeGerminatingDeposits) {
            vars.highestNonGerminatingStem = beanstalk.getHighestNonGerminatingStem(token);
        }

        // Initialize arrays with max possible size
        stems = new int96[](vars.depositIds.length);
        amounts = new uint256[](vars.depositIds.length);

        // if we are using the smallest stalk deposits, initialize an additional
        // temporary array to store the stems and amounts
        if (filterParams.lowStalkDeposits == LibSiloHelpers.Mode.USE_LAST) {
            vars.lowStalkStems = new int96[](vars.depositIds.length);
            vars.lowStalkAmounts = new uint256[](vars.depositIds.length);
        }

        // Track state
        vars.remainingBeansNeeded = amount;
        vars.currentIndex = 0;
        vars.availableAmount = 0;

        // Process deposits in reverse order (highest stem to lowest)
        for (uint256 i = vars.depositIds.length; i > 0; i--) {
            (, vars.stem) = getAddressAndStem(vars.depositIds[i - 1]);

            // Skip deposit if:
            // 1: stem is less than minStem (implying a high stalk deposit),
            // 2: deposit is germinating and excludeGerminatingDeposits is true
            if (
                vars.stem < filterParams.minStem ||
                (filterParams.excludeGerminatingDeposits &&
                    vars.stem > vars.highestNonGerminatingStem)
            ) {
                continue;
            }

            (vars.depositAmount, ) = beanstalk.getDeposit(account, token, vars.stem);

            // if the deposit is a low stalk deposit, check if we want to use the low stalk deposits last.
            if (
                filterParams.lowStalkDeposits != LibSiloHelpers.Mode.USE &&
                vars.stem > filterParams.maxStem
            ) {
                // add the deposit to the low stalk deposits array if we want to use the low stalk deposits last.
                if (filterParams.lowStalkDeposits == LibSiloHelpers.Mode.USE_LAST) {
                    vars.lowStalkStems[vars.lowStalkCount] = vars.stem;
                    vars.lowStalkAmounts[vars.lowStalkCount] = vars.depositAmount;
                    vars.lowStalkCount++;
                }
                // skip if we don't want to use low stalk deposits.
                continue;
            }

            // Check if this deposit is in the existing plan and calculate remaining amount
            vars.remainingAmount = LibSiloHelpers.checkDepositInExistingPlan(
                token,
                vars.stem,
                vars.depositAmount,
                excludingPlan
            );

            // Skip if no remaining amount available
            if (vars.remainingAmount == 0) continue;

            // Calculate amount to take from this deposit
            vars.amountFromDeposit = vars.remainingAmount;
            if (vars.remainingAmount > vars.remainingBeansNeeded) {
                vars.amountFromDeposit = vars.remainingBeansNeeded;
            }

            stems[vars.currentIndex] = vars.stem;
            amounts[vars.currentIndex] = vars.amountFromDeposit;
            vars.availableAmount += vars.amountFromDeposit;
            vars.remainingBeansNeeded -= vars.amountFromDeposit;
            vars.currentIndex++;

            if (vars.remainingBeansNeeded == 0) break;
        }

        // if the user wants to use the low stalk deposits last, and there are remaining beans needed,
        // and there are low stalk deposits, process them.
        if (
            filterParams.lowStalkDeposits == LibSiloHelpers.Mode.USE_LAST &&
            vars.remainingBeansNeeded > 0 &&
            vars.lowStalkCount > 0
        ) {
            // (stems and amounts are ordered backwards from the previous for loop, and thus does
            // not need to loop backwards).
            for (uint256 i = 0; i < vars.lowStalkCount && vars.remainingBeansNeeded > 0; i++) {
                vars.stem = vars.lowStalkStems[i];
                vars.depositAmount = vars.lowStalkAmounts[i];

                // Check against existing plan
                vars.remainingAmount = LibSiloHelpers.checkDepositInExistingPlan(
                    token,
                    vars.stem,
                    vars.depositAmount,
                    excludingPlan
                );

                if (vars.remainingAmount == 0) continue;

                vars.amountFromDeposit = vars.remainingAmount;
                if (vars.remainingAmount > vars.remainingBeansNeeded) {
                    vars.amountFromDeposit = vars.remainingBeansNeeded;
                }

                stems[vars.currentIndex] = vars.stem;
                amounts[vars.currentIndex] = vars.amountFromDeposit;
                vars.availableAmount += vars.amountFromDeposit;
                vars.remainingBeansNeeded -= vars.amountFromDeposit;
                vars.currentIndex++;

                if (vars.remainingBeansNeeded == 0) break;
            }
        }

        // Set the length of the arrays
        uint256 currentIndex = vars.currentIndex;
        assembly {
            mstore(stems, currentIndex)
            mstore(amounts, currentIndex)
        }

        return (stems, amounts, vars.availableAmount);
    }

    /**
     * @notice Returns the index of a token in the whitelisted tokens array
     * @dev Returns 0 for the bean token, otherwise returns the index in the whitelisted tokens array
     * @param token The token to get the index for
     * @return index The index of the token (0 for bean token, otherwise index in whitelisted tokens array)
     */
    function getTokenIndex(address token) public view returns (uint8 index) {
        // This relies on the assumption that the Bean token is whitelisted first
        if (token == beanstalk.getBeanToken()) {
            return 0;
        }
        address[] memory whitelistedTokens = getWhitelistStatusAddresses();
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            if (whitelistedTokens[i] == token) {
                return uint8(i);
            }
        }
        revert("Token not found");
    }

    /**
     * @notice Returns the total amount of Beans available from a given token
     * @param account The address of the account that owns the deposits
     * @param token The token to calculate available beans from (either Bean or LP token)
     * @return beanAmountAvailable The amount of Beans available if token is Bean, or the amount of
     * Beans that would be received from removing all LP if token is an LP token
     */
    function getBeanAmountAvailable(
        address account,
        address token
    ) external view returns (uint256 beanAmountAvailable) {
        // Get total amount deposited
        (, uint256[] memory amounts) = getSortedDeposits(account, token);
        uint256 totalAmount;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }

        // If token is Bean, return total amount
        if (token == beanstalk.getBeanToken()) {
            return totalAmount;
        }

        // If token is LP and we have deposits, calculate Bean amount from LP
        if (totalAmount > 0) {
            return
                IWell(token).getRemoveLiquidityOneTokenOut(
                    totalAmount,
                    IERC20(beanstalk.getBeanToken())
                );
        }

        return 0;
    }

    /**
     * @notice Returns arrays of stems and amounts for all deposits, sorted by stem in descending order
     * @dev This function could be made more gas efficient by using a more efficient sorting algorithm
     * @param account The address of the account that owns the deposits
     * @param token The token to get deposits for
     * @return stems Array of stems in descending order
     * @return amounts Array of corresponding amounts for each stem
     */
    function getSortedDeposits(
        address account,
        address token
    ) public view returns (int96[] memory stems, uint256[] memory amounts) {
        uint256[] memory depositIds = beanstalk.getTokenDepositIdsForAccount(account, token);
        if (depositIds.length == 0) revert("No deposits");

        // Initialize arrays with exact size since we know all deposits are valid
        stems = new int96[](depositIds.length);
        amounts = new uint256[](depositIds.length);

        // Collect all deposits
        for (uint256 i = 0; i < depositIds.length; i++) {
            (, int96 stem) = getAddressAndStem(depositIds[i]);
            (uint256 amount, ) = beanstalk.getDeposit(account, token, stem);
            stems[i] = stem;
            amounts[i] = amount;
        }

        // Sort deposits by stem in descending order using bubble sort
        for (uint256 i = 0; i < depositIds.length - 1; i++) {
            for (uint256 j = 0; j < depositIds.length - i - 1; j++) {
                if (stems[j] < stems[j + 1]) {
                    // Swap stems
                    int96 tempStem = stems[j];
                    stems[j] = stems[j + 1];
                    stems[j + 1] = tempStem;

                    // Swap corresponding amounts
                    uint256 tempAmount = amounts[j];
                    amounts[j] = amounts[j + 1];
                    amounts[j + 1] = tempAmount;
                }
            }
        }
    }

    /**
     * @notice Helper function to get the address and stem from a deposit ID
     * @dev This is a copy of LibBytes.unpackAddressAndStem for gas purposes
     * @param depositId The ID of the deposit to get the address and stem for
     * @return token The address of the token
     * @return stem The stem value of the deposit
     */
    function getAddressAndStem(uint256 depositId) public pure returns (address token, int96 stem) {
        return (address(uint160(depositId >> 96)), int96(int256(depositId)));
    }

    /**
     * @notice Returns the addresses of all whitelisted tokens, even those that have been Dewhitelisted
     * @return addresses The addresses of all whitelisted tokens
     */
    function getWhitelistStatusAddresses() public view returns (address[] memory) {
        IBeanstalk.WhitelistStatus[] memory whitelistStatuses = beanstalk.getWhitelistStatuses();
        address[] memory addresses = new address[](whitelistStatuses.length);
        for (uint256 i = 0; i < whitelistStatuses.length; i++) {
            addresses[i] = whitelistStatuses[i].token;
        }
        return addresses;
    }
}

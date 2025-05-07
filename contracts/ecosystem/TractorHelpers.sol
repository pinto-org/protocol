// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {Call, IWell, IERC20} from "../interfaces/basin/IWell.sol";
import {IBeanstalkWellFunction} from "contracts/interfaces/basin/IBeanstalkWellFunction.sol";
import {BeanstalkPrice, P} from "./price/BeanstalkPrice.sol";
import {ReservesType} from "./price/WellPrice.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {Junction} from "./junction/Junction.sol";
import {LibTokenSilo} from "contracts/libraries/Silo/LibTokenSilo.sol";
import {PriceManipulation} from "./PriceManipulation.sol";
import {PerFunctionPausable} from "./PerFunctionPausable.sol";
import {IOperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {LibTractorHelpers} from "contracts/libraries/Silo/LibTractorHelpers.sol";

/**
 * @title TractorHelpers
 * @author FordPinto
 * @notice Helper contract for Silo operations. For use with Tractor.
 */
contract TractorHelpers is Junction, PerFunctionPausable {
    // Special token index values for withdrawal strategies
    uint8 internal constant LOWEST_PRICE_STRATEGY = type(uint8).max;
    uint8 internal constant LOWEST_SEED_STRATEGY = type(uint8).max - 1;

    IBeanstalk immutable beanstalk;
    BeanstalkPrice immutable beanstalkPrice;
    PriceManipulation immutable priceManipulation;

    enum RewardType {
        ERC20,
        ERC1155
    }

    event OperatorReward(
        RewardType rewardType,
        address indexed publisher,
        address indexed operator,
        address token,
        int256 amount
    );

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
    }

    constructor(
        address _beanstalk,
        address _beanstalkPrice,
        address _owner,
        address _priceManipulation
    ) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
        beanstalkPrice = BeanstalkPrice(_beanstalkPrice);
        priceManipulation = PriceManipulation(_priceManipulation);
    }

    /**
     * @notice Returns a plan for withdrawing beans from multiple sources
     * @param account The account to withdraw from
     * @param tokenIndices Array of indices corresponding to whitelisted tokens to try as sources.
     * Special cases when array length is 1:
     * - If value is LOWEST_PRICE_STRATEGY (uint8.max): Use tokens in ascending price order
     * - If value is LOWEST_SEED_STRATEGY (uint8.max - 1): Use tokens in ascending seed order
     * @param targetAmount The total amount of beans to withdraw
     * @param maxGrownStalkPerBdv The maximum amount of grown stalk allowed to be used for the withdrawal, per bdv
     * @param excludeBean Whether to exclude the Bean token when using special strategies
     * @param excludingPlan Optional plan containing deposits that have been partially used. The function will account for remaining amounts in these deposits.
     * @return plan The withdrawal plan containing source tokens, stems, amounts, and available beans
     */
    function getWithdrawalPlanExcludingPlan(
        address account,
        uint8[] memory tokenIndices,
        uint256 targetAmount,
        uint256 maxGrownStalkPerBdv,
        bool excludeBean,
        LibTractorHelpers.WithdrawalPlan memory excludingPlan
    ) public view returns (LibTractorHelpers.WithdrawalPlan memory plan) {
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
                (tokenIndices, ) = getTokensAscendingPrice(excludeBean);
            } else if (tokenIndices[0] == LOWEST_SEED_STRATEGY) {
                // Use ascending seeds strategy
                (tokenIndices, ) = getTokensAscendingSeeds(excludeBean);
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

            // Calculate minimum stem tip from grown stalk for this token
            (int96 minStem, ) = beanstalk.calculateStemForTokenFromGrownStalk(
                sourceToken,
                maxGrownStalkPerBdv,
                1e6
            );

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
                    minStem,
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
                vars.lpNeeded = getLPTokensToWithdrawForBeans(
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
                    minStem,
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
     * @param maxGrownStalkPerBdv The maximum amount of grown stalk allowed to be used for the withdrawal, per bdv
     * @return plan The withdrawal plan containing source tokens, stems, amounts, and available beans
     */
    function getWithdrawalPlan(
        address account,
        uint8[] memory tokenIndices,
        uint256 targetAmount,
        uint256 maxGrownStalkPerBdv
    ) public view returns (LibTractorHelpers.WithdrawalPlan memory plan) {
        LibTractorHelpers.WithdrawalPlan memory emptyPlan;
        return
            getWithdrawalPlanExcludingPlan(
                account,
                tokenIndices,
                targetAmount,
                maxGrownStalkPerBdv,
                false,
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
     * @param maxGrownStalkPerBdv The maximum amount of grown stalk allowed to be used for the withdrawal, per bdv
     * @param slippageRatio The price slippage ratio for a lp token withdrawal, between the instantaneous price and the current price
     * @param mode The transfer mode for sending tokens back to user
     * @param plan The withdrawal plan to use, or null to generate one
     * @return amountWithdrawn The total amount of beans withdrawn
     */
    function withdrawBeansFromSources(
        address account,
        uint8[] memory tokenIndices,
        uint256 targetAmount,
        uint256 maxGrownStalkPerBdv,
        uint256 slippageRatio,
        LibTransfer.To mode,
        LibTractorHelpers.WithdrawalPlan memory plan
    ) external payable whenFunctionNotPaused returns (uint256) {
        // If passed in plan is empty, get one
        if (plan.sourceTokens.length == 0) {
            plan = getWithdrawalPlan(account, tokenIndices, targetAmount, maxGrownStalkPerBdv);
        }

        uint256 amountWithdrawn = 0;
        address beanToken = beanstalk.getBeanToken();

        // Execute withdrawal plan
        for (uint256 i = 0; i < plan.sourceTokens.length; i++) {
            address sourceToken = plan.sourceTokens[i];

            // Skip Bean token for price manipulation check since it's not a Well
            if (sourceToken != beanToken) {
                // Check for price manipulation in the Well
                (address nonBeanToken, ) = IBeanstalk(beanstalk).getNonBeanTokenAndIndexFromWell(
                    sourceToken
                );
                require(
                    priceManipulation.isValidSlippage(
                        IWell(sourceToken),
                        IERC20(nonBeanToken),
                        slippageRatio
                    ),
                    "Price manipulation detected"
                );
            }

            // If source is bean token, withdraw directly
            if (sourceToken == beanToken) {
                beanstalk.withdrawDeposits(sourceToken, plan.stems[i], plan.amounts[i], mode);
                amountWithdrawn += plan.availableBeans[i];
            } else {
                // For LP tokens, first withdraw LP tokens to the user's internal balance
                beanstalk.withdrawDeposits(
                    sourceToken,
                    plan.stems[i],
                    plan.amounts[i],
                    LibTransfer.To.INTERNAL
                );

                // Calculate total amount of LP tokens to transfer
                uint256 totalLPAmount = 0;
                for (uint256 j = 0; j < plan.amounts[i].length; j++) {
                    totalLPAmount += plan.amounts[i][j];
                }

                // Transfer LP tokens to this contract's external balance
                beanstalk.transferInternalTokenFrom(
                    IERC20(sourceToken),
                    account,
                    address(this),
                    totalLPAmount, // Use the total sum of all amounts
                    LibTransfer.To.EXTERNAL
                );

                // Then remove liquidity to get Beans
                IERC20(sourceToken).approve(sourceToken, totalLPAmount);
                IWell(sourceToken).removeLiquidityOneToken(
                    totalLPAmount,
                    IERC20(beanToken),
                    plan.availableBeans[i],
                    address(this),
                    type(uint256).max
                );

                // Transfer from this contract's external balance to the user's internal/external balance depending on mode
                if (mode == LibTransfer.To.INTERNAL) {
                    // approve spending of Beans from this contract's external balance
                    IERC20(beanToken).approve(address(beanstalk), plan.availableBeans[i]);
                    beanstalk.sendTokenToInternalBalance(
                        beanToken,
                        account,
                        plan.availableBeans[i]
                    );
                } else {
                    IERC20(beanToken).transfer(account, plan.availableBeans[i]);
                }
                amountWithdrawn += plan.availableBeans[i];
            }
        }

        return amountWithdrawn;
    }

    /**
     * @notice Returns the BeanstalkPrice contract address
     */
    function getBeanstalkPrice() external view returns (address) {
        return address(beanstalkPrice);
    }

    /**
     * @notice Returns all whitelisted assets and their seed values, sorted from highest to lowest seeds
     * @return tokens Array of token addresses
     * @return seeds Array of corresponding seed values
     */
    function getSortedWhitelistedTokensBySeeds()
        external
        view
        returns (address[] memory tokens, uint256[] memory seeds)
    {
        // Get whitelisted tokens
        tokens = getWhitelistStatusAddresses();
        seeds = new uint256[](tokens.length);

        // Get seed values for each token
        for (uint256 i = 0; i < tokens.length; i++) {
            seeds[i] = beanstalk.tokenSettings(tokens[i]).stalkEarnedPerSeason;
        }

        // Sort tokens and seeds arrays (bubble sort)
        (tokens, seeds) = sortTokens(tokens, seeds);

        return (tokens, seeds);
    }

    /**
     * @notice Returns the token with the highest seed value and its seed amount
     * @return highestSeedToken The token address with the highest seed value
     * @return seedAmount The seed value of the highest seed token
     */
    function getHighestSeedToken()
        external
        view
        returns (address highestSeedToken, uint256 seedAmount)
    {
        address[] memory tokens = getWhitelistStatusAddresses();
        require(tokens.length > 0, "No whitelisted tokens");

        highestSeedToken = tokens[0];
        seedAmount = beanstalk.tokenSettings(tokens[0]).stalkEarnedPerSeason;

        for (uint256 i = 1; i < tokens.length; i++) {
            uint256 currentSeed = beanstalk.tokenSettings(tokens[i]).stalkEarnedPerSeason;
            if (currentSeed > seedAmount) {
                seedAmount = currentSeed;
                highestSeedToken = tokens[i];
            }
        }

        return (highestSeedToken, seedAmount);
    }

    /**
     * @notice Returns the token with the lowest seed value and its seed amount
     * @return lowestSeedToken The token address with the lowest seed value
     * @return seedAmount The seed value of the lowest seed token
     */
    function getLowestSeedToken()
        external
        view
        returns (address lowestSeedToken, uint256 seedAmount)
    {
        address[] memory tokens = getWhitelistStatusAddresses();
        require(tokens.length > 0, "No whitelisted tokens");

        lowestSeedToken = tokens[0];
        seedAmount = beanstalk.tokenSettings(tokens[0]).stalkEarnedPerSeason;

        for (uint256 i = 1; i < tokens.length; i++) {
            uint256 currentSeed = beanstalk.tokenSettings(tokens[i]).stalkEarnedPerSeason;
            if (currentSeed < seedAmount) {
                seedAmount = currentSeed;
                lowestSeedToken = tokens[i];
            }
        }

        return (lowestSeedToken, seedAmount);
    }

    /**
     * @notice Gets the list of tokens that a user has deposited in the silo
     * @param account The address of the user
     * @return depositedTokens Array of token addresses that the user has deposited
     */
    function getUserDepositedTokens(
        address account
    ) external view returns (address[] memory depositedTokens) {
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
     * @notice Returns arrays of stems and amounts for all deposits, sorted by stem in descending order
     * @dev This function could be made more gas efficient by using a more efficient sorting algorithm
     * @param account The address of the account that owns the deposits
     * @param token The token to get deposits for
     * @param amount The amount of tokens to withdraw
     * @param minStem The minimum stem value to consider for withdrawal
     * @param excludingPlan Optional plan containing deposits that have been partially used. The function will account for remaining amounts in these deposits.
     * @return stems Array of stems in descending order
     * @return amounts Array of corresponding amounts for each stem
     * @return availableAmount The total amount available to withdraw (may be less than requested amount)
     */
    function getDepositStemsAndAmountsToWithdraw(
        address account,
        address token,
        uint256 amount,
        int96 minStem,
        LibTractorHelpers.WithdrawalPlan memory excludingPlan
    )
        public
        view
        returns (int96[] memory stems, uint256[] memory amounts, uint256 availableAmount)
    {
        uint256[] memory depositIds = beanstalk.getTokenDepositIdsForAccount(account, token);
        if (depositIds.length == 0) return (new int96[](0), new uint256[](0), 0);

        // Initialize arrays with max possible size
        stems = new int96[](depositIds.length);
        amounts = new uint256[](depositIds.length);

        // Track state
        uint256 remainingBeansNeeded = amount;
        uint256 currentIndex;
        availableAmount = 0;

        // Process deposits in reverse order (highest stem to lowest)
        for (uint256 i = depositIds.length; i > 0; i--) {
            (, int96 stem) = getAddressAndStem(depositIds[i - 1]);

            // Skip if stem is less than minStem
            if (stem < minStem) {
                continue;
            }

            (uint256 depositAmount, ) = beanstalk.getDeposit(account, token, stem);

            // Check if this deposit is in the existing plan and calculate remaining amount
            uint256 remainingAmount = depositAmount;
            for (uint256 j = 0; j < excludingPlan.sourceTokens.length; j++) {
                if (excludingPlan.sourceTokens[j] == token) {
                    for (uint256 k = 0; k < excludingPlan.stems[j].length; k++) {
                        if (excludingPlan.stems[j][k] == stem) {
                            // If the deposit was fully used in the existing plan, skip it
                            if (excludingPlan.amounts[j][k] >= depositAmount) {
                                remainingAmount = 0;
                                break;
                            }
                            // Otherwise, subtract the used amount from the remaining amount
                            remainingAmount = depositAmount - excludingPlan.amounts[j][k];
                            break;
                        }
                    }
                    if (remainingAmount == 0) break;
                }
            }

            // Skip if no remaining amount available
            if (remainingAmount == 0) continue;

            // Calculate amount to take from this deposit
            uint256 amountFromDeposit = remainingAmount;
            if (remainingAmount > remainingBeansNeeded) {
                amountFromDeposit = remainingBeansNeeded;
            }

            stems[currentIndex] = stem;
            amounts[currentIndex] = amountFromDeposit;
            availableAmount += amountFromDeposit;
            remainingBeansNeeded -= amountFromDeposit;
            currentIndex++;

            if (remainingBeansNeeded == 0) break;
        }

        // Resize arrays using assembly to match currentIndex
        assembly {
            mstore(stems, currentIndex)
            mstore(amounts, currentIndex)
        }

        return (stems, amounts, availableAmount);
    }

    /**
     * @notice Returns arrays of stems and amounts for all deposits, sorted by stem in descending order
     * @dev This function could be made more gas efficient by using a more efficient sorting algorithm
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
        LibTractorHelpers.WithdrawalPlan memory emptyPlan;
        return getDepositStemsAndAmountsToWithdraw(account, token, amount, minStem, emptyPlan);
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
     * @notice Returns the amount of LP tokens that must be withdrawn to receive a specific amount of Beans
     * @param beanAmount The amount of Beans desired
     * @param well The Well LP token address
     * @return lpAmount The amount of LP tokens needed
     */
    function getLPTokensToWithdrawForBeans(
        uint256 beanAmount,
        address well
    ) public view returns (uint256 lpAmount) {
        // Get current reserves if not provided
        uint256[] memory reserves = IWell(well).getReserves();

        // Get bean index in the well
        uint256 beanIndex = beanstalk.getBeanIndex(IWell(well).tokens());

        // Get the well function
        Call memory wellFunction = IWell(well).wellFunction();

        // Calculate current LP supply
        uint256 lpSupplyNow = IBeanstalkWellFunction(wellFunction.target).calcLpTokenSupply(
            reserves,
            wellFunction.data
        );

        // Calculate reserves after removing beans

        reserves[beanIndex] = reserves[beanIndex] - beanAmount;

        // Calculate new LP supply after removing beans
        uint256 lpSupplyAfter = IBeanstalkWellFunction(wellFunction.target).calcLpTokenSupply(
            reserves,
            wellFunction.data
        );

        // The difference is how many LP tokens need to be removed in order to withdraw beanAmount
        return lpSupplyNow - lpSupplyAfter;
    }

    /**
     * @notice Returns all whitelisted tokens sorted by seed value (ascending)
     * @param excludeBean If true, excludes the Bean token from the returned arrays
     * @return tokenIndices Array of token indices in the whitelisted tokens array, sorted by seed value (ascending)
     * @return seeds Array of corresponding seed values
     */
    function getTokensAscendingSeeds(
        bool excludeBean
    ) public view returns (uint8[] memory tokenIndices, uint256[] memory seeds) {
        // Get whitelisted tokens with their status
        IBeanstalk.WhitelistStatus[] memory whitelistStatuses = beanstalk.getWhitelistStatuses();
        require(whitelistStatuses.length > 0, "No whitelisted tokens");

        address beanToken = beanstalk.getBeanToken();

        // Count active whitelisted tokens (not dewhitelisted)
        uint256 whitelistedCount = 0;
        for (uint256 i = 0; i < whitelistStatuses.length; i++) {
            if (whitelistStatuses[i].isWhitelisted) {
                // Skip Bean token if excludeBean is true
                if (excludeBean && whitelistStatuses[i].token == beanToken) {
                    continue;
                }
                whitelistedCount++;
            }
        }

        require(whitelistedCount > 0, "No active whitelisted tokens");

        // Initialize arrays with the count of active whitelisted tokens
        tokenIndices = new uint8[](whitelistedCount);
        seeds = new uint256[](whitelistedCount);

        // Populate arrays with only active whitelisted tokens
        uint256 activeIndex = 0;
        for (uint256 i = 0; i < whitelistStatuses.length; i++) {
            if (whitelistStatuses[i].isWhitelisted) {
                // Skip Bean token if excludeBean is true
                if (excludeBean && whitelistStatuses[i].token == beanToken) {
                    continue;
                }
                // Keep the original index from whitelistStatuses for tokenIndices
                tokenIndices[activeIndex] = uint8(i);
                seeds[activeIndex] = beanstalk
                    .tokenSettings(whitelistStatuses[i].token)
                    .stalkEarnedPerSeason;
                activeIndex++;
            }
        }

        // Sort arrays by seed value (ascending)
        (tokenIndices, seeds) = sortTokenIndices(tokenIndices, seeds);

        return (tokenIndices, seeds);
    }

    /**
     * @notice Returns all whitelisted tokens sorted by seed value (ascending)
     * @return tokenIndices Array of token indices in the whitelisted tokens array, sorted by seed value (ascending)
     * @return seeds Array of corresponding seed values
     */
    function getTokensAscendingSeeds()
        public
        view
        returns (uint8[] memory tokenIndices, uint256[] memory seeds)
    {
        return getTokensAscendingSeeds(false);
    }

    /**
     * @notice Returns all whitelisted tokens sorted by price (ascending)
     * @param excludeBean If true, excludes the Bean token from the returned arrays
     * @return tokenIndices Array of token indices in the whitelisted tokens array, sorted by price (ascending)
     * @return prices Array of corresponding prices
     */
    function getTokensAscendingPrice(
        bool excludeBean
    ) public view returns (uint8[] memory tokenIndices, uint256[] memory prices) {
        // Get whitelisted tokens with their status
        IBeanstalk.WhitelistStatus[] memory whitelistStatuses = beanstalk.getWhitelistStatuses();
        require(whitelistStatuses.length > 0, "No whitelisted tokens");

        address beanToken = beanstalk.getBeanToken();

        // Count active whitelisted tokens (not dewhitelisted)
        uint256 whitelistedCount = 0;
        for (uint256 i = 0; i < whitelistStatuses.length; i++) {
            if (whitelistStatuses[i].isWhitelisted) {
                // Skip Bean token if excludeBean is true
                if (excludeBean && whitelistStatuses[i].token == beanToken) {
                    continue;
                }
                whitelistedCount++;
            }
        }

        require(whitelistedCount > 0, "No active whitelisted tokens");

        // Initialize arrays with the count of active whitelisted tokens
        tokenIndices = new uint8[](whitelistedCount);
        prices = new uint256[](whitelistedCount);

        // Get price from BeanstalkPrice for both Bean and LP tokens
        BeanstalkPrice.Prices memory p = beanstalkPrice.price(ReservesType.INSTANTANEOUS_RESERVES);

        // Populate arrays with only active whitelisted tokens
        uint256 activeIndex = 0;
        for (uint256 i = 0; i < whitelistStatuses.length; i++) {
            if (whitelistStatuses[i].isWhitelisted) {
                // Skip Bean token if excludeBean is true
                if (excludeBean && whitelistStatuses[i].token == beanToken) {
                    continue;
                }
                // Keep the original index from whitelistStatuses for tokenIndices
                tokenIndices[activeIndex] = uint8(i);
                prices[activeIndex] = getTokenPrice(whitelistStatuses[i].token, p);
                activeIndex++;
            }
        }

        // Sort arrays by price (ascending)
        (tokenIndices, prices) = sortTokenIndices(tokenIndices, prices);

        return (tokenIndices, prices);
    }

    /**
     * @notice Returns all whitelisted tokens sorted by price (ascending)
     * @return tokenIndices Array of token indices in the whitelisted tokens array, sorted by price (ascending)
     * @return prices Array of corresponding prices
     */
    function getTokensAscendingPrice()
        public
        view
        returns (uint8[] memory tokenIndices, uint256[] memory prices)
    {
        return getTokensAscendingPrice(false);
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
     * @notice Helper function to get the price of a token from BeanstalkPrice
     * @param token The token to get the price for
     * @param p The Prices struct from BeanstalkPrice
     * @return price The price of the token
     */
    function getTokenPrice(
        address token,
        BeanstalkPrice.Prices memory p
    ) internal view returns (uint256 price) {
        address bean = beanstalk.getBeanToken();
        if (token == bean) {
            return p.price;
        }
        // Find the non-Bean token in the pool's tokens array
        for (uint256 j = 0; j < p.ps.length; j++) {
            if (p.ps[j].pool == token) {
                return p.ps[j].price;
            }
        }
        revert("Token price not found");
    }

    /**
     * @notice Sorts tokens in ascending order based on the index array
     * @param tokens The tokens to sort
     * @param index The index array
     * @return sortedTokens The sorted tokens
     * @return sortedIndex The sorted index
     */
    function sortTokens(
        address[] memory tokens,
        uint256[] memory index
    ) internal pure returns (address[] memory, uint256[] memory) {
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
    ) internal pure returns (uint8[] memory, uint256[] memory) {
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

    /**
     * @notice helper function to tip the operator.
     * @dev if `tipAmount` is negative, the publisher is tipped instead.
     */
    function tip(
        address token,
        address publisher,
        address tipAddress,
        int256 tipAmount,
        LibTransfer.From from,
        LibTransfer.To to
    ) external {
        // Handle tip transfer based on whether it's positive or negative
        if (tipAmount > 0) {
            // Transfer tip to operator
            beanstalk.transferToken(IERC20(token), tipAddress, uint256(tipAmount), from, to);
        } else if (tipAmount < 0) {
            // Transfer tip from operator to user
            beanstalk.transferInternalTokenFrom(
                IERC20(token),
                tipAddress,
                publisher,
                uint256(-tipAmount),
                to
            );
        }

        emit OperatorReward(RewardType.ERC20, publisher, tipAddress, token, tipAmount);
    }

    /**
     * @notice Checks if the current operator is whitelisted
     * @param whitelistedOperators Array of whitelisted operator addresses
     * @return isWhitelisted Whether the current operator is whitelisted
     */
    function isOperatorWhitelisted(
        address[] calldata whitelistedOperators
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

    /**
     * @notice Combines multiple withdrawal plans into a single plan
     * @dev This function aggregates the amounts used from each deposit across all plans
     * @param plans Array of withdrawal plans to combine
     * @return combinedPlan A single withdrawal plan that represents the total usage across all input plans
     */
    function combineWithdrawalPlans(
        LibTractorHelpers.WithdrawalPlan[] memory plans
    ) external view returns (LibTractorHelpers.WithdrawalPlan memory) {
        // Call the library function directly
        return LibTractorHelpers.combineWithdrawalPlans(plans, beanstalk);
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

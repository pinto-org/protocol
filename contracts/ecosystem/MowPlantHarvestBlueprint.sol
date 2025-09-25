// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {LibTractorHelpers} from "contracts/libraries/Silo/LibTractorHelpers.sol";
import {BlueprintBase} from "./BlueprintBase.sol";

/**
 * @title MowPlantHarvestBlueprint
 * @author DefaultJuice
 * @notice Contract for mowing, planting and harvesting with Tractor, with a number of conditions
 */
contract MowPlantHarvestBlueprint is BlueprintBase {
    /**
     * @dev Minutes after sunrise to check if the totalDeltaB is about to be positive for the following season
     */
    uint256 public constant MINUTES_AFTER_SUNRISE = 55 minutes;

    /**
     * @notice Main struct for mow, plant and harvest blueprint
     * @param mowPlantHarvestParams Parameters related to mow, plant and harvest
     * @param opParams Parameters related to operators
     */
    struct MowPlantHarvestBlueprintStruct {
        MowPlantHarvestParams mowPlantHarvestParams;
        OperatorParamsExtended opParams;
    }

    /**
     * @notice Struct to hold mow, plant and harvest parameters
     * @param minMowAmount The minimum total claimable stalk threshold to mow
     * @param mintwaDeltaB The minimum twaDeltaB to mow if the protocol
     * is close to starting the next season above the value target
     * @param minPlantAmount The earned beans threshold to plant
     * @param minHarvestAmount The total harvestable pods threshold to harvest
     * -----------------------------------------------------------
     * @param sourceTokenIndices Indices of source tokens to withdraw from
     * @param maxGrownStalkPerBdv Maximum grown stalk per BDV allowed
     * @param slippageRatio The price slippage ratio for lp token withdrawal.
     * Only applicable for lp token withdrawals.
     */
    struct MowPlantHarvestParams {
        // Mow
        uint256 minMowAmount;
        uint256 mintwaDeltaB;
        // Plant
        uint256 minPlantAmount;
        // Harvest
        uint256 minHarvestAmount;
        // Withdrawal plan parameters for tipping
        uint8[] sourceTokenIndices;
        uint256 maxGrownStalkPerBdv;
        uint256 slippageRatio;
    }

    /**
     * @notice Struct to hold operator parameters including tips for mowing, planting and harvesting
     * -------------- Base OperatorParams --------------
     * @param whitelistedOperators Array of whitelisted operator addresses
     * @param tipAddress Address to send tip to
     * @param operatorTipAmount (unused)
     * -------------- Extended options --------------
     * @param mowTipAmount Amount of tip to pay to operator for mowing
     * @param plantTipAmount Amount of tip to pay to operator for planting
     * @param harvestTipAmount Amount of tip to pay to operator for harvesting
     */
    struct OperatorParamsExtended {
        OperatorParams opParamsBase;
        int256 mowTipAmount;
        int256 plantTipAmount;
        int256 harvestTipAmount;
    }

    /**
     * @notice Local variables for the mow, plant and harvest function
     * @dev Used to avoid stack too deep errors
     */
    struct MowPlantHarvestLocalVars {
        bytes32 orderHash;
        address account;
        address tipAddress;
        address beanToken;
        uint256 totalBeanTip;
        uint256 totalClaimableStalk;
        uint256 totalPlantableBeans;
        uint256 totalHarvestablePods;
        bool shouldMow;
        bool shouldPlant;
        bool shouldHarvest;
        IBeanstalk.Season seasonInfo;
        uint256[] harvestablePlots;
        LibTractorHelpers.WithdrawalPlan plan;
    }

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers
    ) BlueprintBase(_beanstalk, _owner, _tractorHelpers) {}

    /**
     * @notice Main entry point for the mow, plant and harvest blueprint
     * @param params The parameters for the mow, plant and harvest operation
     */
    function mowPlantHarvestBlueprint(
        MowPlantHarvestBlueprintStruct calldata params
    ) external payable whenFunctionNotPaused {
        // Initialize local variables
        MowPlantHarvestLocalVars memory vars;

        // Validate
        vars.orderHash = beanstalk.getCurrentBlueprintHash();
        vars.account = beanstalk.tractorUser();
        vars.tipAddress = params.opParams.opParamsBase.tipAddress;
        // Cache the current season struct
        vars.seasonInfo = beanstalk.time();

        // get the user state from the protocol and validate against params
        (
            vars.harvestablePlots,
            vars.shouldMow,
            vars.shouldPlant,
            vars.shouldHarvest
        ) = _getAndValidateUserState(vars.account, vars.seasonInfo.timestamp, params);

        // validate blueprint
        _validateBlueprint(vars.orderHash, vars.seasonInfo.current);

        // validate order params and revert early if invalid
        _validateParams(params);

        // if tip address is not set, set it to the operator
        vars.tipAddress = _resolveTipAddress(vars.tipAddress);

        // cache bean token
        vars.beanToken = beanstalk.getBeanToken();

        // Mow, Plant and Harvest
        // Check if user should harvest or plant
        // In the case a harvest or plant is executed, mow by default
        if (vars.shouldPlant || vars.shouldHarvest) vars.shouldMow = true;

        // Execute operations in order: mow first (if needed), then plant, then harvest
        if (vars.shouldMow) {
            beanstalk.mowAll(vars.account);
            vars.totalBeanTip += uint256(params.opParams.mowTipAmount);
        }

        // Plant if the conditions are met
        if (vars.shouldPlant) {
            beanstalk.plant();
            vars.totalBeanTip += uint256(params.opParams.plantTipAmount);
        }

        // Harvest if the conditions are met
        if (vars.shouldHarvest) {
            uint256 harvestedBeans = beanstalk.harvest(
                beanstalk.activeField(),
                vars.harvestablePlots,
                LibTransfer.To.INTERNAL
            );
            // pull from the harvest destination and deposit into silo
            beanstalk.deposit(vars.beanToken, harvestedBeans, LibTransfer.From.INTERNAL);
            vars.totalBeanTip += uint256(params.opParams.harvestTipAmount);
        }

        // Enforce the withdrawal plan and tip the total bean amount
        _enforceWithdrawalPlanAndTip(
            vars.account,
            vars.tipAddress,
            vars.beanToken,
            params.mowPlantHarvestParams.sourceTokenIndices,
            vars.totalBeanTip,
            params.mowPlantHarvestParams.maxGrownStalkPerBdv,
            params.mowPlantHarvestParams.slippageRatio,
            vars.plan // passed in plan is empty
        );

        // Update the last executed season for this blueprint
        _updateLastExecutedSeason(vars.orderHash, vars.seasonInfo.current);
    }

    /**
     * @notice Helper function to get the user state and validate against parameters
     * @param account The address of the user
     * @param params The parameters for the mow, plant and harvest operation
     * @return harvestablePlots The harvestable plot ids for the user, if any
     * @return shouldMow True if the user should mow
     * @return shouldPlant True if the user should plant
     * @return shouldHarvest True if the user should harvest
     */
    function _getAndValidateUserState(
        address account,
        uint256 previousSeasonTimestamp,
        MowPlantHarvestBlueprintStruct calldata params
    )
        internal
        view
        returns (
            uint256[] memory harvestablePlots,
            bool shouldMow,
            bool shouldPlant,
            bool shouldHarvest
        )
    {
        // get user state
        (
            uint256 totalClaimableStalk,
            uint256 totalPlantableBeans,
            uint256 totalHarvestablePods,
            uint256[] memory harvestablePlots
        ) = _getUserState(account);

        // validate params - only revert if none of the conditions are met
        shouldMow = _checkSmartMowConditions(
            params.mowPlantHarvestParams.mintwaDeltaB,
            params.mowPlantHarvestParams.minMowAmount,
            totalClaimableStalk,
            previousSeasonTimestamp
        );
        shouldPlant = totalPlantableBeans >= params.mowPlantHarvestParams.minPlantAmount;
        shouldHarvest = totalHarvestablePods >= params.mowPlantHarvestParams.minHarvestAmount;

        require(
            shouldMow || shouldPlant || shouldHarvest,
            "MowPlantHarvestBlueprint: None of the order conditions are met"
        );

        return (harvestablePlots, shouldMow, shouldPlant, shouldHarvest);
    }

    /**
     * @notice Check smart mow conditions to trigger a mow
     * @dev A smart mow happens when:
     * - `MINUTES_AFTER_SUNRISE` has passed since the last sunrise call
     * - The protocol is about to start the next season above the value target.
     * - The user has enough claimable stalk such as he gets more yield.
     * @return bool True if the user should smart mow, false otherwise
     */
    function _checkSmartMowConditions(
        uint256 mintwaDeltaB,
        uint256 minMowAmount,
        uint256 totalClaimableStalk,
        uint256 previousSeasonTimestamp
    ) internal view returns (bool) {
        if (block.timestamp - previousSeasonTimestamp < MINUTES_AFTER_SUNRISE) return false;

        // if the totalDeltaB and totalClaimableStalk are both greater than the min amount, return true
        // This also guards against double dipping the blueprint after planting or harvesting since stalk will be 0
        return totalClaimableStalk > minMowAmount && beanstalk.totalDeltaB() > int256(mintwaDeltaB);
    }

    /**
     * @notice helper function to get the user state to compare against parameters
     * @dev Increasing the total claimable stalk when planting or harvesting does not really matter
     * since we mow by default if we plant or harvest
     */
    function _getUserState(
        address account
    )
        internal
        view
        returns (
            uint256 totalClaimableStalk,
            uint256 totalPlantableBeans,
            uint256 totalHarvestablePods,
            uint256[] memory harvestablePlots
        )
    {
        address[] memory whitelistedTokens = beanstalk.getWhitelistedTokens();

        // check how much claimable stalk the user by all whitelisted tokens combined
        uint256[] memory grownStalks = beanstalk.balanceOfGrownStalkMultiple(
            account,
            whitelistedTokens
        );
        for (uint256 i = 0; i < grownStalks.length; i++) {
            totalClaimableStalk += grownStalks[i];
        }

        // check if user has plantable beans
        totalPlantableBeans = beanstalk.balanceOfEarnedBeans(account);

        // check if user has harvestable beans
        (totalHarvestablePods, harvestablePlots) = _userHarvestablePods(account);

        return (totalClaimableStalk, totalPlantableBeans, totalHarvestablePods, harvestablePlots);
    }

    /**
     * @notice Helper function to get the total harvestable pods and plots for a user
     * @param account The address of the user
     * @return totalUserHarvestablePods The total amount of harvestable pods for the user
     * @return userHarvestablePlots The harvestable plot ids for the user
     */
    function _userHarvestablePods(
        address account
    )
        internal
        view
        returns (uint256 totalUserHarvestablePods, uint256[] memory userHarvestablePlots)
    {
        // get field info and plot count directly
        uint256 activeField = beanstalk.activeField();
        uint256[] memory plotIndexes = beanstalk.getPlotIndexesFromAccount(account, activeField);
        uint256 harvestableIndex = beanstalk.harvestableIndex(activeField);

        if (plotIndexes.length == 0) return (0, new uint256[](0));

        // initialize array with full length
        userHarvestablePlots = new uint256[](plotIndexes.length);
        uint256 harvestableCount;

        // single loop to process all plot indexes directly
        for (uint256 i = 0; i < plotIndexes.length; i++) {
            uint256 startIndex = plotIndexes[i];
            uint256 plotPods = beanstalk.plot(account, activeField, startIndex);

            if (startIndex + plotPods <= harvestableIndex) {
                // Fully harvestable
                userHarvestablePlots[harvestableCount] = startIndex;
                totalUserHarvestablePods += plotPods;
                harvestableCount++;
            } else if (startIndex < harvestableIndex) {
                // Partially harvestable
                userHarvestablePlots[harvestableCount] = startIndex;
                totalUserHarvestablePods += harvestableIndex - startIndex;
                harvestableCount++;
            }
        }

        // resize array to actual harvestable plots count
        assembly {
            mstore(userHarvestablePlots, harvestableCount)
        }

        return (totalUserHarvestablePods, userHarvestablePlots);
    }

    /**
     * @dev validates the parameters for the mow, plant and harvest operation
     */
    function _validateParams(MowPlantHarvestBlueprintStruct calldata params) internal view {
        // Shared validations
        _validateSourceTokens(params.mowPlantHarvestParams.sourceTokenIndices);
        _validateOperatorParams(params.opParams.opParamsBase);

        // Blueprint specific validations
        // Validate that minPlantAmount and minHarvestAmount result in profit after their respective tips
        if (params.opParams.mowTipAmount >= 0) {
            require(
                params.mowPlantHarvestParams.minPlantAmount > uint256(params.opParams.mowTipAmount),
                "Min plant amount must be greater than mow tip amount"
            );
        }
        if (params.opParams.plantTipAmount >= 0) {
            require(
                params.mowPlantHarvestParams.minHarvestAmount >
                    uint256(params.opParams.plantTipAmount),
                "Min harvest amount must be greater than plant tip amount"
            );
        }
    }

    /**
     * @notice Helper function that creates a withdrawal plan and tips the operator the total bean tip amount
     * @param account The account to withdraw for
     * @param tipAddress The address to send the tip to
     * @param beanToken The cached bean token address
     * @param sourceTokenIndices The indices of the source tokens to withdraw from
     * @param totalBeanTip The total tip for mowing, planting and harvesting
     * @param maxGrownStalkPerBdv The maximum amount of grown stalk allowed to be used for the withdrawal, per bdv
     * @param slippageRatio The price slippage ratio for a lp token withdrawal, between the instantaneous price and the current price
     * @param plan The withdrawal plan to use, or null to generate one
     */
    function _enforceWithdrawalPlanAndTip(
        address account,
        address tipAddress,
        address beanToken,
        uint8[] memory sourceTokenIndices,
        uint256 totalBeanTip,
        uint256 maxGrownStalkPerBdv,
        uint256 slippageRatio,
        LibTractorHelpers.WithdrawalPlan memory plan
    ) internal {
        // Check if enough beans are available using getWithdrawalPlan
        LibTractorHelpers.WithdrawalPlan memory plan = tractorHelpers
            .getWithdrawalPlanExcludingPlan(
                account,
                sourceTokenIndices,
                totalBeanTip,
                maxGrownStalkPerBdv,
                plan // passed in plan is empty
            );

        // Execute the withdrawal plan to withdraw the tip amount
        tractorHelpers.withdrawBeansFromSources(
            account,
            sourceTokenIndices,
            totalBeanTip,
            maxGrownStalkPerBdv,
            slippageRatio,
            LibTransfer.To.INTERNAL,
            plan
        );

        // Tip the operator with the withdrawn beans
        tractorHelpers.tip(
            beanToken,
            account,
            tipAddress,
            int256(totalBeanTip),
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );
    }
}

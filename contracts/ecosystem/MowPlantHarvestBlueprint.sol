// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {TractorHelpers} from "./TractorHelpers.sol";
import {PerFunctionPausable} from "./PerFunctionPausable.sol";
import {LibTractorHelpers} from "contracts/libraries/Silo/LibTractorHelpers.sol";

/**
 * @title MowPlantHarvestBlueprint
 * @author DefaultJuice
 * @notice Contract for mowing, planting and harvesting with Tractor, with a number of conditions
 */
contract MowPlantHarvestBlueprint is PerFunctionPausable {
    /// @dev Buffer for operators to check if the protocol is close to printing
    uint256 public constant SMART_MOW_BUFFER = 5 minutes;

    /**
     * @notice Main struct for mow, plant and harvest blueprint
     * @param mowPlantHarvestParams Parameters related to mow, plant and harvest
     * @param opParams Parameters related to operators
     */
    struct MowPlantHarvestBlueprintStruct {
        MowPlantHarvestParams mowPlantHarvestParams;
        OperatorParams opParams;
    }

    /**
     * @notice Struct to hold mow, plant and harvest parameters
     * @param minMowAmount The minimum total claimable stalk threshold to mow
     * @param mintwaDeltaB The minimum twaDeltaB to mow if the protocol is close to printing
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
     * @notice Struct to hold operator parameters
     * @param whitelistedOperators What operators are allowed to execute the blueprint
     * @param tipAddress Address to send tip to
     * @param operatorTipAmount Amount of tip to pay to operator
     */
    struct OperatorParams {
        address[] whitelistedOperators;
        address tipAddress;
        int256 operatorTipAmount;
    }

    /**
     * @notice Local variables for the mow, plant and harvest function
     * @dev Used to avoid stack too deep errors
     */
    struct MowPlantHarvestLocalVars {
        bytes32 orderHash;
        address account;
        address tipAddress;
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

    // Mapping to track the last executed season for each order hash
    mapping(bytes32 orderHash => uint32 lastExecutedSeason) public orderLastExecutedSeason;

    // Contracts
    IBeanstalk public immutable beanstalk;
    TractorHelpers public immutable tractorHelpers;

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers
    ) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
        tractorHelpers = TractorHelpers(_tractorHelpers);
    }

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
        vars.tipAddress = params.opParams.tipAddress;
        // Cache the current season struct
        vars.seasonInfo = beanstalk.time();

        // get the user state from the protocol and validate against params
        (
            vars.harvestablePlots,
            vars.shouldMow,
            vars.shouldPlant,
            vars.shouldHarvest
        ) = _getAndValidateUserState(vars.account, vars.seasonInfo, params);

        // validate blueprint
        _validateBlueprint(vars.orderHash, vars.seasonInfo.current);

        // validate order params and revert early if invalid
        _validateParams(params);

        // if tip address is not set, set it to the operator
        if (vars.tipAddress == address(0)) vars.tipAddress = beanstalk.operator();

        // Withdrawal Plan and Tip
        // Check if enough beans are available using getWithdrawalPlan
        LibTractorHelpers.WithdrawalPlan memory plan = tractorHelpers
            .getWithdrawalPlanExcludingPlan(
                vars.account,
                params.mowPlantHarvestParams.sourceTokenIndices,
                uint256(params.opParams.operatorTipAmount),
                params.mowPlantHarvestParams.maxGrownStalkPerBdv,
                vars.plan // Passed in plan is empty
            );

        // Execute the withdrawal plan to withdraw the tip amount
        tractorHelpers.withdrawBeansFromSources(
            vars.account,
            params.mowPlantHarvestParams.sourceTokenIndices,
            uint256(params.opParams.operatorTipAmount),
            params.mowPlantHarvestParams.maxGrownStalkPerBdv,
            params.mowPlantHarvestParams.slippageRatio,
            LibTransfer.To.INTERNAL,
            plan
        );

        // Tip the operator with the withdrawn beans
        tractorHelpers.tip(
            beanstalk.getBeanToken(),
            vars.account,
            vars.tipAddress,
            params.opParams.operatorTipAmount,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );

        // Mow, Plant and Harvest
        // Check if user should harvest or plant
        // In the case a harvest or plant is executed, mow by default
        if (vars.shouldPlant || vars.shouldHarvest) vars.shouldMow = true;

        // Execute operations in order: mow first (if needed), then plant, then harvest
        if (vars.shouldMow) beanstalk.mowAll(vars.account);

        // Plant if the conditions are met
        if (vars.shouldPlant) beanstalk.plant();

        // Harvest if the conditions are met
        if (vars.shouldHarvest) {
            uint256 harvestedBeans = beanstalk.harvest(
            beanstalk.activeField(),
                vars.harvestablePlots,
                LibTransfer.To.INTERNAL
            );

            // pull from the harvest destination and deposit into silo
            beanstalk.deposit(beanstalk.getBeanToken(), harvestedBeans, LibTransfer.From.INTERNAL);
        }

        // Update the last executed season for this blueprint
        updateLastExecutedSeason(vars.orderHash, vars.seasonInfo.current);
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
        IBeanstalk.Season memory seasonInfo,
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
            seasonInfo.timestamp,
            seasonInfo.period
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
     * @dev A smart mow happens when the protocol is about to print
     * and the user has enough claimable stalk such as he gets more yield.
     * note: Assumes sunrise is called at the top of the hour.
     * @return bool True if the user should smart mow, false otherwise
     */
    function _checkSmartMowConditions(
        uint256 mintwaDeltaB,
        uint256 minMowAmount,
        uint256 totalClaimableStalk,
        uint256 previousSeasonTimestamp,
        uint256 seasonPeriod
    ) internal view returns (bool) {
        // if the time until next season is more than the buffer don't mow, too early
        uint256 nextSeasonExpectedTimestamp = previousSeasonTimestamp + seasonPeriod;
        if (nextSeasonExpectedTimestamp - block.timestamp > SMART_MOW_BUFFER) return false;

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
        // get whitelisted tokens
        address[] memory whitelistedTokens = beanstalk.getWhitelistedTokens();

        // check how much claimable stalk the user by all whitelisted tokens combined
        uint256[] memory grownStalks = beanstalk.balanceOfGrownStalkMultiple(
            account,
            whitelistedTokens
        );

        // sum it to get total claimable grown stalk
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
     * @return totalHarvestablePods The total amount of harvestable pods
     * @return harvestablePlots The harvestable plot ids for the user
     */
    function _userHarvestablePods(
        address account
    ) internal view returns (uint256 totalHarvestablePods, uint256[] memory harvestablePlots) {
        // Get all plots for the user in the field
        IBeanstalk.Plot[] memory plots = beanstalk.getPlotsFromAccount(
            account,
            beanstalk.activeField()
        );
        uint256 harvestableIndex = beanstalk.harvestableIndex(beanstalk.activeField());

        // First, count how many plots are at least partially harvestable
        uint256 count;
        for (uint256 i = 0; i < plots.length; i++) {
            uint256 startIndex = plots[i].index;
            if (startIndex < harvestableIndex) {
                count++;
            }
        }

        // Allocate the array
        harvestablePlots = new uint256[](count);
        uint256 j = 0;

        // Now, fill the array and sum pods
        for (uint256 i = 0; i < plots.length; i++) {
            uint256 startIndex = plots[i].index;
            uint256 plotPods = plots[i].pods;

            if (startIndex + plotPods <= harvestableIndex) {
                // Fully harvestable
                harvestablePlots[j++] = startIndex;
                totalHarvestablePods += plotPods;
            } else if (startIndex < harvestableIndex) {
                // Partially harvestable
                harvestablePlots[j++] = startIndex;
                totalHarvestablePods += harvestableIndex - startIndex;
            }
        }

        return (totalHarvestablePods, harvestablePlots);
    }

    /// @dev validates the parameters for the mow, plant and harvest operation
    function _validateParams(MowPlantHarvestBlueprintStruct calldata params) internal view {
        require(
            params.mowPlantHarvestParams.sourceTokenIndices.length > 0,
            "Must provide at least one source token"
        );
        // Check if the executing operator (msg.sender) is whitelisted
        require(
            tractorHelpers.isOperatorWhitelisted(params.opParams.whitelistedOperators),
            "Operator not whitelisted"
        );
        // Validate that minPlantAmount and minHarvestAmount result in profit
        if (params.opParams.operatorTipAmount >= 0) {
            require(
                params.mowPlantHarvestParams.minPlantAmount >
                    uint256(params.opParams.operatorTipAmount),
                "Min plant amount must be greater than operator tip amount"
            );
            require(
                params.mowPlantHarvestParams.minHarvestAmount >
                    uint256(params.opParams.operatorTipAmount),
                "Min harvest amount must be greater than operator tip amount"
            );
        }
    }

    /// @dev validates info related to the blueprint such as the order hash and the last executed season
    function _validateBlueprint(bytes32 orderHash, uint32 currentSeason) internal view {
        require(orderHash != bytes32(0), "No active blueprint, function must run from Tractor");
        require(
            orderLastExecutedSeason[orderHash] < currentSeason,
            "Blueprint already executed this season"
        );
    }

    /// @dev updates the last executed season for a given order hash
    function updateLastExecutedSeason(bytes32 orderHash, uint32 season) internal {
        orderLastExecutedSeason[orderHash] = season;
    }
}

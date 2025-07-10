// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {TractorHelpers} from "./TractorHelpers.sol";
import {PerFunctionPausable} from "./PerFunctionPausable.sol";
import {BeanstalkPrice} from "./price/BeanstalkPrice.sol";
import {LibTractorHelpers} from "contracts/libraries/Silo/LibTractorHelpers.sol";

/**
 * @title MowPlantHarvestBlueprint
 * @author DefaultJuice
 * @notice Contract for mowing, planting and harvesting with Tractor, with a number of conditions
 */
contract MowPlantHarvestBlueprint is PerFunctionPausable {
    /**
     * @notice Event emitted when a mow, plant and harvest order is complete, or no longer executable due to min sow being less than min sow per season
     * @param blueprintHash The hash of the blueprint
     * @param publisher The address of the publisher
     * @param totalAmountMowed The amount of beans mowed
     * @param totalAmountPlanted The amount of beans planted
     * @param totalAmountHarvested The amount of beans harvested
     */
    event MowPlantHarvestOrderComplete(
        bytes32 indexed blueprintHash,
        address indexed publisher,
        uint256 totalAmountMowed,
        uint256 totalAmountPlanted,
        uint256 totalAmountHarvested
    );

    /**
     * @notice Main struct for mow, plant and harvest blueprint
     * @param mowPlantHarvestParams Parameters related to mow, plant and harvest
     * @param opParams Parameters related to operators
     */
    struct MowPlantHarvestBlueprintStruct {
        MowPlantHarvestParams mowPlantHarvestParams;
        OperatorParams opParams;
    }

    /////////////////////// Parameters notes ////////////////////////
    // Mow:
    // We want them to mow continuously from a protocol perspective for stalk to be as real time as possible
    // The user wants to mow when the system is about to print (what does that mean? maybe a deltaB threshold?)
    ////////////////////////////////////////////////////////////////
    // Plant:
    // Generally people would want to plant if they have any amount of plantable beans
    // to get the compounding effect when printing.
    // One simple parameter is a min plant amount as a threshold after which the user would want to plant.
    // We can protect against them losing money from tips so that a new parameter should be
    // to plant if the plantable beans are more than the tip amount.
    // Or whether the tip is a minimum percentage of the plantable beans.
    ////////////////////////////////////////////////////////////////
    // Harvest:
    // Plots are partially harvestable. Do we want to harvest partial plots?
    // One parameter could be whether to harvest partial plots or not.
    // For sure one parameter should be if to redeposit to the silo or not.
    // Again, like planting, we can protect against them losing money from tips so that a new parameter should be
    // to harvest if the harvested beans are more than the tip amount.
    // Or whether the tip is a minimum percentage of the harvested beans.
    ////////////////////////////////////////////////////////////////
    // General:
    // If someone plants or harvests, we should mow by default.

    /**
     * @notice Struct to hold mow, plant and harvest parameters
     * @param minMowAmount The stalk threshold to mow
     * @param minPlantAmount The earned beans threshold to plant
     * @param minHarvestAmount The bean threshold to harvest
     * ---------------------------------------------------------
     * @param sourceTokenIndices Indices of source tokens to withdraw from
     * @param maxGrownStalkPerBdv Maximum grown stalk per BDV allowed
     * @param slippageRatio The price slippage ratio for a lp token withdrawal.
     * Only applicable for lp token withdrawals.
     * todo: add more parameters here if needed and validate them
     */
    struct MowPlantHarvestParams {
        // Regular parameters for mow, plant and harvest
        uint256 minMowAmount;
        uint256 minPlantAmount;
        uint256 minHarvestAmount;
        // Harvest specific parameters
        bool shouldRedeposit;
        // Where to send the harvested beans (only applicable if shouldRedeposit is false from a user pov)
        LibTransfer.To harvestDestination;
        // Withdrawal plan parameters for tipping
        uint8[] sourceTokenIndices;
        uint256 maxGrownStalkPerBdv;
        uint256 slippageRatio;
    }

    // Mapping to track the last executed season for each order hash
    mapping(bytes32 orderHash => uint32 lastExecutedSeason) public orderLastExecutedSeason;

    IBeanstalk public immutable beanstalk;
    TractorHelpers public immutable tractorHelpers;

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
        uint256[] harvestablePlots;
        LibTractorHelpers.WithdrawalPlan plan;
    }

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers
    ) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
        tractorHelpers = TractorHelpers(_tractorHelpers);
    }

    /// @dev main entry point
    function mowPlantHarvestBlueprint(
        MowPlantHarvestBlueprintStruct calldata params
    ) external payable whenFunctionNotPaused {
        // Initialize local variables
        MowPlantHarvestLocalVars memory vars;

        ////////////////////// Validation ////////////////////////

        // get order hash
        vars.orderHash = beanstalk.getCurrentBlueprintHash();
        // get the tractor user
        vars.account = beanstalk.tractorUser();
        // get the tip address
        vars.tipAddress = params.opParams.tipAddress;

        // get the user state from the protocol and validate against params
        (
            vars.totalClaimableStalk,
            vars.totalPlantableBeans,
            vars.totalHarvestablePods,
            vars.harvestablePlots,
            vars.shouldMow,
            vars.shouldPlant,
            vars.shouldHarvest
        ) = _getAndValidateUserState(vars.account, params);

        // validate blueprint
        _validateBlueprint(vars.orderHash);

        // validate order params and revert early if invalid
        _validateParams(params);

        // if tip address is not set, set it to the operator
        if (vars.tipAddress == address(0)) vars.tipAddress = beanstalk.operator();

        ////////////////////// Withdrawal Plan and Tip ////////////////////////

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

        ////////////////////// Mow, Plant and Harvest ////////////////////////

        // Check if user should harvest or plant
        // In the case a harvest or plant is executed, mow by default
        if (vars.shouldPlant || vars.shouldHarvest) vars.shouldMow = true;

        // Execute operations in order: mow first (if needed), then plant, then harvest
        if (vars.shouldMow) beanstalk.mowAll(vars.account);

        // Plant if the conditions are met
        if (vars.shouldPlant) beanstalk.plant();

        // Harvest if the conditions are met
        if (vars.shouldHarvest) {
            uint256 harvestedPods = beanstalk.harvest(
                beanstalk.activeField(),
                vars.harvestablePlots,
                params.mowPlantHarvestParams.harvestDestination
            );

            // Determine the deposit mode based on the harvest destination
            LibTransfer.From depositMode = params.mowPlantHarvestParams.harvestDestination ==
                LibTransfer.To.EXTERNAL
                ? LibTransfer.From.EXTERNAL
                : LibTransfer.From.INTERNAL;

            // if the user wants to redeposit, pull them from the harvest destination and deposit into silo
            if (params.mowPlantHarvestParams.shouldRedeposit) {
                beanstalk.deposit(beanstalk.getBeanToken(), harvestedPods, depositMode);
            }
        }

        // Update the last executed season for this blueprint
        updateLastExecutedSeason(vars.orderHash, beanstalk.time().current);
    }

    /**
     * @notice Helper function to get the user state and validate against parameters
     * @param account The address of the user
     * @param params The parameters for the mow, plant and harvest operation
     * @return totalClaimableStalk The total amount of claimable stalk
     * @return totalPlantableBeans The total amount of plantable beans
     * @return totalHarvestablePods The total amount of harvestable pods
     */
    function _getAndValidateUserState(
        address account,
        MowPlantHarvestBlueprintStruct calldata params
    )
        internal
        view
        returns (
            uint256 totalClaimableStalk,
            uint256 totalPlantableBeans,
            uint256 totalHarvestablePods,
            uint256[] memory harvestablePlots,
            bool shouldMow,
            bool shouldPlant,
            bool shouldHarvest
        )
    {
        // get user state
        (
            totalClaimableStalk,
            totalPlantableBeans,
            totalHarvestablePods,
            harvestablePlots
        ) = _getUserState(account);

        // validate params - only revert if none of the conditions are met
        shouldMow = totalClaimableStalk >= params.mowPlantHarvestParams.minMowAmount;
        shouldPlant = totalPlantableBeans >= params.mowPlantHarvestParams.minPlantAmount;
        shouldHarvest = totalHarvestablePods >= params.mowPlantHarvestParams.minHarvestAmount;

        require(
            shouldMow || shouldPlant || shouldHarvest,
            "None of the mow, plant or harvest conditions are met"
        );

        // return user state
        return (
            totalClaimableStalk,
            totalPlantableBeans,
            totalHarvestablePods,
            harvestablePlots,
            shouldMow,
            shouldPlant,
            shouldHarvest
        );
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
    function _validateParams(MowPlantHarvestBlueprintStruct calldata params) internal pure {
        require(
            params.mowPlantHarvestParams.sourceTokenIndices.length > 0,
            "Must provide at least one source token"
        );
        /// todo: add more validation here depending on the parameters
    }

    /// @dev validates info related to the blueprint such as the order hash and the last executed season
    function _validateBlueprint(bytes32 orderHash) internal view {
        require(orderHash != bytes32(0), "No active blueprint, function must run from Tractor");
        require(
            orderLastExecutedSeason[orderHash] < beanstalk.time().current,
            "Blueprint already executed this season"
        );
    }

    /// @dev updates the last executed season for a given order hash
    function updateLastExecutedSeason(bytes32 orderHash, uint32 season) internal {
        orderLastExecutedSeason[orderHash] = season;
    }
}

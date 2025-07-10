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

    // we want them to mow continuously from a protocol perspective
    // the user wants to mow when the system is about to print (good point)
    // for planting--> use min pinto amount to plant --> or as a % of tip compared to pinto planted
    // for harvesting --> plots are partially harvestable. do we want to harvest partial plots?

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
        // Withdrawal plan parameters for tipping
        uint8[] sourceTokenIndices;
        uint256 maxGrownStalkPerBdv;
        uint256 slippageRatio;
    }

    // Mapping to track the last executed season for each order hash
    mapping(bytes32 orderHash => uint32 lastExecutedSeason) public orderLastExecutedSeason;

    uint256 internal constant STALK_PER_BEAN = 1e10;

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

    struct MowPlantHarvestLocalVars {
        bytes32 orderHash;
        address account;
        address tipAddress;
        uint256 totalClaimableStalk;
        uint256 totalPlantableBeans;
        uint256 totalHarvestablePods;
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
            vars.harvestablePlots
        ) = _getAndValidateUserState(vars.account, params);

        // validate blueprint
        _validateBlueprint(vars.orderHash);

        // validate order params and revert early if invalid
        _validateParams(params);

        // if tip address is not set, set it to the operator
        if (vars.tipAddress == address(0)) vars.tipAddress = beanstalk.operator();

        ////////////////////// Withdrawal Plan and Tip ////////////////////////

        // Check if enough beans are available using getWithdrawalPlan
        LibTractorHelpers.WithdrawalPlan memory tempPlan;
        LibTractorHelpers.WithdrawalPlan memory plan = tractorHelpers
            .getWithdrawalPlanExcludingPlan(
                vars.account,
                params.mowPlantHarvestParams.sourceTokenIndices,
                uint256(params.opParams.operatorTipAmount),
                params.mowPlantHarvestParams.maxGrownStalkPerBdv,
                tempPlan // Passed in plan is empty
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

        // note: in case the user has harvestable pods or plantable beans, generally the blueprint should be executed
        // in this case, we should check for those 2 scenarios first and proceed if the conditions are met

        // if user can mow, try to mow
        // this could be changed to a threshold as absolute value of claimable stalk
        // or to a percentage of total user stalk
        // note: prob want this to be conditional aka the user decides to claim if he has claimable stalk
        // to avoid paying the tip for a marginal benefit. (could this be season based?)
        if (vars.totalClaimableStalk > params.mowPlantHarvestParams.minMowAmount) {
            beanstalk.mowAll(vars.account);
        }

        // if user can plant, try to plant
        // this could be changed to a threshold as an absolute value
        // (or to a percentage of total portfolio size?)
        // note: generally people would want to plant if they have any amount of plantable beans
        // to get the compounding effect when printing
        if (vars.totalPlantableBeans > params.mowPlantHarvestParams.minPlantAmount) {
            beanstalk.plant();
        }

        // if user can harvest, try to harvest
        // note: execute when harvestable pods are at least x?
        // note: for sure one parameter should be if to redeposit to the silo or not
        // note: if not deposited,for sure one parameter should be where the pinto should be sent (internal or external balance)
        if (vars.totalHarvestablePods > params.mowPlantHarvestParams.minHarvestAmount) {
            beanstalk.harvest(
                beanstalk.activeField(),
                vars.harvestablePlots,
                LibTransfer.To.INTERNAL
            );
        }
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
            uint256[] memory harvestablePlots
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
        bool canMow = totalClaimableStalk >= params.mowPlantHarvestParams.minMowAmount;
        bool canPlant = totalPlantableBeans >= params.mowPlantHarvestParams.minPlantAmount;
        bool canHarvest = totalHarvestablePods >= params.mowPlantHarvestParams.minHarvestAmount;

        require(
            canMow || canPlant || canHarvest,
            "None of the mow, plant or harvest conditions are met"
        );

        // return user state
        return (totalClaimableStalk, totalPlantableBeans, totalHarvestablePods, harvestablePlots);
    }

    /**
     * @notice helper function to get the user state to compare against parameters
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
        // increment total claimable stalk with stalk gained from plantable beans
        totalPlantableBeans = beanstalk.balanceOfEarnedBeans(account);
        // note: this should be counted towards the total only if the conditions for planting are met
        totalClaimableStalk += totalPlantableBeans * STALK_PER_BEAN;

        // check if user has harvestable beans
        // note: when harvesting, beans are not auto-deposited so no stalk is gained
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
}

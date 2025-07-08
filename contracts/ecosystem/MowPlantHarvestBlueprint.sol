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

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers
    ) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
        tractorHelpers = TractorHelpers(_tractorHelpers);
    }


    function mowPlantHarvestBlueprint() external payable whenFunctionNotPaused {
        // get order hash
        bytes32 orderHash = beanstalk.getCurrentBlueprintHash();
        // get the tractor user
        address account = beanstalk.tractorUser();

        // get the user state from the protocol
        (
            uint256 totalClaimableStalk,
            uint256 totalPlantableBeans,
            uint256[] memory harvestablePlots
        ) = _getUserState(account);

        // validate params and revert early if invalid
        _validateParams();

        // Execute the withdrawal plan to withdraw the tip amount
        // note: This is overkill just to withdraw the tip but whatever
        // tractorHelpers.withdrawBeansFromSources(
        //     vars.account,
        //     params.sowParams.sourceTokenIndices,
        //     vars.totalBeansNeeded,
        //     params.sowParams.maxGrownStalkPerBdv,
        //     slippageRatio,
        //     LibTransfer.To.INTERNAL,
        //     vars.withdrawalPlan
        // );

        // Tip the operator with the withdrawn beans
        // tractorHelpers.tip(
        //     vars.beanToken,
        //     vars.account,
        //     vars.tipAddress,
        //     params.opParams.operatorTipAmount,
        //     LibTransfer.From.INTERNAL,
        //     LibTransfer.To.INTERNAL
        // );

        // if user can mow, try to mow
        // this could be changed to a threshold as absolute value of claimable stalk
        // or to a percentage of total user stalk
        // note: prob want this to be conditional aka the user decides to claim if he has claimable stalk
        // to avoid paying the tip for a marginal benefit. (could this be season based?)
        if (totalClaimableStalk > 0) beanstalk.mowAll(account);

        // if user can plant, try to plant
        // this could be changed to a threshold as an absolute value
        // (or to a percentage of total portfolio size?)
        // note: generally people would want to plant if they have any amount of plantable beans
        // to get the compounding effect when printing
        if (totalPlantableBeans > 0) beanstalk.plant();

        // if user can harvest, try to harvest
        // note: execute when harvestable pods are at least x?
        // note: for sure one parameter should be if to redeposit to the silo or not
        // note: if not deposited,for sure one parameter should be where the pinto should be sent (internal or external balance)
        if (harvestablePlots.length > 0) {
            beanstalk.harvest(beanstalk.activeField(), harvestablePlots, LibTransfer.To.INTERNAL);
        }
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
        harvestablePlots = userHarvestablePods(account);

        return (totalClaimableStalk, totalPlantableBeans, harvestablePlots);
    }

    /**
     * @notice helper function to get the total harvestable pods for a user
     * @param account The address of the user
     * @return harvestablePlots The harvestable plot ids for the user
     */
    function userHarvestablePods(
        address account
    ) internal view returns (uint256[] memory harvestablePlots) {
        // Get all plots for the user in the field
        IBeanstalk.Plot[] memory plots = beanstalk.getPlotsFromAccount(account, beanstalk.activeField());
        uint256 harvestableIndex = beanstalk.harvestableIndex(beanstalk.activeField());

        // First, count how many plots are at least partially harvestable
        uint256 count;
        for (uint256 i = 0; i < plots.length; i++) {
            uint256 startIndex = plots[i].index;
            uint256 plotPods = plots[i].pods;
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
            } else if (startIndex < harvestableIndex) {
                // Partially harvestable
                harvestablePlots[j++] = startIndex;
            }
        }

        return harvestablePlots;
    }

    /**
     * @notice Validates the initial parameters for the mow, plant and harvest operation
     * params The MowPlantHarvestBlueprintStruct containing all parameters for the mow, plant and harvest operation
     */
    function _validateParams() internal view {
        // check if params are valid, whatever we decide
    }
}

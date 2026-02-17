// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {SiloHelpers} from "contracts/ecosystem/tractor/utils/SiloHelpers.sol";
import {BlueprintBase} from "./BlueprintBase.sol";

/**
 * @dev Minimal interface for BarnPayback's claim and balance functions.
 * We cannot import IBarnPayback directly because it defines its own local LibTransfer
 * library, which causes a type conflict with the protocol's LibTransfer.To used here.
 */
interface IBarnPaybackClaim {
    function claimFertilized(uint256[] memory ids, LibTransfer.To mode) external;
    function balanceOfFertilized(
        address account,
        uint256[] memory ids
    ) external view returns (uint256 beans);
}

/**
 * @dev Minimal interface for SiloPayback's claim and earned functions.
 * We cannot import ISiloPayback directly because it defines its own local LibTransfer
 * library, which causes a type conflict with the protocol's LibTransfer.To used here.
 */
interface ISiloPaybackClaim {
    function claim(address recipient, LibTransfer.To toMode) external;
    function earned(address account) external view returns (uint256);
}

/**
 * @title AutomateClaimBlueprint
 * @author DefaultJuice
 * @notice Contract for mowing, planting, harvesting and rinsing with Tractor, with a number of conditions
 */
contract AutomateClaimBlueprint is BlueprintBase {
    /**
     * @dev Minutes after sunrise to check if the totalDeltaB is about to be positive for the following season
     */
    uint256 public constant MINUTES_AFTER_SUNRISE = 55 minutes;

    /**
     * @dev Key for operator-provided harvest data in transient storage
     * The key format is: HARVEST_DATA_KEY + fieldId
     * Hash: 0xad7d503bd76a2177b94db747d4e00459b65eb93e2a4be3b707394f51d084fc4c
     */
    uint256 public constant HARVEST_DATA_KEY =
        uint256(keccak256("AutomateClaimBlueprint.harvestData"));

    /**
     * @dev Key for operator-provided rinse data in transient storage
     */
    uint256 public constant RINSE_DATA_KEY = uint256(keccak256("AutomateClaimBlueprint.rinseData"));

    /**
     * @notice Main struct for automate claim blueprint
     * @param automateClaimParams Parameters related to mow, plant and harvest
     * @param opParams Parameters related to operators
     */
    struct AutomateClaimBlueprintStruct {
        AutomateClaimParams automateClaimParams;
        OperatorParamsExtended opParams;
    }

    /**
     * @notice Struct to hold field-specific harvest configuration
     * @param fieldId The field ID to harvest from
     * @param minHarvestAmount The minimum harvestable pods threshold for this field
     */
    struct FieldHarvestConfig {
        uint256 fieldId;
        uint256 minHarvestAmount;
    }

    /**
     * @notice Struct to hold field-specific harvest results
     * @param fieldId The field ID to harvest from
     * @param minHarvestAmount The minimum harvest amount threshold for this field
     * @param harvestablePlots The harvestable plot indexes for the user
     */
    struct UserFieldHarvestResults {
        uint256 fieldId;
        uint256 minHarvestAmount;
        uint256[] harvestablePlots;
    }

    /**
     * @notice Struct to hold mow, plant and harvest parameters
     * @param minMowAmount The minimum total claimable stalk threshold to mow
     * @param minTwaDeltaB The minimum twaDeltaB to mow if the protocol
     * is close to starting the next season above the value target
     * @param minPlantAmount The earned beans threshold to plant
     * @param fieldHarvestConfigs Array of field-specific harvest configurations
     * note: fieldHarvestConfigs should be sorted by fieldId to save gas
     * -----------------------------------------------------------
     * @param sourceTokenIndices Indices of source tokens to withdraw from
     * @param maxGrownStalkPerBdv Maximum grown stalk per BDV allowed
     * @param slippageRatio The price slippage ratio for lp token withdrawal.
     * Only applicable for lp token withdrawals.
     */
    struct AutomateClaimParams {
        // Mow
        uint256 minMowAmount;
        uint256 minTwaDeltaB;
        // Plant
        uint256 minPlantAmount;
        // Harvest, per field id
        FieldHarvestConfig[] fieldHarvestConfigs;
        // Rinse (BarnPayback.claimFertilized)
        uint256 minRinseAmount;
        // Unripe Claim (SiloPayback.claim)
        uint256 minUnripeClaimAmount;
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
        OperatorParams baseOpParams;
        int256 mowTipAmount;
        int256 plantTipAmount;
        int256 harvestTipAmount;
        int256 rinseTipAmount;
        int256 unripeClaimTipAmount;
    }

    /**
     * @notice Local variables for the mow, plant and harvest function
     * @dev Used to avoid stack too deep errors
     */
    struct AutomateClaimLocalVars {
        address account;
        int256 totalBeanTip;
        uint256 totalHarvestedBeans;
        uint256 totalPlantedBeans;
        int96 plantedStem;
        bool shouldMow;
        bool shouldPlant;
        UserFieldHarvestResults[] userFieldHarvestResults;
        uint256[] rinseFertilizerIds;
        uint256 unripeClaimAmount;
    }

    // Silo helpers for withdrawal functionality
    SiloHelpers public immutable siloHelpers;
    // BarnPayback contract for claiming fertilized beans
    IBarnPaybackClaim public immutable barnPayback;
    // SiloPayback contract for claiming unripe silo rewards
    ISiloPaybackClaim public immutable siloPayback;

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers,
        address _siloHelpers,
        address _barnPayback,
        address _siloPayback
    ) BlueprintBase(_beanstalk, _owner, _tractorHelpers) {
        siloHelpers = SiloHelpers(_siloHelpers);
        barnPayback = IBarnPaybackClaim(_barnPayback);
        siloPayback = ISiloPaybackClaim(_siloPayback);
    }

    /**
     * @notice Main entry point for the automate claim blueprint
     * @param params User-controlled parameters for automating mowing, planting and harvesting
     */
    function automateClaimBlueprint(
        AutomateClaimBlueprintStruct calldata params
    ) external payable whenFunctionNotPaused {
        // Initialize local variables
        AutomateClaimLocalVars memory vars;

        // Validate
        vars.account = beanstalk.tractorUser();

        // get the user state from the protocol and validate against params
        (
            vars.shouldMow,
            vars.shouldPlant,
            vars.userFieldHarvestResults,
            vars.rinseFertilizerIds,
            vars.unripeClaimAmount
        ) = _getAndValidateUserState(vars.account, beanstalk.time().timestamp, params);

        // validate order params and revert early if invalid
        _validateSourceTokens(params.automateClaimParams.sourceTokenIndices);
        _validateOperatorParams(params.opParams.baseOpParams);

        // resolve tip address (defaults to operator if not set)
        address tipAddress = _resolveTipAddress(params.opParams.baseOpParams.tipAddress);

        // Mow, Plant, Harvest and Rinse
        // Check if user should harvest, plant or rinse
        // In the case a harvest, plant or rinse is executed, mow by default
        if (
            vars.shouldPlant ||
            vars.userFieldHarvestResults.length > 0 ||
            vars.rinseFertilizerIds.length > 0 ||
            vars.unripeClaimAmount > 0
        ) vars.shouldMow = true;

        // Execute operations in order: mow first (if needed), then plant, then harvest
        if (vars.shouldMow) {
            beanstalk.mowAll(vars.account);
            vars.totalBeanTip += params.opParams.mowTipAmount;
        }

        // Plant if the conditions are met
        if (vars.shouldPlant) {
            (vars.totalPlantedBeans, vars.plantedStem) = beanstalk.plant();
            vars.totalBeanTip += params.opParams.plantTipAmount;
        }

        // Harvest in all configured fields if the conditions are met
        if (vars.userFieldHarvestResults.length > 0) {
            for (uint256 i = 0; i < vars.userFieldHarvestResults.length; i++) {
                // Harvest the pods to the user's internal balance
                uint256 harvestedBeans = beanstalk.harvest(
                    vars.userFieldHarvestResults[i].fieldId,
                    vars.userFieldHarvestResults[i].harvestablePlots,
                    LibTransfer.To.INTERNAL
                );

                // Validate post-harvest: revert if harvested amount is below minimum threshold
                require(
                    harvestedBeans >= vars.userFieldHarvestResults[i].minHarvestAmount,
                    "AutomateClaimBlueprint: Harvested amount below minimum threshold"
                );

                // Accumulate harvested beans
                vars.totalHarvestedBeans += harvestedBeans;
            }
            // tip for harvesting includes all specified fields
            vars.totalBeanTip += params.opParams.harvestTipAmount;
        }

        // Rinse (claim fertilized beans) if the conditions are met
        if (vars.rinseFertilizerIds.length > 0) {
            // Get expected amount before claiming
            uint256 expectedRinseAmount = barnPayback.balanceOfFertilized(
                vars.account,
                vars.rinseFertilizerIds
            );

            require(
                expectedRinseAmount >= params.automateClaimParams.minRinseAmount,
                "AutomateClaimBlueprint: Rinsed amount below minimum threshold"
            );

            // Claim fertilized beans to user's internal balance
            barnPayback.claimFertilized(vars.rinseFertilizerIds, LibTransfer.To.INTERNAL);

            // Rinsed beans are in internal balance, same as harvested beans
            vars.totalHarvestedBeans += expectedRinseAmount;
            vars.totalBeanTip += params.opParams.rinseTipAmount;
        }

        // Claim unripe rewards (SiloPayback) if the conditions are met
        if (vars.unripeClaimAmount > 0) {
            // Claim to user's internal balance
            // Note: In tractor context, transferToken uses the tractor user as sender,
            // so the user must have sufficient external Pinto balance to cover the claim.
            siloPayback.claim(vars.account, LibTransfer.To.INTERNAL);

            // Claimed amount goes to internal balance, same flow as harvested/rinsed beans
            vars.totalHarvestedBeans += vars.unripeClaimAmount;
            vars.totalBeanTip += params.opParams.unripeClaimTipAmount;
        }

        // Handle tip payment
        handleBeansAndTip(
            vars.account,
            tipAddress,
            params.automateClaimParams.sourceTokenIndices,
            vars.totalBeanTip,
            vars.totalHarvestedBeans,
            vars.totalPlantedBeans,
            vars.plantedStem,
            params.automateClaimParams.maxGrownStalkPerBdv,
            params.automateClaimParams.slippageRatio
        );
    }

    /**
     * @notice Helper function to get the user state and validate against parameters
     * @param account The address of the user
     * @param params The parameters for the mow, plant and harvest operation
     * @return shouldMow True if the user should mow
     * @return shouldPlant True if the user should plant
     * @return userFieldHarvestResults An array of structs containing the harvestable pods
     * and plots for the user for each field id where operator provided data
     * @return rinseFertilizerIds Array of fertilizer IDs to rinse (empty if rinse skipped)
     */
    function _getAndValidateUserState(
        address account,
        uint256 previousSeasonTimestamp,
        AutomateClaimBlueprintStruct calldata params
    )
        internal
        view
        returns (
            bool shouldMow,
            bool shouldPlant,
            UserFieldHarvestResults[] memory userFieldHarvestResults,
            uint256[] memory rinseFertilizerIds,
            uint256 unripeClaimAmount
        )
    {
        // get user state
        (
            uint256 totalClaimableStalk,
            uint256 totalPlantableBeans,
            UserFieldHarvestResults[] memory userFieldHarvestResults
        ) = _getUserState(account, params.automateClaimParams.fieldHarvestConfigs);

        // get rinse data from operator-provided transient storage
        rinseFertilizerIds = _getRinseData(account, params.automateClaimParams.minRinseAmount);

        // get unripe claim amount from SiloPayback earned balance
        unripeClaimAmount = _getUnripeClaimAmount(
            account,
            params.automateClaimParams.minUnripeClaimAmount
        );

        // validate params - only revert if none of the conditions are met
        shouldMow = _checkMowConditions(
            params.automateClaimParams.minTwaDeltaB,
            params.automateClaimParams.minMowAmount,
            totalClaimableStalk,
            previousSeasonTimestamp
        );
        shouldPlant = totalPlantableBeans >= params.automateClaimParams.minPlantAmount;

        require(
            shouldMow ||
                shouldPlant ||
                userFieldHarvestResults.length > 0 ||
                rinseFertilizerIds.length > 0 ||
                unripeClaimAmount > 0,
            "AutomateClaimBlueprint: None of the order conditions are met"
        );

        return (
            shouldMow,
            shouldPlant,
            userFieldHarvestResults,
            rinseFertilizerIds,
            unripeClaimAmount
        );
    }

    /**
     * @notice Check mow conditions to trigger a mow
     * @dev A mow happens when:
     * - `MINUTES_AFTER_SUNRISE` has passed since the last sunrise call
     * - The protocol is about to start the next season above the value target.
     * - The user has enough claimable stalk such as he gets more yield.
     * @return bool True if the user should mow, false otherwise
     */
    function _checkMowConditions(
        uint256 minTwaDeltaB,
        uint256 minMowAmount,
        uint256 totalClaimableStalk,
        uint256 previousSeasonTimestamp
    ) internal view returns (bool) {
        if (block.timestamp - previousSeasonTimestamp < MINUTES_AFTER_SUNRISE) return false;

        // if the totalDeltaB and totalClaimableStalk are both greater than the min amount, return true
        // This also guards against double dipping the blueprint after planting or harvesting since stalk will be 0
        return totalClaimableStalk > minMowAmount && beanstalk.totalDeltaB() > int256(minTwaDeltaB);
    }

    /**
     * @notice helper function to get the user state to compare against parameters
     * @dev Uses operator-provided harvest data from transient storage.
     * If no data is provided for a field, treats it as no harvestable pods.
     * Increasing the total claimable stalk when planting or harvesting does not really matter
     * since we mow by default if we plant or harvest.
     */
    function _getUserState(
        address account,
        FieldHarvestConfig[] memory fieldHarvestConfigs
    )
        internal
        view
        returns (
            uint256 totalClaimableStalk,
            uint256 totalPlantableBeans,
            UserFieldHarvestResults[] memory userFieldHarvestResults
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

        // for every field id, read operator-provided harvest data via dynamic calldata
        userFieldHarvestResults = new UserFieldHarvestResults[](fieldHarvestConfigs.length);
        uint256 index;
        for (uint256 i = 0; i < fieldHarvestConfigs.length; i++) {
            uint256 fieldId = fieldHarvestConfigs[i].fieldId;

            // Read operator-provided data from transient storage
            bytes memory operatorData = beanstalk.getTractorData(HARVEST_DATA_KEY + fieldId);

            // Skip if operator didn't provide data for this field
            if (operatorData.length == 0) {
                continue;
            }

            // Decode operator-provided harvestable plot indexes
            uint256[] memory harvestablePlotIndexes = abi.decode(operatorData, (uint256[]));

            // Skip if operator provided empty array
            if (harvestablePlotIndexes.length == 0) {
                continue;
            }

            userFieldHarvestResults[index] = UserFieldHarvestResults({
                fieldId: fieldId,
                minHarvestAmount: fieldHarvestConfigs[i].minHarvestAmount,
                harvestablePlots: harvestablePlotIndexes
            });
            index++;
        }

        assembly {
            mstore(userFieldHarvestResults, index)
        }

        return (totalClaimableStalk, totalPlantableBeans, userFieldHarvestResults);
    }

    /**
     * @notice Reads rinse data from operator-provided transient storage
     * @dev If no data is provided or claimable amount is below minRinseAmount, returns empty array (rinse skipped)
     * @param account The account to check fertilized balance for
     * @param minRinseAmount The minimum rinsable amount threshold
     * @return fertilizerIds Array of fertilizer IDs to rinse (empty if skipped)
     */
    function _getRinseData(
        address account,
        uint256 minRinseAmount
    ) internal view returns (uint256[] memory fertilizerIds) {
        bytes memory operatorData = beanstalk.getTractorData(RINSE_DATA_KEY);

        if (operatorData.length == 0) {
            return new uint256[](0);
        }

        fertilizerIds = abi.decode(operatorData, (uint256[]));

        if (fertilizerIds.length == 0) {
            return new uint256[](0);
        }

        // Check if claimable amount meets minimum threshold
        uint256 claimableAmount = barnPayback.balanceOfFertilized(account, fertilizerIds);
        if (claimableAmount < minRinseAmount) {
            return new uint256[](0);
        }

        return fertilizerIds;
    }

    /**
     * @notice Checks if user has enough earned unripe rewards to claim
     * @dev Returns 0 if earned amount is below threshold (soft skip, no revert)
     * @param account The account to check earned rewards for
     * @param minUnripeClaimAmount The minimum earned amount threshold
     * @return earnedAmount The earned amount if above threshold, 0 otherwise
     */
    function _getUnripeClaimAmount(
        address account,
        uint256 minUnripeClaimAmount
    ) internal view returns (uint256) {
        uint256 earnedAmount = siloPayback.earned(account);
        if (earnedAmount < minUnripeClaimAmount) {
            return 0;
        }
        return earnedAmount;
    }

    /**
     * @notice Handles tip payment
     * @param account The account to withdraw for
     * @param tipAddress The address to send the tip to
     * @param sourceTokenIndices The indices of the source tokens to withdraw from
     * @param totalBeanTip The total tip for mowing, planting and harvesting
     * @param totalHarvestedBeans Total beans harvested in this transaction (in internal balance)
     * @param totalPlantedBeans Total beans planted in this transaction (deposited by plant())
     * @param plantedStem The stem of the planted deposit (for withdrawal if needed)
     * @param maxGrownStalkPerBdv The maximum amount of grown stalk allowed to be used for the withdrawal, per bdv
     * @param slippageRatio The price slippage ratio for a lp token withdrawal
     */
    function handleBeansAndTip(
        address account,
        address tipAddress,
        uint8[] memory sourceTokenIndices,
        int256 totalBeanTip,
        uint256 totalHarvestedBeans,
        uint256 totalPlantedBeans,
        int96 plantedStem,
        uint256 maxGrownStalkPerBdv,
        uint256 slippageRatio
    ) internal {
        // Check if tip source is Bean - enables direct use of harvested/planted beans
        bool tipWithBean = _resolvedSourceIsBean(sourceTokenIndices);

        if (tipWithBean) {
            // Bean tip flow: use harvested/planted beans directly without extra withdrawals
            int256 toDeposit = int256(totalHarvestedBeans) - totalBeanTip;

            if (toDeposit < 0) {
                uint256 neededFromPlanted = uint256(-toDeposit);
                uint256 withdrawFromPlanted = neededFromPlanted < totalPlantedBeans
                    ? neededFromPlanted
                    : totalPlantedBeans;

                if (withdrawFromPlanted > 0) {
                    beanstalk.withdrawDeposit(
                        beanToken,
                        plantedStem,
                        withdrawFromPlanted,
                        LibTransfer.To.INTERNAL
                    );
                }

                // If planted wasn't enough, withdraw from other sources
                uint256 remainingNeeded = neededFromPlanted - withdrawFromPlanted;
                if (remainingNeeded > 0) {
                    _withdrawBeansOnly(
                        account,
                        sourceTokenIndices,
                        remainingNeeded,
                        maxGrownStalkPerBdv,
                        slippageRatio
                    );
                }
            }

            if (toDeposit > 0) {
                beanstalk.deposit(beanToken, uint256(toDeposit), LibTransfer.From.INTERNAL);
            }

            tractorHelpers.tip(
                beanToken,
                account,
                tipAddress,
                totalBeanTip,
                LibTransfer.From.INTERNAL,
                LibTransfer.To.INTERNAL
            );
        } else {
            // Non-Bean source: deposit harvested beans back, then withdraw tip from user's deposits
            if (totalHarvestedBeans > 0) {
                beanstalk.deposit(beanToken, totalHarvestedBeans, LibTransfer.From.INTERNAL);
            }

            _withdrawBeansOnly(
                account,
                sourceTokenIndices,
                uint256(totalBeanTip),
                maxGrownStalkPerBdv,
                slippageRatio
            );

            tractorHelpers.tip(
                beanToken,
                account,
                tipAddress,
                totalBeanTip,
                LibTransfer.From.INTERNAL,
                LibTransfer.To.INTERNAL
            );
        }
    }

    /**
     * @notice Helper function that withdraws beans from sources without tipping
     * @dev Used when we need to supplement harvested/planted beans with additional withdrawals
     * @param account The account to withdraw for
     * @param sourceTokenIndices The indices of the source tokens to withdraw from
     * @param amount The amount of beans to withdraw
     * @param maxGrownStalkPerBdv The maximum amount of grown stalk allowed to be used for the withdrawal, per bdv
     * @param slippageRatio The price slippage ratio for a lp token withdrawal
     */
    function _withdrawBeansOnly(
        address account,
        uint8[] memory sourceTokenIndices,
        uint256 amount,
        uint256 maxGrownStalkPerBdv,
        uint256 slippageRatio
    ) internal {
        // Create filter params for the withdrawal plan
        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams(
            maxGrownStalkPerBdv
        );

        // Get withdrawal plan for the needed amount
        LibSiloHelpers.WithdrawalPlan memory withdrawalPlan = siloHelpers.getWithdrawalPlan(
            account,
            sourceTokenIndices,
            amount,
            filterParams
        );

        // Execute the withdrawal plan
        siloHelpers.withdrawBeansFromSources(
            account,
            sourceTokenIndices,
            amount,
            filterParams,
            slippageRatio,
            LibTransfer.To.INTERNAL,
            withdrawalPlan
        );
    }

    /**
     * @notice Checks if the resolved first source token is Bean
     * @dev Handles both direct token indices and strategy-based indices (LOWEST_PRICE_STRATEGY, LOWEST_SEED_STRATEGY)
     * @param sourceTokenIndices The indices of the source tokens to withdraw from
     * @return True if the first resolved source token is Bean
     */
    function _resolvedSourceIsBean(uint8[] memory sourceTokenIndices) internal view returns (bool) {
        uint8 firstIdx = sourceTokenIndices[0];

        // Direct index - check if it points to Bean
        if (firstIdx < siloHelpers.LOWEST_PRICE_STRATEGY()) {
            address[] memory tokens = siloHelpers.getWhitelistStatusAddresses();
            if (firstIdx >= tokens.length) return false;
            return tokens[firstIdx] == beanToken;
        }

        if (firstIdx == siloHelpers.LOWEST_PRICE_STRATEGY()) {
            // For price strategy, check if Bean is the lowest priced token
            (uint8[] memory priceIndices, ) = tractorHelpers.getTokensAscendingPrice();
            if (priceIndices.length == 0) return false;
            address[] memory tokens = siloHelpers.getWhitelistStatusAddresses();
            if (priceIndices[0] >= tokens.length) return false;
            return tokens[priceIndices[0]] == beanToken;
        }

        if (firstIdx == siloHelpers.LOWEST_SEED_STRATEGY()) {
            // For seed strategy, check if Bean is the lowest seeded token
            (address lowestSeedToken, ) = tractorHelpers.getLowestSeedToken();
            return lowestSeedToken == beanToken;
        }

        return false;
    }
}

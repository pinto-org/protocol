// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {SiloHelpers} from "contracts/ecosystem/tractor/utils/SiloHelpers.sol";
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
     * @dev Key for operator-provided harvest data in transient storage
     * The key format is: HARVEST_DATA_KEY + fieldId
     * Hash: 0x57c0c06c01076b3dedd361eef555163669978891b716ce6c5ef1355fc8ab5a36
     */
    uint256 public constant HARVEST_DATA_KEY =
        uint256(keccak256("MowPlantHarvestBlueprint.harvestData"));

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
     * @param harvestablePlots The harvestable plot indexes for the user
     */
    struct UserFieldHarvestResults {
        uint256 fieldId;
        uint256[] harvestablePlots;
    }

    /**
     * @notice Struct for operator-provided harvest data via dynamic calldata
     * @dev Operator passes this via tractorDynamicData to avoid on-chain plot iteration
     * @param fieldId The field ID this data is for
     * @param harvestablePlotIndexes Array of harvestable plot indexes
     */
    struct OperatorHarvestData {
        uint256 fieldId;
        uint256[] harvestablePlotIndexes;
    }

    /**
     * @notice Struct to hold mow, plant and harvest parameters
     * @param minMowAmount The minimum total claimable stalk threshold to mow
     * @param mintwaDeltaB The minimum twaDeltaB to mow if the protocol
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
    struct MowPlantHarvestParams {
        // Mow
        uint256 minMowAmount;
        uint256 mintwaDeltaB;
        // Plant
        uint256 minPlantAmount;
        // Harvest, per field id
        FieldHarvestConfig[] fieldHarvestConfigs;
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
    }

    /**
     * @notice Local variables for the mow, plant and harvest function
     * @dev Used to avoid stack too deep errors
     */
    struct MowPlantHarvestLocalVars {
        address account;
        int256 totalBeanTip;
        uint256 totalHarvestedBeans;
        uint256 totalPlantedBeans;
        int96 plantedStem;
        bool shouldMow;
        bool shouldPlant;
        bool shouldHarvest;
        UserFieldHarvestResults[] userFieldHarvestResults;
    }

    // Silo helpers for withdrawal functionality
    SiloHelpers public immutable siloHelpers;

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers,
        address _siloHelpers
    ) BlueprintBase(_beanstalk, _owner, _tractorHelpers) {
        siloHelpers = SiloHelpers(_siloHelpers);
    }

    /**
     * @notice Main entry point for the mow, plant and harvest blueprint
     * @param params User-controlled parameters for automating mowing, planting and harvesting
     */
    function mowPlantHarvestBlueprint(
        MowPlantHarvestBlueprintStruct calldata params
    ) external payable whenFunctionNotPaused {
        // Initialize local variables
        MowPlantHarvestLocalVars memory vars;

        // Validate
        vars.account = beanstalk.tractorUser();

        // get the user state from the protocol and validate against params
        (
            vars.shouldMow,
            vars.shouldPlant,
            vars.shouldHarvest,
            vars.userFieldHarvestResults
        ) = _getAndValidateUserState(vars.account, beanstalk.time().timestamp, params);

        // validate order params and revert early if invalid
        _validateSourceTokens(params.mowPlantHarvestParams.sourceTokenIndices);
        _validateOperatorParams(params.opParams.baseOpParams);

        // resolve tip address (defaults to operator if not set)
        address tipAddress = _resolveTipAddress(params.opParams.baseOpParams.tipAddress);

        // Mow, Plant and Harvest
        // Check if user should harvest or plant
        // In the case a harvest or plant is executed, mow by default
        if (vars.shouldPlant || vars.shouldHarvest) vars.shouldMow = true;

        // Execute operations in order: mow first (if needed), then plant, then harvest
        if (vars.shouldMow) {
            beanstalk.mowAll(vars.account);
            vars.totalBeanTip += params.opParams.mowTipAmount;
        }

        // Plant if the conditions are met
        if (vars.shouldPlant) {
            vars.totalPlantedBeans = beanstalk.plant();
            vars.plantedStem = beanstalk.getHighestNonGerminatingStem(beanToken);
            vars.totalBeanTip += params.opParams.plantTipAmount;
        }

        // Harvest in all configured fields if the conditions are met
        if (vars.shouldHarvest) {
            for (uint256 i = 0; i < vars.userFieldHarvestResults.length; i++) {
                // Skip fields with no harvestable plots
                if (vars.userFieldHarvestResults[i].harvestablePlots.length == 0) continue;

                // Harvest the pods to the user's internal balance
                uint256 harvestedBeans = beanstalk.harvest(
                    vars.userFieldHarvestResults[i].fieldId,
                    vars.userFieldHarvestResults[i].harvestablePlots,
                    LibTransfer.To.INTERNAL
                );

                // Validate post-harvest: revert if harvested amount is below minimum threshold
                require(
                    harvestedBeans >=
                        params.mowPlantHarvestParams.fieldHarvestConfigs[i].minHarvestAmount,
                    "MowPlantHarvestBlueprint: Harvested amount below minimum threshold"
                );

                // Accumulate harvested beans
                vars.totalHarvestedBeans += harvestedBeans;
            }
            // tip for harvesting includes all specified fields
            vars.totalBeanTip += params.opParams.harvestTipAmount;
        }

        // Handle tip payment
        _handleTip(
            vars.account,
            tipAddress,
            params.mowPlantHarvestParams.sourceTokenIndices,
            vars.totalBeanTip,
            vars.totalHarvestedBeans,
            vars.totalPlantedBeans,
            vars.plantedStem,
            params.mowPlantHarvestParams.maxGrownStalkPerBdv,
            params.mowPlantHarvestParams.slippageRatio
        );
    }

    /**
     * @notice Helper function to get the user state and validate against parameters
     * @param account The address of the user
     * @param params The parameters for the mow, plant and harvest operation
     * @return shouldMow True if the user should mow
     * @return shouldPlant True if the user should plant
     * @return shouldHarvest True if the user should harvest in at least one field id
     * @return userFieldHarvestResults An array of structs containing the total harvestable pods
     * and plots for the user for each field id specified in the blueprint config
     */
    function _getAndValidateUserState(
        address account,
        uint256 previousSeasonTimestamp,
        MowPlantHarvestBlueprintStruct calldata params
    )
        internal
        view
        returns (
            bool shouldMow,
            bool shouldPlant,
            bool shouldHarvest,
            UserFieldHarvestResults[] memory userFieldHarvestResults
        )
    {
        // get user state
        (
            uint256 totalClaimableStalk,
            uint256 totalPlantableBeans,
            UserFieldHarvestResults[] memory userFieldHarvestResults
        ) = _getUserState(account, params.mowPlantHarvestParams.fieldHarvestConfigs);

        // validate params - only revert if none of the conditions are met
        shouldMow = _checkMowConditions(
            params.mowPlantHarvestParams.mintwaDeltaB,
            params.mowPlantHarvestParams.minMowAmount,
            totalClaimableStalk,
            previousSeasonTimestamp
        );
        shouldPlant = totalPlantableBeans >= params.mowPlantHarvestParams.minPlantAmount;
        shouldHarvest = _checkHarvestConditions(userFieldHarvestResults);

        require(
            shouldMow || shouldPlant || shouldHarvest,
            "MowPlantHarvestBlueprint: None of the order conditions are met"
        );

        return (shouldMow, shouldPlant, shouldHarvest, userFieldHarvestResults);
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
     * @notice Checks harvest conditions to trigger a harvest operation
     * @dev Harvests should happen when:
     * - The user has enough harvestable pods in at least one field id
     * as specified by `fieldHarvestConfigs.minHarvestAmount`
     * @return bool True if the user should harvest, false otherwise
     */
    function _checkHarvestConditions(
        UserFieldHarvestResults[] memory userFieldHarvestResults
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < userFieldHarvestResults.length; i++) {
            // If operator provided any harvestable plots for this field, we should harvest
            if (userFieldHarvestResults[i].harvestablePlots.length > 0) return true;
        }
        return false;
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
        for (uint256 i = 0; i < fieldHarvestConfigs.length; i++) {
            uint256 fieldId = fieldHarvestConfigs[i].fieldId;

            // Read operator-provided data from transient storage
            bytes memory operatorData = beanstalk.getTractorData(HARVEST_DATA_KEY + fieldId);

            // If operator didn't provide data for this field, treat as no harvestable pods
            if (operatorData.length == 0) {
                userFieldHarvestResults[i] = UserFieldHarvestResults({
                    fieldId: fieldId,
                    harvestablePlots: new uint256[](0)
                });
                continue;
            }

            // Decode operator-provided harvest data
            OperatorHarvestData memory harvestData = abi.decode(
                operatorData,
                (OperatorHarvestData)
            );

            // Verify operator provided data for the correct field
            require(harvestData.fieldId == fieldId, "MowPlantHarvestBlueprint: Field ID mismatch");

            // Use operator data - validation happens in harvest() call
            userFieldHarvestResults[i] = UserFieldHarvestResults({
                fieldId: fieldId,
                harvestablePlots: harvestData.harvestablePlotIndexes
            });
        }

        return (totalClaimableStalk, totalPlantableBeans, userFieldHarvestResults);
    }

    /**
     * @notice Handles tip payment
     * @dev Optimizes gas by using freshly obtained Pinto for tips when possible:
     *      1. If harvested beans >= tip: Use harvested beans only (most efficient)
     *      2. If harvested + planted >= tip: Use harvested first, withdraw remainder from planted deposit
     *      3. Otherwise: Fallback to full withdrawal plan
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
    function _handleTip(
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
        uint256 tipAmount = totalBeanTip > 0 ? uint256(totalBeanTip) : 0;

        if (tipAmount == 0) {
            // Just deposit any harvested beans
            if (totalHarvestedBeans > 0) {
                beanstalk.deposit(beanToken, totalHarvestedBeans, LibTransfer.From.INTERNAL);
            }
            return;
        }

        // Check if we can optimize (tip token resolves to Pinto)
        bool canOptimize = _resolvedSourceIsPinto(sourceTokenIndices);

        if (canOptimize) {
            // CASE 1: Harvest covers full tip (most gas efficient - no withdraw call needed)
            if (totalHarvestedBeans >= tipAmount) {
                _tipFromHarvestedOnly(
                    account,
                    tipAddress,
                    totalBeanTip,
                    totalHarvestedBeans,
                    tipAmount
                );
                return;
            }

            // CASE 2: Need to combine harvested beans + planted beans
            if (totalPlantedBeans > 0 && totalHarvestedBeans + totalPlantedBeans >= tipAmount) {
                _tipFromPlantedAndHarvested(
                    account,
                    tipAddress,
                    totalBeanTip,
                    totalHarvestedBeans,
                    tipAmount,
                    plantedStem
                );
                return;
            }
        }

        // FALLBACK: Deposit all harvested beans first, then use withdrawal plan for tip
        if (totalHarvestedBeans > 0) {
            beanstalk.deposit(beanToken, totalHarvestedBeans, LibTransfer.From.INTERNAL);
        }

        _enforceWithdrawalPlanAndTip(
            account,
            tipAddress,
            sourceTokenIndices,
            totalBeanTip,
            maxGrownStalkPerBdv,
            slippageRatio
        );
    }

    /**
     * @notice Handles tip payment using only harvested beans (CASE 1 - most gas efficient)
     */
    function _tipFromHarvestedOnly(
        address account,
        address tipAddress,
        int256 totalBeanTip,
        uint256 totalHarvestedBeans,
        uint256 tipAmount
    ) internal {
        // Pay tip from harvested beans (already in internal balance)
        tractorHelpers.tip(
            beanToken,
            account,
            tipAddress,
            totalBeanTip,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );

        // Deposit remaining harvested beans to silo
        uint256 remaining = totalHarvestedBeans - tipAmount;
        if (remaining > 0) {
            beanstalk.deposit(beanToken, remaining, LibTransfer.From.INTERNAL);
        }
    }

    /**
     * @notice Handles tip payment using harvested + planted beans (CASE 2)
     * @dev Uses all harvested beans first, then withdraws remainder from planted deposit
     */
    function _tipFromPlantedAndHarvested(
        address account,
        address tipAddress,
        int256 totalBeanTip,
        uint256 totalHarvestedBeans,
        uint256 tipAmount,
        int96 plantedStem
    ) internal {
        // Calculate how much to withdraw from planted deposit
        uint256 tipFromPlant = tipAmount - totalHarvestedBeans;

        // Withdraw needed amount from planted deposit
        int96[] memory stems = new int96[](1);
        stems[0] = plantedStem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = tipFromPlant;
        beanstalk.withdrawDeposits(beanToken, stems, amounts, LibTransfer.To.INTERNAL);

        // Now all tip amount is in internal balance, pay the tip
        tractorHelpers.tip(
            beanToken,
            account,
            tipAddress,
            totalBeanTip,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );
    }

    /**
     * @notice Helper function that creates a withdrawal plan and tips the operator the total bean tip amount
     * @param account The account to withdraw for
     * @param tipAddress The address to send the tip to
     * @param sourceTokenIndices The indices of the source tokens to withdraw from
     * @param totalBeanTip The total tip for mowing, planting and harvesting
     * @param maxGrownStalkPerBdv The maximum amount of grown stalk allowed to be used for the withdrawal, per bdv
     * @param slippageRatio The price slippage ratio for a lp token withdrawal, between the instantaneous price and the current price
     */
    function _enforceWithdrawalPlanAndTip(
        address account,
        address tipAddress,
        uint8[] memory sourceTokenIndices,
        int256 totalBeanTip,
        uint256 maxGrownStalkPerBdv,
        uint256 slippageRatio
    ) internal {
        // Create filter params for the withdrawal plan
        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams(
            maxGrownStalkPerBdv
        );

        // Check if enough beans are available using getWithdrawalPlan
        LibSiloHelpers.WithdrawalPlan memory withdrawalPlan = siloHelpers.getWithdrawalPlan(
            account,
            sourceTokenIndices,
            uint256(totalBeanTip),
            filterParams
        );

        // Execute the withdrawal plan to withdraw the tip amount
        siloHelpers.withdrawBeansFromSources(
            account,
            sourceTokenIndices,
            uint256(totalBeanTip),
            filterParams,
            slippageRatio,
            LibTransfer.To.INTERNAL,
            withdrawalPlan
        );

        // Tip the operator with the withdrawn beans
        tractorHelpers.tip(
            beanToken,
            account,
            tipAddress,
            totalBeanTip,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );
    }

    /**
     * @notice Checks if the resolved first source token is Pinto
     * @dev Handles both direct token indices and strategy-based indices (LOWEST_PRICE_STRATEGY, LOWEST_SEED_STRATEGY)
     * @param sourceTokenIndices The indices of the source tokens to withdraw from
     * @return True if the first resolved source token is Pinto
     */
    function _resolvedSourceIsPinto(
        uint8[] memory sourceTokenIndices
    ) internal view returns (bool) {
        if (sourceTokenIndices.length == 0) return false;

        uint8 firstIdx = sourceTokenIndices[0];

        // LOWEST_PRICE_STRATEGY = type(uint8).max
        if (firstIdx == type(uint8).max) {
            // For price strategy, check if Pinto is the lowest priced token
            (uint8[] memory priceIndices, ) = tractorHelpers.getTokensAscendingPrice();
            if (priceIndices.length == 0) return false;
            address[] memory tokens = siloHelpers.getWhitelistStatusAddresses();
            if (priceIndices[0] >= tokens.length) return false;
            return tokens[priceIndices[0]] == beanToken;
        }

        // LOWEST_SEED_STRATEGY = type(uint8).max - 1
        if (firstIdx == type(uint8).max - 1) {
            // For seed strategy, check if Pinto is the lowest seeded token
            (address lowestSeedToken, ) = tractorHelpers.getLowestSeedToken();
            return lowestSeedToken == beanToken;
        }

        // Direct index - check if it points to Pinto
        address[] memory tokens = siloHelpers.getWhitelistStatusAddresses();
        if (firstIdx >= tokens.length) return false;
        return tokens[firstIdx] == beanToken;
    }
}

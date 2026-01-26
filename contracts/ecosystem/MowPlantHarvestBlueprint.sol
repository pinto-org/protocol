// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
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
    struct MowPlantHarvestParams {
        // Mow
        uint256 minMowAmount;
        uint256 minTwaDeltaB;
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
        UserFieldHarvestResults[] userFieldHarvestResults;
    }

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers,
        address _gasCostCalculator,
        address _siloHelpers
    ) BlueprintBase(_beanstalk, _owner, _tractorHelpers, _gasCostCalculator, _siloHelpers) {}

    /**
     * @notice Main entry point for the mow, plant and harvest blueprint
     * @param params User-controlled parameters for automating mowing, planting and harvesting
     */
    function mowPlantHarvestBlueprint(
        MowPlantHarvestBlueprintStruct calldata params
    ) external payable whenFunctionNotPaused {
        uint256 startGas = gasleft();

        // Initialize local variables
        MowPlantHarvestLocalVars memory vars;

        // Validate
        vars.account = beanstalk.tractorUser();

        // get the user state from the protocol and validate against params
        (vars.shouldMow, vars.shouldPlant, vars.userFieldHarvestResults) = _getAndValidateUserState(
            vars.account,
            beanstalk.time().timestamp,
            params
        );

        // validate order params and revert early if invalid
        _validateSourceTokens(params.mowPlantHarvestParams.sourceTokenIndices);
        _validateOperatorParams(params.opParams.baseOpParams);

        // resolve tip address (defaults to operator if not set)
        address tipAddress = _resolveTipAddress(params.opParams.baseOpParams.tipAddress);

        // Mow, Plant and Harvest
        // Check if user should harvest or plant
        // In the case a harvest or plant is executed, mow by default
        if (vars.shouldPlant || vars.userFieldHarvestResults.length > 0) vars.shouldMow = true;

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
                    "MowPlantHarvestBlueprint: Harvested amount below minimum threshold"
                );

                // Accumulate harvested beans
                vars.totalHarvestedBeans += harvestedBeans;
            }
            // tip for harvesting includes all specified fields
            vars.totalBeanTip += params.opParams.harvestTipAmount;
        }

        // Add dynamic fee if enabled
        if (params.opParams.baseOpParams.useDynamicFee) {
            uint256 gasUsedBeforeFee = startGas - gasleft();
            uint256 estimatedTotalGas = gasUsedBeforeFee + DYNAMIC_FEE_GAS_BUFFER;
            uint256 dynamicFee = _payDynamicFee(
                DynamicFeeParams({
                    account: vars.account,
                    sourceTokenIndices: params.mowPlantHarvestParams.sourceTokenIndices,
                    gasUsed: estimatedTotalGas,
                    feeMarginBps: params.opParams.baseOpParams.feeMarginBps,
                    maxGrownStalkPerBdv: params.mowPlantHarvestParams.maxGrownStalkPerBdv,
                    slippageRatio: params.mowPlantHarvestParams.slippageRatio
                })
            );
            vars.totalBeanTip = _safeAddDynamicFee(vars.totalBeanTip, dynamicFee);
        }

        // Handle tip payment
        handleBeansAndTip(
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
     * @return userFieldHarvestResults An array of structs containing the harvestable pods
     * and plots for the user for each field id where operator provided data
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
            params.mowPlantHarvestParams.minTwaDeltaB,
            params.mowPlantHarvestParams.minMowAmount,
            totalClaimableStalk,
            previousSeasonTimestamp
        );
        shouldPlant = totalPlantableBeans >= params.mowPlantHarvestParams.minPlantAmount;

        require(
            shouldMow || shouldPlant || userFieldHarvestResults.length > 0,
            "MowPlantHarvestBlueprint: None of the order conditions are met"
        );

        return (shouldMow, shouldPlant, userFieldHarvestResults);
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

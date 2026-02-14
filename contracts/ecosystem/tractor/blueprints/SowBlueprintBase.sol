// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {BlueprintBase} from "contracts/ecosystem/BlueprintBase.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {SiloHelpers} from "../utils/SiloHelpers.sol";

/**
 * @title SowBlueprintBase
 * @author FordPinto, Frijo
 * @notice Base contract for sowing blueprints with shared logic.
 *         Inherits from BlueprintBase for common blueprint functionality.
 */
abstract contract SowBlueprintBase is BlueprintBase {
    /**
     * @notice Event emitted when a sow order is complete, or no longer executable due to min sow being less than min sow per season
     * @param blueprintHash The hash of the blueprint
     * @param publisher The address of the publisher
     * @param totalAmountSown The amount of beans sown
     * @param amountUnfulfilled The amount of beans that were not sown
     */
    event SowOrderComplete(
        bytes32 indexed blueprintHash,
        address indexed publisher,
        uint256 totalAmountSown,
        uint256 amountUnfulfilled
    );

    /**
     * @notice Struct to hold local variables for the sow operation to avoid stack too deep errors
     * @param beanToken Address of the Bean token
     * @param availableSoil Amount of soil available for sowing at time of execution
     * @param currentSeason Current season number from Beanstalk
     * @param pintoLeftToSow Current value of the order counter
     * @param totalBeansNeeded Total amount of beans needed including tip
     * @param orderHash Hash of the current blueprint order
     * @param beansWithdrawn Amount of beans withdrawn from sources
     * @param tipAddress Address to send tip to
     * @param account Address of the user's account (current Tractor user), not operator
     * @param totalAmountToSow Total amount intended to sow
     * @param withdrawalPlan The plan for withdrawing beans
     */
    struct SowLocalVars {
        address beanToken;
        uint256 availableSoil;
        uint32 currentSeason;
        uint256 pintoLeftToSow;
        uint256 totalBeansNeeded;
        bytes32 orderHash;
        uint256 beansWithdrawn;
        address tipAddress;
        address account;
        uint256 totalAmountToSow;
        LibSiloHelpers.WithdrawalPlan withdrawalPlan;
    }

    /**
     * @notice Struct to hold sow amounts
     * @param totalAmountToSow Total amount intended to sow
     * @param minAmountToSowPerSeason Minimum amount that must be sown per season
     * @param maxAmountToSowPerSeason Maximum amount that can be sown per season
     */
    struct SowAmounts {
        uint256 totalAmountToSow;
        uint256 minAmountToSowPerSeason;
        uint256 maxAmountToSowPerSeason;
    }

    /**
     * @notice Struct to hold sow parameters
     * @param sourceTokenIndices Indices of source tokens to withdraw from
     * @param sowAmounts Amounts for sowing
     * @param minTemp Minimum temperature required for sowing
     * @param maxPodlineLength Maximum podline length allowed
     * @param maxGrownStalkPerBdv Maximum grown stalk per BDV allowed
     * @param runBlocksAfterSunrise Number of blocks to wait after sunrise before executing
     * @param slippageRatio The price slippage ratio for a lp token withdrawal
     */
    struct SowParams {
        uint8[] sourceTokenIndices;
        SowAmounts sowAmounts;
        uint256 minTemp;
        uint256 maxPodlineLength;
        uint256 maxGrownStalkPerBdv;
        uint256 runBlocksAfterSunrise;
        uint256 slippageRatio;
    }

    /**
     * @notice Main struct for sow blueprint
     * @param sowParams Parameters related to sowing
     * @param opParams Parameters related to operators (from BlueprintBase)
     */
    struct SowBlueprintStruct {
        SowParams sowParams;
        OperatorParams opParams;
    }

    /**
     * @notice Blueprint specific struct to hold order info
     * @param pintoSownCounter Counter for the number of maximum pinto that can be sown from this blueprint
     * @param lastExecutedSeason Last season this blueprint was executed (moved from BlueprintBase for SowBlueprint-specific tracking)
     */
    struct OrderInfo {
        uint256 pintoSownCounter;
        uint32 lastExecutedSeason;
    }

    // Default slippage ratio for LP token withdrawals (1%)
    uint256 internal constant DEFAULT_SLIPPAGE_RATIO = 0.01e18;

    // Combined state mapping for order info
    mapping(bytes32 => OrderInfo) private orderInfo;

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
     * @notice Gets the number of maximum pinto that can be sown from this blueprint
     * @param orderHash The hash of the order
     * @return The number of maximum pinto that can be sown from this blueprint
     */
    function getPintosLeftToSow(bytes32 orderHash) public view returns (uint256) {
        return orderInfo[orderHash].pintoSownCounter;
    }

    /**
     * @notice Gets the last executed season for a given order hash
     */
    function getLastExecutedSeason(bytes32 orderHash) public view returns (uint32) {
        return orderInfo[orderHash].lastExecutedSeason;
    }

    /**
     * @notice Internal function containing shared sow blueprint logic
     * @param params Parameters for sow execution
     * @param referral Referral address (address(0) for no referral)
     */
    function _sowBlueprintInternal(SowBlueprintStruct memory params, address referral) internal {
        // Initialize local variables
        SowLocalVars memory vars;

        // get order hash
        vars.orderHash = beanstalk.getCurrentBlueprintHash();
        vars.account = beanstalk.tractorUser();

        // Get various data from beanstalk and validate parameters
        (
            vars.availableSoil,
            vars.beanToken,
            vars.currentSeason,
            vars.pintoLeftToSow,
            vars.totalAmountToSow,
            vars.totalBeansNeeded,
            vars.withdrawalPlan
        ) = _validateParamsAndReturnBeanstalkState(params, vars.orderHash, vars.account);

        // Get tip address. If tip address is not set, set it to the operator
        vars.tipAddress = _resolveTipAddress(params.opParams.tipAddress);

        // if slippage ratio is not set, set a default parameter:
        uint256 slippageRatio = params.sowParams.slippageRatio;
        if (slippageRatio == 0) {
            slippageRatio = DEFAULT_SLIPPAGE_RATIO;
        }

        // Execute the withdrawal plan
        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams(
            params.sowParams.maxGrownStalkPerBdv
        );

        vars.beansWithdrawn = siloHelpers.withdrawBeansFromSources(
            vars.account,
            params.sowParams.sourceTokenIndices,
            vars.totalBeansNeeded,
            filterParams,
            slippageRatio,
            LibTransfer.To.INTERNAL,
            vars.withdrawalPlan
        );

        uint256 pintoRemainingAfterSow = vars.pintoLeftToSow - vars.totalAmountToSow;
        uint256 sowCounter = pintoRemainingAfterSow;
        // if `pintoRemainingAfterSow` is less than the min amount to sow per season,
        // the order has completed, and should emit a SowOrderComplete event
        if (
            pintoRemainingAfterSow == 0 ||
            pintoRemainingAfterSow < params.sowParams.sowAmounts.minAmountToSowPerSeason
        ) {
            if (pintoRemainingAfterSow == 0) {
                // If the pinto remaining after sow is 0,
                // set the sow counter to max to indicate completion
                // (as `0` in `sowCounter` implies an uninitialized counter)
                sowCounter = type(uint256).max;
            }
            emit SowOrderComplete(
                vars.orderHash,
                vars.account,
                params.sowParams.sowAmounts.totalAmountToSow - pintoRemainingAfterSow,
                pintoRemainingAfterSow
            );
        }
        updatePintoLeftToSowCounter(vars.orderHash, sowCounter);

        // Tip the operator
        tractorHelpers.tip(
            vars.beanToken,
            vars.account,
            vars.tipAddress,
            params.opParams.operatorTipAmount,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );

        // Sow the withdrawn beans
        if (referral == address(0)) {
            // Standard sow without referral
            beanstalk.sowWithMin(
                vars.totalAmountToSow,
                params.sowParams.minTemp,
                params.sowParams.sowAmounts.minAmountToSowPerSeason,
                LibTransfer.From.INTERNAL
            );
        } else {
            // Sow with referral
            beanstalk.sowWithReferral(
                vars.totalAmountToSow,
                params.sowParams.minTemp,
                params.sowParams.sowAmounts.minAmountToSowPerSeason,
                LibTransfer.From.INTERNAL,
                referral
            );
        }

        // Update the last executed season for this blueprint
        _updateSowLastExecutedSeason(vars.orderHash, vars.currentSeason);
    }

    /**
     * @notice Updates the pinto left to sow counter for a given order hash
     */
    function updatePintoLeftToSowCounter(bytes32 orderHash, uint256 newCounter) internal {
        orderInfo[orderHash].pintoSownCounter = newCounter;
    }

    /**
     * @notice Updates the last executed season for a given order hash
     */
    function _updateSowLastExecutedSeason(bytes32 orderHash, uint32 season) internal {
        orderInfo[orderHash].lastExecutedSeason = season;
    }

    /**
     * @notice Validates the initial parameters for the sow operation
     */
    function _validateSowParams(SowBlueprintStruct memory params) internal view {
        // Validate source tokens (inline since base version requires calldata)
        require(
            params.sowParams.sourceTokenIndices.length > 0,
            "Must provide at least one source token"
        );

        // Require that maxAmountToSowPerSeason > 0
        require(
            params.sowParams.sowAmounts.maxAmountToSowPerSeason > 0,
            "Max amount to sow per season is 0"
        );

        // Require that minAmountToSowPerSeason <= maxAmountToSowPerSeason
        require(
            params.sowParams.sowAmounts.minAmountToSowPerSeason <=
                params.sowParams.sowAmounts.maxAmountToSowPerSeason,
            "Min amount to sow per season is greater than max amount to sow per season"
        );

        // Check if enough blocks have passed since sunrise
        require(
            block.number >= beanstalk.sunriseBlock() + params.sowParams.runBlocksAfterSunrise,
            "Not enough blocks since sunrise"
        );

        // Check podline length
        require(
            beanstalk.totalUnharvestableForActiveField() <= params.sowParams.maxPodlineLength,
            "Podline too long"
        );
    }

    /**
     * @notice Validates parameters and returns beanstalk state
     */
    function _validateParamsAndReturnBeanstalkState(
        SowBlueprintStruct memory params,
        bytes32 orderHash,
        address blueprintPublisher
    )
        internal
        view
        returns (
            uint256 availableSoil,
            address beanToken,
            uint32 currentSeason,
            uint256 pintoLeftToSow,
            uint256 totalAmountToSow,
            uint256 totalBeansNeeded,
            LibSiloHelpers.WithdrawalPlan memory plan
        )
    {
        (availableSoil, beanToken, currentSeason) = getAndValidateBeanstalkState(params.sowParams);

        _validateSowParams(params);
        pintoLeftToSow = _validateBlueprintAndPintoLeftToSow(orderHash, currentSeason);

        // If this is the first execution, initialize the counter
        if (pintoLeftToSow == 0) {
            pintoLeftToSow = params.sowParams.sowAmounts.totalAmountToSow;
        }

        // Determine the total amount to sow based on various constraints
        totalAmountToSow = determineTotalAmountToSow(
            params.sowParams.sowAmounts.totalAmountToSow,
            pintoLeftToSow == 0 ? params.sowParams.sowAmounts.totalAmountToSow : pintoLeftToSow,
            params.sowParams.sowAmounts.maxAmountToSowPerSeason,
            availableSoil
        );

        // Calculate total beans needed (sow amount + tip if positive)
        totalBeansNeeded = totalAmountToSow;
        if (params.opParams.operatorTipAmount > 0) {
            totalBeansNeeded += uint256(params.opParams.operatorTipAmount);
        }

        // Check if enough beans are available using getWithdrawalPlan
        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams(
            params.sowParams.maxGrownStalkPerBdv
        );

        plan = siloHelpers.getWithdrawalPlanExcludingPlan(
            blueprintPublisher,
            params.sowParams.sourceTokenIndices,
            totalBeansNeeded,
            filterParams,
            plan // Passed in plan is empty
        );

        // Verify enough beans are available
        if (plan.totalAvailableBeans < totalBeansNeeded) {
            require(
                plan.totalAvailableBeans >=
                    params.sowParams.sowAmounts.minAmountToSowPerSeason +
                        uint256(
                            params.opParams.operatorTipAmount > 0
                                ? params.opParams.operatorTipAmount
                                : int256(0)
                        ),
                "Insufficient beans available"
            );

            // Adjust the total amount to sow based on available beans
            if (params.opParams.operatorTipAmount > 0) {
                totalAmountToSow =
                    plan.totalAvailableBeans -
                    uint256(params.opParams.operatorTipAmount);
            } else {
                totalAmountToSow = plan.totalAvailableBeans;
            }

            totalBeansNeeded = plan.totalAvailableBeans;
        }
    }

    /**
     * @notice Gets and validates current beanstalk state
     */
    function getAndValidateBeanstalkState(
        SowParams memory params
    ) internal view returns (uint256 availableSoil, address beanToken_, uint32 currentSeason) {
        availableSoil = beanstalk.totalSoil();
        beanToken_ = beanToken;
        currentSeason = beanstalk.time().current;

        // Check temperature and soil requirements
        require(beanstalk.temperature() >= params.minTemp, "Temperature too low");
        require(
            availableSoil >= params.sowAmounts.minAmountToSowPerSeason,
            "Not enough soil for min sow"
        );
    }

    /**
     * @notice Gets the pinto left to sow for a given order hash
     */
    function _validateBlueprintAndPintoLeftToSow(
        bytes32 orderHash,
        uint32 currentSeason
    ) internal view returns (uint256 pintoLeftToSow) {
        // Check that this blueprint hasn't been executed this season yet
        require(
            getLastExecutedSeason(orderHash) < currentSeason,
            "Blueprint already executed this season"
        );

        // Blueprint specific validations
        // Verify there's still sow amount available with the counter
        pintoLeftToSow = getPintosLeftToSow(orderHash);

        // If pintoLeftToSow is max uint256, then the sow order has already been fully used, so revert
        require(pintoLeftToSow != type(uint256).max, "Sow order already fulfilled");
    }

    /**
     * @notice Determines the total amount to sow based on various constraints
     * @param totalAmountToSow Total amount intended to sow
     * @param pintoLeftToSow Current value of the running total requested to be sown
     * @param maxAmountToSowPerSeason Maximum amount that can be sown per season
     * @param availableSoil Amount of soil available for sowing
     * @return The determined total amount to sow
     */
    function determineTotalAmountToSow(
        uint256 totalAmountToSow,
        uint256 pintoLeftToSow,
        uint256 maxAmountToSowPerSeason,
        uint256 availableSoil
    ) internal pure returns (uint256) {
        // If the Pinto left to sow is less than the totalAmountToSow, use the remaining pinto left to sow
        if (pintoLeftToSow < totalAmountToSow) {
            totalAmountToSow = pintoLeftToSow;
        }

        // Check and enforce maxAmountToSowPerSeason limit first
        if (totalAmountToSow > maxAmountToSowPerSeason) {
            totalAmountToSow = maxAmountToSowPerSeason;
        }

        // Then check soil availability and adjust if needed
        if (totalAmountToSow > availableSoil) {
            totalAmountToSow = availableSoil;
        }

        return totalAmountToSow;
    }
}

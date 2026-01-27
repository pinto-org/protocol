// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {TractorHelpers} from "contracts/ecosystem/tractor/utils/TractorHelpers.sol";
import {PerFunctionPausable} from "contracts/ecosystem/tractor/utils/PerFunctionPausable.sol";
import {GasCostCalculator} from "contracts/ecosystem/tractor/utils/GasCostCalculator.sol";
import {SiloHelpers} from "contracts/ecosystem/tractor/utils/SiloHelpers.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";

/**
 * @title BlueprintBase
 * @notice Abstract base contract for Tractor blueprints providing shared state and validation functions
 */
abstract contract BlueprintBase is PerFunctionPausable {
    /**
     * @notice Gas buffer for dynamic fee calculation to account for remaining operations
     * @dev This buffer covers the gas cost of fee withdrawal and subsequent tip operations
     */
    uint256 public constant DYNAMIC_FEE_GAS_BUFFER = 15000;
    /**
     * @notice Struct to hold operator parameters
     * @param whitelistedOperators Array of whitelisted operator addresses
     * @param tipAddress Address to send tip to
     * @param operatorTipAmount Amount of tip to pay to operator
     * @param useDynamicFee Whether to use dynamic gas-based fee calculation
     * @param feeMarginBps Additional margin for dynamic fee in basis points (0 = no margin, 1000 = 10%)
     */
    struct OperatorParams {
        address[] whitelistedOperators;
        address tipAddress;
        int256 operatorTipAmount;
        bool useDynamicFee;
        uint256 feeMarginBps;
    }

    /**
     * @notice Struct to hold dynamic fee parameters
     * @param account The account to withdraw fee from
     * @param sourceTokenIndices Indices of source tokens to withdraw from
     * @param gasUsed Total gas used for fee calculation
     * @param feeMarginBps Additional margin in basis points
     * @param maxGrownStalkPerBdv Maximum grown stalk per BDV for withdrawal filtering
     * @param slippageRatio Slippage ratio for LP token withdrawals
     */
    struct DynamicFeeParams {
        address account;
        uint8[] sourceTokenIndices;
        uint256 gasUsed;
        uint256 feeMarginBps;
        uint256 maxGrownStalkPerBdv;
        uint256 slippageRatio;
    }

    /**
     * @notice Struct to hold parameters for tip processing with dynamic fees
     * @param account The user account to process tips for
     * @param tipAddress Address to send the tip to
     * @param sourceTokenIndices Indices of source tokens for fee withdrawal
     * @param operatorTipAmount Base tip amount for the operator
     * @param useDynamicFee Whether to add dynamic gas-based fee
     * @param feeMarginBps Margin in basis points for dynamic fee
     * @param maxGrownStalkPerBdv Maximum grown stalk per BDV for fee withdrawal
     * @param slippageRatio Slippage ratio for LP token withdrawals
     * @param startGas Gas at function start for fee calculation
     */
    struct TipParams {
        address account;
        address tipAddress;
        uint8[] sourceTokenIndices;
        int256 operatorTipAmount;
        bool useDynamicFee;
        uint256 feeMarginBps;
        uint256 maxGrownStalkPerBdv;
        uint256 slippageRatio;
        uint256 startGas;
    }

    /**
     * Mapping to track the last executed season for each order hash
     * If a Blueprint needs to track more state about orders, an additional
     * mapping(orderHash => state) can be added to the contract inheriting from BlueprintBase.
     */
    mapping(bytes32 orderHash => uint32 lastExecutedSeason) public orderLastExecutedSeason;

    // Contracts
    IBeanstalk public immutable beanstalk;
    address public immutable beanToken;
    TractorHelpers public immutable tractorHelpers;
    GasCostCalculator public immutable gasCostCalculator;
    SiloHelpers public immutable siloHelpers;

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers,
        address _gasCostCalculator,
        address _siloHelpers
    ) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
        beanToken = beanstalk.getBeanToken();
        tractorHelpers = TractorHelpers(_tractorHelpers);
        gasCostCalculator = GasCostCalculator(_gasCostCalculator);
        siloHelpers = SiloHelpers(_siloHelpers);
    }

    /**
     * @notice Updates the last executed season for a given tractor order hash
     * @param orderHash The hash of the order
     * @param season The season number
     */
    function _updateLastExecutedSeason(bytes32 orderHash, uint32 season) internal {
        orderLastExecutedSeason[orderHash] = season;
    }

    /**
     * @notice Validates shared blueprint execution conditions
     * @param orderHash The hash of the blueprint
     * @param currentSeason The current season
     */
    function _validateBlueprint(bytes32 orderHash, uint32 currentSeason) internal view {
        require(orderHash != bytes32(0), "No active blueprint, function must run from Tractor");
        require(
            orderLastExecutedSeason[orderHash] < currentSeason,
            "Blueprint already executed this season"
        );
        // add any additional shared validation for blueprints here
    }

    /**
     * @notice Validates operator parameters
     * @param opParams The operator parameters to validate
     */
    function _validateOperatorParams(OperatorParams calldata opParams) internal view {
        require(
            tractorHelpers.isOperatorWhitelisted(opParams.whitelistedOperators),
            "Operator not whitelisted"
        );
        // add any additional shared validation for operators here
    }

    /**
     * @notice Validates source token indices
     * @param sourceTokenIndices Array of source token indices
     */
    function _validateSourceTokens(uint8[] calldata sourceTokenIndices) internal pure {
        require(sourceTokenIndices.length > 0, "Must provide at least one source token");
    }

    /**
     * @notice Resolves tip address, defaulting to operator if not provided
     * @param providedTipAddress The provided tip address
     * @return The resolved tip address
     */
    function _resolveTipAddress(address providedTipAddress) internal view returns (address) {
        return providedTipAddress == address(0) ? beanstalk.operator() : providedTipAddress;
    }

    /**
     * @notice Calculates and withdraws dynamic fee from user's deposits
     * @param feeParams Struct containing all parameters for dynamic fee calculation
     * @return fee The calculated fee amount in Pinto
     */
    function _payDynamicFee(DynamicFeeParams memory feeParams) internal returns (uint256 fee) {
        fee = gasCostCalculator.calculateFeeInPinto(feeParams.gasUsed, feeParams.feeMarginBps);

        // Validate fee doesn't overflow when cast to int256
        require(fee <= uint256(type(int256).max), "BlueprintBase: fee overflow");

        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams(
            feeParams.maxGrownStalkPerBdv
        );
        LibSiloHelpers.WithdrawalPlan memory emptyPlan;

        siloHelpers.withdrawBeansFromSources(
            feeParams.account,
            feeParams.sourceTokenIndices,
            fee,
            filterParams,
            feeParams.slippageRatio,
            LibTransfer.To.INTERNAL,
            emptyPlan
        );
    }

    /**
     * @notice Safely adds dynamic fee to existing tip amount with overflow protection
     * @param currentTip The current tip amount (can be negative for operator-pays-user)
     * @param dynamicFee The dynamic fee to add (always positive)
     * @return newTip The new total tip amount after adding dynamic fee
     * @dev Reverts if addition would overflow int256
     */
    function _safeAddDynamicFee(
        int256 currentTip,
        uint256 dynamicFee
    ) internal pure returns (int256 newTip) {
        // Fee is already validated to fit in int256 by _payDynamicFee
        int256 feeAsInt = int256(dynamicFee);

        if (currentTip > 0 && feeAsInt > type(int256).max - currentTip) {
            revert("BlueprintBase: tip + fee overflow");
        }

        newTip = currentTip + feeAsInt;
    }

    /**
     * @notice Handles dynamic fee calculation and tip payment
     * @param tipParams Parameters for tip processing
     * @dev This is a shared implementation for blueprints with simple tip flows
     *      (single operatorTipAmount + optional dynamic fee).
     *      Blueprints with complex tip logic (e.g., multiple accumulated tips,
     *      special bean handling) should implement their own tip handling.
     */
    function _processFeesAndTip(TipParams memory tipParams) internal {
        int256 totalTipAmount = tipParams.operatorTipAmount;

        if (tipParams.useDynamicFee) {
            uint256 gasUsedBeforeFee = tipParams.startGas - gasleft();
            uint256 estimatedTotalGas = gasUsedBeforeFee + DYNAMIC_FEE_GAS_BUFFER;
            uint256 dynamicFee = _payDynamicFee(
                DynamicFeeParams({
                    account: tipParams.account,
                    sourceTokenIndices: tipParams.sourceTokenIndices,
                    gasUsed: estimatedTotalGas,
                    feeMarginBps: tipParams.feeMarginBps,
                    maxGrownStalkPerBdv: tipParams.maxGrownStalkPerBdv,
                    slippageRatio: tipParams.slippageRatio
                })
            );
            totalTipAmount = _safeAddDynamicFee(totalTipAmount, dynamicFee);
        }

        tractorHelpers.tip(
            beanToken,
            tipParams.account,
            tipParams.tipAddress,
            totalTipAmount,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );
    }
}

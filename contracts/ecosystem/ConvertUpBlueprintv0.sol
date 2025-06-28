// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {TractorHelpers} from "./TractorHelpers.sol";
import {PerFunctionPausable} from "./PerFunctionPausable.sol";
import {BeanstalkPrice} from "./price/BeanstalkPrice.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {ReservesType} from "./price/WellPrice.sol";
import {Call, IWell, IERC20} from "../interfaces/basin/IWell.sol";
import {SiloHelpers} from "./SiloHelpers.sol";

/**
 * @title ConvertUpBlueprintv0
 * @author FordPinto
 * @notice Contract for converting up with Tractor, with a number of conditions
 * @dev This contract always converts up to Bean token, which is obtained from beanstalk.getBeanToken()
 */
contract ConvertUpBlueprintv0 is PerFunctionPausable {
    /**
     * @notice Event emitted when a convert up order is complete
     * @param blueprintHash The hash of the blueprint
     * @param publisher The address of the publisher
     * @param amountConverted The amount that was converted
     */
    event ConvertUpOrderComplete(
        bytes32 indexed blueprintHash,
        address indexed publisher,
        uint256 amountConverted
    );

    /**
     * @notice Struct to hold local variables for the convert up operation to avoid stack too deep errors
     * @param orderHash Hash of the current blueprint order
     * @param account Address of the user's account (current Tractor user), not operator
     * @param tipAddress Address to send tip to
     * @param pdvLeftToConvert Amount of PDV left to convert from the total
     * @param currentPdvToConvert Amount of PDV to convert in this execution
     * @param amountConverted Amount actually converted
     * @param withdrawalPlan Plan for withdrawing tokens for conversion
     */
    struct ConvertUpLocalVars {
        bytes32 orderHash;
        address account;
        address tipAddress;
        uint256 pdvLeftToConvert;
        uint256 currentPdvToConvert;
        uint256 amountConverted;
        LibSiloHelpers.WithdrawalPlan withdrawalPlan;
    }

    /**
     * @notice Main struct for convert up blueprint
     * @param convertUpParams Parameters related to converting up
     * @param opParams Parameters related to operators
     */
    struct ConvertUpBlueprintStruct {
        ConvertUpParams convertUpParams;
        OperatorParams opParams;
    }

    /**
     * @notice Struct to hold convert up parameters
     * @param sourceTokenIndices Indices of source tokens to use for conversion
     * @param totalConvertPdv Total amount to convert in PDV terms
     * @param minConvertPdvPerExecution Minimum PDV to convert per execution
     * @param maxConvertPdvPerExecution Maximum PDV to convert per execution
     * @param minTimeBetweenConverts Minimum time (in seconds) between convert executions
     * @param minConvertBonusCapacity Minimum capacity required for convert bonus
     * @param maxGrownStalkPerBdv Maximum grown stalk per BDV to withdraw from deposits
     * @param minGrownStalkPerBdvBonusThreshold Threshold for considering a deposit to have a good stalk-to-BDV ratio
     * @param maxPriceToConvertUp Maximum price at which to convert up (for MEV resistance)
     * @param minPriceToConvertUp Minimum price at which to convert up (for range targeting)
     * @param maxGrownStalkPerPdvPenalty Maximum grown stalk per PDV penalty to accept
     * @param slippageRatio Slippage tolerance ratio for the conversion
     */
    struct ConvertUpParams {
        // Source tokens to withdraw from
        uint8[] sourceTokenIndices;
        // Conversion amounts
        uint256 totalConvertPdv;
        uint256 minConvertPdvPerExecution;
        uint256 maxConvertPdvPerExecution;
        // Time constraints
        uint256 minTimeBetweenConverts;
        // Bonus/capacity parameters
        uint256 minConvertBonusCapacity;
        uint256 maxGrownStalkPerBdv;
        uint256 minGrownStalkPerBdvBonusThreshold;
        // Price constraints
        uint256 maxPriceToConvertUp;
        uint256 minPriceToConvertUp;
        // Penalty tolerance
        int256 maxGrownStalkPerPdvPenalty;
        // Execution parameters
        uint256 slippageRatio;
    }

    /**
     * @notice Struct to hold operator parameters
     * @param whitelistedOperators Array of whitelisted operator addresses
     * @param tipAddress Address to send tip to
     * @param operatorTipAmount Amount of tip to pay to operator
     */
    struct OperatorParams {
        address[] whitelistedOperators;
        address tipAddress;
        int256 operatorTipAmount;
    }

    IBeanstalk immutable beanstalk;
    TractorHelpers public immutable tractorHelpers;
    BeanstalkPrice public immutable beanstalkPrice;
    SiloHelpers public immutable siloHelpers;

    // Default slippage ratio for conversions (1%)
    uint256 internal constant DEFAULT_SLIPPAGE_RATIO = 0.01e18;

    /**
     * @notice Struct to hold order info
     * @param lastExecutedTimestamp Last timestamp when a blueprint was executed
     * @param pdvLeftToConvert Amount of PDV left to convert from the total
     */
    struct OrderInfo {
        uint256 lastExecutedTimestamp;
        uint256 pdvLeftToConvert;
    }

    // Combined state mapping for order info
    mapping(bytes32 => OrderInfo) public orderInfo;

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers,
        address _siloHelpers,
        address _beanstalkPrice
    ) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
        tractorHelpers = TractorHelpers(_tractorHelpers);
        siloHelpers = SiloHelpers(_siloHelpers);
        beanstalkPrice = BeanstalkPrice(_beanstalkPrice);
    }

    /**
     * @notice Converts tokens up to Bean using specified parameters
     * @param params The ConvertUpBlueprintStruct containing all parameters for the convert up operation
     */
    function convertUpBlueprintv0(
        ConvertUpBlueprintStruct calldata params
    ) external payable whenFunctionNotPaused {
        // Initialize local variables
        ConvertUpLocalVars memory vars;
        // Get order hash
        vars.orderHash = beanstalk.getCurrentBlueprintHash();

        // Get user account
        vars.account = beanstalk.tractorUser();

        // Validate parameters
        validateParams(params);

        // Check if the executing operator (msg.sender) is whitelisted
        require(
            tractorHelpers.isOperatorWhitelisted(params.opParams.whitelistedOperators),
            "Operator not whitelisted"
        );

        // Get tip address. If tip address is not set, set it to the operator
        if (params.opParams.tipAddress == address(0)) {
            vars.tipAddress = beanstalk.operator();
        } else {
            vars.tipAddress = params.opParams.tipAddress;
        }

        // Get current PDV left to convert
        vars.pdvLeftToConvert = getPdvLeftToConvert(vars.orderHash);

        // If pdvLeftToConvert is max, revert, as the order has already been completed
        if (vars.pdvLeftToConvert == type(uint256).max) {
            revert("Order has already been completed");
        } else if (vars.pdvLeftToConvert == 0) {
            // If pdvLeftToConvert is 0, initialize it with the total amount
            vars.pdvLeftToConvert = params.convertUpParams.totalConvertPdv;
        }

        // Determine current convert amount based on constraints
        vars.currentPdvToConvert = determineConvertAmount(
            vars.pdvLeftToConvert,
            params.convertUpParams.minConvertPdvPerExecution,
            params.convertUpParams.maxConvertPdvPerExecution
        );

        // Fetch current price and check if price is within acceptable range
        validatePriceRange(
            beanstalkPrice.price(ReservesType.INSTANTANEOUS_RESERVES).price,
            params.convertUpParams.minPriceToConvertUp,
            params.convertUpParams.maxPriceToConvertUp
        );

        // Apply slippage ratio if needed
        uint256 slippageRatio = params.convertUpParams.slippageRatio;
        if (slippageRatio == 0) {
            slippageRatio = DEFAULT_SLIPPAGE_RATIO;
        }

        // First withdraw Beans from which to tip Operator (using a newer deposit burns less stalk)
        LibSiloHelpers.WithdrawalPlan memory emptyPlan;
        if (params.opParams.operatorTipAmount > 0) {
            siloHelpers.withdrawBeansFromSources(
                vars.account,
                params.convertUpParams.sourceTokenIndices,
                uint256(params.opParams.operatorTipAmount),
                params.convertUpParams.maxGrownStalkPerBdv,
                true, // excludeBean from the withdrawal plan (only applies if using a strategy)
                true, // excludeGerminatingDeposits from the withdrawal plan
                slippageRatio,
                LibTransfer.To.INTERNAL,
                emptyPlan
            );
        }

        // Get withdrawal plan for the tokens to convert
        vars.withdrawalPlan = siloHelpers.getWithdrawalPlanExcludingPlan(
            vars.account,
            params.convertUpParams.sourceTokenIndices,
            vars.currentPdvToConvert,
            params.convertUpParams.maxGrownStalkPerBdv,
            true, // excludeBean from the withdrawal plan (only applies if using a strategy)
            true, // excludeGerminatingDeposits from the withdrawal plan
            emptyPlan
        );

        address beanToken = beanstalk.getBeanToken();

        // Execute the conversion using Beanstalk's convert function
        vars.amountConverted = executeConvertUp(
            vars,
            beanToken,
            slippageRatio,
            params.convertUpParams.maxGrownStalkPerPdvPenalty
        );

        // Update the state
        // If all PDV has been converted, set to max to indicate completion
        uint256 pdvConverted = vars.pdvLeftToConvert - vars.currentPdvToConvert == 0
            ? type(uint256).max
            : vars.pdvLeftToConvert - vars.currentPdvToConvert;

        // Update the PDV left to convert
        updatePdvLeftToConvert(vars.orderHash, pdvConverted);

        // Tip the operator
        tractorHelpers.tip(
            beanToken,
            vars.account,
            vars.tipAddress,
            params.opParams.operatorTipAmount,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );

        // Update the last executed timestamp for this blueprint
        updateLastExecutedTimestamp(vars.orderHash, block.timestamp);

        // Emit completion event
        emit ConvertUpOrderComplete(vars.orderHash, vars.account, vars.amountConverted);
    }

    /**
     * @notice Validates the parameters for the convert up operation
     * @param params The ConvertUpBlueprintStruct containing all parameters for the convert up operation
     */
    function validateParams(ConvertUpBlueprintStruct calldata params) internal view {
        // Source tokens validation
        require(
            params.convertUpParams.sourceTokenIndices.length > 0,
            "Must provide at least one source token"
        );

        // Amount validations
        require(params.convertUpParams.totalConvertPdv > 0, "Total convert PDV must be > 0");
        require(
            params.convertUpParams.minConvertPdvPerExecution <=
                params.convertUpParams.maxConvertPdvPerExecution,
            "Min convert PDV per execution > max"
        );
        require(
            params.convertUpParams.minConvertPdvPerExecution > 0,
            "Min convert PDV per execution must be > 0"
        );

        // Price validations
        require(
            params.convertUpParams.minPriceToConvertUp <=
                params.convertUpParams.maxPriceToConvertUp,
            "Min price to convert up > max price"
        );

        // Time constraint validation
        require(
            params.convertUpParams.minTimeBetweenConverts > 0,
            "Min time between converts must be > 0"
        );

        // Check if blueprint is active
        bytes32 orderHash = beanstalk.getCurrentBlueprintHash();
        require(orderHash != bytes32(0), "No active blueprint, function must run from Tractor");

        // Time between conversions check
        uint256 lastExecution = getLastExecutedTimestamp(orderHash);
        if (lastExecution > 0) {
            require(
                block.timestamp >= lastExecution + params.convertUpParams.minTimeBetweenConverts,
                "Too soon after last execution"
            );
        }

        // Check convert bonus conditions
        if (
            params.convertUpParams.minGrownStalkPerBdvBonusThreshold > 0 ||
            params.convertUpParams.minConvertBonusCapacity > 0
        ) {
            // Get current bonus amount and remaining capacity
            (uint256 bonusStalkPerBdv, uint256 remainingCapacity) = beanstalk
                .getConvertStalkPerBdvBonusAndRemainingCapacity();

            // Check if bonus amount meets threshold
            if (params.convertUpParams.minGrownStalkPerBdvBonusThreshold > 0) {
                require(
                    bonusStalkPerBdv >= params.convertUpParams.minGrownStalkPerBdvBonusThreshold,
                    "Convert bonus amount below threshold"
                );
            }

            // Check if remaining capacity meets minimum
            if (params.convertUpParams.minConvertBonusCapacity > 0) {
                require(
                    remainingCapacity >= params.convertUpParams.minConvertBonusCapacity,
                    "Convert bonus capacity below minimum"
                );
            }
        }
    }

    /**
     * @notice Determines the amount to convert based on constraints
     * @param pdvLeftToConvert Total PDV left to convert
     * @param minConvertPdvPerExecution Minimum PDV per execution
     * @param maxConvertPdvPerExecution Maximum PDV per execution
     * @return The amount to convert in this execution
     */
    function determineConvertAmount(
        uint256 pdvLeftToConvert,
        uint256 minConvertPdvPerExecution,
        uint256 maxConvertPdvPerExecution
    ) internal pure returns (uint256) {
        // If pdvLeftToConvert is less than minConvertPdvPerExecution, we can't convert
        require(pdvLeftToConvert >= minConvertPdvPerExecution, "Not enough PDV left to convert");

        // If pdvLeftToConvert is less than maxConvertPdvPerExecution, use pdvLeftToConvert
        if (pdvLeftToConvert < maxConvertPdvPerExecution) {
            return pdvLeftToConvert;
        }

        // Otherwise, use maxConvertPdvPerExecution
        return maxConvertPdvPerExecution;
    }

    /**
     * @notice Gets the PDV left to convert for an order
     * @param orderHash The hash of the order
     * @return The PDV left to convert
     */
    function getPdvLeftToConvert(bytes32 orderHash) public view returns (uint256) {
        return orderInfo[orderHash].pdvLeftToConvert;
    }

    /**
     * @notice Updates the PDV left to convert
     * @param orderHash The hash of the order
     * @param amount The new PDV left to convert
     */
    function updatePdvLeftToConvert(bytes32 orderHash, uint256 amount) internal {
        orderInfo[orderHash].pdvLeftToConvert = amount;
    }

    /**
     * @notice Gets the last timestamp a blueprint was executed
     * @param orderHash The hash of the blueprint
     * @return The last timestamp the blueprint was executed, or 0 if never executed
     */
    function getLastExecutedTimestamp(bytes32 orderHash) public view returns (uint256) {
        return orderInfo[orderHash].lastExecutedTimestamp;
    }

    /**
     * @notice Updates the last executed timestamp for a given order hash
     * @param orderHash The hash of the order
     * @param timestamp The current timestamp
     */
    function updateLastExecutedTimestamp(bytes32 orderHash, uint256 timestamp) internal {
        orderInfo[orderHash].lastExecutedTimestamp = timestamp;
    }

    /**
     * @notice Validates that the current price is within the acceptable range for converting up
     * @param currentPrice The current price from BeanstalkPrice
     * @param minPriceToConvertUp Minimum price at which to convert up
     * @param maxPriceToConvertUp Maximum price at which to convert up
     */
    function validatePriceRange(
        uint256 currentPrice,
        uint256 minPriceToConvertUp,
        uint256 maxPriceToConvertUp
    ) internal pure {
        require(
            currentPrice >= minPriceToConvertUp,
            "Current price below minimum price for convert up"
        );
        require(
            currentPrice <= maxPriceToConvertUp,
            "Current price above maximum price for convert up"
        );
    }

    /**
     * @notice Executes the convert up operation using Beanstalk's convert function
     * @param vars Local variables containing the necessary data for execution
     * @param slippageRatio Slippage tolerance ratio for the conversion
     * @param maxGrownStalkPerPdvPenalty Maximum grown stalk per PDV penalty to accept
     * @return totalAmountConverted The total amount converted across all token types
     */
    function executeConvertUp(
        ConvertUpLocalVars memory vars,
        address beanToken,
        uint256 slippageRatio,
        int256 maxGrownStalkPerPdvPenalty
    ) internal returns (uint256 totalAmountConverted) {
        totalAmountConverted = 0;

        // Process each token type in the withdrawal plan
        for (uint256 i = 0; i < vars.withdrawalPlan.sourceTokens.length; i++) {
            address token = vars.withdrawalPlan.sourceTokens[i];
            if (token == address(0) || token == beanToken) continue; // Skip empty tokens or Bean tokens

            // Get stems and amounts from the withdrawal plan for this token
            if (vars.withdrawalPlan.stems[i].length == 0) continue;

            // Use the stems and amounts for this token directly from the withdrawal plan
            int96[] memory stems = vars.withdrawalPlan.stems[i];
            uint256[] memory amounts = vars.withdrawalPlan.amounts[i];

            uint256 tokenAmountToConvert = 0;

            // Calculate total amount to convert for this token
            for (uint256 j = 0; j < amounts.length; j++) {
                tokenAmountToConvert += amounts[j];
            }

            if (tokenAmountToConvert == 0) continue;

            // Validate slippage to detect price manipulation
            {
                IERC20[] memory wellTokens = IWell(token).tokens();
                address nonBeanToken = address(wellTokens[0]) == beanToken
                    ? address(wellTokens[1])
                    : address(wellTokens[0]);
                require(
                    tractorHelpers.priceManipulation().isValidSlippage(
                        IWell(token),
                        IERC20(nonBeanToken),
                        slippageRatio
                    ),
                    "Price manipulation detected"
                );
            }

            // Calculate minimum output amount based on slippage
            uint256 expectedOutput = IWell(token).getRemoveLiquidityOneTokenOut(
                tokenAmountToConvert,
                IERC20(beanToken)
            );

            // Create convert data for WELL_LP_TO_BEANS conversion
            // Format: ConvertKind, amountIn, expectedOutput, token address
            bytes memory convertData = abi.encode(
                LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
                tokenAmountToConvert,
                expectedOutput,
                token
            );

            // Call Beanstalk's convert function to convert LP tokens to Beans
            (, , uint256 amountConverted, , ) = beanstalk.convertWithStalkSlippage(
                convertData,
                stems,
                amounts,
                maxGrownStalkPerPdvPenalty
            );

            // Add to total amount converted
            totalAmountConverted += amountConverted;
        }

        return totalAmountConverted;
    }
}

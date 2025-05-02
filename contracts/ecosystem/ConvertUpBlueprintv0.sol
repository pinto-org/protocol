// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {TractorHelpers} from "./TractorHelpers.sol";
import {PerFunctionPausable} from "./PerFunctionPausable.sol";
import {BeanstalkPrice} from "./price/BeanstalkPrice.sol";
import {LibTractorHelpers} from "contracts/libraries/Silo/LibTractorHelpers.sol";

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
     * @param tokenFrom The address of the token being converted from
     * @param amountConverted The amount that was converted
     */
    event ConvertUpOrderComplete(
        bytes32 indexed blueprintHash,
        address indexed publisher,
        address tokenFrom,
        uint256 amountConverted
    );

    /**
     * @notice Struct to hold local variables for the convert up operation to avoid stack too deep errors
     * @param orderHash Hash of the current blueprint order
     * @param account Address of the user's account (current Tractor user), not operator
     * @param tipAddress Address to send tip to
     * @param tokenFrom Address of token being converted from (determined from sourceTokenIndices)
     * @param currentTimestamp Current block timestamp
     * @param lastExecution Last time this blueprint was executed
     * @param pdvLeftToConvert Amount of PDV left to convert from the total
     * @param currentPdvToConvert Amount of PDV to convert in this execution
     * @param currentPrice Current price for the conversion
     * @param amountConverted Amount actually converted
     * @param withdrawalPlan Plan for withdrawing tokens for conversion
     */
    struct ConvertUpLocalVars {
        bytes32 orderHash;
        address account;
        address tipAddress;
        address tokenFrom;
        uint256 currentTimestamp;
        uint256 lastExecution;
        uint256 pdvLeftToConvert;
        uint256 currentPdvToConvert;
        uint256 currentPrice;
        uint256 amountConverted;
        LibTractorHelpers.WithdrawalPlan withdrawalPlan;
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
     * @param grownStalkPerBdvBonusThreshold Threshold for considering a deposit to have a good stalk-to-BDV ratio
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
        uint256 grownStalkPerBdvBonusThreshold;
        // Price constraints
        uint256 maxPriceToConvertUp;
        uint256 minPriceToConvertUp;
        // Penalty tolerance
        uint256 maxGrownStalkPerPdvPenalty;
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
    mapping(bytes32 => OrderInfo) private orderInfo;

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers,
        address _beanstalkPrice
    ) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
        tractorHelpers = TractorHelpers(_tractorHelpers);
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
        vars.currentTimestamp = block.timestamp;

        // Get order hash
        vars.orderHash = beanstalk.getCurrentBlueprintHash();

        // Get user account
        vars.account = beanstalk.tractorUser();

        // Get the last execution timestamp
        vars.lastExecution = getLastExecutedTimestamp(vars.orderHash);

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

        // Determine source token from sourceTokenIndices (first token for now as placeholder)
        // In the future, we'll need logic to select the best source token
        // vars.tokenFrom = getTokenFromSourceIndices(params.convertUpParams.sourceTokenIndices);

        // For now, use the first source token index as a placeholder
        // This would be replaced with proper logic to select the token
        vars.tokenFrom = address(0); // Placeholder - to be implemented

        // Get current PDV left to convert
        vars.pdvLeftToConvert = getPdvLeftToConvert(vars.orderHash);

        // If pdvLeftToConvert is 0, initialize it with the total amount
        if (vars.pdvLeftToConvert == 0) {
            vars.pdvLeftToConvert = params.convertUpParams.totalConvertPdv;
        }

        // Determine current convert amount based on constraints
        vars.currentPdvToConvert = determineConvertAmount(
            vars.pdvLeftToConvert,
            params.convertUpParams.minConvertPdvPerExecution,
            params.convertUpParams.maxConvertPdvPerExecution
        );

        // Get current price and check price constraints using BeanstalkPrice
        // vars.currentPrice = beanstalkPrice.price();

        // Check if price is within acceptable range
        // validatePriceRange(vars.currentPrice, params.convertUpParams.minPriceToConvertUp, params.convertUpParams.maxPriceToConvertUp);

        // Check convert bonus capacity
        // validateConvertBonusCapacity(vars.tokenFrom, beanstalk.getBeanToken(), params.convertUpParams.minConvertBonusCapacity);

        // Get withdrawal plan
        // vars.withdrawalPlan = getWithdrawalPlan(
        //     vars.account,
        //     params.convertUpParams.sourceTokenIndices,
        //     vars.currentPdvToConvert,
        //     params.convertUpParams.maxGrownStalkPerBdv,
        //     params.convertUpParams.grownStalkPerBdvBonusThreshold
        // );

        // Execute the conversion
        // vars.amountConverted = executeConvertUp(
        //     vars,
        //     params.convertUpParams.slippageRatio,
        //     params.convertUpParams.maxGrownStalkPerPdvPenalty
        // );

        // Apply slippage ratio if needed
        uint256 slippageRatio = params.convertUpParams.slippageRatio;
        if (slippageRatio == 0) {
            slippageRatio = DEFAULT_SLIPPAGE_RATIO;
        }

        // For now, this is a placeholder implementation until we add the actual conversion logic
        vars.amountConverted = 0;

        // Update the state
        // If all PDV has been converted, set to max to indicate completion
        if (vars.pdvLeftToConvert - vars.currentPdvToConvert == 0) {
            updatePdvLeftToConvert(vars.orderHash, type(uint256).max);
            // Order is complete, emit a completion event
        } else {
            // Update the PDV left to convert
            updatePdvLeftToConvert(
                vars.orderHash,
                vars.pdvLeftToConvert - vars.currentPdvToConvert
            );
        }

        // Tip the operator
        tractorHelpers.tip(
            beanstalk.getBeanToken(),
            vars.account,
            vars.tipAddress,
            params.opParams.operatorTipAmount,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );

        // Update the last executed timestamp for this blueprint
        updateLastExecutedTimestamp(vars.orderHash, vars.currentTimestamp);

        // Emit completion event
        emit ConvertUpOrderComplete(
            vars.orderHash,
            vars.account,
            vars.tokenFrom,
            vars.amountConverted
        );
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
}

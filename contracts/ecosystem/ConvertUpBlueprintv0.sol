// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {TractorHelpers} from "./TractorHelpers.sol";
import {PerFunctionPausable} from "./PerFunctionPausable.sol";
import {BeanstalkPrice} from "./price/BeanstalkPrice.sol";
import {LibTractorHelpers} from "contracts/libraries/Silo/LibTractorHelpers.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {ReservesType} from "./price/WellPrice.sol";
import {Call, IWell, IERC20} from "../interfaces/basin/IWell.sol";
import {console} from "forge-std/console.sol";
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

    // Constants for specifying token selection strategies
    uint8 internal constant LOWEST_PRICE_STRATEGY = type(uint8).max;
    uint8 internal constant LOWEST_SEED_STRATEGY = type(uint8).max - 1;

    /**
     * @notice Struct to hold local variables for the convert up operation to avoid stack too deep errors
     * @param orderHash Hash of the current blueprint order
     * @param account Address of the user's account (current Tractor user), not operator
     * @param tipAddress Address to send tip to
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
    mapping(bytes32 => OrderInfo) public orderInfo;

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

        // log min and max convert pdv per execution
        console.log("minConvertPdvPerExecution", params.convertUpParams.minConvertPdvPerExecution);
        console.log("maxConvertPdvPerExecution", params.convertUpParams.maxConvertPdvPerExecution);

        // Get order hash
        vars.orderHash = beanstalk.getCurrentBlueprintHash();

        // Get user account
        vars.account = beanstalk.tractorUser();

        console.log("convertUpBlueprintv0 vars.account: %s", vars.account);

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

        // Get current PDV left to convert
        vars.pdvLeftToConvert = getPdvLeftToConvert(vars.orderHash);

        console.log("stored pdvLeftToConvert", vars.pdvLeftToConvert);

        // If pdvLeftToConvert is max, revert, as the order has already been completed
        if (vars.pdvLeftToConvert == type(uint256).max) {
            revert("Order has already been completed");
        }

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

        console.log("pdv to convert this time: %s", vars.currentPdvToConvert);
        // log pdv left to convert
        console.log("pdv left to convert: %s", vars.pdvLeftToConvert);

        // Get current price and check price constraints using BeanstalkPrice
        BeanstalkPrice.Prices memory p = beanstalkPrice.price(ReservesType.INSTANTANEOUS_RESERVES);
        vars.currentPrice = p.price;

        // Check if price is within acceptable range
        validatePriceRange(
            vars.currentPrice,
            params.convertUpParams.minPriceToConvertUp,
            params.convertUpParams.maxPriceToConvertUp
        );

        // First withdraw Beans from which to tip Operator (using a newer deposit burns less stalk)
        if (params.opParams.operatorTipAmount > 0) {
            LibTractorHelpers.WithdrawalPlan memory emptyPlan;
            tractorHelpers.withdrawBeansFromSources(
                vars.account,
                params.convertUpParams.sourceTokenIndices,
                uint256(params.opParams.operatorTipAmount),
                params.convertUpParams.maxGrownStalkPerBdv,
                params.convertUpParams.slippageRatio,
                LibTransfer.To.INTERNAL,
                emptyPlan
            );
        }

        // Process source token indices based on strategy
        uint8[] memory sourceTokenIndices = processSourceTokenIndices(
            params.convertUpParams.sourceTokenIndices
        );

        console.log("sourceTokenIndices: ");
        for (uint256 i = 0; i < sourceTokenIndices.length; i++) {
            // log i
            console.log("----- i: %s", i);
            console.log(sourceTokenIndices[i]);
        }

        // Get withdrawal plan for the tokens to convert
        vars.withdrawalPlan = tractorHelpers.getWithdrawalPlan(
            vars.account,
            sourceTokenIndices,
            vars.currentPdvToConvert,
            params.convertUpParams.maxGrownStalkPerBdv
        );

        // Apply slippage ratio if needed
        uint256 slippageRatio = params.convertUpParams.slippageRatio;
        if (slippageRatio == 0) {
            slippageRatio = DEFAULT_SLIPPAGE_RATIO;
        }

        // Execute the conversion using Beanstalk's convert function
        vars.amountConverted = executeConvertUp(
            vars,
            slippageRatio,
            params.convertUpParams.maxGrownStalkPerPdvPenalty
        );

        // log pdv left to convert and current pdv to convert
        // console.log("pdvLeftToConvert", vars.pdvLeftToConvert);
        // console.log("currentPdvToConvert", vars.currentPdvToConvert);

        // Update the state
        // If all PDV has been converted, set to max to indicate completion
        if (vars.pdvLeftToConvert - vars.currentPdvToConvert == 0) {
            updatePdvLeftToConvert(vars.orderHash, type(uint256).max);
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
        // console.log("Updating pdvLeftToConvert", amount);
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
        uint256 slippageRatio,
        uint256 maxGrownStalkPerPdvPenalty
    ) internal returns (uint256 totalAmountConverted) {
        address beanToken = beanstalk.getBeanToken();
        totalAmountConverted = 0;

        console.log(
            "executeConvertUp, vars.withdrawalPlan.sourceTokens.length: %s",
            vars.withdrawalPlan.sourceTokens.length
        );

        // Process each token type in the withdrawal plan
        for (uint256 i = 0; i < vars.withdrawalPlan.sourceTokens.length; i++) {
            address token = vars.withdrawalPlan.sourceTokens[i];
            console.log("executeConvertUp, converting token:", token);
            if (token == address(0) || token == beanToken) continue; // Skip empty tokens or Bean tokens

            // Get stems and amounts from the withdrawal plan for this token
            if (vars.withdrawalPlan.stems[i].length == 0) continue;

            // Use the stems and amounts for this token directly from the withdrawal plan
            int96[] memory stems = vars.withdrawalPlan.stems[i];
            uint256[] memory amounts = vars.withdrawalPlan.amounts[i];

            // Log stems and amounts
            console.log("stems: ");
            for (uint256 j = 0; j < stems.length; j++) {
                console.logInt(stems[j]);
            }
            console.log("amounts: ");
            for (uint256 j = 0; j < amounts.length; j++) {
                console.log(amounts[j]);
            }

            uint256 tokenAmountToConvert = 0;

            // Calculate total amount to convert for this token
            for (uint256 j = 0; j < amounts.length; j++) {
                tokenAmountToConvert += amounts[j];
            }

            if (tokenAmountToConvert == 0) continue;

            // Calculate minimum output amount based on slippage
            uint256 expectedOutput = IWell(token).getRemoveLiquidityOneTokenOut(
                tokenAmountToConvert,
                IERC20(beanToken)
            );

            console.log("expectedOutput: ", expectedOutput);
            console.log("tokenAmountToConvert: ", tokenAmountToConvert);

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

    /**
     * @notice Processes source token indices
     * @param originalSourceTokenIndices Indices of source tokens to use for conversion
     * @return sourceTokenIndices Processed source token indices with any strategies resolved
     */
    function processSourceTokenIndices(
        uint8[] memory originalSourceTokenIndices
    ) internal view returns (uint8[] memory sourceTokenIndices) {
        // Create a memory copy of source token indices that we can modify
        sourceTokenIndices = new uint8[](originalSourceTokenIndices.length);
        for (uint256 i = 0; i < originalSourceTokenIndices.length; i++) {
            sourceTokenIndices[i] = originalSourceTokenIndices[i];
        }

        // If strategy is LOWEST_PRICE_STRATEGY or LOWEST_SEED_STRATEGY, use the appropriate strategy with Bean excluded
        if (
            sourceTokenIndices.length > 0 &&
            (sourceTokenIndices[0] == LOWEST_PRICE_STRATEGY ||
                sourceTokenIndices[0] == LOWEST_SEED_STRATEGY)
        ) {
            // If lowest price strategy, get the tokens in ascending price order with Bean excluded
            if (sourceTokenIndices[0] == LOWEST_PRICE_STRATEGY) {
                (sourceTokenIndices, ) = tractorHelpers.getTokensAscendingPrice(true);
            }

            // If lowest seed strategy, get the tokens in ascending seed order with Bean excluded
            if (sourceTokenIndices[0] == LOWEST_SEED_STRATEGY) {
                (sourceTokenIndices, ) = tractorHelpers.getTokensAscendingSeeds(true);
            }
        }

        return sourceTokenIndices;
    }
}

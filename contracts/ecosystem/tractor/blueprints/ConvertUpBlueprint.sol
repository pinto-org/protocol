// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {TractorHelpers} from "../utils/TractorHelpers.sol";
import {PerFunctionPausable} from "../utils/PerFunctionPausable.sol";
import {BeanstalkPrice} from "../../price/BeanstalkPrice.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {ReservesType} from "../../price/WellPrice.sol";
import {Call, IWell, IERC20} from "contracts/interfaces/basin/IWell.sol";
import {SiloHelpers} from "../utils/SiloHelpers.sol";

/**
 * @title ConvertUpBlueprint
 * @author FordPinto, Frijo
 * @notice Contract for converting up with Tractor, with a number of conditions
 * @dev This contract always converts up to Bean token, which is obtained from beanstalk.getBeanToken()
 */
contract ConvertUpBlueprint is PerFunctionPausable {
    /**
     * @notice Event emitted when a convert up order is complete, or no longer executable due to remaining bdv being less than min convert per season
     * @param blueprintHash The hash of the blueprint
     * @param publisher The address of the publisher
     * @param totalAmountConverted The total amount of beans that was converted across all executions
     * @param beansUnfulfilled The amount of beans that were not converted
     */
    event ConvertUpOrderComplete(
        bytes32 indexed blueprintHash,
        address indexed publisher,
        uint256 totalAmountConverted,
        uint256 beansUnfulfilled
    );

    /**
     * @notice Struct to hold local variables for the convert up operation to avoid stack too deep errors
     * @param orderHash Hash of the current blueprint order
     * @param account Address of the user's account (current Tractor user), not operator
     * @param tipAddress Address to send tip to
     * @param beansLeftToConvert Amount of beans left to convert from the total
     * @param beansToConvertThisExecution Amount of beans to convert in this execution
     * @param amountBeansConverted Amount of beans actually converted
     * @param withdrawalPlan Plan for withdrawing tokens for conversion
     */
    struct ConvertUpLocalVars {
        bytes32 orderHash;
        address account;
        address tipAddress;
        uint256 beansLeftToConvert;
        uint256 beansToConvertThisExecution;
        uint256 amountBeansConverted;
        uint256 bonusStalkPerBdv;
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
     * @param totalBeanAmountToConvert Total beans to convert
     * @param minBeansConvertPerExecution Minimum beans to convert per execution
     * @param maxBeansConvertPerExecution Maximum beans to convert per execution
     * @param capAmountToBonusCapacity a flag that indicates whether an execution should convert up to the bonus capacity, or up to `maxBeansConvertPerExecution`.
     * @param minTimeBetweenConverts Minimum time (in seconds) between convert executions
     * @param minConvertBonusCapacity Minimum capacity required for convert bonus
     * @param maxGrownStalkPerBdv Maximum grown stalk per bdv to withdraw from deposits
     * @param grownStalkPerBdvBonusBid The minimum bid for grown stalk per bdv bonus to execute a convert.
     * @param maxPriceToConvertUp Maximum price at which to convert up (for MEV resistance)
     * @param minPriceToConvertUp Minimum price at which to convert up (for range targeting)
     * @param seedDifference The difference between the bean seeds and the well seeds needed to convert up. A value of `0` denotes N/A (do not check difference)
     * @param maxGrownStalkPerBdvPenalty Maximum grown stalk per BDV penalty to accept
     * @param slippageRatio Slippage tolerance ratio for the conversion
     * @param lowStalkDeposits How low stalk deposits are processed. See LibSiloHelpers.Mode for more details.
     */
    struct ConvertUpParams {
        // Source tokens to withdraw from
        uint8[] sourceTokenIndices;
        // Conversion amounts
        uint256 totalBeanAmountToConvert;
        uint256 minBeansConvertPerExecution;
        uint256 maxBeansConvertPerExecution;
        bool capAmountToBonusCapacity;
        // Time constraints
        uint256 minTimeBetweenConverts;
        // Bonus/capacity parameters
        uint256 minConvertBonusCapacity;
        uint256 maxGrownStalkPerBdv;
        uint256 grownStalkPerBdvBonusBid;
        // Price / seed constraints
        uint256 maxPriceToConvertUp;
        uint256 minPriceToConvertUp;
        int256 seedDifference;
        // Penalty tolerance
        int256 maxGrownStalkPerBdvPenalty;
        // Execution parameters
        uint256 slippageRatio;
        LibSiloHelpers.Mode lowStalkDeposits; // USE (0): use low stalk deposit. OMIT (1): omit low stalk deposits. USE_LAST (2): use low stalk deposits last.
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
     * @param beansLeftToConvert Amount of Beans left to convert from the total
     */
    struct OrderInfo {
        uint256 lastExecutedTimestamp;
        uint256 beansLeftToConvert;
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
     * @notice Converts tokens up to `Amount` using specified parameters
     * @param params The ConvertUpBlueprintStruct containing all parameters for the convert up operation
     */
    function convertUpBlueprint(
        ConvertUpBlueprintStruct calldata params
    ) external payable whenFunctionNotPaused {
        // Initialize local variables
        ConvertUpLocalVars memory vars;

        // Get user account
        vars.account = beanstalk.tractorUser();

        // Get order hash and validate convert parameters
        vars.orderHash = beanstalk.getCurrentBlueprintHash();
        require(
            vars.orderHash != bytes32(0),
            "No active blueprint, function must run from Tractor"
        );

        (vars.bonusStalkPerBdv, ) = validateParams(params.convertUpParams, vars.orderHash);

        // Check if the executing operator (msg.sender) is whitelisted
        require(
            tractorHelpers.isOperatorWhitelisted(params.opParams.whitelistedOperators),
            "Operator not whitelisted"
        );

        // Create memory copy of opParams to make it writable
        OperatorParams memory opParams = params.opParams;

        // If tip address is not set, set it to the operator
        if (opParams.tipAddress == address(0)) {
            opParams.tipAddress = beanstalk.operator();
        }

        // Get current BDV left to convert
        vars.beansLeftToConvert = getBeansLeftToConvert(vars.orderHash);

        // If beansLeftToConvert is max, revert, as the order has already been completed
        if (vars.beansLeftToConvert == type(uint256).max) {
            revert("Order has already been completed");
        } else if (vars.beansLeftToConvert == 0) {
            // If beansLeftToConvert is 0, initialize it with the total amount
            vars.beansLeftToConvert = params.convertUpParams.totalBeanAmountToConvert;
        }

        // Determine current convert amount based on constraints
        vars.beansToConvertThisExecution = determineConvertAmount(
            vars.beansLeftToConvert,
            params.convertUpParams.minBeansConvertPerExecution,
            params.convertUpParams.maxBeansConvertPerExecution
        );

        // Apply slippage ratio if needed
        uint256 slippageRatio = params.convertUpParams.slippageRatio;
        if (slippageRatio == 0) {
            slippageRatio = DEFAULT_SLIPPAGE_RATIO;
        }

        // First withdraw Beans from which to tip Operator (using a newer deposit burns less stalk)
        LibSiloHelpers.WithdrawalPlan memory emptyPlan;
        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams();
        filterParams.maxGrownStalkPerBdv = params.convertUpParams.maxGrownStalkPerBdv;
        if (opParams.operatorTipAmount > 0) {
            siloHelpers.withdrawBeansFromSources(
                vars.account,
                params.convertUpParams.sourceTokenIndices,
                uint256(opParams.operatorTipAmount),
                filterParams,
                slippageRatio,
                LibTransfer.To.INTERNAL,
                emptyPlan
            );
        }

        // for conversions, beans and germinating deposits are excluded
        filterParams.excludeBean = true;
        filterParams.excludeGerminatingDeposits = true;
        // a bonus for a deposit is capped at their current stalk grown.
        // the contract will attempt to withdraw deposits that have this amount,
        // then the remaining deposits.
        filterParams.lowGrownStalkPerBdv = vars.bonusStalkPerBdv;
        filterParams.lowStalkDeposits = params.convertUpParams.lowStalkDeposits;
        filterParams.seedDifference = params.convertUpParams.seedDifference;

        // Get withdrawal plan for the tokens to convert
        vars.withdrawalPlan = siloHelpers.getWithdrawalPlanExcludingPlan(
            vars.account,
            params.convertUpParams.sourceTokenIndices,
            vars.beansToConvertThisExecution,
            filterParams,
            emptyPlan
        );

        address beanToken = beanstalk.getBeanToken();

        // Execute the conversion using Beanstalk's convert function
        vars.amountBeansConverted = executeConvertUp(
            vars,
            beanToken,
            slippageRatio,
            params.convertUpParams.maxGrownStalkPerBdvPenalty
        );

        require(vars.amountBeansConverted > 0, "No amount converted");

        // Update the state
        // If all BDV has been converted, set to max to indicate completion
        uint256 beansRemaining = vars.beansLeftToConvert - vars.amountBeansConverted;
        if (beansRemaining == 0) beansRemaining = type(uint256).max;

        // Update the BDV left to convert
        updateBeansLeftToConvert(vars.orderHash, beansRemaining);

        // Tip the operator
        tractorHelpers.tip(
            beanToken,
            vars.account,
            opParams.tipAddress,
            opParams.operatorTipAmount,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );

        // Update the last executed timestamp for this blueprint
        updateLastExecutedTimestamp(vars.orderHash, block.timestamp);

        // Emit completion event
        if (beansRemaining == type(uint256).max) {
            emit ConvertUpOrderComplete(
                vars.orderHash,
                vars.account,
                params.convertUpParams.totalBeanAmountToConvert,
                0
            );
        } else if (beansRemaining < params.convertUpParams.minBeansConvertPerExecution) {
            // If the min convert per season is greater than the amount unfulfilled, this order will
            // never be able to execute again, so emit event as such
            emit ConvertUpOrderComplete(
                vars.orderHash,
                vars.account,
                params.convertUpParams.totalBeanAmountToConvert - beansRemaining,
                beansRemaining
            );
        }
    }

    /**
     * @notice Validates the convert up parameters, and returns the beanstalk state
     * @param params The ConvertUpBlueprintStruct containing all parameters for the convert up operation
     * @return bonusStalkPerBdv The bonus stalk per bdv
     * @return beansLeftToConvert The total amount requested to be converted (considers stored value)
     * @return beansToConvertThisExecution the total amount to convert, adjusted based on constraints
     * @return withdrawalPlan The withdrawal plan to check if enough beans are available
     */
    function validateParamsAndReturnBeanstalkState(
        ConvertUpBlueprintStruct calldata params,
        bytes32 orderHash,
        address blueprintPublisher
    )
        public
        view
        returns (
            uint256 bonusStalkPerBdv,
            uint256 beansLeftToConvert,
            uint256 beansToConvertThisExecution,
            LibSiloHelpers.WithdrawalPlan memory withdrawalPlan
        )
    {
        uint256 remainingCapacity;
        (bonusStalkPerBdv, remainingCapacity) = validateParams(params.convertUpParams, orderHash);
        beansLeftToConvert = getBeansLeftToConvert(orderHash);
        // If the beansLeftToConvert is 0, then it has not been initialized yet,
        // thus, the amount left to convert is the total amount to convert
        if (beansLeftToConvert == 0) {
            beansLeftToConvert = params.convertUpParams.totalBeanAmountToConvert;
        }

        // if the capAmountToBonusCapacity flag is set,
        // then the max beans convert per execution is the remaining capacity
        // unless the remaining capacity is less than the max beans convert per execution
        uint256 maxBeansConvertPerExecution = params.convertUpParams.maxBeansConvertPerExecution;
        if (params.convertUpParams.capAmountToBonusCapacity) {
            if (remainingCapacity < maxBeansConvertPerExecution) {
                maxBeansConvertPerExecution = remainingCapacity;
            }
        }

        beansToConvertThisExecution = determineConvertAmount(
            beansLeftToConvert,
            params.convertUpParams.minBeansConvertPerExecution,
            maxBeansConvertPerExecution
        );

        // Apply slippage ratio if needed
        uint256 slippageRatio = params.convertUpParams.slippageRatio;
        if (slippageRatio == 0) {
            slippageRatio = DEFAULT_SLIPPAGE_RATIO;
        }

        LibSiloHelpers.WithdrawalPlan memory emptyPlan;
        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams();
        filterParams.maxGrownStalkPerBdv = params.convertUpParams.maxGrownStalkPerBdv;

        // for conversions, beans and germinating deposits are excluded
        filterParams.excludeBean = true;
        filterParams.excludeGerminatingDeposits = true;
        // a bonus for a deposit is capped at their current stalk grown.
        // the contract will attempt to withdraw deposits that have this amount,
        // then the remaining deposits.
        filterParams.lowGrownStalkPerBdv = bonusStalkPerBdv;
        filterParams.lowStalkDeposits = params.convertUpParams.lowStalkDeposits;
        filterParams.seedDifference = params.convertUpParams.seedDifference;

        // verify that a user has enough beans to execute this convert.
        uint256 tipAmount = params.opParams.operatorTipAmount > 0
            ? uint256(params.opParams.operatorTipAmount)
            : 0;
        withdrawalPlan = siloHelpers.getWithdrawalPlanExcludingPlan(
            blueprintPublisher,
            params.convertUpParams.sourceTokenIndices,
            beansToConvertThisExecution + tipAmount,
            filterParams,
            emptyPlan
        );
    }

    /**
     * @notice Validates multiple convert up parameters and returns an array of valid order hashes
     * @param paramsArray Array of ConvertUpBlueprintStruct containing all parameters for the convert up operations
     * @param orderHashes Array of order hashes to validate
     * @param blueprintPublishers Array of blueprint publishers to validate
     * @return validOrderHashes Array of valid order hashes that passed validation
     */
    function validateParamsAndReturnBeanstalkStateArray(
        ConvertUpBlueprintStruct[] calldata paramsArray,
        bytes32[] calldata orderHashes,
        address[] calldata blueprintPublishers
    ) external view returns (bytes32[] memory validOrderHashes) {
        uint256 length = paramsArray.length;
        validOrderHashes = new bytes32[](length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < length; i++) {
            try
                this.validateParamsAndReturnBeanstalkState(
                    paramsArray[i],
                    orderHashes[i],
                    blueprintPublishers[i]
                )
            returns (
                uint256, // bonusStalkPerBdv
                uint256, // beansLeftToConvert
                uint256, // beansToConvertThisExecution
                LibSiloHelpers.WithdrawalPlan memory // withdrawalPlan
            ) {
                validOrderHashes[validCount] = orderHashes[i];
                validCount++;
            } catch {
                // Skip invalid parameters
                continue;
            }
        }
    }

    /**
     * @notice Gets the BDV left to convert for an order
     * @param orderHash The hash of the order
     * @return The BDV left to convert
     */
    function getBeansLeftToConvert(bytes32 orderHash) public view returns (uint256) {
        return orderInfo[orderHash].beansLeftToConvert;
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
     * @notice Updates the BDV left to convert
     * @param orderHash The hash of the order
     * @param amount The new BDV left to convert
     */
    function updateBeansLeftToConvert(bytes32 orderHash, uint256 amount) internal {
        orderInfo[orderHash].beansLeftToConvert = amount;
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
     * @notice Executes the convert up operation using Beanstalk's convert function
     * @param vars Local variables containing the necessary data for execution
     * @param slippageRatio Slippage tolerance ratio for the conversion
     * @param maxGrownStalkPerBdvPenalty Maximum grown stalk per BDV penalty to accept
     * @return totalAmountConverted The total amount converted across all token types
     */
    function executeConvertUp(
        ConvertUpLocalVars memory vars,
        address beanToken,
        uint256 slippageRatio,
        int256 maxGrownStalkPerBdvPenalty
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
            require(
                siloHelpers.isValidSlippage(token, slippageRatio),
                "Price manipulation detected"
            );

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
                maxGrownStalkPerBdvPenalty
            );

            // Add to total amount converted
            totalAmountConverted += amountConverted;
        }

        return totalAmountConverted;
    }

    /**
     * @notice Validates the parameters for the convert up operation
     * @param cup The ConvertUpParams containing all parameters for the convert up operation
     * @param orderHash The hash of the order
     * @return bonusStalkPerBdv The bonus stalk per bdv
     */
    function validateParams(
        ConvertUpParams memory cup,
        bytes32 orderHash
    ) internal view returns (uint256 bonusStalkPerBdv, uint256 remainingCapacity) {
        // Source tokens validation
        require(cup.sourceTokenIndices.length > 0, "Must provide at least one source token");

        // Amount validations
        require(cup.totalBeanAmountToConvert > 0, "Total convert BDV must be > 0");
        require(
            cup.minBeansConvertPerExecution <= cup.maxBeansConvertPerExecution,
            "Min convert BDV per execution > max"
        );
        require(cup.minBeansConvertPerExecution > 0, "Min convert BDV per execution must be > 0");

        // Price validations
        require(
            cup.minPriceToConvertUp <= cup.maxPriceToConvertUp,
            "Min price to convert up > max price"
        );
        uint256 currentPrice = beanstalkPrice.price(ReservesType.INSTANTANEOUS_RESERVES).price;
        require(
            currentPrice >= cup.minPriceToConvertUp,
            "Current price below minimum price for convert up"
        );
        require(
            currentPrice <= cup.maxPriceToConvertUp,
            "Current price above maximum price for convert up"
        );

        // Time constraint validation
        require(cup.minTimeBetweenConverts > 0, "Min time between converts must be > 0");

        // Time between conversions check
        uint256 lastExecution = getLastExecutedTimestamp(orderHash);
        if (lastExecution > 0) {
            require(
                block.timestamp >= lastExecution + cup.minTimeBetweenConverts,
                "Too soon after last execution"
            );
        }

        // Check convert bonus conditions
        if (cup.grownStalkPerBdvBonusBid > 0 || cup.minConvertBonusCapacity > 0) {
            // Get current bonus amount and remaining capacity
            (bonusStalkPerBdv, remainingCapacity) = beanstalk
                .getConvertStalkPerBdvBonusAndRemainingCapacity();

            // Check if bonus amount meets threshold
            if (cup.grownStalkPerBdvBonusBid > 0) {
                require(
                    bonusStalkPerBdv >= cup.grownStalkPerBdvBonusBid,
                    "Convert bonus amount below threshold"
                );
            }

            // Check if remaining capacity meets minimum
            if (cup.minConvertBonusCapacity > 0) {
                require(
                    remainingCapacity >= cup.minConvertBonusCapacity,
                    "Convert bonus capacity below minimum"
                );
            }
        }
    }

    /**
     * @notice Determines the amount to convert based on constraints
     * @param beansLeftToConvert Total BDV left to convert
     * @param minBeansConvertPerExecution Minimum BDV per execution
     * @param maxBeansConvertPerExecution Maximum BDV per execution
     * @return The amount to convert in this execution
     */
    function determineConvertAmount(
        uint256 beansLeftToConvert,
        uint256 minBeansConvertPerExecution,
        uint256 maxBeansConvertPerExecution
    ) internal pure returns (uint256) {
        // If beansLeftToConvert is less than minBeansConvertPerExecution, we can't convert
        require(
            beansLeftToConvert >= minBeansConvertPerExecution,
            "Not enough BDV left to Convert"
        );

        // If beansLeftToConvert is less than maxBeansConvertPerExecution, use beansLeftToConvert
        if (beansLeftToConvert < maxBeansConvertPerExecution) {
            return beansLeftToConvert;
        }

        // Otherwise, use maxBeansConvertPerExecution
        return maxBeansConvertPerExecution;
    }

    function version() public pure returns (string memory) {
        return "1.0";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {SiloHelpers} from "./SiloHelpers.sol";
import {PerFunctionPausable} from "./PerFunctionPausable.sol";
import {IOperatorWhitelist} from "./OperatorWhitelist.sol";

/**
 * @title SowBlueprintv0
 * @author FordPinto
 * @notice Contract for sowing with Tractor, with a number of conditions
 */
contract SowBlueprintv0 is PerFunctionPausable {
    /**
     * @notice Struct to hold local variables for the sow operation to avoid stack too deep errors
     * @param currentTemp Current temperature from Beanstalk
     * @param availableSoil Amount of soil available for sowing at time of execution
     * @param beanToken Address of the Bean token
     * @param counterValue Current value of the order counter
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
        uint256 counterValue;
        uint256 totalBeansNeeded;
        bytes32 orderHash;
        uint256 beansWithdrawn;
        address tipAddress;
        address account;
        uint256 totalAmountToSow;
        SiloHelpers.WithdrawalPlan withdrawalPlan;
    }

    /**
     * @notice Main struct for sow blueprint
     * @param sowParams Parameters related to sowing
     * @param opParams Parameters related to operators
     */
    struct SowBlueprintStruct {
        SowParams sowParams;
        OperatorParams opParams;
    }

    /**
     * @notice Struct to hold sow parameters
     * @param sourceTokenIndices Indices of source tokens to withdraw from
     * @param sowAmounts Amounts for sowing
     * @param minTemp Minimum temperature required for sowing
     * @param maxPodlineLength Maximum podline length allowed
     * @param maxGrownStalkPerBdv Maximum grown stalk per BDV allowed
     * @param runBlocksAfterSunrise Number of blocks to wait after sunrise before executing
     */
    struct SowParams {
        uint8[] sourceTokenIndices;
        SowAmounts sowAmounts;
        uint256 minTemp;
        uint256 maxPodlineLength;
        uint256 maxGrownStalkPerBdv;
        uint256 runBlocksAfterSunrise;
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
    SiloHelpers immutable siloHelpers;

    /**
     * @notice Struct to hold order info
     * @param pintoSownCounter Counter for the number of maximum pinto that can be sown from this blueprint. Used for orders that sow over multiple seasons.
     * @param lastExecutedSeason Last season a blueprint was executed
     */
    struct OrderInfo {
        uint256 pintoSownCounter;
        uint32 lastExecutedSeason;
    }

    // Combined state mapping for order info
    mapping(bytes32 => OrderInfo) private orderInfo;

    constructor(address _beanstalk, address _siloHelpers) PerFunctionPausable(msg.sender) {
        beanstalk = IBeanstalk(_beanstalk);
        siloHelpers = SiloHelpers(_siloHelpers);
    }

    /**
     * @notice Sows beans using specified source tokens in order of preference
     * @param params The SowBlueprintStruct containing all parameters for the sow operation
     */
    function sowBlueprintv0(
        SowBlueprintStruct calldata params
    ) external payable whenFunctionNotPaused {
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
            vars.counterValue,
            vars.totalAmountToSow,
            vars.totalBeansNeeded,
            vars.withdrawalPlan
        ) = validateParamsAndReturnBeanstalkState(params, vars.orderHash, vars.account);

        // Check if the executing operator (msg.sender) is whitelisted
        require(
            _isOperatorWhitelisted(params.opParams.whitelistedOperators),
            "Operator not whitelisted"
        );

        // If the counter value is 0, then it has not been initialized yet, initialize it
        if (vars.counterValue == 0) {
            updatePintoLeftToSowCounter(
                vars.orderHash,
                params.sowParams.sowAmounts.totalAmountToSow
            );
        }

        // Get tip address. If tip address is not set, set it to the operator
        if (params.opParams.tipAddress == address(0)) {
            vars.tipAddress = beanstalk.operator();
        } else {
            vars.tipAddress = params.opParams.tipAddress;
        }

        // Execute the withdrawal plan
        vars.beansWithdrawn = siloHelpers.withdrawBeansFromSources(
            vars.account,
            params.sowParams.sourceTokenIndices,
            vars.totalBeansNeeded,
            params.sowParams.maxGrownStalkPerBdv,
            LibTransfer.To.INTERNAL
        );

        // Update the counter
        // If this will use up all remaining amount, set to max to indicate completion
        if (vars.counterValue - vars.totalAmountToSow == 0) {
            updatePintoLeftToSowCounter(vars.orderHash, type(uint256).max);
        } else {
            updatePintoLeftToSowCounter(vars.orderHash, vars.counterValue - vars.totalAmountToSow);
        }

        // Tip the operator
        siloHelpers.tip(
            vars.beanToken,
            vars.account,
            vars.tipAddress,
            params.opParams.operatorTipAmount
        );

        // Sow the withdrawn beans
        beanstalk.sowWithMin(
            vars.totalAmountToSow,
            params.sowParams.minTemp,
            params.sowParams.sowAmounts.minAmountToSowPerSeason,
            LibTransfer.From.INTERNAL
        );

        // Update the last executed season for this blueprint
        updateLastExecutedSeason(vars.orderHash, vars.currentSeason);
    }

    /**
     * @notice Validates the initial parameters for the sow operation
     * @param params The SowBlueprintStruct containing all parameters for the sow operation
     */
    function _validateParams(SowBlueprintStruct calldata params) internal view {
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
     * @notice validates the blueprint parameters.
     */
    function _validateBlueprintAndCounterValue(
        bytes32 orderHash
    ) internal view returns (uint256 counterValue) {
        require(orderHash != bytes32(0), "No active blueprint, function must run from Tractor");
        require(
            getLastExecutedSeason(orderHash) < beanstalk.time().current,
            "Blueprint already executed this season"
        );

        // Verify there's still sow amount available with the counter
        counterValue = getPintosLeftToSow(orderHash);

        // If counterValue is max uint256, then the sow order has already been fully used, so revert
        require(counterValue != type(uint256).max, "Sow order already fulfilled");
    }

    /**
     * @notice Gets the last season a blueprint was executed
     * @param blueprintHash The hash of the blueprint
     * @return The last season the blueprint was executed, or 0 if never executed
     */
    function getLastExecutedSeason(bytes32 blueprintHash) public view returns (uint32) {
        return orderInfo[blueprintHash].lastExecutedSeason;
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
     * @notice Updates the counter value for a given order hash
     * @param orderHash The hash of the order
     * @param amount The amount to update by
     */
    function updatePintoLeftToSowCounter(bytes32 orderHash, uint256 amount) internal {
        orderInfo[orderHash].pintoSownCounter = amount;
    }

    /**
     * @notice Updates the last executed season for a given order hash
     * @param orderHash The hash of the order
     * @param season The season number
     */
    function updateLastExecutedSeason(bytes32 orderHash, uint32 season) internal {
        orderInfo[orderHash].lastExecutedSeason = season;
    }

    /**
     * @notice Checks if the current operator is whitelisted
     * @param whitelistedOperators Array of whitelisted operator addresses
     * @return isWhitelisted Whether the current operator is whitelisted
     */
    function _isOperatorWhitelisted(
        address[] calldata whitelistedOperators
    ) internal view returns (bool) {
        // If there are no whitelisted operators, pass in, accept any operator
        if (whitelistedOperators.length == 0) {
            return true;
        }

        address currentOperator = beanstalk.operator();
        for (uint256 i = 0; i < whitelistedOperators.length; i++) {
            address checkAddress = whitelistedOperators[i];
            if (checkAddress == currentOperator) {
                return true;
            } else {
                // Skip if address is a precompiled contract (address < 0x20)
                if (uint160(checkAddress) <= 0x20) continue;

                // Check if the address is a contract before attempting staticcall
                uint256 size;
                assembly {
                    size := extcodesize(checkAddress)
                }

                if (size > 0) {
                    try
                        IOperatorWhitelist(checkAddress).checkOperatorWhitelist(currentOperator)
                    returns (bool success) {
                        if (success) {
                            return true;
                        }
                    } catch {
                        // If the call fails, continue to the next address
                        continue;
                    }
                }
            }
        }
        return false;
    }

    /**
     * @notice Determines the total amount to sow based on various constraints
     * @param totalAmountToSow Total amount intended to sow
     * @param counterValue Current value of the order counter
     * @param maxAmountToSowPerSeason Maximum amount that can be sown per season
     * @param availableSoil Amount of soil available for sowing
     * @return The determined total amount to sow
     */
    function determineTotalAmountToSow(
        uint256 totalAmountToSow,
        uint256 counterValue,
        uint256 maxAmountToSowPerSeason,
        uint256 availableSoil
    ) internal pure returns (uint256) {
        // If the counter value is less than the totalAmountToSow, use the counter value remaining
        if (counterValue < totalAmountToSow) {
            totalAmountToSow = counterValue;
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

    /**
     * @notice helper function to get various parameters from beanstalk.
     */
    function getAndValidateBeanstalkState(
        SowParams calldata params
    ) internal view returns (uint256 availableSoil, address beanToken, uint32 currentSeason) {
        availableSoil = beanstalk.totalSoil();
        beanToken = beanstalk.getBeanToken();
        currentSeason = beanstalk.time().current;

        // Check temperature and soil requirements
        require(beanstalk.temperature() >= params.minTemp, "Temperature too low");
        require(
            availableSoil >= params.sowAmounts.minAmountToSowPerSeason,
            "Not enough soil for min sow"
        );
    }

    /**
     * @notice Validates the sow parameters, and returns the beanstalk state
     * @param params The SowBlueprintStruct containing all parameters for the sow operation
     * @return availableSoil The amount of soil available for sowing
     * @return beanToken The address of the bean token
     * @return currentSeason The current season
     * @return counterValue The current counter value for this order
     * @return totalAmountToSow The total amount to sow, adjusted based on constraints
     * @return totalBeansNeeded The total beans needed (sow amount + tip)
     * @return plan The withdrawal plan to check if enough beans are available
     */
    function validateParamsAndReturnBeanstalkState(
        SowBlueprintStruct calldata params,
        bytes32 orderHash,
        address blueprintPublisher
    )
        public
        view
        returns (
            uint256 availableSoil,
            address beanToken,
            uint32 currentSeason,
            uint256 counterValue,
            uint256 totalAmountToSow,
            uint256 totalBeansNeeded,
            SiloHelpers.WithdrawalPlan memory plan
        )
    {
        (availableSoil, beanToken, currentSeason) = getAndValidateBeanstalkState(params.sowParams);

        _validateParams(params);
        counterValue = _validateBlueprintAndCounterValue(orderHash);
        counterValue == 0 ? params.sowParams.sowAmounts.totalAmountToSow : counterValue;

        // Determine the total amount to sow based on various constraints
        totalAmountToSow = determineTotalAmountToSow(
            params.sowParams.sowAmounts.totalAmountToSow,
            counterValue,
            params.sowParams.sowAmounts.maxAmountToSowPerSeason,
            availableSoil
        );

        // Calculate total beans needed (sow amount + tip if positive)
        totalBeansNeeded = totalAmountToSow;
        if (params.opParams.operatorTipAmount > 0) {
            totalBeansNeeded += uint256(params.opParams.operatorTipAmount);
        }

        // Check if enough beans are available using getWithdrawalPlan
        plan = siloHelpers.getWithdrawalPlan(
            blueprintPublisher,
            params.sowParams.sourceTokenIndices,
            totalBeansNeeded,
            params.sowParams.maxGrownStalkPerBdv
        );

        // Verify enough beans are available
        require(plan.totalAvailableBeans >= totalBeansNeeded, "Not enough beans available");
    }

    /**
     * @notice Validates multiple sow parameters and returns an array of valid order hashes
     * @param paramsArray Array of SowBlueprintStruct containing all parameters for the sow operations
     * @param orderHashes Array of order hashes to validate
     * @return validOrderHashes Array of valid order hashes that passed validation
     */
    function validateParamsAndReturnBeanstalkStateArray(
        SowBlueprintStruct[] calldata paramsArray,
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
                uint256, // availableSoil
                address, // beanToken
                uint32, // currentSeason
                uint256, // counterValue
                uint256, // totalAmountToSow
                uint256, // totalBeansNeeded
                SiloHelpers.WithdrawalPlan memory // plan
            ) {
                validOrderHashes[validCount] = orderHashes[i];
                validCount++;
            } catch {
                // Skip invalid parameters
                continue;
            }
        }

        // Resize array to only include valid hashes
        assembly {
            mstore(validOrderHashes, validCount)
        }
    }
}

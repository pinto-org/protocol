// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {TractorHelpers} from "contracts/ecosystem/tractor/utils/TractorHelpers.sol";
import {PerFunctionPausable} from "contracts/ecosystem/tractor/utils/PerFunctionPausable.sol";

/**
 * @title BlueprintBase
 * @notice Abstract base contract for Tractor blueprints providing shared state and validation functions
 */
abstract contract BlueprintBase is PerFunctionPausable {
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

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers
    ) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
        beanToken = beanstalk.getBeanToken();
        tractorHelpers = TractorHelpers(_tractorHelpers);
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
}

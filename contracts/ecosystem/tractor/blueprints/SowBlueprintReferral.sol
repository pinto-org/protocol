// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SowBlueprintBase, LibSiloHelpers} from "./SowBlueprintBase.sol";

/**
 * @title SowBlueprintReferral
 * @author FordPinto, Frijo
 * @notice Contract for sowing with Tractor, with a number of conditions. Has a referral address.
 */
contract SowBlueprintReferral is SowBlueprintBase {
    /**
     * @notice Struct for sow referral blueprint
     * @param params Base sow parameters
     * @param referral Referral address for the sow operation
     */
    struct SowReferralBlueprintStruct {
        SowBlueprintStruct params;
        address referral;
    }

    constructor(
        address _beanstalk,
        address _owner,
        address _tractorHelpers,
        address _siloHelpers
    ) SowBlueprintBase(_beanstalk, _owner, _tractorHelpers, _siloHelpers) {}

    /**
     * @notice Sows beans using specified source tokens in order of preference with referral
     * @param params The SowReferralBlueprintStruct containing all parameters for the sow operation including referral
     */
    function sowBlueprintReferral(
        SowReferralBlueprintStruct calldata params
    ) external payable whenFunctionNotPaused {
        _validateOperatorParams(params.params.opParams);
        _sowBlueprintInternal(params.params, params.referral);
    }

    /**
     * @notice Validates parameters and returns beanstalk state
     * @dev Public wrapper for external callers
     */
    function validateParamsAndReturnBeanstalkState(
        SowReferralBlueprintStruct calldata params,
        bytes32 orderHash,
        address blueprintPublisher
    )
        public
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
        return _validateParamsAndReturnBeanstalkState(params.params, orderHash, blueprintPublisher);
    }

    /**
     * @notice Validates multiple sow parameters and returns an array of valid order hashes
     * @param paramsArray Array of SowReferralBlueprintStruct containing all parameters for the sow operations
     * @param orderHashes Array of order hashes to validate
     * @param blueprintPublishers Array of blueprint publishers to validate
     * @return validOrderHashes Array of valid order hashes that passed validation
     */
    function validateParamsAndReturnBeanstalkStateArray(
        SowReferralBlueprintStruct[] calldata paramsArray,
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
                uint256, // pintoLeftToSow
                uint256, // totalAmountToSow
                uint256, // totalBeansNeeded
                LibSiloHelpers.WithdrawalPlan memory // plan
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

    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}

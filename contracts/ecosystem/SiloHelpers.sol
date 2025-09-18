// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {PerFunctionPausable} from "./PerFunctionPausable.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";

/**
 * @title SiloHelpers
 * @author FordPinto
 * @notice Helper contract for Silo operations related to sorting deposits and managing their order
 */
contract SiloHelpers is PerFunctionPausable {
    IBeanstalk immutable beanstalk;

    constructor(address _beanstalk, address _owner) PerFunctionPausable(_owner) {
        beanstalk = IBeanstalk(_beanstalk);
    }

    /**
     * @notice Sorts all deposits for every token the user has and updates the sorted lists in Beanstalk
     * @param account The address of the account that owns the deposits
     * @return updatedTokens Array of tokens that had their sorted deposit lists updated
     */
    function sortDeposits(
        address account
    ) external whenFunctionNotPaused returns (address[] memory updatedTokens) {
        // Get all tokens the user has deposited
        address[] memory depositedTokens = getUserDepositedTokens(account);
        if (depositedTokens.length == 0) return new address[](0);

        updatedTokens = new address[](depositedTokens.length);

        // Process each token
        for (uint256 i = 0; i < depositedTokens.length; i++) {
            address token = depositedTokens[i];

            // Get deposit IDs for this token
            uint256[] memory depositIds = beanstalk.getTokenDepositIdsForAccount(account, token);
            if (depositIds.length == 0) continue;

            // Sort deposits by stem in ascending order (required for updateSortedDepositIds)
            for (uint256 j = 0; j < depositIds.length - 1; j++) {
                for (uint256 k = 0; k < depositIds.length - j - 1; k++) {
                    (, int96 stem1) = getAddressAndStem(depositIds[k]);
                    (, int96 stem2) = getAddressAndStem(depositIds[k + 1]);

                    if (stem1 > stem2) {
                        // Swap deposit IDs
                        uint256 temp = depositIds[k];
                        depositIds[k] = depositIds[k + 1];
                        depositIds[k + 1] = temp;
                    }
                }
            }

            // Update the sorted list in Beanstalk
            beanstalk.updateSortedDepositIds(account, token, depositIds);
            updatedTokens[i] = token;
        }

        return updatedTokens;
    }

    /**
     * @notice Gets the list of tokens that a user has deposited in the silo
     * @param account The address of the user
     * @return depositedTokens Array of token addresses that the user has deposited
     */
    function getUserDepositedTokens(
        address account
    ) public view returns (address[] memory depositedTokens) {
        address[] memory allWhitelistedTokens = getWhitelistStatusAddresses();

        // First, get the mow status for all tokens to check which ones have deposits
        IBeanstalk.MowStatus[] memory mowStatuses = beanstalk.getMowStatus(
            account,
            allWhitelistedTokens
        );

        // Count how many tokens have deposits (bdv > 0)
        uint256 depositedTokenCount = 0;
        for (uint256 i = 0; i < mowStatuses.length; i++) {
            if (mowStatuses[i].bdv > 0) {
                depositedTokenCount++;
            }
        }

        // Create array of the right size for deposited tokens
        depositedTokens = new address[](depositedTokenCount);

        // Fill the array with tokens that have deposits
        uint256 index = 0;
        for (uint256 i = 0; i < mowStatuses.length; i++) {
            if (mowStatuses[i].bdv > 0) {
                depositedTokens[index] = allWhitelistedTokens[i];
                index++;
            }
        }

        return depositedTokens;
    }

    /**
     * @notice Helper function to get the address and stem from a deposit ID
     * @dev This is a copy of LibBytes.unpackAddressAndStem for gas purposes
     * @param depositId The ID of the deposit to get the address and stem for
     * @return token The address of the token
     * @return stem The stem value of the deposit
     */
    function getAddressAndStem(uint256 depositId) public pure returns (address token, int96 stem) {
        return (address(uint160(depositId >> 96)), int96(int256(depositId)));
    }

    /**
     * @notice Returns the addresses of all whitelisted tokens, even those that have been Dewhitelisted
     * @return addresses The addresses of all whitelisted tokens
     */
    function getWhitelistStatusAddresses() public view returns (address[] memory) {
        IBeanstalk.WhitelistStatus[] memory whitelistStatuses = beanstalk.getWhitelistStatuses();
        address[] memory addresses = new address[](whitelistStatuses.length);
        for (uint256 i = 0; i < whitelistStatuses.length; i++) {
            addresses[i] = whitelistStatuses[i].token;
        }
        return addresses;
    }
}

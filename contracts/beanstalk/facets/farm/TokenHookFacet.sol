/*
 * SPDX-License-Identifier: MIT
 */

pragma solidity ^0.8.20;

import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {LibTokenHook} from "contracts/libraries/Token/LibTokenHook.sol";
import {Implementation} from "contracts/beanstalk/storage/System.sol";

/**
 * @title TokenHookFacet
 * @notice Manages the pre-transfer hook whitelist for internal token transfers.
 * @dev State changing functions are commented out for security reasons.
 */
contract TokenHookFacet is Invariable, ReentrancyGuard {
    // /**
    //  * @notice Registers a pre-transfer hook for a specific token.
    //  * @param token The token address to register the hook for.
    //  * @param hook The Implementation token hook struct. (See System.{Implementation})
    //  */
    // function whitelistTokenHook(
    //     address token,
    //     TokenHook memory hook
    // ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
    //     LibDiamond.enforceIsOwnerOrContract();
    //     LibTokenHook.addTokenHook(token, hook);
    // }

    // /**
    //  * @notice Removes a pre-transfer hook for a specific token.
    //  * @param token The token address to remove the hook for.
    //  */
    // function dewhitelistTokenHook(
    //     address token
    // ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
    //     LibDiamond.enforceIsOwnerOrContract();
    //     LibTokenHook.removeTokenHook(token);
    // }

    // /**
    //  * @notice Updates a pre-transfer hook for a specific token.
    //  * @param token The token address to update the hook for.
    //  * @param hook The new Implementation token hook struct. (See System.{Implementation})
    //  */
    // function updateTokenHook(
    //     address token,
    //     Implementation memory hook
    // ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
    //     LibDiamond.enforceIsOwnerOrContract();
    //     LibTokenHook.updateTokenHook(token, hook);
    // }

    /**
     * @notice Checks if token has a pre-transfer hook associated with it.
     * @param token The token address to check.
     */
    function hasTokenHook(address token) external view returns (bool) {
        return LibTokenHook.hasTokenHook(token);
    }

    /**
     * @notice Gets the pre-transfer hook struct for a specific token.
     * @param token The token address.
     * @return Implementation token hook struct for the token. (See System.{Implementation})
     */
    function getTokenHook(address token) external view returns (Implementation memory) {
        return LibTokenHook.getTokenHook(token);
    }
}

/*
 * SPDX-License-Identifier: MIT
 */

pragma solidity ^0.8.20;

import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {LibTokenHook} from "contracts/libraries/Token/LibTokenHook.sol";
import {TokenHook} from "contracts/beanstalk/storage/System.sol";

/**
 * @title TokenHookFacet
 * @notice Manages the pre-transfer hook whitelist for internal token transfers.
 */
contract TokenHookFacet is Invariable, ReentrancyGuard {

    /**
     * @notice Registers a pre-transfer hook for a specific token.
     * @param token The token address to register the hook for.
     * @param hook The TokenHook struct. (See System.{TokenHook})
     */
    function whitelistTokenHook(
        address token,
        TokenHook memory hook
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        LibDiamond.enforceIsOwnerOrContract();
        LibTokenHook.whitelistHook(token, hook);
    }

    /**
     * @notice Removes a pre-transfer hook for a specific token.
     * @param token The token address to remove the hook for.
     */
    function dewhitelistTokenHook(
        address token
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        LibDiamond.enforceIsOwnerOrContract();
        LibTokenHook.removeWhitelistedHook(token);
    }

    /**
     * @notice Updates a pre-transfer hook for a specific token.
     * @param token The token address to update the hook for.
     * @param hook The new TokenHook struct.
     */
    function updateTokenHook(
        address token,
        TokenHook memory hook
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        LibDiamond.enforceIsOwnerOrContract();
        LibTokenHook.updateWhitelistedHook(token, hook);
    }

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
     * @return TokenHook struct for the token. (See System.{TokenHook})
     */
    function getTokenHook(address token) external view returns (TokenHook memory) {
        return LibTokenHook.getTokenHook(token);
    }
}
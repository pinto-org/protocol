/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenHook} from "contracts/beanstalk/storage/System.sol";
import {LibAppStorage} from "../LibAppStorage.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";

/**
 * @title LibTokenHook
 * @notice Handles token hook management and execution for internal transfers.
 */
library LibTokenHook {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when a pre-transfer token hook is registered.
     */
    event AddedTokenHook(address indexed token, address indexed target, bytes4 selector);

    /**
     * @notice Emitted when a whitelisted pre-transfer token hook is removed.
     */
    event RemovedTokenHook(address indexed token);

    /**
     * @notice Emitted when a whitelisted pre-transfer token hook is called.
     */
    event TokenHookCalled(address indexed token, address indexed target, bytes4 selector);

    /**
     * @notice Registers and verifies a token hook for a specific token.
     * @param token The token address to register the hook for.
     * @param hook The TokenHook struct containing target, selector, and data.
     */
    function addTokenHook(address token, TokenHook memory hook) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(token != address(0), "LibTokenHook: Invalid token address");
        require(hook.target != address(0), "LibTokenHook: Invalid target address");
        require(hook.selector != bytes4(0), "LibTokenHook: Invalid selector");

        // Verify the hook implementation is callable
        verifyPreTransferHook(token, hook);

        s.sys.tokenHook[token] = hook;

        emit AddedTokenHook(token, hook.target, hook.selector);
    }

    /**
     * @notice Removes a pre-transfer hook for a specific token.
     * @param token The token address to remove the hook for.
     */
    function removeTokenHook(address token) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(s.sys.tokenHook[token].target != address(0), "LibTokenHook: Hook not whitelisted");

        delete s.sys.tokenHook[token];

        emit RemovedTokenHook(token);
    }

    /**
     * @notice Updates a pre-transfer hook for a specific token.
     * @param token The token address to update the hook for.
     * @param hook The new TokenHook struct.
     */
    function updateTokenHook(address token, TokenHook memory hook) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(s.sys.tokenHook[token].target != address(0), "LibTokenHook: Hook not whitelisted");

        // remove old hook
        removeTokenHook(token);
        // add new hook
        addTokenHook(token, hook);
    }

    /**
     * @notice Checks if a token has a registered pre-transfer hook.
     * @param token The token address to check.
     * @return True if the token has a hook, false otherwise.
     */
    function hasTokenHook(address token) internal view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.sys.tokenHook[token].target != address(0);
    }

    /**
     * @notice Gets the pre-transfer hook for a specific token.
     * @param token The token address.
     * @return The TokenHook struct for the token.
     */
    function getTokenHook(address token) internal view returns (TokenHook memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.sys.tokenHook[token];
    }

    /// Call ///

    /**
     * @notice Calls the pre-transfer hook for a token before an internal transfer.
     * - We revert in case of failure since internal transfers are non-critical protocol operations.
     * - We assume that the hook returns no data
     * @param token The token being transferred.
     * @param from The sender address.
     * @param to The recipient address.
     * @param amount The transfer amount.
     */
    function checkForAndCallPreTransferHook(address token, address from, address to, uint256 amount) internal {
        TokenHook memory hook = getTokenHook(token);
        if (hook.target == address(0)) return;

        // call the hook. If it reverts, revert the entire transfer.
        (bool success, ) = hook.target.call(
            encodeHookCall(hook.encodeType, hook.selector, from, to, amount)
        );
        require(success, "LibTokenHook: Hook execution failed");

        emit TokenHookCalled(token, hook.target, hook.selector);
    }

    /**
     * @notice Verifies that a pre-transfer hook function is valid and callable.
     * @dev Unlike view functions like the bdv selector, we can't staticcall pre-transfer hooks
     * since they might potentially modify state or emit events so we perform a regular call with
     * default parameters and assume the hook does not revert for 0 values.
     * @dev Care must be taken to only whitelist trusted hooks since a hook is an arbitrary function call.
     * @param token The token address.
     * @param hook The TokenHook to verify.
     */
    function verifyPreTransferHook(address token, TokenHook memory hook) internal {
        // verify the target is a contract, regular calls don't revert for non-contracts
        require(isContract(hook.target), "LibTokenHook: Target is not a contract");
        // verify the target is callable
        (bool success, ) = hook.target.call(
            encodeHookCall(hook.encodeType, hook.selector, address(0), address(0), uint256(0))
        );
        require(success, "LibTokenHook: Invalid TokenHook implementation");
    }

    /**
     * @notice Encodes a hook call for a token before an internal transfer.
     * @param encodeType The encode type byte, indicating the parameters to be passed to the hook.
     * @param selector The selector to call on the target contract.
     * @param from The sender address from the transfer.
     * @param to The recipient address from the transfer.
     * @param amount The transfer amount.
     */
    function encodeHookCall(
        bytes1 encodeType,
        bytes4 selector,
        address from,
        address to,
        uint256 amount
    ) internal pure returns (bytes memory) {
        if (encodeType == 0x00) {
            return abi.encodeWithSelector(selector, from, to, amount);
            // any other encode types should be added here
        } else {
            revert("LibTokenHook: Invalid encodeType");
        }
    }

    /**
     * @notice Checks if an account is a contract.
     */
    function isContract(address account) internal view returns (bool) {
        uint size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}

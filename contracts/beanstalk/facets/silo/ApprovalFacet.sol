/**
 * SPDX-License-Identifier: MIT
 */
pragma solidity ^0.8.20;

import {TokenSilo} from "./abstract/TokenSilo.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import "contracts/C.sol";
import "contracts/libraries/Silo/LibSilo.sol";
import "contracts/libraries/Silo/LibTokenSilo.sol";
import "contracts/libraries/Math/LibRedundantMath32.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";

/**
 * @title Handles Approval related functions for the Silo
 *
 */
contract ApprovalFacet is Invariable, ReentrancyGuard {
    using LibRedundantMath256 for uint256;

    event ApprovalForAll(address indexed account, address indexed operator, bool approved);

    //////////////////////// APPROVE ////////////////////////

    /**
     * @notice Approve `spender` to Transfer Deposits for user.
     *
     * Sets the allowance to `amount`.
     *
     * @dev Gas optimization: We neglect to check whether `token` is actually
     * whitelisted. If a token is not whitelisted, it cannot be Deposited,
     * therefore it cannot be Transferred.
     */
    function approveDeposit(
        address spender,
        address token,
        uint256 amount
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        require(spender != address(0), "approve from the zero address");
        require(token != address(0), "approve to the zero address");
        LibSilo._approveDeposit(LibTractor._user(), spender, token, amount);
    }

    /**
     * @notice Increase the Transfer allowance for `spender`.
     *
     * @dev Gas optimization: We neglect to check whether `token` is actually
     * whitelisted. If a token is not whitelisted, it cannot be Deposited,
     * therefore it cannot be Transferred.
     */
    function increaseDepositAllowance(
        address spender,
        address token,
        uint256 addedValue
    ) public virtual fundsSafu noNetFlow noSupplyChange nonReentrant returns (bool) {
        LibSilo._approveDeposit(
            LibTractor._user(),
            spender,
            token,
            depositAllowance(LibTractor._user(), spender, token).add(addedValue)
        );
        return true;
    }

    /**
     * @notice Decrease the Transfer allowance for `spender`.
     *
     * @dev Gas optimization: We neglect to check whether `token` is actually
     * whitelisted. If a token is not whitelisted, it cannot be Deposited,
     * therefore it cannot be Transferred.
     */
    function decreaseDepositAllowance(
        address spender,
        address token,
        uint256 subtractedValue
    ) public virtual fundsSafu noNetFlow noSupplyChange nonReentrant returns (bool) {
        uint256 currentAllowance = depositAllowance(LibTractor._user(), spender, token);
        require(currentAllowance >= subtractedValue, "Silo: decreased allowance below zero");
        LibSilo._approveDeposit(
            LibTractor._user(),
            spender,
            token,
            currentAllowance.sub(subtractedValue)
        );
        return true;
    }

    /**
     * @notice Returns how much of a `token` Deposit that `spender` can transfer on behalf of `owner`.
     * @param owner The account that has given `spender` approval to transfer Deposits.
     * @param spender The address (contract or EOA) that is allowed to transfer Deposits on behalf of `owner`.
     * @param token Whitelisted ERC20 token.
     */
    function depositAllowance(
        address owner,
        address spender,
        address token
    ) public view virtual returns (uint256) {
        return s.accts[owner].depositAllowances[spender][token];
    }

    // ERC1155 Approvals
    function setApprovalForAll(
        address spender,
        bool approved
    ) external fundsSafu noNetFlow noSupplyChange nonReentrant {
        s.accts[LibTractor._user()].isApprovedForAll[spender] = approved;
        emit ApprovalForAll(LibTractor._user(), spender, approved);
    }

    function isApprovedForAll(address _owner, address _operator) external view returns (bool) {
        return s.accts[_owner].isApprovedForAll[_operator];
    }
}

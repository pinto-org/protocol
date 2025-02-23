/**
 * SPDX-License-Identifier: MIT
 */
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {C} from "contracts/C.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {LibWeth} from "contracts/libraries/Token/LibWeth.sol";
import {LibEth} from "contracts/libraries/Token/LibEth.sol";
import {LibTokenApprove} from "contracts/libraries/Token/LibTokenApprove.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibBalance} from "contracts/libraries/Token/LibBalance.sol";
import {IERC1155Receiver} from "contracts/interfaces/IERC1155Receiver.sol";

/**
 * @title TokenFacet handles transfers of assets
 */
contract TokenFacet is Invariable, IERC1155Receiver, ReentrancyGuard {
    struct Balance {
        uint256 internalBalance;
        uint256 externalBalance;
        uint256 totalBalance;
    }

    using SafeERC20 for IERC20;
    using LibRedundantMath256 for uint256;

    //////////////////////// Transfer ////////////////////////

    /**
     * @notice transfers a token from user to `recipient`.
     * @dev enables transfers between internal and external balances.
     *
     * @param token The token to transfer.
     * @param recipient The recipient of the transfer.
     * @param amount The amount to transfer.
     * @param fromMode The source of token from the sender. See {LibTransfer.From}.
     * @param toMode The destination of token to the recipient. See {LibTransfer.To}.
     */
    function transferToken(
        IERC20 token,
        address recipient,
        uint256 amount,
        LibTransfer.From fromMode,
        LibTransfer.To toMode
    ) external payable fundsSafu noSupplyChange oneOutFlow(address(token)) nonReentrant {
        LibTransfer.transferToken(token, LibTractor._user(), recipient, amount, fromMode, toMode);
    }

    /**
     * @notice transfers a token from `sender` to an `recipient` from Internal balance.
     * @dev differs from transferToken as sender != user.
     */
    function transferInternalTokenFrom(
        IERC20 token,
        address sender,
        address recipient,
        uint256 amount,
        LibTransfer.To toMode
    ) external payable fundsSafu noSupplyChange oneOutFlow(address(token)) nonReentrant {
        LibTransfer.transferToken(
            token,
            sender,
            recipient,
            amount,
            LibTransfer.From.INTERNAL,
            toMode
        );

        if (sender != LibTractor._user()) {
            LibTokenApprove.spendAllowance(sender, LibTractor._user(), token, amount);
        }
    }

    //////////////////////// Transfer ////////////////////////

    /**
     * @notice approves a token for a spender.
     * @dev this approves a token for both internal and external balances.
     */
    function approveToken(
        address spender,
        IERC20 token,
        uint256 amount
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        LibTokenApprove.approve(LibTractor._user(), spender, token, amount);
    }

    /**
     * @notice increases approval for a token for a spender.
     */
    function increaseTokenAllowance(
        address spender,
        IERC20 token,
        uint256 addedValue
    ) public virtual fundsSafu noNetFlow noSupplyChange nonReentrant returns (bool) {
        LibTokenApprove.approve(
            LibTractor._user(),
            spender,
            token,
            LibTokenApprove.allowance(LibTractor._user(), spender, token).add(addedValue)
        );
        return true;
    }

    /**
     * @notice decreases approval for a token for a spender.
     */
    function decreaseTokenAllowance(
        address spender,
        IERC20 token,
        uint256 subtractedValue
    ) public virtual fundsSafu noNetFlow noSupplyChange nonReentrant returns (bool) {
        uint256 currentAllowance = LibTokenApprove.allowance(LibTractor._user(), spender, token);
        require(currentAllowance >= subtractedValue, "Silo: decreased allowance below zero");
        LibTokenApprove.approve(
            LibTractor._user(),
            spender,
            token,
            currentAllowance.sub(subtractedValue)
        );
        return true;
    }

    /**
     * @notice returns the allowance for a token for a spender.
     */
    function tokenAllowance(
        address account,
        address spender,
        IERC20 token
    ) public view virtual returns (uint256) {
        return LibTokenApprove.allowance(account, spender, token);
    }

    //////////////////////// ERC1155Receiver ////////////////////////

    /**
     * @notice ERC1155Receiver function that allows the silo to receive ERC1155 tokens.
     *
     * @dev as ERC1155 deposits are not accepted yet,
     * this function will revert.
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert("Silo: ERC1155 deposits are not accepted yet.");
    }

    /**
     * @notice onERC1155BatchReceived function that allows the silo to receive ERC1155 tokens.
     *
     * @dev as ERC1155 deposits are not accepted yet,
     * this function will revert.
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert("Silo: ERC1155 deposits are not accepted yet.");
    }

    //////////////////////// WETH ////////////////////////

    /**
     * @notice wraps ETH into WETH.
     */
    function wrapEth(
        uint256 amount,
        LibTransfer.To mode
    ) external payable nonReentrant fundsSafu noOutFlow noSupplyChange {
        LibWeth.wrap(amount, mode);
        LibEth.refundEth();
    }

    /**
     * @notice unwraps WETH into ETH.
     */
    function unwrapEth(
        uint256 amount,
        LibTransfer.From mode
    ) external payable nonReentrant fundsSafu oneOutFlow(LibWeth.WETH) noSupplyChange {
        LibWeth.unwrap(amount, mode);
    }

    //////////////////////// GETTERS ////////////////////////

    /**
     * @notice returns the internal balance of a token for an account.
     */
    function getInternalBalance(
        address account,
        IERC20 token
    ) public view returns (uint256 balance) {
        balance = LibBalance.getInternalBalance(account, token);
    }

    /**
     * @notice returns the internal balances of tokens for an account.
     */
    function getInternalBalances(
        address account,
        IERC20[] memory tokens
    ) external view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = getInternalBalance(account, tokens[i]);
        }
    }

    // External

    /**
     * @notice returns the external balance of a token for an account.
     */
    function getExternalBalance(
        address account,
        IERC20 token
    ) public view returns (uint256 balance) {
        balance = token.balanceOf(account);
    }

    /**
     * @notice returns the external balances of tokens for an account.
     */
    function getExternalBalances(
        address account,
        IERC20[] memory tokens
    ) external view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = getExternalBalance(account, tokens[i]);
        }
    }

    /**
     * @notice returns the total balance (internal and external)
     * of a token
     */
    function getBalance(address account, IERC20 token) public view returns (uint256 balance) {
        balance = LibBalance.getBalance(account, token);
    }

    /**
     * @notice returns the total balances (internal and external)
     * of a token for an account.
     */
    function getBalances(
        address account,
        IERC20[] memory tokens
    ) external view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = getBalance(account, tokens[i]);
        }
    }

    /**
     * @notice returns the total balance (internal and external)
     * of a token, in a balance struct (internal, external, total).
     */
    function getAllBalance(address account, IERC20 token) public view returns (Balance memory b) {
        b.internalBalance = getInternalBalance(account, token);
        b.externalBalance = getExternalBalance(account, token);
        b.totalBalance = b.internalBalance.add(b.externalBalance);
    }

    /**
     * @notice returns the total balance (internal and external)
     * of a token, in a balance struct (internal, external, total).
     */
    function getAllBalances(
        address account,
        IERC20[] memory tokens
    ) external view returns (Balance[] memory balances) {
        balances = new Balance[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = getAllBalance(account, tokens[i]);
        }
    }
}

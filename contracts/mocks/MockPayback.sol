// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPayback} from "contracts/interfaces/IPayback.sol";


contract MockPayback is IPayback {
    uint256 constant INITIAL_REMAINING = 1_000_000_000e6;

    address bean;
    uint256 remainingBean;
    uint256 amountPaid;

    constructor(address beanAddress) {
        bean = beanAddress;
        remainingBean = INITIAL_REMAINING;
    }

    function siloRemaining() external view returns (uint256) {
        uint256 balance = IERC20(bean).balanceOf(address(this));
        // Silo gets paid off first.
        uint256 remaining = (remainingBean * 1) / 4;
        if (remaining > balance) {
            return remaining - balance;
        }
        return 0;
    }

    function barnRemaining() external view returns (uint256) {
        uint256 balance = IERC20(bean).balanceOf(address(this));
        if (remainingBean > balance) {
            return remainingBean - balance;
        }
        return 0;
    }
}

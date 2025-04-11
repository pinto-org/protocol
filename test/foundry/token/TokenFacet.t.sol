// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, IMockFBeanstalk, C} from "test/foundry/utils/TestHelper.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenFacetTest is TestHelper {
    // test accounts
    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // init users
        farmers.push(users[1]);
        farmers.push(users[2]);
        maxApproveBeanstalk(farmers);

        // Mint some tokens to test with
        mintTokensToUser(farmers[0], BEAN, 10000e6); // 10,000 Beans
    }

    function test_sendTokenToInternalBalance() public {
        uint256 transferAmount = 1000e6; // 1000 Beans

        // Initial balances
        uint256 initialSenderBalance = IERC20(BEAN).balanceOf(farmers[0]);
        uint256 initialReceiverBalance = IERC20(BEAN).balanceOf(farmers[1]);

        // Approve Beanstalk to spend tokens
        vm.prank(farmers[0]);
        IERC20(BEAN).approve(address(bs), transferAmount);

        // Transfer tokens from external balance to internal balance
        vm.prank(farmers[0]);
        bs.sendTokenToInternalBalance(BEAN, farmers[1], transferAmount);

        // Check balances after transfer
        assertEq(
            IERC20(BEAN).balanceOf(farmers[0]),
            initialSenderBalance - transferAmount,
            "Sender balance incorrect"
        );

        // For internal transfers, the token balance doesn't change
        assertEq(
            IERC20(BEAN).balanceOf(farmers[1]),
            initialReceiverBalance,
            "Receiver external balance should not change for internal transfer"
        );

        // Check internal balance
        assertEq(
            bs.getInternalBalance(farmers[1], BEAN),
            transferAmount,
            "Receiver internal balance incorrect"
        );
    }

    function test_sendTokenToInternalBalance_revertInsufficientAllowance() public {
        // First zero-out the approval
        vm.prank(farmers[0]);
        IERC20(BEAN).approve(address(bs), 0);

        uint256 transferAmount = 1000e6; // 1000 Beans

        // Try to transfer without approval
        vm.prank(farmers[0]);
        vm.expectRevert(); // Matching the full revert message is complex because it contains the address
        bs.sendTokenToInternalBalance(BEAN, farmers[1], transferAmount);
    }

    function test_sendTokenToInternalBalance_revertInsufficientBalance() public {
        uint256 transferAmount = 20000e6; // 20,000 Beans (more than minted)

        // Approve spending
        vm.prank(farmers[0]);
        IERC20(BEAN).approve(address(bs), transferAmount);

        // Try to transfer more than balance
        vm.prank(farmers[0]);
        vm.expectRevert();
        bs.sendTokenToInternalBalance(BEAN, farmers[1], transferAmount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, IMockFBeanstalk, C} from "test/foundry/utils/TestHelper.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockTokenWithHook} from "contracts/mocks/MockTokenWithHook.sol";

contract TokenHookTest is TestHelper {
    // Mock token hooks
    event InternalTransferTokenHookCalled(address indexed from, address indexed to, uint256 amount);
    event RegularTransferTokenHookCalled(address indexed from, address indexed to, uint256 amount);

    // Protocol events
    event TokenHookCalled(address indexed token, address indexed target, bytes encodedCall);
    event AddedTokenHook(address indexed token, IMockFBeanstalk.Implementation hook);

    // test accounts
    address[] farmers;

    // test tokens
    address randomMockTokenAddress = makeAddr("randomMockToken");

    MockTokenWithHook mockToken;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // deploy mock token with hook, set protocol to beanstalk
        // the hooks only emit events:
        // - RegularTransferTokenHookCalled for regular transfers
        // - InternalTransferTokenHookCalled for internal transfers.
        mockToken = new MockTokenWithHook("MockHookToken", "MOCKHT", address(bs));

        // Whitelist token hook for internal transfers, expect whitelist event to be emitted
        vm.startPrank(deployer);
        vm.expectEmit(true, true, true, true);
        IMockFBeanstalk.Implementation memory hook = IMockFBeanstalk.Implementation({
            target: address(mockToken),
            selector: mockToken.internalTransferUpdate.selector,
            encodeType: 0x00,
            data: "" // data is unused
        });
        emit AddedTokenHook(address(mockToken), hook);
        bs.addTokenHook(address(mockToken), hook);
        vm.stopPrank();

        // init users
        farmers.push(users[1]);
        farmers.push(users[2]);

        // mint tokens to farmers
        mockToken.mint(farmers[0], 1000e18);
        mockToken.mint(farmers[1], 1000e18);

        // Approve Beanstalk to spend tokens
        vm.prank(farmers[0]);
        IERC20(address(mockToken)).approve(address(bs), 1000e18);
        vm.prank(farmers[1]);
        IERC20(address(mockToken)).approve(address(bs), 1000e18);
    }

    /**
     * @notice Tests that a token hook is called for internal <> internal transfers.
     */
    function test_mockTokenInternalToInternalTransferTokenHook() public {
        uint256 transferAmount = 100e18; // 100 tokens

        // Initial balances
        uint256 initialFarmer0Balance = IERC20(address(mockToken)).balanceOf(farmers[0]);
        uint256 initialFarmer1Balance = IERC20(address(mockToken)).balanceOf(farmers[1]);

        // Transfer tokens from external balance to internal balance for farmer[0]
        // Assert that the regular transfer token hook is called
        vm.prank(farmers[0]);
        vm.expectEmit(true, true, true, true);
        emit RegularTransferTokenHookCalled(farmers[0], address(bs), transferAmount);
        bs.sendTokenToInternalBalance(address(mockToken), farmers[0], transferAmount);

        // Transfer tokens from internal balance to external balance for farmer[1]
        // Assert that the regular transfer token hook is called
        vm.prank(farmers[1]);
        vm.expectEmit(true, true, true, true);
        emit RegularTransferTokenHookCalled(farmers[1], address(bs), transferAmount);
        bs.sendTokenToInternalBalance(address(mockToken), farmers[1], transferAmount);

        // send tokens from internal to internal between farmer[0] and farmer[1]
        // Assert that the internal transfer token hook is called
        vm.prank(farmers[0]);
        vm.expectEmit(true, true, true, true);
        emit InternalTransferTokenHookCalled(farmers[0], farmers[1], transferAmount);
        emit TokenHookCalled(
            address(mockToken), // token
            address(mockToken), // target
            abi.encodeWithSelector(
                mockToken.internalTransferUpdate.selector,
                farmers[0],
                farmers[1],
                transferAmount
            )
        );
        bs.transferInternalTokenFrom(
            address(mockToken),
            farmers[0],
            farmers[1],
            transferAmount,
            uint8(LibTransfer.To.INTERNAL)
        );

        // check balances after transfers, make sure the internal balance is updated
        assertEq(
            IERC20(address(mockToken)).balanceOf(farmers[0]),
            initialFarmer0Balance - transferAmount
        );
        assertEq(
            IERC20(address(mockToken)).balanceOf(farmers[1]),
            initialFarmer1Balance - transferAmount
        );
        assertEq(bs.getInternalBalance(farmers[0], address(mockToken)), 0);
        assertEq(bs.getInternalBalance(farmers[1], address(mockToken)), 200e18);
    }

    /**
     * @notice Tests that a token hook is called for external <> internal transfers.
     */
    function test_mockTokenExternalToInternalTransferTokenHook() public {
        uint256 transferAmount = 100e18; // 100 tokens

        // Initial balances
        uint256 initialFarmer0Balance = IERC20(address(mockToken)).balanceOf(farmers[0]);

        // Transfer tokens from external balance to internal balance for farmer[0]
        // Assert that the internal transfer token hook is called (since this goes through internal transfer logic)
        vm.prank(farmers[0]);
        vm.expectEmit(true, true, true, true);
        emit InternalTransferTokenHookCalled(farmers[0], farmers[0], transferAmount);
        emit TokenHookCalled(
            address(mockToken), // token
            address(mockToken), // target
            abi.encodeWithSelector(
                mockToken.internalTransferUpdate.selector,
                farmers[0],
                farmers[0],
                transferAmount
            )
        );
        bs.sendTokenToInternalBalance(address(mockToken), farmers[0], transferAmount);

        // Verify balances after transfer
        assertEq(
            IERC20(address(mockToken)).balanceOf(farmers[0]),
            initialFarmer0Balance - transferAmount
        );
        assertEq(bs.getInternalBalance(farmers[0], address(mockToken)), transferAmount);
    }

    /**
     * @notice Tests that a token hook is called for internal <> external transfers.
     */
    function test_mockTokenInternalToExternalTransferTokenHook() public {
        uint256 transferAmount = 100e18; // 100 tokens

        // First transfer tokens to internal balance
        vm.prank(farmers[0]);
        bs.sendTokenToInternalBalance(address(mockToken), farmers[0], transferAmount);

        // Initial balances after internal transfer
        uint256 initialFarmer0Balance = IERC20(address(mockToken)).balanceOf(farmers[0]);

        // Transfer tokens from internal balance to external balance for farmer[0]
        // Assert that the internal transfer token hook is called
        vm.prank(farmers[0]);
        vm.expectEmit(true, true, true, true);
        emit InternalTransferTokenHookCalled(farmers[0], farmers[0], transferAmount);
        emit TokenHookCalled(
            address(mockToken), // token
            address(mockToken), // target
            abi.encodeWithSelector(
                mockToken.internalTransferUpdate.selector,
                farmers[0],
                farmers[0],
                transferAmount
            )
        );
        bs.transferInternalTokenFrom(
            address(mockToken),
            farmers[0],
            farmers[0],
            transferAmount,
            uint8(LibTransfer.To.EXTERNAL)
        );

        // Verify balances after transfer
        assertEq(
            IERC20(address(mockToken)).balanceOf(farmers[0]),
            initialFarmer0Balance + transferAmount
        );
        assertEq(bs.getInternalBalance(farmers[0], address(mockToken)), 0);
    }

    /**
     * @notice Tests that the token hook admin functions revert for non-owners.
     */
    function test_onlyOwnerTokenHookAdminFunctions() public {
        // try to whitelist token hook as non-owner
        vm.expectRevert("LibDiamond: Must be contract or owner");
        vm.prank(farmers[0]);
        bs.addTokenHook(
            address(mockToken),
            IMockFBeanstalk.Implementation({
                target: address(mockToken),
                selector: mockToken.internalTransferUpdate.selector,
                encodeType: 0x00,
                data: "" // data is unused
            })
        );

        // try to dewhitelist token hook as non-owner
        vm.expectRevert("LibDiamond: Must be contract or owner");
        vm.prank(farmers[0]);
        bs.removeTokenHook(address(mockToken));

        // try to update token hook as non-owner
        vm.expectRevert("LibDiamond: Must be contract or owner");
        vm.prank(farmers[0]);
        bs.updateTokenHook(
            address(mockToken),
            IMockFBeanstalk.Implementation({
                target: address(mockToken),
                selector: mockToken.internalTransferUpdate.selector,
                encodeType: 0x00,
                data: "" // data is unused
            })
        );

        // try to dewhitelist a non existent token hook as owner
        vm.expectRevert("LibTokenHook: Hook not whitelisted");
        vm.prank(deployer);
        bs.removeTokenHook(address(1));

        // try to update a non existent token hook as owner
        vm.expectRevert("LibTokenHook: Hook not whitelisted");
        vm.prank(deployer);
        bs.updateTokenHook(
            address(1),
            IMockFBeanstalk.Implementation({
                target: address(mockToken),
                selector: mockToken.internalTransferUpdate.selector,
                encodeType: 0x00,
                data: "" // data is unused
            })
        );
    }

    /**
     * @notice Tests that the token hook verification fails for invalid targets, non-contracts, and selectors.
     */
    function test_failedHookVerification() public {
        // try to whitelist a token hook with a non-contract target
        vm.prank(deployer);
        vm.expectRevert("LibTokenHook: Target is not a contract");
        bs.addTokenHook(
            address(randomMockTokenAddress),
            IMockFBeanstalk.Implementation({
                target: randomMockTokenAddress, // invalid target
                selector: mockToken.internalTransferUpdate.selector,
                encodeType: 0x00,
                data: "" // data is unused
            })
        );

        // try to whitelist a token hook on a contract with an invalid selector
        vm.prank(deployer);
        vm.expectRevert("LibTokenHook: Invalid TokenHook implementation");
        bs.addTokenHook(
            address(mockToken),
            IMockFBeanstalk.Implementation({
                target: address(mockToken),
                selector: bytes4(0x12345678), // invalid selector
                encodeType: 0x00,
                data: "" // data is unused
            })
        );
    }

    /**
     * @notice Tests that the token hook whitelisting fails for invalid encode types.
     */
    function test_failedHookWhitelistingInvalidEncodeType() public {
        // try to whitelist a token hook on a contract with an invalid encode type, expect early revert
        vm.prank(deployer);
        vm.expectRevert("LibTokenHook: Invalid encodeType");
        bs.addTokenHook(
            address(mockToken),
            IMockFBeanstalk.Implementation({
                target: address(mockToken),
                selector: mockToken.internalTransferUpdate.selector,
                encodeType: 0x02, // invalid encode type
                data: "" // data is unused
            })
        );
    }

    /**
     * @notice Tests that if a token hook execution fails, no internal state gets updated.
     */
    function test_failedHookExecutionRevertsTransfer() public {
        vm.prank(farmers[0]);
        bs.sendTokenToInternalBalance(address(mockToken), farmers[0], 100e18);

        // get initial internal balance of farmer[0]
        uint256 initialInternalBalance = bs.getInternalBalance(farmers[0], address(mockToken));

        // etch the target address to another token that does not have a hook
        MockToken mockToken2 = new MockToken("MockToken2", "MT2");
        vm.etch(address(mockToken), address(mockToken2).code);

        // try to transfer tokens from internal to internal, expect execution failure
        vm.prank(farmers[0]);
        vm.expectRevert("LibTokenHook: Hook execution failed");
        bs.transferInternalTokenFrom(
            address(mockToken),
            farmers[0],
            farmers[1],
            100e18,
            uint8(LibTransfer.To.INTERNAL)
        );

        // check that the internal balance of farmer[0] is the same as before the transfer,
        // no state should have been updated
        assertEq(bs.getInternalBalance(farmers[0], address(mockToken)), initialInternalBalance);
    }
}

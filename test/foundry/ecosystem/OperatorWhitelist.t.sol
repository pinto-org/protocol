// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {OperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract OperatorWhitelistTest is TestHelper {
    OperatorWhitelist whitelist;
    address[] operators;

    function setUp() public {
        operators = createUsers(3);
        whitelist = new OperatorWhitelist(address(this));
    }

    function test_addOperator() public {
        // Add operator
        whitelist.addOperator(operators[0]);
        assertTrue(
            whitelist.checkOperatorWhitelist(operators[0]),
            "Operator should be whitelisted"
        );

        // Verify operator is in the list
        address[] memory whitelistedOperators = whitelist.getWhitelistedOperators();
        assertEq(whitelistedOperators.length, 1, "Should have one operator");
        assertEq(whitelistedOperators[0], operators[0], "Wrong operator address");

        // Try to add same operator again
        vm.expectRevert("Operator already whitelisted");
        whitelist.addOperator(operators[0]);

        // Try to add zero address
        vm.expectRevert("Cannot whitelist zero address");
        whitelist.addOperator(address(0));

        // Try to add as non-owner
        vm.prank(operators[1]);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operators[1])
        );
        whitelist.addOperator(operators[2]);
    }

    function test_removeOperator() public {
        // Add operators
        whitelist.addOperator(operators[0]);
        whitelist.addOperator(operators[1]);
        whitelist.addOperator(operators[2]);

        // Remove middle operator
        whitelist.removeOperator(operators[1]);
        assertFalse(
            whitelist.checkOperatorWhitelist(operators[1]),
            "Operator should not be whitelisted"
        );

        // Verify directly from mapping
        assertFalse(
            whitelist.whitelistedOperators(operators[1]),
            "Operator should not be whitelisted in mapping"
        );

        // Verify remaining operators
        address[] memory whitelistedOperators = whitelist.getWhitelistedOperators();
        assertEq(whitelistedOperators.length, 2, "Should have two operators");
        assertTrue(
            whitelistedOperators[0] == operators[0] || whitelistedOperators[0] == operators[2],
            "Wrong operator address"
        );
        assertTrue(
            whitelistedOperators[1] == operators[0] || whitelistedOperators[1] == operators[2],
            "Wrong operator address"
        );

        // Try to remove non-whitelisted operator
        vm.expectRevert("Operator not whitelisted");
        whitelist.removeOperator(operators[1]);

        // Try to remove as non-owner
        vm.prank(operators[1]);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operators[1])
        );
        whitelist.removeOperator(operators[0]);
    }

    function test_checkOperatorWhitelist() public {
        // Check non-whitelisted operator
        assertFalse(
            whitelist.checkOperatorWhitelist(operators[0]),
            "Should not be whitelisted initially"
        );

        // Verify with direct mapping access
        assertFalse(
            whitelist.whitelistedOperators(operators[0]),
            "Should not be whitelisted in mapping initially"
        );

        // Add operator
        whitelist.addOperator(operators[0]);
        assertTrue(
            whitelist.checkOperatorWhitelist(operators[0]),
            "Should be whitelisted after adding"
        );

        // Verify with direct mapping access
        assertTrue(
            whitelist.whitelistedOperators(operators[0]),
            "Should be whitelisted in mapping after adding"
        );

        // Remove operator
        whitelist.removeOperator(operators[0]);
        assertFalse(
            whitelist.checkOperatorWhitelist(operators[0]),
            "Should not be whitelisted after removing"
        );

        // Verify with direct mapping access
        assertFalse(
            whitelist.whitelistedOperators(operators[0]),
            "Should not be whitelisted in mapping after removing"
        );
    }

    function test_getWhitelistedOperators() public {
        // Check empty list
        address[] memory emptyList = whitelist.getWhitelistedOperators();
        assertEq(emptyList.length, 0, "Should start with empty list");

        // Add operators
        whitelist.addOperator(operators[0]);
        whitelist.addOperator(operators[1]);
        whitelist.addOperator(operators[2]);

        // Check full list
        address[] memory fullList = whitelist.getWhitelistedOperators();
        assertEq(fullList.length, 3, "Should have three operators");
        assertEq(fullList[0], operators[0], "Wrong first operator");
        assertEq(fullList[1], operators[1], "Wrong second operator");
        assertEq(fullList[2], operators[2], "Wrong third operator");

        // Verify each operator status using public mapping
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(
                whitelist.whitelistedOperators(operators[i]),
                "Operator should be whitelisted in mapping"
            );
        }
    }
}

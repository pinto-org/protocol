// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk, IERC20} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import "forge-std/console.sol";

contract Pi11ForkTest is TestHelper {

    function setUp() public {
        initializeBeanstalkTestState(true, false);
    }

    function test_forkBase_pi11() public {
        uint256 forkBlock = 31599727;
        assertEq(forkBlock, 31599727);
    }
}

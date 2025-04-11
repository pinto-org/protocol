// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {C} from "contracts/C.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {LibWellMinting} from "contracts/libraries/Minting/LibWellMinting.sol";
import {LibMinting} from "contracts/libraries/Minting/LibMinting.sol";
import {LibRedundantMathSigned256} from "contracts/libraries/Math/LibRedundantMathSigned256.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";

/**
 * @title Oracle
 * @notice Tracks the Delta B in available pools.
 */
abstract contract Oracle is ReentrancyGuard {
    using LibRedundantMathSigned256 for int256;

    //////////////////// ORACLE INTERNAL ////////////////////

    function stepOracle() internal returns (int256 deltaB) {
        address[] memory tokens = LibWhitelistedTokens.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            deltaB = deltaB.add(LibWellMinting.capture(tokens[i]));
        }
        s.sys.season.timestamp = block.timestamp;
        deltaB = LibMinting.checkForMaxDeltaB(C.GLOBAL_ABSOLUTE_MAX, C.GLOBAL_RATIO_MAX, deltaB);
    }
}

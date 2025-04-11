/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import "contracts/beanstalk/facets/silo/WhitelistFacet.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";

/**
 * @title Mock Whitelist Facet
 *
 */
contract MockWhitelistFacet is WhitelistFacet {
    function updateWhitelistStatus(
        address token,
        bool isWhitelisted,
        bool isWhitelistedLp,
        bool isWhitelistedWell,
        bool isSoppable
    ) external {
        LibWhitelistedTokens.updateWhitelistStatus(
            token,
            isWhitelisted,
            isWhitelistedLp,
            isWhitelistedWell,
            isSoppable
        );
    }

    function addWhitelistStatus(
        address token,
        bool isWhitelisted,
        bool isWhitelistedLp,
        bool isWhitelistedWell,
        bool isSoppable
    ) external {
        LibWhitelistedTokens.addWhitelistStatus(
            token,
            isWhitelisted,
            isWhitelistedLp,
            isWhitelistedWell,
            isSoppable
        );
    }
}

/*
 * SPDX-License-Identifier: MIT
 */

pragma solidity ^0.8.20;

/**
 * @title LiquidityWeightFacet
 * @notice determines the liquidity weight. Used in the gauge system.
 */
interface ILiquidityWeightFacet {
    function maxWeight(bytes memory) external pure returns (uint256);

    function noWeight(bytes memory) external pure returns (uint256);
}

contract LiquidityWeightFacet {
    uint256 constant MAX_WEIGHT = 1e18;

    function maxWeight(bytes memory) external pure returns (uint256) {
        return MAX_WEIGHT;
    }

    function noWeight(bytes memory) external pure returns (uint256) {
        return 0;
    }
}

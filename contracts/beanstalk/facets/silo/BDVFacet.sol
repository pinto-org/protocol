/*
 * SPDX-License-Identifier: MIT
 */

pragma solidity ^0.8.20;

import "contracts/C.sol";
import "contracts/libraries/Well/LibWellBdv.sol";

/**
 * @title BDVFacet
 * @notice Calculates BDV for whitelisted Silo tokens.
 */
contract BDVFacet {
    using LibRedundantMath256 for uint256;

    /**
     * @dev Returns the BDV of a given `amount` of Beans.
     */
    function beanToBDV(uint256 amount) public pure returns (uint256) {
        return amount;
    }

    /**
     * @dev Returns the BDV of a given `amount` of Well LP Tokens given a Well `token`.
     * A Well's `token` address is the same as the Well address.
     * Any Well `token` that uses the `wellBdv` function as its BDV function must have 
     `encodeType = 1` in {AssetSettings}.
     */
    function wellBdv(address token, uint256 amount) external view returns (uint256) {
        return LibWellBdv.bdv(token, amount);
    }
}

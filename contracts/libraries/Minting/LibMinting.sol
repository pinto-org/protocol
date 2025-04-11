/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";
import {LibAppStorage, AppStorage} from "contracts/libraries/LibAppStorage.sol";
import {C} from "contracts/C.sol";

/**
 * @title Minting Library
 * @notice Contains Helper Fucntions for Minting related functionality.
 **/
library LibMinting {
    using LibRedundantMath256 for uint256;

    function checkForMaxDeltaB(
        uint256 absoluteMax,
        uint256 relativeMax,
        int256 deltaB
    ) internal view returns (int256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // get the maximum deltaB based on the relative max
        int256 maxDeltaB = int256(
            BeanstalkERC20(s.sys.bean).totalSupply().mul(relativeMax).div(C.PRECISION)
        );

        // if the absolute max is greater than the relative max, use the absolute max
        if (int256(absoluteMax) > maxDeltaB) maxDeltaB = int256(absoluteMax);
        // if the deltaB is negative, return the negative maxDeltaB
        if (deltaB < 0) return deltaB > -maxDeltaB ? deltaB : -maxDeltaB;
        return deltaB < maxDeltaB ? deltaB : maxDeltaB;
    }
}

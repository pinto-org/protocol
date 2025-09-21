// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Diamond} from "contracts/beanstalk/Diamond.sol";
import {InitializeTractorDiamond} from "contracts/ecosystem/tractor/InitializeTractorDiamond.sol";

/**
 * @title TractorDiamond
 * @notice TractorDiamond contract inheriting from Diamond
 * @dev Adds an additional function to the Diamond that allows for compressed Tractor data be published in a gas efficent manner.
 */
contract TractorDiamond is InitializeTractorDiamond, Diamond {
    constructor(address contractOwner) Diamond(contractOwner) {
        // adds `publishTractorData` and `publishMultiTractorData` to the Diamond
        addTractorDiamondImmutables();
    }
}

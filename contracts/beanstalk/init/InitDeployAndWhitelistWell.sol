/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {InitWells} from "contracts/beanstalk/init/deployment/InitWells.sol";

/**
 * @title InitDeployAndWhitelistWell is used for deploying and whitelisting a well
 **/
contract InitDeployAndWhitelistWell is InitWells {
    function init(WellData calldata well, WhitelistData calldata whitelist) external {
        // Deploy the well
        deployUpgradableWell(well);
        // Whitelist bean assets
        whitelistBeanAsset(whitelist);
    }
}

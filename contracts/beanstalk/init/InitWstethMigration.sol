/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import {LibInitGauges} from "contracts/libraries/Gauge/LibInitGauges.sol";
import {InitWells} from "contracts/beanstalk/init/deployment/InitWells.sol";

/**
 * @title InitWstethMigration
 * @dev performs the wsteth migration.
 * This PI performs the following steps:
 * 1. Deploys a new pinto-wsteth well.
 * 2. Whitelists the new asset.
 * 3. Initializes the LP distribution gauge to distribute the LP over the new asset.
 **/
contract InitWstethMigration is InitWells {

    int64 internal constant DELTA = 1e6;
    uint256 internal constant NUM_SEASONS = 33;
    address internal constant PINTO_CBETH_WELL = 0x3e111115A82dF6190e36ADf0d552880663A4dBF1;

    function init(WellData calldata well, WhitelistData calldata whitelist) external {
        // Deploy the new well.
        (, address wstethWell) = deployUpgradableWell(well);
        // Whitelist new asset.
        whitelistBeanAsset(whitelist);

        // Initialize the LP distribution gauge.
        LibInitGauges.initLpDistributionGauge(NUM_SEASONS, PINTO_CBETH_WELL, wstethWell, DELTA);
    }
}

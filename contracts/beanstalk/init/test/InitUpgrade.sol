/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import {AppStorage, LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {ShipmentRoute, ShipmentRecipient} from "contracts/beanstalk/storage/System.sol";

/**
 * @title InitSetHighSeeds is used to increase the amount of seeds that each whitelisted token gets,
 * to mimic a large amount of stalk growth in 1 season.
 * @dev this will only effect the stalk after a `gm` call occurs. once that occurs, the seeds are set again based on
 * the seed gauge system.
 **/
contract InitSetHighSeeds {
    AppStorage internal s;

    function init() external {
        for (uint256 i = 0; i < s.sys.silo.whitelistStatuses.length; i++) {
            if (s.sys.silo.whitelistStatuses[i].isWhitelisted) {
                s
                    .sys
                    .silo
                    .assetSettings[s.sys.silo.whitelistStatuses[i].token]
                    .stalkEarnedPerSeason = 10_000e6; // 1e6 = 1 seed, 10_000e6 = 10k seeds. 10k seeds = 1 stalk earned per season.
            }
        }
    }
}

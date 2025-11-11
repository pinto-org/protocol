// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibClone} from "@beanstalk/wells/src/libraries/LibClone.sol";

/**
 * @title LibCloneTest
 * @notice Helper contract to test LibClone.initCodeHash calculation
 */
contract LibCloneTest {
    /**
     * @notice Calculate the initCodeHash for a clone with immutable args
     * @param implementation The implementation contract address
     * @param data The immutable data to append
     * @return hash The init code hash
     */
    function calculateInitCodeHash(
        address implementation,
        bytes memory data
    ) external pure returns (bytes32 hash) {
        return LibClone.initCodeHash(implementation, data);
    }

    /**
     * @notice Predict the deterministic address for a clone
     * @param implementation The implementation contract address
     * @param data The immutable data to append
     * @param salt The CREATE2 salt
     * @param deployer The deployer address
     * @return predicted The predicted address
     */
    function predictDeterministicAddress(
        address implementation,
        bytes memory data,
        bytes32 salt,
        address deployer
    ) external pure returns (address predicted) {
        return LibClone.predictDeterministicAddress(implementation, data, salt, deployer);
    }
}

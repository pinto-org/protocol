/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {LibTractorStorage} from "./LibTractorStorage.sol";
import {LibTransientStorage} from "./LibTransientStorage.sol";

/**
 * @title Lib Tractor
 **/
library LibTractor {
    enum CounterUpdateType {
        INCREASE,
        DECREASE
    }

    bytes32 private constant TRACTOR_HASHED_NAME = keccak256(bytes("Tractor"));
    bytes32 private constant EIP712_TYPE_HASH =
        keccak256(
            bytes(
                "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
            )
        );
    bytes32 public constant BLUEPRINT_TYPE_HASH =
        keccak256(
            bytes(
                "Blueprint(address publisher,bytes data,bytes32[] operatorPasteInstrs,uint256 maxNonce,uint256 startTime,uint256 endTime)"
            )
        );

    event TractorVersionSet(string version);

    // Blueprint stores blueprint related values
    struct Blueprint {
        address publisher;
        bytes data;
        bytes32[] operatorPasteInstrs;
        uint256 maxNonce;
        uint256 startTime;
        uint256 endTime;
    }

    /**
     * @notice Stores blueprint, hash, and signature, which enables verification.
     */
    struct Requisition {
        Blueprint blueprint;
        bytes32 blueprintHash; // including this is not strictly necessary, but helps avoid hashing more than once on chain
        bytes signature;
    }


    /**
     * @notice Set the tractor hashed version.
     */
    function _setVersion(string memory version) internal {
        LibTractorStorage.tractorStorage().version = version;
        emit TractorVersionSet(version);
    }

    /**
     * @notice Get the current tractor version
     * @return version Current tractor version string
     */
    function _getVersion() internal view returns (string memory) {
        return LibTractorStorage.tractorStorage().version;
    }

    /**
     * @notice Increment the blueprint nonce by 1.
     * @param blueprintHash blueprint hash
     */
    function _incrementBlueprintNonce(bytes32 blueprintHash) internal {
        LibTractorStorage.tractorStorage().blueprintNonce[blueprintHash]++;
    }

    /**
     * @notice Cancel blueprint.
     * @dev set blueprintNonce to type(uint256).max
     * @param blueprintHash blueprint hash
     */
    function _cancelBlueprint(bytes32 blueprintHash) internal {
        LibTractorStorage.tractorStorage().blueprintNonce[blueprintHash] = type(uint256).max;
    }

    /**
     * @notice Set blueprint publisher address.
     * @param publisher blueprint publisher address
     */
    function _setPublisher(address payable publisher) internal {
        LibTractorStorage.TractorStorage storage ts = LibTractorStorage.tractorStorage();
        require(
            uint160(bytes20(address(ts.activePublisher))) <= 1,
            "LibTractor: publisher already set"
        );
        ts.activePublisher = publisher;
    }

    /**
     * @notice Reset blueprint publisher address.
     */
    function _resetPublisher() internal {
        LibTractorStorage.tractorStorage().activePublisher = payable(address(1));
    }

    /** @notice Return current activePublisher address.
     * @return publisher current activePublisher address
     */
    function _getActivePublisher() internal view returns (address payable) {
        return LibTractorStorage.tractorStorage().activePublisher;
    }

    /** @notice Return current activePublisher address or msg.sender if no active blueprint.
     * @return user to take actions on behalf of
     */
    function _user() internal view returns (address payable user) {
        user = _getActivePublisher();
        if (uint160(bytes20(address(user))) <= 1) {
            user = payable(msg.sender);
        }
    }

    /**
     * @notice Get blueprint nonce.
     * @param blueprintHash blueprint hash
     * @return nonce current blueprint nonce
     */
    function _getBlueprintNonce(bytes32 blueprintHash) internal view returns (uint256) {
        return LibTractorStorage.tractorStorage().blueprintNonce[blueprintHash];
    }

    /**
     * @notice Calculates blueprint hash.
     * @dev https://eips.ethereum.org/EIPS/eip-712
     * @dev  https://github.com/BeanstalkFarms/Beanstalk/pull/727#discussion_r1577293450
     * @param blueprint blueprint object
     * @return hash calculated Blueprint hash
     */
    function _getBlueprintHash(Blueprint calldata blueprint) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        BLUEPRINT_TYPE_HASH,
                        blueprint.publisher,
                        keccak256(blueprint.data),
                        keccak256(abi.encodePacked(blueprint.operatorPasteInstrs)),
                        blueprint.maxNonce,
                        blueprint.startTime,
                        blueprint.endTime
                    )
                )
            );
    }

    /**
     * @notice Hashes in an EIP712 compliant way.
     * @dev Returns an Ethereum Signed Typed Data, created from a
     * `domainSeparator` and a `structHash`. This produces hash corresponding
     * to the one signed with the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`]
     * JSON-RPC method as part of EIP-712.
     *
     * Sourced from OpenZeppelin 0.8 ECDSA lib.
     */
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    /**
     * @notice Returns the domain separator for the current chain.
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_TYPE_HASH,
                    TRACTOR_HASHED_NAME,
                    keccak256(bytes(LibTractorStorage.tractorStorage().version)),
                    block.chainid,
                    address(this)
                )
            );
    }

    /**
     * @notice Set the current blueprint hash
     * @param blueprintHash The hash of the currently executing blueprint
     */
    function _setCurrentBlueprintHash(bytes32 blueprintHash) internal {
        LibTractorStorage.tractorStorage().currentBlueprintHash = blueprintHash;
    }

    /**
     * @notice Set blueprint counter value for an account
     * @param account The account address
     * @param counterId The counter identifier
     * @param value The counter value to set
     */
    function _setBlueprintCounter(address account, bytes32 counterId, uint256 value) internal {
        LibTractorStorage.tractorStorage().blueprintCounters[account][counterId] = value;
    }

    /**
     * @notice Reset the current blueprint hash
     */
    function _resetCurrentBlueprintHash() internal {
        LibTractorStorage.tractorStorage().currentBlueprintHash = bytes32(uint256(1));
    }

    /**
     * @notice Get the current blueprint hash
     * @return The hash of the currently executing blueprint
     */
    function _getCurrentBlueprintHash() internal view returns (bytes32) {
        return LibTractorStorage.tractorStorage().currentBlueprintHash;
    }

    /**
     * @notice Get blueprint counter value for an account
     * @param account The account address
     * @param counterId The counter identifier
     * @return counter The counter value
     */
    function _getBlueprintCounter(address account, bytes32 counterId) internal view returns (uint256) {
        return LibTractorStorage.tractorStorage().blueprintCounters[account][counterId];
    }

    /**
     * @notice Set the operator
     * @param operator The operator address
     */
    function _setOperator(address operator) internal {
        LibTractorStorage.tractorStorage().operator = operator;
    }

    /**
     * @notice Reset the operator
     */
    function _resetOperator() internal {
        LibTractorStorage.tractorStorage().operator = address(1);
    }

    /**
     * @notice Get the operator
     * @return The operator address
     */
    function _getOperator() internal view returns (address) {
        return LibTractorStorage.tractorStorage().operator;
    }

    /**
     * @notice Clear transient data for a given key.
     * @dev Uses EIP-1153 transient storage for gas efficiency.
     *      Data is automatically cleared at transaction end.
     * @param key The key to clear the data for.
     */
    function clearTractorData(uint256 key) internal {
        LibTransientStorage.clearBytes(key);
    }

    /**
     * @notice Set transient data for a given key.
     * @dev Uses EIP-1153 transient storage for gas efficiency.
     *      Data persists only during transaction execution.
     * @param key The key to set the data for.
     * @param value The data to set for the given key.
     */
    function setTractorData(uint256 key, bytes memory value) internal {
        LibTransientStorage.setBytes(key, value);
    }

    /**
     * @notice Get transient data for a given key.
     * @dev Uses EIP-1153 transient storage for gas efficiency.
     *      Returns empty bytes if key not found.
     * @param key The key to get the data for.
     * @return The data for the given key.
     */
    function getTractorData(uint256 key) internal view returns (bytes memory) {
        return LibTransientStorage.getBytes(key);
    }
}

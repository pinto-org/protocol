/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {AdvancedFarmCall, LibFarm} from "contracts/libraries/LibFarm.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";
import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {LibTransfer, IERC20} from "contracts/libraries/Token/LibTransfer.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title TractorFacet handles tractor and blueprint operations.
 */
contract TractorFacet is Invariable, ReentrancyGuard {
    using LibBytes for bytes32;
    using LibRedundantMath256 for uint256;

    event PublishRequisition(LibTractor.Requisition requisition);

    event CancelBlueprint(bytes32 indexed blueprintHash);

    event Tractor(
        address indexed operator,
        address indexed publisher,
        bytes32 indexed blueprintHash,
        uint256 nonce,
        uint256 gasleft
    );

    event TractorExecutionBegan(
        address indexed operator,
        address indexed publisher,
        bytes32 indexed blueprintHash,
        uint256 nonce,
        uint256 gasleft
    );

    // bytes4(keccak256("isValidSignature(bytes32,bytes)")
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    /**
     * @notice Ensure requisition hash matches blueprint data and signer is publisher.
     */
    modifier verifyRequisition(LibTractor.Requisition calldata requisition) {
        bytes32 blueprintHash = LibTractor._getBlueprintHash(requisition.blueprint);
        require(blueprintHash == requisition.blueprintHash, "TractorFacet: invalid hash");
        if (requisition.blueprint.publisher.code.length > 0) {
            // if the publisher is a smart contract, verify the publisher using EIP-1271.
            bytes4 magicValue = IERC1271(requisition.blueprint.publisher).isValidSignature(
                requisition.blueprintHash,
                requisition.signature
            );
            require(magicValue == MAGICVALUE, "TractorFacet: invalid signature");
        } else {
            // if the publisher is an anonymous account, verify the signature using ECDSA.
            address signer = ECDSA.recover(requisition.blueprintHash, requisition.signature);
            require(signer == requisition.blueprint.publisher, "TractorFacet: signer mismatch");
        }
        _;
    }

    /**
     * @notice Verify nonce and time are acceptable, increment nonce, set publisher, clear publisher.
     */
    modifier runBlueprint(LibTractor.Requisition calldata requisition) {
        uint256 nonce = LibTractor._getBlueprintNonce(requisition.blueprintHash);
        require(nonce < requisition.blueprint.maxNonce, "TractorFacet: maxNonce reached");
        require(
            requisition.blueprint.startTime <= block.timestamp &&
                block.timestamp <= requisition.blueprint.endTime,
            "TractorFacet: blueprint is not active"
        );

        emit TractorExecutionBegan(
            msg.sender,
            requisition.blueprint.publisher,
            requisition.blueprintHash,
            nonce,
            gasleft()
        );

        LibTractor._incrementBlueprintNonce(requisition.blueprintHash);
        LibTractor._setPublisher(payable(requisition.blueprint.publisher));
        _;
        LibTractor._resetPublisher();
        emit Tractor(
            msg.sender,
            requisition.blueprint.publisher,
            requisition.blueprintHash,
            nonce,
            gasleft()
        );
    }

    /**
     * @notice Updates the tractor version used for EIP712 signatures.
     * @dev This function will render all existing blueprints invalid.
     */
    function updateTractorVersion(
        string calldata version
    ) external fundsSafu noNetFlow noSupplyChange nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibTractor._setVersion(version);
    }

    /**
     * @notice Get the current tractor version.
     * @dev Only blueprints using the current version can be run.
     */
    function getTractorVersion() external view returns (string memory) {
        return LibTractor._tractorStorage().version;
    }

    /**
     * @notice Publish a new blueprint by emitting its data in an event.
     */
    function publishRequisition(
        LibTractor.Requisition calldata requisition
    ) external fundsSafu noNetFlow noSupplyChange verifyRequisition(requisition) nonReentrant {
        require(
            LibTractor._getBlueprintNonce(requisition.blueprintHash) <
                requisition.blueprint.maxNonce,
            "TractorFacet: maxNonce reached"
        );
        emit PublishRequisition(requisition);
    }

    /**
     * @notice Destroy existing blueprint
     */
    function cancelBlueprint(
        LibTractor.Requisition calldata requisition
    ) external fundsSafu noNetFlow noSupplyChange verifyRequisition(requisition) nonReentrant {
        require(msg.sender == requisition.blueprint.publisher, "TractorFacet: not publisher");
        LibTractor._cancelBlueprint(requisition.blueprintHash);
        emit CancelBlueprint(requisition.blueprintHash);
    }

    /**
     * @notice Execute a Tractor blueprint as an operator.
     */
    function tractor(
        LibTractor.Requisition calldata requisition,
        bytes memory operatorData
    )
        external
        payable
        fundsSafu
        nonReentrantFarm
        verifyRequisition(requisition)
        runBlueprint(requisition)
        returns (bytes[] memory results)
    {
        require(requisition.blueprint.data.length > 0, "Tractor: data empty");

        // Set current blueprint hash
        LibTractor._setCurrentBlueprintHash(requisition.blueprintHash);

        // Set operator
        LibTractor._setOperator(msg.sender);

        // Decode and execute advanced farm calls.
        // Cut out blueprint calldata selector.
        AdvancedFarmCall[] memory calls = abi.decode(
            LibBytes.sliceFrom(requisition.blueprint.data, 4),
            (AdvancedFarmCall[])
        );

        // Update data with operator-defined fillData.
        for (uint256 i; i < requisition.blueprint.operatorPasteInstrs.length; ++i) {
            bytes32 operatorPasteInstr = requisition.blueprint.operatorPasteInstrs[i];
            uint80 pasteCallIndex = operatorPasteInstr.getIndex1();
            require(calls.length > pasteCallIndex, "Tractor: pasteCallIndex OOB");

            LibBytes.pasteBytesTractor(
                operatorPasteInstr,
                operatorData,
                calls[pasteCallIndex].callData
            );
        }

        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            require(calls[i].callData.length != 0, "Tractor: empty AdvancedFarmCall");
            results[i] = LibFarm._advancedFarm(calls[i], results);
        }

        // Clear current blueprint hash
        LibTractor._resetCurrentBlueprintHash();

        // Clear operator
        LibTractor._resetOperator();
    }

    /**
     * @notice Transfers a token from `msg.sender` to a `recipient` from the External balance.
     * @dev When any function is called via Tractor (e.g., from a blueprint), the protocol substitutes
     * the blueprint publisher as the sender instead of the actual caller.
     *
     * Some contracts within a blueprint may need to transfer ERC-20 tokens to an address's
     * internal balance (e.g., to deposit into the Silo or to sow into the Field).
     * This function facilitates such transfers.
     *
     * Tractor operators should be cautious when using this function, as it may result in
     * funds being withdrawn from their wallet. To mitigate risks, operators should ensure that:
     * 1) No ERC-20 permissions are granted to the Beanstalk contract, and/or
     * 2) This function is not exploited maliciously.
     *
     * Operators can check for this function in bytecode via the selector (0xca1e71ae)
     */
    function sendTokenToInternalBalance(
        IERC20 token,
        address recipient,
        uint256 amount
    ) external payable fundsSafu noSupplyChange noOutFlow nonReentrant {
        LibTransfer.transferToken(
            token,
            msg.sender,
            recipient,
            amount,
            LibTransfer.From.EXTERNAL,
            LibTransfer.To.INTERNAL
        );
    }

    /**
     * @notice Get current counter value for any account.
     * @dev Intended for external access.
     * @return count Counter value
     */
    function getCounter(address account, bytes32 counterId) external view returns (uint256 count) {
        return LibTractor._tractorStorage().blueprintCounters[account][counterId];
    }

    /**
     * @notice Get current counter value.
     * @dev Intended for access via Tractor farm call. QoL function.
     * @return count Counter value
     */
    function getPublisherCounter(bytes32 counterId) public view returns (uint256 count) {
        return
            LibTractor._tractorStorage().blueprintCounters[
                LibTractor._tractorStorage().activePublisher
            ][counterId];
    }

    /**
     * @notice Update counter value.
     * @dev Intended for use via Tractor farm call.
     * @return count New value of counter
     */
    function updatePublisherCounter(
        bytes32 counterId,
        LibTractor.CounterUpdateType updateType,
        uint256 amount
    ) external fundsSafu noNetFlow noSupplyChange nonReentrant returns (uint256 count) {
        uint256 newCount;
        if (updateType == LibTractor.CounterUpdateType.INCREASE) {
            newCount = getPublisherCounter(counterId).add(amount);
        } else if (updateType == LibTractor.CounterUpdateType.DECREASE) {
            newCount = getPublisherCounter(counterId).sub(amount);
        }
        LibTractor._tractorStorage().blueprintCounters[
            LibTractor._tractorStorage().activePublisher
        ][counterId] = newCount;
        return newCount;
    }

    /**
     * @notice Get current blueprint nonce.
     * @return nonce current blueprint nonce
     */
    function getBlueprintNonce(bytes32 blueprintHash) external view returns (uint256) {
        return LibTractor._getBlueprintNonce(blueprintHash);
    }

    /**
     * @notice Get EIP712 compliant hash of the blueprint.
     * @return hash Hash of Blueprint
     */
    function getBlueprintHash(
        LibTractor.Blueprint calldata blueprint
    ) external view returns (bytes32) {
        return LibTractor._getBlueprintHash(blueprint);
    }

    /**
     * @notice Get the hash of the currently executing blueprint
     * @return The current blueprint hash
     */
    function getCurrentBlueprintHash() external view returns (bytes32) {
        return LibTractor._getCurrentBlueprintHash();
    }

    /**
     * @notice Get the user context for tractor operations.
     * @return user Current user, either active publisher or msg.sender
     */
    function tractorUser() external view returns (address payable) {
        return LibTractor._user();
    }

    function operator() external view returns (address) {
        return LibTractor._getOperator();
    }
}

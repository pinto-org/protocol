// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {C} from "contracts/C.sol";
import {AppStorage, LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {ShipmentRecipient} from "contracts/beanstalk/storage/System.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {ISiloPayback} from "contracts/interfaces/ISiloPayback.sol";
import {IBarnPayback} from "contracts/interfaces/IBarnPayback.sol";

/**
 * @title LibReceiving
 * @notice Holds the logic responsible for receiving Bean shipments after mints. These
 *  functions must be delegatecalled from inside of the Beanstalk Diamond. If new receiving components
 *  are needed, this library and its calling Facet will need to be updated.
 * @dev An alternative design could remove the need for the generalized receive() entry function
 *  and instead require the shipping route to define the selector of its own corresponding receive
 *  function. However, both designs will require a Facet cut if a new receive function is needed,
 *  so this design was chosen for additional clarity.
 * @dev Functions are internal, but only pulled into LibShipping. Reduces the size of facet.
 */
library LibReceiving {
    using SafeCast for uint256;

    /**
     * @notice Emitted during Sunrise when Bean mints are shipped through active routes.
     * @param recipient The receiver.
     * @param receivedAmount The amount of Bean successfully received and processed.
     * @param data The data the Bean were received with. Optional.
     */
    event Receipt(ShipmentRecipient indexed recipient, uint256 receivedAmount, bytes data);

    /**
     * @notice General entry point to receive Bean at a given component of the system.
     * @param recipient The Beanstalk component that will receive the Bean.
     * @param shipmentAmount The amount of Bean to receive.
     * @param data Additional data to pass to the receiving function.
     */
    function receiveShipment(
        ShipmentRecipient recipient,
        uint256 shipmentAmount,
        bytes memory data
    ) internal {
        if (recipient == ShipmentRecipient.SILO) {
            siloReceive(shipmentAmount, data);
        } else if (recipient == ShipmentRecipient.FIELD) {
            fieldReceive(shipmentAmount, data);
        } else if (recipient == ShipmentRecipient.INTERNAL_BALANCE) {
            internalBalanceReceive(shipmentAmount, data);
        } else if (recipient == ShipmentRecipient.EXTERNAL_BALANCE) {
            externalBalanceReceive(shipmentAmount, data);
        } else if (recipient == ShipmentRecipient.BARN_PAYBACK) {
            barnPaybackReceive(shipmentAmount, data);
        } else if (recipient == ShipmentRecipient.SILO_PAYBACK) {
            siloPaybackReceive(shipmentAmount, data);
        }
        // New receiveShipment enum values should have a corresponding function call here.
    }

    /**
     * @notice Receive Bean at the Silo, distributing Stalk & Earned Bean.
     * @dev Data param not used.
     * @param shipmentAmount Amount of Bean to receive.
     */
    function siloReceive(uint256 shipmentAmount, bytes memory) private {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // `s.earnedBeans` is an accounting mechanism that tracks the total number
        // of Earned Bean that are claimable by Stalkholders. When claimed via `plant()`,
        // it is decremented. See {Silo.sol:_plant} for more details.
        s.sys.silo.earnedBeans += shipmentAmount.toUint128();

        // Mint Stalk (as Earned Stalk).
        // Stalk is created here because only Bean that are allocated to the Silo receive Stalk.
        s.sys.silo.stalk += (shipmentAmount * C.STALK_PER_BEAN);

        // SafeCast unnecessary here because of prior safe cast.
        s.sys.silo.balances[s.sys.bean].deposited += uint128(shipmentAmount);
        s.sys.silo.balances[s.sys.bean].depositedBdv += uint128(shipmentAmount);

        // Confirm successful receipt.
        emit Receipt(ShipmentRecipient.SILO, shipmentAmount, abi.encode(""));
    }

    /**
     * @notice Receive Bean at the Field. The next `shipmentAmount` Pods become harvestable.
     * @dev Amount should never exceed the number of Pods that are not yet Harvestable.
     * @dev In the case of a payback field, even though it cointains additional data,
     * the fieldId is always the first parameter to be decoded.
     * @param shipmentAmount Amount of Bean to receive.
     * @param data Encoded uint256 containing the index of the Field to receive the Bean.
     */
    function fieldReceive(uint256 shipmentAmount, bytes memory data) private {
        AppStorage storage s = LibAppStorage.diamondStorage();

        uint256 fieldId = abi.decode(data, (uint256));
        require(fieldId < s.sys.fieldCount, "Field does not exist");
        s.sys.fields[fieldId].harvestable += shipmentAmount;

        // Confirm successful receipt.
        emit Receipt(ShipmentRecipient.FIELD, shipmentAmount, data);
    }

    /**
     * @notice Receive Bean at the Internal Balance of a destination address.
     * @param shipmentAmount Amount of Bean to receive.
     * @param data ABI encoded address of the destination.
     */
    function internalBalanceReceive(uint256 shipmentAmount, bytes memory data) private {
        AppStorage storage s = LibAppStorage.diamondStorage();

        address destination = abi.decode(data, (address));
        LibTransfer.sendToken(
            IERC20(s.sys.bean),
            shipmentAmount,
            destination,
            LibTransfer.To.INTERNAL
        );

        // Confirm successful receipt.
        emit Receipt(ShipmentRecipient.INTERNAL_BALANCE, shipmentAmount, data);
    }

    /**
     * @notice Receive Bean at the External Balance of a destination address.
     * @param shipmentAmount Amount of Bean to receive.
     * @param data ABI encoded address of the destination.
     */
    function externalBalanceReceive(uint256 shipmentAmount, bytes memory data) private {
        AppStorage storage s = LibAppStorage.diamondStorage();

        address destination = abi.decode(data, (address));
        LibTransfer.sendToken(
            IERC20(s.sys.bean),
            shipmentAmount,
            destination,
            LibTransfer.To.EXTERNAL
        );

        // Confirm successful receipt.
        emit Receipt(ShipmentRecipient.EXTERNAL_BALANCE, shipmentAmount, data);
    }

    /**
     * @notice Receive Bean at the Barn Payback contract.
     * When the Barn Payback contract receives Bean, it needs to update the amount of sprouts that become rinsible.
     * @param shipmentAmount Amount of Bean to receive.
     * @param data ABI encoded address of the barn payback contract.
     */
    function barnPaybackReceive(uint256 shipmentAmount, bytes memory data) private {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // barn payback is the second parameter in the data
        (, address barnPaybackContract) = abi.decode(data, (address, address));

        // transfer the shipment amount to the barn payback contract
        LibTransfer.sendToken(
            IERC20(s.sys.bean),
            shipmentAmount,
            barnPaybackContract,
            LibTransfer.To.EXTERNAL
        );

        // update the state of the barn payback contract to account for the newly received beans
        // Do not revert on failure to prevent sunrise from failing
        try IBarnPayback(barnPaybackContract).barnPaybackReceive(shipmentAmount) {
            // Confirm successful receipt.
            emit Receipt(ShipmentRecipient.BARN_PAYBACK, shipmentAmount, data);
        } catch {}
    }

    /**
     * @notice Receive Bean at the Silo Payback contract.
     * When the Silo Payback contract receives Bean, it needs to update:
     * - the total beans that have been sent to beanstalk unripe
     * - the reward accumulators for the unripe bdv tokens
     * @param shipmentAmount Amount of Bean to receive.
     * @param data ABI encoded address of the silo payback contract.
     */
    function siloPaybackReceive(uint256 shipmentAmount, bytes memory data) private {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // silo payback is the first parameter in the data
        (address siloPaybackContract, ) = abi.decode(data, (address, address));

        // transfer the shipment amount to the silo payback contract
        LibTransfer.sendToken(
            IERC20(s.sys.bean),
            shipmentAmount,
            siloPaybackContract,
            LibTransfer.To.EXTERNAL
        );

        // update the state of the silo payback contract to account for the newly received beans
        // Do not revert on failure to prevent sunrise from failing
        try ISiloPayback(siloPaybackContract).siloPaybackReceive(shipmentAmount) {
            // Confirm successful receipt.
            emit Receipt(ShipmentRecipient.SILO_PAYBACK, shipmentAmount, data);
        } catch {}
    }
}

/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {LibRedundantMath128} from "contracts/libraries/Math/LibRedundantMath128.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {BeanstalkFertilizer} from "./BeanstalkFertilizer.sol";

/**
 * @dev BarnPayback facilitates the payback of beanstalk fertilizer holders.
 * Inherits from BeanstalkFertilizer that contains a copy of the beanstalk ERC-1155 fertilizer implementation.
 * Instead of keeping the fertilizerstate in the main protocol storage all state is copied and initialized locally.
 * The BarnPayback contract is initialized using the state at the snapshot of Pinto's deployment and repays
 * beanstalk fertilizer holders with pinto until they all become inactive.
 */
contract BarnPayback is BeanstalkFertilizer {
    /**
     * @notice Contains per-account intialization data for Fertilizer.
     */
    struct AccountFertilizerData {
        address account;
        uint128 amount;
        uint128 lastBpf;
    }

    /**
     * @notice Fertilizers contains the ids, accounts, amounts, and lastBpf of each Fertilizer.
     * @dev fertilizerIds MUST be in ascending order.
     * Maps each fertilizer ID to an array of account data containing amounts and last BPF values
     */
    struct Fertilizers {
        uint128 fertilizerId;
        AccountFertilizerData[] accountData;
    }

    /// @dev modifier to ensure only the Pinto protocol can call the function
    modifier onlyPintoProtocol() {
        require(msg.sender == address(pintoProtocol), "BarnPayback: only pinto protocol");
        _;
    }

    //////////////////////////// Initialization ////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _pinto,
        address _pintoProtocol,
        InitSystemFertilizer calldata initSystemFert
    ) public override initializer {
        super.initialize(_pinto, _pintoProtocol, initSystemFert);
    }

    /**
     * @notice Batch mints fertilizers to all accounts and initializes balances.
     * @dev We skip contract addresses except for the distributor address that we know implements the ERC-1155Receiver standard.
     * @param fertilizerIds Array of fertilizer data containing ids, accounts, amounts, and lastBpf.
     */
    function mintFertilizers(Fertilizers[] calldata fertilizerIds) external onlyOwner {
        for (uint i; i < fertilizerIds.length; i++) {
            Fertilizers memory f = fertilizerIds[i];
            uint128 fid = f.fertilizerId;

            // Mint fertilizer to each holder
            for (uint j; j < f.accountData.length; j++) {
                address account = f.accountData[j].account;
                // Mint to non-contract accounts and the distributor address
                if (!isContract(account) || account == CONTRACT_DISTRIBUTOR_ADDRESS) {
                    _balances[fid][account].amount = f.accountData[j].amount;
                    _balances[fid][account].lastBpf = f.accountData[j].lastBpf;

                    // This line used to call beanstalkMint but amounts and balances are set directly here
                    // We also do not need to perform any checks since we are only minting once.
                    // After deployment, no more beanstalk fertilizers will be distributed
                    _safeMint(account, fid, f.accountData[j].amount, "");

                    emit TransferSingle(
                        msg.sender,
                        address(0),
                        account,
                        fid,
                        f.accountData[j].amount
                    );
                }
            }
        }
    }

    //////////////////////////// Barn Payback Functions ////////////////////////////

    /**
     * @notice Receive Beans at the Barn. Amount of Sprouts become Rinsible.
     * Copied from LibReceiving.barnReceive on the beanstalk protocol.
     * @dev Rounding here can cause up to fert.activeFertilizer / 1e6 Beans to be lost.
     * Currently there are 17,217,105 activeFertilizer. So up to 17.217 Beans can be lost.
     * @param shipmentAmount Amount of Beans to receive.
     */
    function barnPaybackReceive(uint256 shipmentAmount) external onlyPintoProtocol {
        uint256 amountToFertilize = shipmentAmount + fert.leftoverBeans;
        // Get the new Beans per Fertilizer and the total new Beans per Fertilizer
        // Zeroness of activeFertilizer handled in Planner.
        uint256 remainingBpf = amountToFertilize / fert.activeFertilizer;
        uint256 oldBpf = fert.bpf;
        uint256 newBpf = oldBpf + remainingBpf;
        // Get the end BPF of the first Fertilizer to run out.
        uint256 firstBpf = fert.fertFirst;
        uint256 deltaFertilized;
        // If the next fertilizer is going to run out, then step BPF according
        while (newBpf >= firstBpf) {
            // Increment the cumulative change in Fertilized.
            deltaFertilized += (firstBpf - oldBpf) * fert.activeFertilizer; // fertilizer between init and next cliff
            if (fertilizerPop()) {
                oldBpf = firstBpf;
                firstBpf = fert.fertFirst;
                // Calculate BPF beyond the first Fertilizer edge.
                remainingBpf = (amountToFertilize - deltaFertilized) / fert.activeFertilizer;
                newBpf = oldBpf + remainingBpf;
            } else {
                fert.bpf = uint128(firstBpf);
                fert.fertilizedIndex += deltaFertilized;
                // Else, if there is no more fertilizer. Matches plan cap.
                // fert.fertilizedIndex == fert.unfertilizedIndex
                break;
            }
        }
        // If there is Fertilizer remaining.
        if (fert.fertilizedIndex != fert.unfertilizedIndex) {
            // Distribute the rest of the Fertilized Beans
            fert.bpf = uint128(newBpf); // SafeCast unnecessary here.
            deltaFertilized += (remainingBpf * fert.activeFertilizer);
            fert.fertilizedIndex += deltaFertilized;
        }
        // There will be up to activeFertilizer Beans leftover Beans that are not fertilized.
        // These leftovers will be applied on future Fertilizer receipts.
        fert.leftoverBeans = amountToFertilize - deltaFertilized;
        emit BarnPaybackRewardsReceived(shipmentAmount);
    }

    //////////////////////////// Claiming Functions (Update) ////////////////////////////

    /**
     * @notice Allows users to claim their fertilized beans directly.
     * @param ids - an array of fertilizer ids to claim
     * @param mode - the balance to transfer Beans to; see {LibTransfer.To}
     */
    function claimFertilized(uint256[] memory ids, LibTransfer.To mode) external {
        uint256 amount = __update(msg.sender, ids, uint256(fert.bpf));
        if (amount > 0) {
            fert.fertilizedPaidIndex += amount;
            // Transfer the rewards to the recipient, pintos are streamed to the contract's external balance
            pintoProtocol.transferToken(pinto, msg.sender, amount, LibTransfer.From.EXTERNAL, mode);
        }
    }

    /**
     * @notice Called by the ShipmentPlanner contract to determine how many pinto to send to the barn payback contract
     * @return The amount of pinto remaining to be sent to the barn payback contract
     */
    function barnRemaining() external view returns (uint256) {
        return totalUnfertilizedBeans();
    }
}

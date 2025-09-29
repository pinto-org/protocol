/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {LibTransfer, BeanstalkFertilizer} from "./BeanstalkFertilizer.sol";
/**
 * @dev BarnPayback facilitates the payback of beanstalk fertilizer holders.
 * Inherits from BeanstalkFertilizer that contains a copy of the beanstalk ERC-1155 fertilizer implementation.
 * Instead of keeping the fertilizer state in the main protocol storage, all state is copied and initialized locally.
 * The BarnPayback contract is initialized using the state of Beanstalk at block 276160746 on Arbitrum and repays
 * beanstalk fertilizer holders until they all become inactive.
 */
contract BarnPayback is BeanstalkFertilizer {
    event BarnPaybackRewardsReceived(uint256 amount);

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
        address _contractDistributor,
        InitSystemFertilizer calldata initSystemFert
    ) public override initializer {
        super.initialize(_pinto, _pintoProtocol, _contractDistributor, initSystemFert);
    }

    /**
     * @notice Batch mints fertilizers to all accounts and initializes balances.
     * @dev We skip contract addresses except for the distributor address that we know implements the ERC-1155Receiver standard.
     * Contract addresses will be able to use the Distributor contract to claim their fertilizers.
     * @param fertilizerIds Array of fertilizer data containing ids, accounts, amounts, and lastBpf.
     */
    function mintFertilizers(Fertilizers[] calldata fertilizerIds) external onlyOwner {
        // cache the distributor address
        address distributor = contractDistributor;
        for (uint i; i < fertilizerIds.length; i++) {
            Fertilizers memory f = fertilizerIds[i];
            uint128 fid = f.fertilizerId;

            // Mint fertilizer to each holder
            for (uint j; j < f.accountData.length; j++) {
                address account = f.accountData[j].account;
                // Mint to non-contract accounts and the distributor address
                if (!isContract(account) || account == distributor) {
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
     * @param shipmentAmount Amount of Beans received from shipments.
     */
    function barnPaybackReceive(uint256 shipmentAmount) external onlyPintoProtocol {
        uint256 amountToFertilize = shipmentAmount + fert.leftoverBeans;
        // Get the new Beans per Fertilizer and the total new Beans per Fertilizer
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
        address account = _getBeanstalkFarmer();
        uint256 amount = __update(account, ids, uint256(fert.bpf));
        if (amount > 0) {
            fert.fertilizedPaidIndex += amount;
            // Transfer the rewards to the caller, pintos are streamed to the contract's external balance
            pintoProtocol.transferToken(
                pintoToken,
                account,
                amount,
                LibTransfer.From.EXTERNAL,
                mode
            );
        }
    }

    /**
     * @notice Called by the ShipmentPlanner contract to determine how many pinto tokens to send to the barn payback contract
     * @return The amount of pinto tokens remaining to be sent to the barn payback contract
     */
    function barnRemaining() external view returns (uint256) {
        return totalUnfertilizedBeans();
    }
}

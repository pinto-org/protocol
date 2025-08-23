// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICrossDomainMessenger} from "contracts/interfaces/ICrossDomainMessenger.sol";


interface IContractPaybackDistributor {
    function claimFromL1Message(
        address caller,
        address receiver
    ) external;
}

/**
 * @title L1ContractMessenger
 * @notice This contract can be used as a backup solution from smart contract accounts on Ethereum L1 that are
 * eligible for beanstalk repayment assets but are unable to claim their assets directly on Base.
 */
contract L1ContractMessenger {
    // Base Superchain messenger from Ethereum L1
    // (https://docs.base.org/base-chain/network-information/base-contracts#l1-contract-addresses)
    ICrossDomainMessenger public constant MESSENGER =
        ICrossDomainMessenger(0x866E82a600A1414e583f7F13623F1aC5d58b0Afa);
    // The address of the L2 ContractPaybackDistributor contract
    address public immutable L2_CONTRACT_PAYBACK_DISTRIBUTOR;

    uint32 public constant MAX_GAS_LIMIT = 32_000_000;

    // Contract addresses allowed to call the claimL2BeanstalkAssets function
    // To release their funds on the L2 from the L2 ContractPaybackDistributor contract
    mapping(address => bool) public isWhitelistedL1Caller;

    modifier onlyWhitelistedL1Caller() {
        require(
            isWhitelistedL1Caller[msg.sender],
            "L1ContractMessenger: Caller not whitelisted for claim"
        );
        _;
    }

    constructor(address _l2ContractPaybackDistributor, address[] memory _whitelistedL1Callers) {
        L2_CONTRACT_PAYBACK_DISTRIBUTOR = _l2ContractPaybackDistributor;
        // Whitelist the L1 callers
        for (uint256 i = 0; i < _whitelistedL1Callers.length; i++) {
            isWhitelistedL1Caller[_whitelistedL1Callers[i]] = true;
        }
    }

    /**
     * @notice Sends a message from the L1 to the L2 ContractPaybackDistributor contract
     * to claim the assets for a given L2 receiver address
     * @param l2Receiver The address to transfer the assets to on the L2
     * The gas limit is the max gas limit needed on the l2 with a 20% on top of that as buffer
     * From fork testing, all contract accounts claimed with a maximum of 26mil gas.
     * (https://docs.optimism.io/app-developers/bridging/messaging#basics-of-communication-between-layers)
     */
    function claimL2BeanstalkAssets(address l2Receiver) public onlyWhitelistedL1Caller {
        MESSENGER.sendMessage(
            L2_CONTRACT_PAYBACK_DISTRIBUTOR, // target
            abi.encodeCall(IContractPaybackDistributor.claimFromL1Message, (msg.sender, l2Receiver)), // message
            MAX_GAS_LIMIT // gas limit
        );
    }
}

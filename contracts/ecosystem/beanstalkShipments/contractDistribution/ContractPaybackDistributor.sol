// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {IBarnPayback} from "contracts/interfaces/IBarnPayback.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICrossDomainMessenger} from "contracts/interfaces/ICrossDomainMessenger.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ContractPaybackDistributor
 * @notice Contract that distributes the beanstalk repayment assets to the contract accounts.
 * After the distribution, this contract will custody and distrubute all assets for all eligible contract accounts.
 *
 * Contract accounts eligible for Beanstalk repayment assets can either:
 *
 * 1. Deploy their contracts on the same address as in Ethereum L1 using the following methods:
 *    - For safe multisigs with version >1.3.0 , deploy their safe from the official UI
 *        (https://help.safe.global/en/articles/222612-deploying-a-multi-chain-safe)
 *    - For regular contracts, deploy using the same deployer nonce as on L1 to replicate their address on Base
 *         (https://github.com/pinto-org/beanstalkContractRedeployer)
 *    - For amibre wallets just perform a transaction on Base to activate their account
 *   Once their address is replicated they can just call claimDirect() and receive their assets.
 *
 * 2. Send a cross chain message from Ethereum L1 using the cross chain messenger that when
 *    received, calls claimFromMessage and receive their assets in an address of their choice
 *
 * 3. If an account has just delegated its code to a contract, they can just call claimDirect() and receive their assets.
 */
contract ContractPaybackDistributor is ReentrancyGuard, Ownable, IERC1155Receiver {
    using SafeERC20 for IERC20;

    // Repayment field id
    uint256 public constant REPAYMENT_FIELD_ID = 1;

    // L2 messenger on the Superchain
    ICrossDomainMessenger public constant MESSENGER =
        ICrossDomainMessenger(0x4200000000000000000000000000000000000007);

    // L1 sender: the contract address that sent the claim message from the L1
    address public constant L1_SENDER = 0x51f472874a303D5262d7668f5a3d17e3317f8E51;

    struct AccountData {
        bool whitelisted;
        bool claimed;
        uint256 siloPaybackTokensOwed;
        uint256[] fertilizerIds;
        uint256[] fertilizerAmounts;
        uint256[] plotIds;
        uint256[] plotEnds;
    }

    /// @dev contains all the data for all the contract accounts
    mapping(address => AccountData) public accounts;

    // Beanstalk protocol
    IBeanstalk immutable pintoProtocol;
    // Silo payback token
    IERC20 immutable siloPayback;
    // Barn payback token
    IBarnPayback immutable barnPayback;

    modifier onlyWhitelistedCaller(address caller) {
        require(
            accounts[caller].whitelisted,
            "ContractPaybackDistributor: Caller not whitelisted for claim"
        );
        _;
    }

    modifier onlyL1Messenger() {
        require(
            msg.sender == address(MESSENGER),
            "ContractPaybackDistributor: Caller not L1 messenger"
        );
        require(
            MESSENGER.xDomainMessageSender() == L1_SENDER,
            "ContractPaybackDistributor: Bad origin"
        );
        _;
    }

    modifier isValidReceiver(address receiver) {
        require(receiver != address(0), "ContractPaybackDistributor: Invalid receiver address");
        _;
    }

    /**
     * @param _pintoProtocol The pinto protocol address
     * @param _siloPayback The silo payback token address
     * @param _barnPayback The barn payback token address
     */
    constructor(
        address _pintoProtocol,
        address _siloPayback,
        address _barnPayback
    ) Ownable(msg.sender) {
        pintoProtocol = IBeanstalk(_pintoProtocol);
        siloPayback = IERC20(_siloPayback);
        barnPayback = IBarnPayback(_barnPayback);
    }

    /**
     * @notice Initializes the claimable assets for the contract accounts
     * @param _contractAccounts The contract account addresses to whitelist
     * @param _accountsData The account data for the contract accounts to whitelist
     */
    function initializeAccountData(
        address[] memory _contractAccounts,
        AccountData[] memory _accountsData
    ) external onlyOwner {
        require(_contractAccounts.length == _accountsData.length, "Init Array length mismatch");
        for (uint256 i = 0; i < _contractAccounts.length; i++) {
            require(_contractAccounts[i] != address(0), "Invalid contract account address");
            accounts[_contractAccounts[i]] = _accountsData[i];
        }
    }

    /**
     * @notice Allows a contract account to claim their beanstalk repayment assets directly to a receiver.
     * @param receiver The address to transfer the assets to
     */
    function claimDirect(
        address receiver
    ) external nonReentrant onlyWhitelistedCaller(msg.sender) isValidReceiver(receiver) {
        AccountData storage account = accounts[msg.sender];
        require(!account.claimed, "ContractPaybackDistributor: Caller already claimed");

        account.claimed = true;
        _transferAllAssetsForAccount(msg.sender, receiver);
    }

    /**
     * @notice Receives a message from the l1 messenger and distrubutes all assets to a receiver.
     * @param caller The address of the caller on the l1. (The encoded msg.sender in the message)
     * @param receiver The address to transfer all the assets to.
     */
    function claimFromL1Message(
        address caller,
        address receiver
    ) public nonReentrant onlyL1Messenger onlyWhitelistedCaller(caller) isValidReceiver(receiver) {
        AccountData storage account = accounts[caller];
        require(!account.claimed, "ContractPaybackDistributor: Caller already claimed");
        account.claimed = true;
        _transferAllAssetsForAccount(caller, receiver);
    }

    /**
     * @notice Transfers all assets for a whitelisted contract account to a receiver
     * note: if the receiver is a contract it must implement the ERC1155Receiver interface
     * @param account The address of the account to claim from
     * @param receiver The address to transfer the assets to
     */
    function _transferAllAssetsForAccount(address account, address receiver) internal {
        AccountData memory accountData = accounts[account];

        // transfer silo payback tokens to the receiver
        if (accountData.siloPaybackTokensOwed > 0) {
            siloPayback.safeTransfer(receiver, accountData.siloPaybackTokensOwed);
        }

        // transfer fertilizer ERC1155s to the receiver
        if (accountData.fertilizerIds.length > 0) {
            barnPayback.safeBatchTransferFrom(
                address(this),
                receiver,
                accountData.fertilizerIds,
                accountData.fertilizerAmounts,
                ""
            );
        }

        // transfer the plots to the receiver
        // make an empty array of plotStarts since all plot transfers start from the beginning of the plot
        uint256[] memory plotStarts = new uint256[](accountData.plotIds.length);
        if (accountData.plotIds.length > 0) {
            pintoProtocol.transferPlots(
                address(this),
                receiver,
                REPAYMENT_FIELD_ID,
                accountData.plotIds,
                plotStarts,
                accountData.plotEnds
            );
        }
    }

    //////////////////////////// ERC1155Receiver ////////////////////////////

    /**
     * @dev ERC-1155 hook allowing this contract to receive a single fertilizer from the barn payback contract
     */
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @dev ERC-1155 hook allowing this contract to receive a batch of fertilizers from the barn payback contract
     */
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @dev ERC-1155 compliance function to indicate that this contract implements the IERC1155Receiver interface
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}

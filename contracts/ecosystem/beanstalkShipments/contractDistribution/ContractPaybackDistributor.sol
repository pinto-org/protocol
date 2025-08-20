// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {Season} from "contracts/beanstalk/storage/System.sol";
import {IBudget} from "contracts/interfaces/IBudget.sol";
import {ISiloPayback} from "contracts/interfaces/ISiloPayback.sol";
import {IBarnPayback} from "contracts/interfaces/IBarnPayback.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
 *    - For amibre wallets just perform a transaction on Base to activate their account
 *   Once their address is replicated they can just call claimDirect() and receive their assets.
 *
 * 2. Send a cross chain message from Ethereum L1 using the cross chain messenger that when
 *    received, calls claimFromMessage and receive their assets in an address of their choice
 *
 */
contract ContractPaybackDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct AccountFertilizerClaimData {
        address contractAccount;
        uint256[] fertilizerIds;
        uint256[] fertilizerAmounts;
    }

    struct AccountPlotClaimData {
        address contractAccount;
        uint256 fieldId;
        uint256[] ids;
        uint256[] starts;
        uint256[] ends;
    }

    /// @dev whitelisted contract accounts
    mapping(address contractAccount => bool whitelisted) public isWhitelisted;
    /// @dev keep track of which contracts have claimed
    mapping(address contractAccount => bool hasClaimed) public claimed;
    /// @dev keep track of how many silo payback tokens are owed to each whitelisted contract
    mapping(address contractAccount => uint256 siloPaybackTokensOwed) public siloPaybackTokensOwed;
    /// @dev keep track of which fertilizer tokens are owed to each whitelisted contract
    mapping(address contractAccount => AccountFertilizerClaimData) public accountFertilizer;
    /// @dev keep track of which plots are owed to each whitelisted contract
    mapping(address contractAccount => AccountPlotClaimData) public accountPlots;

    IBeanstalk immutable pintoProtocol;
    IERC20 immutable siloPayback;
    IBarnPayback immutable barnPayback;

    /**
     * @param _contractAccounts The contract accounts that are allowed to claim
     * @param _siloPaybackTokensOwed The amount of silo payback tokens owed to each contract
     * @param _fertilizerClaims The fertilizer claims for each contract
     * @param _plotClaims The plot claims for each contract
     * @param _pintoProtocol The pinto protocol address
     * @param _siloPayback The silo payback contract address
     * @param _barnPayback The barn payback contract address
     */
    constructor(
        address[] memory _contractAccounts,
        uint256[] memory _siloPaybackTokensOwed,
        AccountFertilizerClaimData[] memory _fertilizerClaims,
        AccountPlotClaimData[] memory _plotClaims,
        address _pintoProtocol,
        address _siloPayback,
        address _barnPayback
    ) {
        // whitelist the contract accounts and set their claims
        for (uint256 i = 0; i < _contractAccounts.length; i++) {
            isWhitelisted[_contractAccounts[i]] = true;
            siloPaybackTokensOwed[_contractAccounts[i]] = _siloPaybackTokensOwed[i];
            accountFertilizer[_contractAccounts[i]] = _fertilizerClaims[i];
            accountPlots[_contractAccounts[i]] = _plotClaims[i];
        }
        pintoProtocol = IBeanstalk(_pintoProtocol);
        siloPayback = IERC20(_siloPayback);
        barnPayback = IBarnPayback(_barnPayback);
    }

    /**
     * @notice Allows a contract account to claim their beanstalk repayment assets directly.
     * @param receiver The address to transfer the assets to
     */
    function claimDirect(address receiver) external nonReentrant {
        require(
            isWhitelisted[msg.sender],
            "ContractPaybackDistributor: Caller not whitelisted for claim"
        );
        require(!claimed[msg.sender], "ContractPaybackDistributor: Caller already claimed");

        // mark the caller as claimed
        claimed[msg.sender] = true;

        _transferAllAssetsForAccount(msg.sender, receiver);
    }

    // receives a message from the l1 and distrubutes all assets.
    function claimFromMessage(bytes memory message) public nonReentrant {
        // todo: decode message, verify and send assets.

        require(
            isWhitelisted[msg.sender],
            "ContractPaybackDistributor: Caller not whitelisted for claim"
        );
        require(!claimed[msg.sender], "ContractPaybackDistributor: Caller already claimed");
        claimed[msg.sender] = true;

        address receiver = abi.decode(message, (address));
        // _transferAllAssetsForAccount(msg.sender, receiver);
    }

    /**
     * @notice Transfers all assets for a whitelisted contract account to a receiver
     * @dev note: if the receiver is a contract it must implement the IERC1155Receiver interface
     * @param account The address of the account to claim from
     * @param receiver The address to transfer the assets to
     */
    function _transferAllAssetsForAccount(address account, address receiver) internal {
        // get the amount of silo payback tokens owed to the contract account
        uint256 claimableSiloPaybackTokens = siloPaybackTokensOwed[account];

        // get the amount of fertilizer tokens owed to the contract account
        uint256[] memory fertilizerIds = accountFertilizer[account].fertilizerIds;
        uint256[] memory fertilizerAmounts = accountFertilizer[account].fertilizerAmounts;

        // get the amount of plots owed to the contract account
        uint256 fieldId = accountPlots[account].fieldId;
        uint256[] memory plotIds = accountPlots[account].ids;
        uint256[] memory starts = accountPlots[account].starts;
        uint256[] memory ends = accountPlots[account].ends;

        // transfer silo payback tokens to the contract account
        if (claimableSiloPaybackTokens > 0) {
            siloPayback.safeTransfer(receiver, claimableSiloPaybackTokens);
        }

        // transfer fertilizer erc115s to the contract account
        if (fertilizerIds.length > 0) {
            barnPayback.safeBatchTransferFrom(
                address(this),
                receiver,
                fertilizerIds,
                fertilizerAmounts,
                ""
            );
        }

        // transfer the plots to the receiver
        // todo: very unlikely but need to test with
        // 0xBc7c5f21C632c5C7CA1Bfde7CBFf96254847d997 that has a ton of plots
        // to make sure gas is not an issue
        if (plotIds.length > 0) {
            pintoProtocol.transferPlots(address(this), receiver, fieldId, plotIds, starts, ends);
        }
    }
}

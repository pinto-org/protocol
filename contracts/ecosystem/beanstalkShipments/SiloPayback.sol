// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TractorEnabled} from "contracts/ecosystem/TractorEnabled.sol";

/**
 * @title SiloPayback
 * @notice SiloPayback is an ERC20 representation of Unripe BDV in Beanstalk calculated as if Beanstalk was fully recapitalized.
 * It facilitates the payback of unripe holders by allowing them to claim pinto rewards after the 1 billion supply threshold.
 * Tokens are initially distributed and yield gets continuously accrued every time new Pinto supply is minted,
 * until all unripe tokens are worth exactly 1 Pinto underlying.
 */
contract SiloPayback is Initializable, ERC20Upgradeable, OwnableUpgradeable, TractorEnabled {
    /// @dev precision used for reward calculations
    uint256 public constant PRECISION = 1e18;

    struct UnripeBdvTokenData {
        address receipient;
        uint256 bdv;
    }

    IERC20 public pinto;

    /// @dev Tracks total distributed bdv tokens. After initial mint, no more tokens can be distributed.
    uint128 public totalDistributed;
    /// @dev Tracks total received pinto from shipments.
    uint128 public totalReceived;

    // Rewards
    /// @dev Global accumulator tracking total rewards per token since contract inception (scaled by 1e18)
    uint256 public rewardPerTokenStored;
    /// @dev Per-user checkpoint of rewardPerTokenStored at their last reward update to prevent double claiming
    mapping(address => uint256) public userRewardPerTokenPaid;
    /// @dev Per-user accumulated rewards ready to claim (updated on transfers/claims)
    mapping(address => uint256) public rewards;

    // Events
    event SiloPaybackRewardsClaimed(
        address indexed account,
        address indexed recipient,
        uint256 amount,
        LibTransfer.To toMode
    );
    event SiloPaybackRewardsReceived(uint256 amount, uint256 newRewardsIndex);
    event UnripeBdvTokenMinted(address indexed receipient, uint256 amount);

    // Modifiers
    modifier onlyPintoProtocol() {
        require(msg.sender == address(pintoProtocol), "SiloPayback: only pinto protocol");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _pinto, address _pintoProtocol) public initializer {
        __ERC20_init("UnripeBdvToken", "urBDV");
        __Ownable_init(msg.sender);
        pinto = IERC20(_pinto);
        pintoProtocol = IBeanstalk(_pintoProtocol);
        // Approve the Pinto Diamond to spend pinto tokens for transfers
        pinto.approve(_pintoProtocol, type(uint256).max);
    }

    /**
     * @notice Distribute unripe bdv tokens to the old beanstalk participants.
     * Called in batches after deployment to make sure we don't run out of gas.
     * @dev After distribution is complete "totalDistributed" will reflect the required pinto
     * amount to pay off unripe.
     * @param unripeReceipts Array of UnripeBdvTokenData
     */
    function batchMint(UnripeBdvTokenData[] memory unripeReceipts) external onlyOwner {
        for (uint256 i = 0; i < unripeReceipts.length; i++) {
            _mint(unripeReceipts[i].receipient, unripeReceipts[i].bdv);
            totalDistributed += uint128(unripeReceipts[i].bdv);
            emit UnripeBdvTokenMinted(unripeReceipts[i].receipient, unripeReceipts[i].bdv);
        }
    }

    /**
     * @notice Receives Pinto rewards from shipments
     * Updates the global reward accumulator and the total amount of Pinto received
     * @dev Called by LibReceiving to update the state of the Silo Payback contract
     * @param shipmentAmount The amount of Pinto rewards received
     */
    function siloPaybackReceive(uint256 shipmentAmount) external onlyPintoProtocol {
        rewardPerTokenStored += (shipmentAmount * PRECISION) / totalSupply();
        totalReceived += uint128(shipmentAmount);
        emit SiloPaybackRewardsReceived(shipmentAmount, rewardPerTokenStored);
    }

    /////////////////// Claiming rewards ///////////////////

    /**
     * @notice Claims accumulated rewards for an account and sends them to a recipient's external or internal balance
     * If no active tractor execution, the caller is msg.sender. Otherwise it is the active blueprint publisher
     * @param recipient The address to send the rewards to
     * @param toMode The mode to send the rewards in
     */
    function claim(address recipient, LibTransfer.To toMode) external {
        address account = _getBeanstalkFarmer();
        uint256 userCombinedBalance = getBalanceCombined(account);

        // Validate balance
        require(userCombinedBalance > 0, "SiloPayback: token balance must be greater than 0");

        // Update the reward state for the account
        uint256 rewardsToClaim = _updateReward(account);
        require(rewardsToClaim > 0, "SiloPayback: no rewards to claim");
        rewards[account] = 0;

        // Transfer the rewards to the recipient
        pintoProtocol.transferToken(
            pinto,
            recipient,
            rewardsToClaim,
            LibTransfer.From.EXTERNAL,
            toMode
        );

        emit SiloPaybackRewardsClaimed(account, recipient, rewardsToClaim, toMode);
    }

    /**
     * @notice Updates the reward state for an account before a claim
     * @param account The account to update the reward state for
     */
    function _updateReward(address account) internal returns (uint256) {
        if (account == address(0)) return 0;
        uint256 earnedRewards = earned(account);
        rewards[account] = earnedRewards;
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        return earnedRewards;
    }

    /**
     * @notice Gets the balance of an account
     * @param account The account to get the balance of UnripeBDV tokens for
     * @param mode The mode where the user's tokens are stored (EXTERNAL or INTERNAL)
     */
    function getBalanceInMode(
        address account,
        LibTransfer.From mode
    ) public view returns (uint256) {
        return
            mode == LibTransfer.From.EXTERNAL
                ? balanceOf(account)
                : pintoProtocol.getInternalBalance(account, address(this));
    }

    /**
     * @notice Gets the combined balance of an account from both EXTERNAL and INTERNAL modes
     * Used to calculate the total balance of the account for claiming rewards
     */
    function getBalanceCombined(address account) public view returns (uint256) {
        return
            getBalanceInMode(account, LibTransfer.From.EXTERNAL) +
            getBalanceInMode(account, LibTransfer.From.INTERNAL);
    }

    /**
     * @notice Calculate earned rewards for an account of their combined balance
     * @dev Calculates the pro-rata share of rewards based on the delta between rewardPerTokenStored
     * and userRewardPerTokenPaid.
     * ------------------------------------------------------------
     * - `rewardPerTokenStored` represents the cumulative ratio of total rewards to total tokens,
     *    which monotonically increases since tokens cannot be burned and totalSupply is fixed.
     * - `userRewardPerTokenPaid` is the checkpoint of rewardPerTokenStored at the last reward update.
     * - `rewards` is the accumulated rewards of the user ready to claim.
     * - `rewardPerTokenStored` can be at most 1e18 * totalSupply() since distribution is capped.
     * ------------------------------------------------------------
     * @param account The account to calculate rewards for
     * @return The total earned rewards for the account
     */
    function earned(address account) public view returns (uint256) {
        return
            ((getBalanceCombined(account) *
                (rewardPerTokenStored - userRewardPerTokenPaid[account])) / PRECISION) +
            rewards[account];
    }

    /**
     * @notice Returns the remaining amount of pinto required to pay off the unripe bdv tokens
     * Called by the shipment planner to calculate the amount of pinto to ship as underlying rewards.
     * When rewards per token reach 1 then all unripe bdv tokens will be paid off.
     */
    function siloRemaining() public view returns (uint256) {
        return totalDistributed - totalReceived;
    }

    /////////////////// Transfer Hook ///////////////////

    /**
     * @notice Pre-transfer hook to update rewards for both sender and receiver
     * The result is that token balances change, but both parties have been
     * "checkpointed" to prevent any reward manipulation through transfers.
     * Claims happen only when the user decides to claim.
     * This way all claims can also happen in the internal balance.
     * @param from The address of the sender
     * @param to The address of the receiver
     * @param amount The amount of tokens being transferred. (Unused here but required by openzeppelin)
     */
    function _update(address from, address to, uint256 amount) internal override {
        _updateReward(from);
        _updateReward(to);
        super._update(from, to, amount);
    }

    /**
     * @notice External variant of the pre-transfer hook.
     * Updates reward state when transferring between internal balances from inside the protocol.
     * We don't need to call super._update here since we don't update the token balance mappings in internal transfers.
     * @param from The address of the sender
     * @param to The address of the receiver
     * @param amount The amount of tokens being transferred
     */
    function protocolUpdate(address from, address to, uint256 amount) external onlyPintoProtocol {
        _updateReward(from);
        _updateReward(to);
    }

    /**
     * @dev override the decimals to 6 decimal places, BDV has 6 decimals
     */
    function decimals() public view override returns (uint8) {
        return 6;
    }
}

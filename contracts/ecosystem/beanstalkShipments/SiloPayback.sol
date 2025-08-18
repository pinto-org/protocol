// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract SiloPayback is Initializable, ERC20Upgradeable, OwnableUpgradeable {
    /// @dev precision used for reward calculations
    uint256 public constant PRECISION = 1e18;

    /// @dev struct to store the unripe bdv token data for batch minting
    struct UnripeBdvTokenData {
        address receipient;
        uint256 bdv;
    }

    /// @dev External contracts for interactions with the Pinto protocol
    IBeanstalk public pintoProtocol;
    IERC20 public pinto;

    /// @dev Tracks total distributed bdv tokens. After initial mint, no more tokens can be distributed.
    uint256 public totalDistributed;
    /// @dev Tracks total received pinto from shipments.
    uint256 public totalReceived;

    /// @dev Global accumulator tracking total rewards per token since contract inception (scaled by 1e18)
    uint256 public rewardPerTokenStored;
    /// @dev Per-user checkpoint of rewardPerTokenStored at their last reward update to prevent double claiming
    mapping(address => uint256) public userRewardPerTokenPaid;
    /// @dev Per-user accumulated rewards ready to claim (updated on transfers/claims)
    mapping(address => uint256) public rewards;

    /// @dev event emitted when user claims rewards
    event Claimed(address indexed user, uint256 amount, uint256 rewards);
    /// @dev event emitted when rewards are received from shipments
    event SiloPaybackRewardsReceived(uint256 amount, uint256 newIndex);

    /// @dev modifier to ensure only the Pinto protocol can call the function
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
            totalDistributed += unripeReceipts[i].bdv;
        }
    }

    /**
     * @notice Receives Pinto rewards from shipments
     * Updates the global reward accumulator and the total amount of Pinto received
     * @dev Called by LibReceiving to update the state of the Silo Payback contract
     * @param shipmentAmount The amount of Pinto rewards received
     */
    function siloPaybackReceive(uint256 shipmentAmount) external onlyPintoProtocol {
        uint256 tokenTotalSupply = totalSupply();
        if (tokenTotalSupply > 0) {
            rewardPerTokenStored += (shipmentAmount * PRECISION) / tokenTotalSupply;
            totalReceived += shipmentAmount;
        }

        emit SiloPaybackRewardsReceived(shipmentAmount, rewardPerTokenStored);
    }

    /////////////////// Claiming rewards ///////////////////

    /**
     * @notice Claims accumulated rewards for the caller, optionally for a specific token amount
     * If no active tractor execution, the caller is msg.sender.
     * Otherwise it is the active blueprint publisher
     * By specifying the token amount to claim for, users can partially claim using tokens from their internal
     * balance without actually specfifying a mode where the rewards are stored.
     * @param tokenAmount The amount of tokens to claim rewards for (0 to claim for the entire balance)
     * @param recipient The address to send the rewards to
     * @param toMode The mode to send the rewards in
     */
    function claim(uint256 tokenAmount, address recipient, LibTransfer.To toMode) external {
        address account = _getActiveAccount();
        uint256 userCombinedBalance = getBalanceCombined(account);

        // If tokenAmount is 0, claim for all tokens
        if (tokenAmount == 0) tokenAmount = userCombinedBalance;

        // Validate tokenAmount and balance
        require(tokenAmount > 0, "SiloPayback: tokenAmount to claim for must be greater than 0");
        require(userCombinedBalance > 0, "SiloPayback: token balance must be greater than 0");
        require(
            tokenAmount <= userCombinedBalance,
            "SiloPayback: tokenAmount to claim for exceeds balance"
        );

        // update the reward state for the account
        _updateReward(account);
        uint256 totalEarned = rewards[account];
        require(totalEarned > 0, "SiloPayback: no rewards to claim");

        uint256 rewardsToClaim;
        if (tokenAmount == userCombinedBalance) {
            // full balance claim, reset rewards to 0
            rewardsToClaim = totalEarned;
            rewards[account] = 0;
        } else {
            // partial claim, rewards are proportional to the token amount specified
            rewardsToClaim = (totalEarned * tokenAmount) / userCombinedBalance;
            // update rewards to reflect the portion claimed
            // maintains consistency since the user's checkpoint remains valid
            rewards[account] = totalEarned - rewardsToClaim;
        }

        // Transfer the rewards to the recipient
        pintoProtocol.transferToken(
            pinto,
            recipient,
            rewardsToClaim,
            LibTransfer.From.EXTERNAL,
            toMode
        );

        emit Claimed(account, tokenAmount, rewardsToClaim);
    }

    /**
     * @notice Updates the reward state for an account before a claim
     * @param account The account to update the reward state for
     */
    function _updateReward(address account) internal {
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    /**
     * @notice Gets the active account from the diamond tractor storage
     * The account returned is either msg.sender or an active publisher
     * Since msg.sender for the external call is this contract, we need to adjust
     * it to the actual function caller
     */
    function _getActiveAccount() internal view returns (address) {
        address tractorAccount = pintoProtocol.tractorUser();
        return tractorAccount == address(this) ? msg.sender : tractorAccount;
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

    /// @dev get the remaining amount of silo payback tokens to be distributed, called by the planner
    function siloRemaining() public view returns (uint256) {
        return totalDistributed - totalReceived;
    }

    /////////////////// Transfer Hook and ERC20 overrides ///////////////////

    /**
     * @notice pre transfer hook to update rewards for both sender and receiver
     * The result is that token balances change, but both parties have been
     * "checkpointed" to prevent any reward manipulation through transfers.
     * Claims happen only when the user decides to claim.
     * This way all claims can also happen in the internal balance.
     * @param from The address of the sender
     * @param to The address of the receiver
     */
    function _beforeTokenTransfer(address from, address to) internal {
        if (from != address(0)) {
            // capture any existing rewards for the sender, update their checkpoint to current global state
            rewards[from] = earned(from);
            userRewardPerTokenPaid[from] = rewardPerTokenStored;
        }

        if (to != address(0)) {
            // capture any existing rewards for the receiver, update their checkpoint to current global state
            rewards[to] = earned(to);
            userRewardPerTokenPaid[to] = rewardPerTokenStored;
        }
    }

    /// @dev override the standard transfer function to update rewards
    function transfer(address to, uint256 amount) public override returns (bool) {
        _beforeTokenTransfer(msg.sender, to);
        return super.transfer(to, amount);
    }

    /// @dev override the standard transferFrom function to update rewards
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _beforeTokenTransfer(from, to);
        return super.transferFrom(from, to, amount);
    }

    /// @dev override the decimals to 6 decimal places, BDV has 6 decimals
    function decimals() public view override returns (uint8) {
        return 6;
    }
}

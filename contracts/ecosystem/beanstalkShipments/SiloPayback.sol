// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalkWellFunction} from "contracts/interfaces/basin/IBeanstalkWellFunction.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract SiloPayback is Initializable, ERC20Upgradeable, OwnableUpgradeable {
    struct UnripeBdvTokenData {
        address receipient;
        uint256 bdv;
    }

    /// @dev the Pinto Diamond contract
    IBeanstalk public pintoProtocol;
    /// @dev the Pinto token
    IERC20 public pinto;

    /// @dev Tracks total distributed bdv tokens. After initial mint, no more tokens can be distributed.
    uint256 public totalDistributed;
    /// @dev Tracks total received pinto from shipments.
    uint256 public totalReceived;

    /// @dev Synthetix-style reward distribution variables
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    /// @dev event emitted when user redeems bdv tokens for underlying pinto
    event Redeemed(address indexed user, uint256 unripeBdvAmount, uint256 underlyingPintoAmount);
    /// @dev event emitted when user claims rewards
    event Claimed(address indexed user, uint256 amount, uint256 rewards);
    /// @dev event emitted when rewards are received from shipments
    event RewardsReceived(uint256 amount, uint256 newIndex);

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
     * @notice Claims accumulated rewards for the caller
     * @param recipient the address to send the rewards to
     * @param toMode the mode to send the rewards in
     */
    function claim(address recipient, LibTransfer.To toMode) external updateReward(msg.sender) {
        uint256 rewardsToClaim = rewards[msg.sender];
        require(rewardsToClaim > 0, "SiloPayback: no rewards to claim");
        
        rewards[msg.sender] = 0;
        
        // Transfer the rewards to the recipient
        pintoProtocol.transferToken(
            pinto,
            recipient,
            rewardsToClaim,
            LibTransfer.From.EXTERNAL,
            toMode
        );
        
        emit Claimed(msg.sender, rewardsToClaim, rewardsToClaim);
    }


    /// @notice Modifier to update rewards for an account
    /// @param account The account to update rewards for
    modifier updateReward(address account) {
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /// @notice Calculate earned rewards for an account.
    /// The pro-rata delta between the current rewardPerTokenStored and the user's userRewardPerTokenPaid
    /// rewardPerTokenStored is the ratio of the total amount of rewards received to the total amount of tokens distributed.
    /// Since tokens cannot be burned, this will only increase over time.
    /// @param account The account to calculate rewards for
    /// @return The total earned rewards
    function earned(address account) public view returns (uint256) {
        return ((balanceOf(account) * (rewardPerTokenStored - userRewardPerTokenPaid[account])) / 1e18) + rewards[account];
    }

    /// @dev override the decimals to 6 decimal places, BDV has 6 decimals
    function decimals() public view override returns (uint8) {
        return 6;
    }

    /// @dev view function to get the remaining amount of silo payback tokens to be distributed
    function siloRemaining() public view returns (uint256) {
        return totalDistributed - totalReceived;
    }

    /**
     * @notice Receives Bean rewards from Beanstalk shipments
     * @dev Called by the Beanstalk protocol to distribute rewards
     * @param amount The amount of Bean rewards received
     */
    function receiveRewards(uint256 amount) external {
        require(msg.sender == address(pintoProtocol), "SiloPayback: only pinto protocol");
        require(amount > 0, "SiloPayback: amount must be greater than 0");
        
        uint256 tokenTotalSupply = totalSupply();
        if (tokenTotalSupply > 0) {
            rewardPerTokenStored += (amount * 1e18) / tokenTotalSupply;
            totalReceived += amount;
        }
        
        emit RewardsReceived(amount, rewardPerTokenStored);
    }

    /**
     * @notice View function to calculate pending rewards for a user
     * @param user The address to check pending rewards for
     * @return The amount of pending rewards
     */
    function pendingRewards(address user) external view returns (uint256) {
        return earned(user);
    }

    /**
     * @notice View function to get the total amount of rewards distributed
     * @return The total rewards distributed since inception
     */
    function totalRewardsDistributed() external view returns (uint256) {
        return (rewardPerTokenStored * totalSupply()) / 1e18;
    }

    /////////////////// Transfer Hooks ///////////////////

    /// @dev pre transfer hook to update rewards for both sender and receiver
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        // Update rewards for both sender and receiver to prevent gaming
        if (from != address(0)) {
            rewards[from] = earned(from);
            userRewardPerTokenPaid[from] = rewardPerTokenStored;
        }
        if (to != address(0)) {
            rewards[to] = earned(to);
            userRewardPerTokenPaid[to] = rewardPerTokenStored;
        }
    }

    /// @dev need to override the transfer function to update rewards
    function transfer(address to, uint256 amount) public override returns (bool) {
        _beforeTokenTransfer(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    /// @dev need to override the transferFrom function to update rewards
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        _beforeTokenTransfer(from, to, amount);
        return super.transferFrom(from, to, amount);
    }
}

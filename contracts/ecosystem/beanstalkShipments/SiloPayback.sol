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
    /// @dev struct to store the unripe bdv token data for batch minting
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

    /// @dev Global accumulator tracking total rewards per token since contract inception (scaled by 1e18)
    uint256 public rewardPerTokenStored;
    /// @dev Per-user checkpoint of rewardPerTokenStored at their last reward update (prevents double claiming)
    mapping(address => uint256) public userRewardPerTokenPaid;
    /// @dev Per-user accumulated rewards ready to claim (updated on transfers/claims)
    mapping(address => uint256) public rewards;

    /// @dev event emitted when user claims rewards
    event Claimed(address indexed user, uint256 amount, uint256 rewards);
    /// @dev event emitted when rewards are received from shipments
    event RewardsReceived(uint256 amount, uint256 newIndex);

    /// @notice Modifier to update rewards for an account before a claim
    modifier updateReward(address account) {
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
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
     * @dev Called by the protocol to distribute rewards and update state
     * @param amount The amount of Pinto rewards received
     */
    function receiveRewards(uint256 amount) external {
        require(msg.sender == address(pintoProtocol), "SiloPayback: only pinto protocol");
        require(amount > 0, "SiloPayback: shipment amount must be greater than 0");

        uint256 tokenTotalSupply = totalSupply();
        if (tokenTotalSupply > 0) {
            rewardPerTokenStored += (amount * 1e18) / tokenTotalSupply;
            totalReceived += amount;
        }

        emit RewardsReceived(amount, rewardPerTokenStored);
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

    /**
     * @notice Calculate earned rewards for an account
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
            ((balanceOf(account) * (rewardPerTokenStored - userRewardPerTokenPaid[account])) /
                1e18) + rewards[account];
    }

    /// @dev get the remaining amount of silo payback tokens to be distributed, called by the planner
    function siloRemaining() public view returns (uint256) {
        return totalDistributed - totalReceived;
    }

    /////////////////// Transfer Hook and ERC20 overrides ///////////////////

    /// @dev pre transfer hook to update rewards for both sender and receiver
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal {
        
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

        // result: token balances change, but both parties have been
        // "checkpointed" to prevent any reward manipulation through transfers
        // claims happen when the users decide to claim. 
        // This way all claims can also happen in the internal balance.
    }

    /// @dev override the standard transfer function to update rewards
    function transfer(address to, uint256 amount) public override returns (bool) {
        _beforeTokenTransfer(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    /// @dev override the standard transferFrom function to update rewards
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _beforeTokenTransfer(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    /// @dev override the decimals to 6 decimal places, BDV has 6 decimals
    function decimals() public view override returns (uint8) {
        return 6;
    }
}

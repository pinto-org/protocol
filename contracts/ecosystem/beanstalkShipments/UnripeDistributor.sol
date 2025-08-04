// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalkWellFunction} from "contracts/interfaces/basin/IBeanstalkWellFunction.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract UnripeDistributor is Initializable, ERC20Upgradeable, OwnableUpgradeable {
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

    /// @dev event emitted when user redeems bdv tokens for underlying pinto
    event Redeemed(address indexed user, uint256 unripeBdvAmount, uint256 underlyingPintoAmount);

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
     * @param unripeReceipts Array of UnripeBdvTokenData
     */
    function batchDistribute(UnripeBdvTokenData[] memory unripeReceipts) external onlyOwner {
        for (uint256 i = 0; i < unripeReceipts.length; i++) {
            _mint(unripeReceipts[i].receipient, unripeReceipts[i].bdv);
            totalDistributed += unripeReceipts[i].bdv;
        }
    }

    /**
     * @notice Redeems a given amount of unripe bdv tokens for underlying pinto
     * @param amount the amount of unripe bdv tokens to redeem
     * @param recipient the address to send the underlying pinto to
     * @param toMode the mode to send the underlying pinto in
     */
    function redeem(uint256 amount, address recipient, LibTransfer.To toMode) external {
        uint256 pintoToRedeem = unripeToUnderlyingPinto(amount);
        // burn the corresponding amount of unripe bdv tokens
        _burn(msg.sender, amount);
        // send the underlying pintos to the user
        pintoProtocol.transferToken(
            pinto,
            recipient,
            pintoToRedeem,
            LibTransfer.From.EXTERNAL,
            toMode
        );
        emit Redeemed(msg.sender, amount, pintoToRedeem);
    }

    /**
     * @dev Gets the amount of underlying pinto that corresponds to a given amount of unripe bdv tokens
     * according to the current exchange rate.
     * @param amount the amount of unripe bdv tokens to redeem
     */
    function unripeToUnderlyingPinto(uint256 amount) public view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return (amount * totalUnderlyingPinto()) / totalSupply();
    }

    /**
     * @dev Tracks how many underlying pintos are available to redeem
     * @return the total amount of underlying pintos in the contract
     */
    function totalUnderlyingPinto() public view returns (uint256) {
        return pinto.balanceOf(address(this));
    }

    /// @dev override the decimals to 6 decimal places, BDV has 6 decimals
    function decimals() public view override returns (uint8) {
        return 6;
    }
}

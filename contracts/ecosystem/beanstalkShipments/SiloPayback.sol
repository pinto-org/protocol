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
     * @notice Redeems a given amount of unripe bdv tokens for underlying pinto
     * @param amount the amount of unripe bdv tokens to redeem
     * @param recipient the address to send the underlying pinto to
     * @param toMode the mode to send the underlying pinto in
     */
    function claim(uint256 amount, address recipient, LibTransfer.To toMode) external {
        // send the underlying pintos to the user
        pintoProtocol.transferToken(
            pinto,
            recipient,
            pintoToRedeem,
            LibTransfer.From.EXTERNAL, // External since pintos are sent to the contract
            toMode
        );
        emit Claimed(msg.sender, amount, pintoToRedeem);
    }

    /// @notice update the global index of earned rewards
    function update() public {
        uint256 totalSupply = pinto.balanceOf(address(this));
        if (totalSupply > 0) {
            uint256 _balance = pinto.balanceOf(address(this));
            if (_balance > balance) {
                uint256 _diff = _balance - balance;
                if (_diff > 0) {
                    uint256 _ratio = _diff * 1e18 / totalSupply;
                    if (_ratio > 0) {
                      index = index + _ratio;
                      balance = _balance;
                    }
                }
            }
        }
    }


    /// @notice update the index for a user
    /// @param recipient the user to update
    function updateFor(address recipient) public {
        update();
        uint256 _supplied = balanceOf(recipient);
        if (_supplied > 0) {
            uint256 _supplyIndex = supplyIndex[recipient];
            supplyIndex[recipient] = index;
            uint256 _delta = index - _supplyIndex;
            if (_delta > 0) {
              uint256 _share = _supplied * _delta / 1e18;
              claimable[recipient] += _share;
            }
        } else {
            supplyIndex[recipient] = index;
        }
    }

    /// @dev override the decimals to 6 decimal places, BDV has 6 decimals
    function decimals() public view override returns (uint8) {
        return 6;
    }

    function siloRemaining() public view returns (uint256) {
        return totalDistributed;
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from != address(0) && to != address(0)) {
            revert("SiloPayback: cannot transfer between addresses");
        }
    }

    /**
     * @dev override the transfer function to enforce claiming before transferring
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        _beforeTokenTransfer(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    /**
     * @dev override the transferFrom function to enforce claiming before transferring
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        _beforeTokenTransfer(from, to, amount);
        return super.transferFrom(from, to, amount);
    }
}

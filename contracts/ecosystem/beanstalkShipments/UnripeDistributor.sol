// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalkWellFunction} from "contracts/interfaces/basin/IBeanstalkWellFunction.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract UnripeDistributor is ERC20, Ownable {
    uint256 public constant PRECISION = 1e6; // 6 decimal precision
    uint256 public constant MIN_SIZE = 1e6; // 1 Pinto

    /// @dev error thrown when the user tries to claim but has no unripe bdv tokens
    error NoUnripeBdvTokens();

    IBeanstalk public pintoProtocol;
    IERC20 public pinto;

    struct UnripeReceiptBdvTokenData {
        address receipient;
        uint256 bdv;
    }

    /// @dev event emitted when user redeems bdv tokens for underlying pinto
    event Redeemed(address indexed user, uint256 amount);

    /// @dev tracks total distributed bdv tokens. After initial mint, no more tokens can be distributed.
    uint256 public totalDistributed;

    /// @dev tracks the total underlying pdv in the contract
    uint256 public totalUnerlyingPdv;

    constructor(
        address _pinto,
        address _pintoProtocol
    ) ERC20("UnripeBdvReceipt", "urBDV") Ownable(msg.sender) {
        pinto = IERC20(_pinto);
        pintoProtocol = IBeanstalk(_pintoProtocol);
        // Approve the Pinto Diamond to spend pinto tokens for deposits
        pinto.approve(pintoProtocol, type(uint256).max);
    }

    /**
     * @notice Distribute unripe bdv tokens to the old beanstalk participants.
     * Called in batches after deployment to make sure we don't run out of gas.
     * @param unripeReceipts Array of UnripeReceiptBdvTokenData
     */
    function distributeUnripeBdvTokens(
        UnripeReceiptBdvTokenData[] memory unripeReceipts
    ) external onlyOwner {
        // just mint the tokens to the recipients
        for (uint256 i = 0; i < unripeReceipts.length; i++) {
            _mint(unripeReceipts[i].receipient, unripeReceipts[i].bdv);
            totalDistributed += unripeReceipts[i].bdv;
        }
    }

    /// redeem bdv tokens for a portion of the underlying pdv
    function redeem(address recipient, LibTransfer.To toMode) external {
        // check if the user has any bdv tokens
        uint256 userBalance = balanceOf(msg.sender);
        if (userBalance == 0) revert NoUnripeBdvTokens();

        // calculate the amount of pintos to redeem, pro rata based on the user's percentage ownership of the total distributed bdv tokens
        uint256 userUnripeBdvBalance = balanceOf(msg.sender);
        uint256 pintoToRedeem = (userUnripeBdvBalance * PRECISION) / totalDistributed;

        // burn the corresponding amount of unripe bdv tokens
        _burn(msg.sender, userUnripeBdvBalance);

        // send the underlying pintos to the user
        pintoProtocol.transferToken(pinto, recipient, pintoToRedeem, LibTransfer.From.INTERNAL, toMode);
    }

    /// @dev tracks how many underlying pintos are available to redeem
    function totalUnderlyingPinto() public view returns (uint256) {
        return pinto.balanceOf(address(this));
    }

    /// @dev override the decimals to 6 decimal places, like bdv
    function decimals() public view override returns (uint8) {
        return 6;
    }

    /**
     * @notice Deposits distributed pintos to start earning yield, mows if needed
     * @dev This function should be called before any redeeming of bdv tokens to update the underlying pdv.
     */
    function claim() public {
        // Check for newly received pintos, deposit them if needed
        if (pinto.balanceOf(address(this)) > MIN_SIZE) {
            (, uint256 bdv, ) = pintoProtocol.deposit(
                address(pinto),
                pinto.balanceOf(address(this)),
                LibTransfer.From.EXTERNAL
            );
            totalUnerlyingPdv += bdv;
        }

        // Check for pinto yield from existing deposits, plant if needed
        // Earned pinto also increases the total underlying pdv
        if (pintoProtocol.balanceOfEarnedBeans(address(this)) > MIN_SIZE) {
            (uint256 earnedPinto, ) = pintoProtocol.plant();
            totalUnerlyingPdv += earnedPinto;
        }
        // Attempt to mow if the protocol did not plant (planting invokes a mow).
        else if (pintoProtocol.balanceOfGrownStalk(address(this), address(pinto)) > 0) {
            pintoProtocol.mow(address(this), address(pinto));
        }
    }
}

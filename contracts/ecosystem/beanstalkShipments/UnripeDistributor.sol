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

    /// @dev error thrown when the user tries to claim but has no unripe bdv tokens
    error NoUnripeBdvTokens();

    /// @dev error thrown when the user has already claimed in the current season
    error AlreadyClaimed();

    IBeanstalk public pintoProtocol;
    IERC20 public pinto;

    struct UnripeReceiptBdvTokenData {
        address receipient;
        uint256 bdv;
    }

    /// @dev tracks the last season a user claimed their unripe bdv tokens
    /// @dev we should make the tokens soul-bound such that they cannot be transferred to prevent double claiming
    mapping(address account => uint256 lastSeasonClaimed) public userLastSeasonClaimed;

    constructor(
        address _pinto,
        address _pintoProtocol
    ) ERC20("UnripeBdvReceipt", "urBDV") Ownable(msg.sender) {
        pinto = IERC20(_pinto);
        pintoProtocol = IBeanstalk(_pintoProtocol);
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
        }
    }

    /**
     * @notice Claim unripe bdv tokens for the user. Claim is pro rata based on the user's percentage ownership.
     */
    function claimUnripeBdvTokens(address recipient, LibTransfer.To toMode) external {
        // check if the user has claimed in the current season
        if (userLastSeasonClaimed[msg.sender] == pintoProtocol.time().current) {
            revert AlreadyClaimed();
        }

        // check if the user has any unripe bdv tokens
        uint256 userUnripeBdv = balanceOf(msg.sender);
        if (userUnripeBdv == 0) revert NoUnripeBdvTokens();

        // calculate the amount of pintos to claim
        uint256 userUnripeBdvBalance = balanceOf(msg.sender);
        uint256 pintoToClaim = (userUnripeBdvBalance * PRECISION) / totalUnderlyingPinto();

        // no need to burn here, the user will keep claiming pro rata until repayment is complete
        // like a static pinto deposit system

        // send the underlying pintos to the user
        // TODO: "From" here is wherever this contract receives the pintos from the shipments
        pintoProtocol.transferToken(pinto, recipient, pintoToClaim, LibTransfer.From.INTERNAL, toMode);

        // update the last season claimed
        userLastSeasonClaimed[msg.sender] = pintoProtocol.time().current;
    }

    /// @dev tracks how many pintos have beed received by the diamond shipments
    function totalUnderlyingPinto() public view returns (uint256) {
        return pinto.balanceOf(address(this));
    }

    /// @dev override the decimals to 6 decimal places, like bdv
    function decimals() public view override returns (uint8) {
        return 6;
    }
}

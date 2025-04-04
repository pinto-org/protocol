// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AdvancedFarmCall} from "../libraries/LibFarm.sol";
import {LibTransfer} from "../libraries/Token/LibTransfer.sol";

interface IBeanstalk {
    function balanceOfSeeds(address account) external view returns (uint256);

    function balanceOfStalk(address account) external view returns (uint256);

    function transferDeposits(
        address sender,
        address recipient,
        address token,
        uint32[] calldata seasons,
        uint256[] calldata amounts
    ) external payable returns (uint256[] memory bdvs);

    function plant() external payable returns (uint256);

    function update(address account) external payable;

    function transferInternalTokenFrom(
        IERC20 token,
        address from,
        address to,
        uint256 amount,
        LibTransfer.To toMode
    ) external payable;

    function transferToken(
        IERC20 token,
        address recipient,
        uint256 amount,
        LibTransfer.From fromMode,
        LibTransfer.To toMode
    ) external payable;

    function deposit(
        address token,
        uint256 _amount,
        LibTransfer.From mode
    ) external payable returns (uint256 amount, uint256 _bdv, int96 stem);

    function getDeposit(
        address account,
        address token,
        uint32 season
    ) external view returns (uint256, uint256);

    function advancedFarm(
        AdvancedFarmCall[] calldata data
    ) external payable returns (bytes[] memory results);

    // Price and well-related functions
    function getWhitelistedWellLpTokens() external view returns (address[] memory);
    function getBeanIndex(IERC20[] memory tokens) external view returns (uint256);
    function getUsdTokenPrice(address token) external view returns (uint256);
    function getTokenUsdPrice(address token) external view returns (uint256);
    function bdv(address token, uint256 amount) external view returns (uint256);
    function poolCurrentDeltaB(address pool) external view returns (int256 deltaB);
}

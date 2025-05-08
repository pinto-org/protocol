// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AdvancedFarmCall} from "../libraries/LibFarm.sol";
import {LibTransfer} from "../libraries/Token/LibTransfer.sol";
import {LibTractor} from "../libraries/LibTractor.sol";

interface IBeanstalk {
    enum GerminationSide {
        ODD,
        EVEN,
        NOT_GERMINATING
    }

    enum CounterUpdateType {
        INCREASE,
        DECREASE
    }

    struct AssetSettings {
        bytes4 selector;
        uint40 stalkEarnedPerSeason;
        uint48 stalkIssuedPerBdv;
        uint32 milestoneSeason;
        int96 milestoneStem;
        bytes1 encodeType;
        uint40 deltaStalkEarnedPerSeason;
        uint128 gaugePoints;
        uint64 optimalPercentDepositedBdv;
        Implementation gaugePointImplementation;
        Implementation liquidityWeightImplementation;
    }

    struct Deposit {
        uint128 amount;
        uint128 bdv;
    }

    struct Implementation {
        address target;
        bytes4 selector;
        bytes1 encodeType;
        bytes data;
    }

    struct MowStatus {
        int96 lastStem;
        uint128 bdv;
    }

    struct Season {
        uint32 current;
        uint32 lastSop;
        uint32 lastSopSeason;
        uint32 rainStart;
        bool raining;
        uint64 sunriseBlock;
        bool abovePeg;
        uint256 start;
        uint256 period;
        uint256 timestamp;
        uint256 standardMintedBeans;
        bytes32[8] _buffer;
    }

    struct WhitelistStatus {
        address token;
        bool isWhitelisted;
        bool isWhitelistedLp;
        bool isWhitelistedWell;
        bool isSoppable;
    }

    function advancedFarm(
        AdvancedFarmCall[] calldata data
    ) external payable returns (bytes[] memory results);

    function balanceOfSeeds(address account) external view returns (uint256);

    function balanceOfStalk(address account) external view returns (uint256);

    function calculateStemForTokenFromGrownStalk(
        address token,
        uint256 grownStalk,
        uint256 bdvOfDeposit
    ) external view returns (int96 stem, GerminationSide germ);

    function calculateDeltaBFromReserves(
        address well,
        uint256[] memory reserves,
        uint256 lookback
    ) external view returns (int256);

    function convert(
        bytes calldata convertData,
        int96[] memory stems,
        uint256[] memory amounts
    )
        external
        payable
        returns (
            int96 toStem,
            uint256 fromAmount,
            uint256 toAmount,
            uint256 fromBdv,
            uint256 toBdv
        );

    function convertWithStalkSlippage(
        bytes calldata convertData,
        int96[] memory stems,
        uint256[] memory amounts,
        int256 grownStalkSlippage
    )
        external
        payable
        returns (
            int96 toStem,
            uint256 fromAmount,
            uint256 toAmount,
            uint256 fromBdv,
            uint256 toBdv
        );

    function deposit(
        address token,
        uint256 _amount,
        LibTransfer.From mode
    ) external payable returns (uint256 amount, uint256 _bdv, int96 stem);

    function getAddressAndStem(uint256 depositId) external pure returns (address token, int96 stem);

    function getBeanIndex(IERC20[] calldata tokens) external view returns (uint256);

    function getBeanToken() external view returns (address);

    function getConvertBonusBdvAmountAndRemainingCapacity()
        external
        view
        returns (uint256, uint256);

    function getCounter(address account, bytes32 counterId) external view returns (uint256);

    function getCurrentBlueprintHash() external view returns (bytes32);

    function getDeposit(
        address account,
        address token,
        uint32 season
    ) external view returns (uint256, uint256);

    function getDeposit(
        address account,
        address token,
        int96 stem
    ) external view returns (uint256, uint256);

    function getHighestNonGerminatingStem(address token) external view returns (int96 stem);

    function getHighestNonGerminatingStems(
        address[] memory tokens
    ) external view returns (int96[] memory highestNonGerminatingStems);

    function getMowStatus(
        address account,
        address[] calldata tokens
    ) external view returns (MowStatus[] memory mowStatuses);

    function getNonBeanTokenAndIndexFromWell(address well) external view returns (address, uint256);

    function getTokenDepositIdsForAccount(
        address account,
        address token
    ) external view returns (uint256[] memory depositIds);

    function getWhitelistedTokens() external view returns (address[] memory);

    function maxTemperature() external view returns (uint256);

    function operator() external view returns (address);

    function plant() external payable returns (uint256);

    function sowWithMin(
        uint256 beans,
        uint256 minTemperature,
        uint256 minSoil,
        LibTransfer.From mode
    ) external payable returns (uint256 pods);

    function stemTipForToken(address token) external view returns (int96 _stemTip);

    function sunriseBlock() external view returns (uint64);

    function temperature() external view returns (uint256);

    function time() external view returns (Season memory);

    function tokenSettings(address token) external view returns (AssetSettings memory);

    function totalSoil() external view returns (uint256);

    function totalUnharvestable(uint256 fieldId) external view returns (uint256);

    function totalUnharvestableForActiveField() external view returns (uint256);

    function tractorUser() external view returns (address payable);

    function transferDeposits(
        address sender,
        address recipient,
        address token,
        uint32[] calldata seasons,
        uint256[] calldata amounts
    ) external payable returns (uint256[] memory bdvs);

    function sendTokenToInternalBalance(
        address token,
        address recipient,
        uint256 amount
    ) external payable;

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

    function update(address account) external payable;

    function withdrawDeposits(
        address token,
        int96[] calldata stems,
        uint256[] calldata amounts,
        LibTransfer.To mode
    ) external payable;

    function updatePublisherCounter(
        bytes32 counterId,
        CounterUpdateType updateType,
        uint256 amount
    ) external payable returns (uint256);

    // Price and well-related functions
    function getWhitelistedWellLpTokens() external view returns (address[] memory);
    function getUsdTokenPrice(address token) external view returns (uint256);
    function getTokenUsdPrice(address token) external view returns (uint256);
    function getMillionUsdPrice(address token, uint256 lookback) external view returns (uint256);
    function bdv(address token, uint256 amount) external view returns (uint256);
    function poolCurrentDeltaB(address pool) external view returns (int256 deltaB);

    function getWhitelistStatuses()
        external
        view
        returns (WhitelistStatus[] memory _whitelistStatuses);
}

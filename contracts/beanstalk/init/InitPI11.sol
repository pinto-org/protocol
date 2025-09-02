/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import {AppStorage, LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {Gauge, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibGaugeHelpers} from "../../libraries/LibGaugeHelpers.sol";
import {IGaugeFacet} from "contracts/beanstalk/facets/sun/GaugeFacet.sol";
import {LibUpdate} from "../../libraries/LibUpdate.sol";
import {LibWhitelist} from "../../libraries/Silo/LibWhitelist.sol";

/**
 * @title InitPI11
 * @dev Initializes parameters for pinto improvement 11.
 * Updates the convert down penalty gauge to include new fields.
 **/
contract InitPI11 {
    // Original values for convert down penalty gauge.
    uint256 internal constant INIT_CONVERT_DOWN_PENALTY_RATIO = 0;
    uint256 internal constant INIT_ROLLING_SEASONS_ABOVE_PEG = 0;
    uint256 internal constant ROLLING_SEASONS_ABOVE_PEG_CAP = 12;
    uint256 internal constant ROLLING_SEASONS_ABOVE_PEG_RATE = 1;

    // New fields for convert down penalty gauge
    uint256 internal constant INIT_BEANS_MINTED_ABOVE_PEG = 0;
    uint256 internal constant PERCENT_SUPPLY_THRESHOLD_RATE = 416666666666667; // 1%/24 = 0.01e18/24 ≈ 0.0004166667e18
    uint256 internal constant INIT_BEAN_AMOUNT_ABOVE_THRESHOLD = 15_007_159_669041; // calculation from https://github.com/pinto-org/PI-Data-Analysis.
    uint256 internal constant INIT_RUNNING_THRESHOLD = 0; // initialize running threshold to 0
    uint256 internal constant CONVERT_DOWN_PENALTY_RATE = 1.005e6; // $1.005 convert price.

    // Seed Gauge:
    address internal constant PINTO_WETH_LP = 0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3;
    address internal constant PINTO_CBETH_LP = 0x3e111115A82dF6190e36ADf0d552880663A4dBF1;
    address internal constant PINTO_CBBTC_LP = 0x3e11226fe3d85142B734ABCe6e58918d5828d1b4;
    address internal constant PINTO_USDC_LP = 0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1;
    address internal constant PINTO_WSOL_LP = 0x3e11444c7650234c748D743D8d374fcE2eE5E6C9;

    // New optimal percent deposited BDV allocations for remaining tokens
    uint64 internal constant PINTO_CBETH_LP_OPTIMAL_PERCENT_DEPOSITED_BDV = 33_333333; // 33%
    uint64 internal constant PINTO_CBBTC_LP_OPTIMAL_PERCENT_DEPOSITED_BDV = 33_333333; // 33%
    uint64 internal constant PINTO_USDC_LP_OPTIMAL_PERCENT_DEPOSITED_BDV = 33_333333; // 33%

    // New optimal percent deposited BDV allocations for remaining tokens
    struct TokenAllocation {
        address token;
        uint64 optimalPercentDepositedBdv;
    }

    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Update the convertDownPenaltyGauge with new data structure
        Gauge memory convertDownPenaltyGauge = Gauge(
            abi.encode(
                LibGaugeHelpers.ConvertDownPenaltyValue({
                    penaltyRatio: INIT_CONVERT_DOWN_PENALTY_RATIO,
                    rollingSeasonsAbovePeg: INIT_ROLLING_SEASONS_ABOVE_PEG
                })
            ),
            address(this),
            IGaugeFacet.convertDownPenaltyGauge.selector,
            abi.encode(
                LibGaugeHelpers.ConvertDownPenaltyData({
                    rollingSeasonsAbovePegRate: ROLLING_SEASONS_ABOVE_PEG_RATE,
                    rollingSeasonsAbovePegCap: ROLLING_SEASONS_ABOVE_PEG_CAP,
                    beansMintedAbovePeg: INIT_BEANS_MINTED_ABOVE_PEG,
                    beanMintedThreshold: INIT_BEAN_AMOUNT_ABOVE_THRESHOLD,
                    runningThreshold: INIT_RUNNING_THRESHOLD,
                    percentSupplyThresholdRate: PERCENT_SUPPLY_THRESHOLD_RATE,
                    convertDownPenaltyRate: CONVERT_DOWN_PENALTY_RATE,
                    thresholdSet: true
                })
            )
        );
        LibGaugeHelpers.updateGauge(GaugeId.CONVERT_DOWN_PENALTY, convertDownPenaltyGauge);

        dewhitelistAndUpdateAllocations();
    }

    function dewhitelistAndUpdateAllocations() internal {
        // Define the new allocations
        TokenAllocation[] memory newAllocations = new TokenAllocation[](3);

        // Initialize the new allocations array with the new allocations
        newAllocations[0] = TokenAllocation({
            token: PINTO_CBETH_LP,
            optimalPercentDepositedBdv: PINTO_CBETH_LP_OPTIMAL_PERCENT_DEPOSITED_BDV
        });
        newAllocations[1] = TokenAllocation({
            token: PINTO_CBBTC_LP,
            optimalPercentDepositedBdv: PINTO_CBBTC_LP_OPTIMAL_PERCENT_DEPOSITED_BDV
        });
        newAllocations[2] = TokenAllocation({
            token: PINTO_USDC_LP,
            optimalPercentDepositedBdv: PINTO_USDC_LP_OPTIMAL_PERCENT_DEPOSITED_BDV
        });

        // Validate total allocations don't exceed 100%
        _validateTotalAllocations(newAllocations);

        // Dewhitelist token
        _dewhitelistToken(PINTO_WSOL_LP);
        _dewhitelistToken(PINTO_WETH_LP);

        // Rebalance the optimal percent deposited BDV for remaining tokens
        _rebalanceTokenAllocations(newAllocations);
    }

    function _dewhitelistToken(address token) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Verify token is currently whitelisted
        require(
            s.sys.silo.assetSettings[token].milestoneSeason != 0,
            "InitWhitelistRebalance: Token not whitelisted"
        );
        // Dewhitelist the token using LibWhitelist
        LibWhitelist.dewhitelistToken(token);
    }

    function _rebalanceTokenAllocations(TokenAllocation[] memory newAllocations) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Update optimal percent deposited BDV for each token in the rebalancing list
        for (uint256 i = 0; i < newAllocations.length; i++) {
            TokenAllocation memory allocation = newAllocations[i];

            // Verify token is still whitelisted
            require(
                s.sys.silo.assetSettings[allocation.token].milestoneSeason != 0,
                "InitWhitelistRebalance: Token not whitelisted for rebalancing"
            );

            // Update the optimal percent deposited BDV
            LibWhitelist.updateOptimalPercentDepositedBdvForToken(
                allocation.token,
                allocation.optimalPercentDepositedBdv
            );
        }
    }

    // Helper function to validate total allocations don't exceed 100%
    function _validateTotalAllocations(TokenAllocation[] memory newAllocations) internal view {
        uint256 totalPercent = 0;
        for (uint256 i = 0; i < newAllocations.length; i++) {
            totalPercent += newAllocations[i].optimalPercentDepositedBdv;
        }
        require(
            totalPercent <= 100e6, // 100% in basis points
            "InitWhitelistRebalance: Total allocations exceed 100%"
        );
    }
}

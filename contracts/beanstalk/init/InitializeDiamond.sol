/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {ILiquidityWeightFacet} from "contracts/beanstalk/facets/sun/LiquidityWeightFacet.sol";
import {IGaugeFacet} from "contracts/beanstalk/facets/sun/GaugeFacet.sol";
import {BDVFacet} from "contracts/beanstalk/facets/silo/BDVFacet.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {AssetSettings, Implementation} from "contracts/beanstalk/storage/System.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {LibCases} from "contracts/libraries/LibCases.sol";
import {LibGauge} from "contracts/libraries/LibGauge.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {Gauge, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibGaugeHelpers} from "../../libraries/LibGaugeHelpers.sol";
import {C} from "contracts/C.sol";

/**
 * @title InitializeDiamond
 * @notice InitializeDiamond provides helper functions to initalize beanstalk.
 **/

contract InitializeDiamond {
    AppStorage internal s;

    // INITIAL CONSTANTS //
    uint128 constant INIT_BEAN_TO_MAX_LP_GP_RATIO = 33_333_333_333_333_333_333; // 33%
    uint128 constant INIT_AVG_GSPBDV = 3e12;
    uint32 constant INIT_BEAN_STALK_EARNED_PER_SEASON = 2e6;
    uint32 constant INIT_BEAN_TOKEN_WELL_STALK_EARNED_PER_SEASON = 4e6;
    uint48 constant INIT_STALK_ISSUED_PER_BDV = 1e10;
    uint128 constant INIT_TOKEN_G_POINTS = 100e18;
    uint32 constant INIT_BEAN_TOKEN_WELL_PERCENT_TARGET = 100e6;

    // Pod rate bounds
    uint256 internal constant POD_RATE_LOWER_BOUND = 0.05e18; // 5%
    uint256 internal constant POD_RATE_OPTIMAL = 0.15e18; // 15%
    uint256 internal constant POD_RATE_UPPER_BOUND = 0.25e18; // 25%

    // Change in Soil demand bounds
    uint256 internal constant DELTA_POD_DEMAND_LOWER_BOUND = 0.95e18; // 95%
    uint256 internal constant DELTA_POD_DEMAND_UPPER_BOUND = 1.05e18; // 105%

    // Liquidity to supply ratio bounds
    uint256 internal constant LP_TO_SUPPLY_RATIO_UPPER_BOUND = 0.8e18; // 80%
    uint256 internal constant LP_TO_SUPPLY_RATIO_OPTIMAL = 0.4e18; // 40%
    uint256 internal constant LP_TO_SUPPLY_RATIO_LOWER_BOUND = 0.12e18; // 12%

    // Excessive price threshold constant
    uint256 internal constant EXCESSIVE_PRICE_THRESHOLD = 1.025e6;

    /// @dev When the Pod Rate is high, issue less Soil.
    uint256 private constant SOIL_COEFFICIENT_HIGH = 0.25e18;

    uint256 private constant SOIL_COEFFICIENT_REALATIVELY_HIGH = 0.5e18;

    /// @dev When the Pod Rate is low, issue more Soil.
    uint256 private constant SOIL_COEFFICIENT_REALATIVELY_LOW = 1e18;

    uint256 private constant SOIL_COEFFICIENT_LOW = 1.2e18;

    /// @dev Base BEAN reward to cover cost of operating a bot.
    uint256 internal constant BASE_REWARD = 5e6; // 5 BEAN

    // Gauge
    uint256 internal constant TARGET_SEASONS_TO_CATCHUP = 4320;
    uint256 internal constant MAX_BEAN_MAX_LP_GP_PER_BDV_RATIO = 150e18; // 150%
    uint256 internal constant MIN_BEAN_MAX_LP_GP_PER_BDV_RATIO = 50e18; // 50%
    uint128 internal constant RAINING_MIN_BEAN_MAX_LP_GP_PER_BDV_RATIO = 10e18;

    // Soil scalar.
    uint256 internal constant BELOW_PEG_SOIL_L2SR_SCALAR = 1.0e6;

    // Delta B divisor when twaDeltaB < 0 and instDeltaB > 0
    uint256 internal constant ABOVE_PEG_DELTA_B_SOIL_SCALAR = 0.01e6; // 1% of twaDeltaB (6 decimals)

    // Soil distribution period
    uint256 internal constant SOIL_DISTRIBUTION_PERIOD = 24 * 60 * 60; // 24 hours

    // GAUGE DATA:

    // Cultivation Factor
    uint256 internal constant INIT_CULTIVATION_FACTOR = 50e6; // 50%
    uint256 internal constant MIN_DELTA_CULTIVATION_FACTOR = 0.5e6; // 0.5%
    uint256 internal constant MAX_DELTA_CULTIVATION_FACTOR = 2e6; // 2%
    uint256 internal constant MIN_CULTIVATION_FACTOR = 1e6; // 1%
    uint256 internal constant MAX_CULTIVATION_FACTOR = 100e6; // 100%

    // Rolling Seasons Above Peg.
    // The % penalty to be applied to grown stalk when down converting.
    uint256 internal constant INIT_CONVERT_DOWN_PENALTY_RATIO = 0;
    // Rolling count of seasons with a twap above peg.
    uint256 internal constant INIT_ROLLING_SEASONS_ABOVE_PEG = 0;
    // Max magnitude for rolling seasons above peg count.
    uint256 internal constant ROLLING_SEASONS_ABOVE_PEG_CAP = 12;
    // Rate at which rolling seasons above peg count changes. If not one, it is not actual count.
    uint256 internal constant ROLLING_SEASONS_ABOVE_PEG_RATE = 1;

    // Convert Down Penalty Gauge additional fields
    uint256 internal constant INIT_BEANS_MINTED_ABOVE_PEG = 0;
    uint256 internal constant INIT_BEAN_AMOUNT_ABOVE_THRESHOLD = 10_000_000e6; // initalize to 10M
    // 1%/24 = 0.01e18/24 ≈ 0.0004166667e18 = 4.1666667e14 (18 decimals)
    uint256 internal constant INIT_PERCENT_SUPPLY_THRESHOLD_RATE = 416666666666667; // ~0.000416667e18 with 18 decimals

    // Min Soil Issuance
    uint256 internal constant MIN_SOIL_ISSUANCE = 50e6; // 50

    // Min Soil Sown Demand
    uint256 internal constant MIN_SOIL_SOWN_DEMAND = 5e6; // 5

    // Convert Down Penalty Rate (1.005 with 6 decimals)
    uint256 internal constant CONVERT_DOWN_PENALTY_RATE = 1.005e6;

    // EVENTS:
    event BeanToMaxLpGpPerBdvRatioChange(uint256 indexed season, uint256 caseId, int80 absChange);

    /**
     * @notice Initializes the diamond with base conditions.
     * @dev the base initialization initializes various parameters,
     * as well as whitelists the bean and bean:TKN pools.
     */
    function initializeDiamond(address bean, address beanTokenWell) internal {
        addInterfaces();
        initializeTokens(bean);
        initalizeSeason();
        initalizeField();
        initalizeFarmAndTractor();
        initializeGauges();

        address[] memory tokens = new address[](2);
        tokens[0] = bean;
        tokens[1] = beanTokenWell;

        // note: bean and assets that are not in the gauge system
        // do not need to initalize the gauge system.
        Implementation memory impl = Implementation(address(0), bytes4(0), bytes1(0), new bytes(0));
        Implementation memory liquidityWeightImpl = Implementation(
            address(0),
            ILiquidityWeightFacet.maxWeight.selector,
            bytes1(0),
            new bytes(0)
        );
        Implementation memory gaugePointImpl = Implementation(
            address(0),
            IGaugeFacet.defaultGaugePoints.selector,
            bytes1(0),
            new bytes(0)
        );

        AssetSettings[] memory assetSettings = new AssetSettings[](2);
        assetSettings[0] = AssetSettings({
            selector: BDVFacet.beanToBDV.selector,
            stalkEarnedPerSeason: INIT_BEAN_STALK_EARNED_PER_SEASON,
            stalkIssuedPerBdv: INIT_STALK_ISSUED_PER_BDV,
            milestoneSeason: s.sys.season.current,
            milestoneStem: 0,
            encodeType: 0x00,
            deltaStalkEarnedPerSeason: 0,
            gaugePoints: 0,
            optimalPercentDepositedBdv: 0,
            gaugePointImplementation: impl,
            liquidityWeightImplementation: impl
        });

        assetSettings[1] = AssetSettings({
            selector: BDVFacet.wellBdv.selector,
            stalkEarnedPerSeason: INIT_BEAN_TOKEN_WELL_STALK_EARNED_PER_SEASON,
            stalkIssuedPerBdv: INIT_STALK_ISSUED_PER_BDV,
            milestoneSeason: s.sys.season.current,
            milestoneStem: 0,
            encodeType: 0x01,
            deltaStalkEarnedPerSeason: 0,
            gaugePoints: INIT_TOKEN_G_POINTS,
            optimalPercentDepositedBdv: INIT_BEAN_TOKEN_WELL_PERCENT_TARGET,
            gaugePointImplementation: gaugePointImpl,
            liquidityWeightImplementation: liquidityWeightImpl
        });

        whitelistPools(tokens, assetSettings);

        // init usdTokenPrice. beanTokenWell should be
        // a bean well w/ the native token of the network.
        s.sys.usdTokenPrice[beanTokenWell] = 1;
        s.sys.twaReserves[beanTokenWell].reserve0 = 1;
        s.sys.twaReserves[beanTokenWell].reserve1 = 1;

        // init tractor.
        LibTractor._tractorStorage().activePublisher = payable(address(1));
    }

    /**
     * @notice Adds ERC1155 and ERC1155Metadata interfaces to the diamond.
     */
    function addInterfaces() internal {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();

        ds.supportedInterfaces[0xd9b67a26] = true; // ERC1155
        ds.supportedInterfaces[0x0e89341c] = true; // ERC1155Metadata
    }

    function initializeTokens(address bean) internal {
        s.sys.bean = bean;
    }

    /**
     * @notice Initializes field parameters.
     */
    function initalizeField() internal {
        s.sys.weather.temp = 1e6;
        s.sys.weather.thisSowTime = type(uint32).max;
        s.sys.weather.lastSowTime = type(uint32).max;

        s.sys.extEvaluationParameters.minSoilIssuance = MIN_SOIL_ISSUANCE;
    }

    /**
     * @notice Initializes season parameters.
     */
    function initalizeSeason() internal {
        // set current season to 1.
        s.sys.season.current = 1;

        // initalize the duration of 1 season in seconds.
        s.sys.season.period = C.CURRENT_SEASON_PERIOD;

        // initalize current timestamp.
        s.sys.season.timestamp = block.timestamp;

        // initalize the start timestamp.
        // Rounds down to the nearest hour
        // if needed.
        s.sys.season.start = s.sys.season.period > 0
            ? (block.timestamp / s.sys.season.period) * s.sys.season.period
            : block.timestamp;

        // initializes the cases that beanstalk uses
        // to change certain parameters of itself.
        setCases();

        initializeSeedGaugeSettings();
    }

    /**
     * @notice Initalize the cases for the diamond.
     */
    function setCases() internal {
        LibCases.setCasesV2();
    }

    function initalizeSeedGauge(
        uint128 beanToMaxLpGpRatio,
        uint128 averageGrownStalkPerBdvPerSeason
    ) internal {
        // initalize the ratio of bean to max lp gp per bdv.
        s.sys.seedGauge.beanToMaxLpGpPerBdvRatio = beanToMaxLpGpRatio;

        // initalize the average grown stalk per bdv per season.
        s.sys.seedGauge.averageGrownStalkPerBdvPerSeason = averageGrownStalkPerBdvPerSeason;

        // emit events.
        emit BeanToMaxLpGpPerBdvRatioChange(
            s.sys.season.current,
            type(uint256).max,
            int80(int128(s.sys.seedGauge.beanToMaxLpGpPerBdvRatio))
        );
        emit LibGauge.UpdateAverageStalkPerBdvPerSeason(
            s.sys.seedGauge.averageGrownStalkPerBdvPerSeason
        );
    }

    /**
     * Whitelists the pools.
     * @param assetSettings The pools to whitelist.
     */
    function whitelistPools(
        address[] memory tokens,
        AssetSettings[] memory assetSettings
    ) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            // note: no error checking.
            s.sys.silo.assetSettings[tokens[i]] = assetSettings[i];

            bool isLPandWell = true;
            if (tokens[i] == s.sys.bean) {
                isLPandWell = false;
            }

            // All tokens (excluding bean) are assumed to be
            // - whitelisted,
            // - an LP and well.
            LibWhitelistedTokens.addWhitelistStatus(
                tokens[i],
                true, // is whitelisted,
                isLPandWell,
                isLPandWell,
                isLPandWell // assumes any well LP is soppable, may not be true in the future
            );
        }
    }

    function initializeSeedGaugeSettings() internal {
        s.sys.evaluationParameters.maxBeanMaxLpGpPerBdvRatio = MAX_BEAN_MAX_LP_GP_PER_BDV_RATIO;
        s.sys.evaluationParameters.minBeanMaxLpGpPerBdvRatio = MIN_BEAN_MAX_LP_GP_PER_BDV_RATIO;
        s.sys.evaluationParameters.targetSeasonsToCatchUp = TARGET_SEASONS_TO_CATCHUP;
        s.sys.evaluationParameters.podRateLowerBound = POD_RATE_LOWER_BOUND;
        s.sys.evaluationParameters.podRateOptimal = POD_RATE_OPTIMAL;
        s.sys.evaluationParameters.podRateUpperBound = POD_RATE_UPPER_BOUND;
        s.sys.evaluationParameters.deltaPodDemandLowerBound = DELTA_POD_DEMAND_LOWER_BOUND;
        s.sys.evaluationParameters.deltaPodDemandUpperBound = DELTA_POD_DEMAND_UPPER_BOUND;
        s.sys.evaluationParameters.lpToSupplyRatioUpperBound = LP_TO_SUPPLY_RATIO_UPPER_BOUND;
        s.sys.evaluationParameters.lpToSupplyRatioOptimal = LP_TO_SUPPLY_RATIO_OPTIMAL;
        s.sys.evaluationParameters.lpToSupplyRatioLowerBound = LP_TO_SUPPLY_RATIO_LOWER_BOUND;
        s.sys.evaluationParameters.excessivePriceThreshold = EXCESSIVE_PRICE_THRESHOLD;
        s.sys.evaluationParameters.soilCoefficientHigh = SOIL_COEFFICIENT_HIGH;
        s
            .sys
            .extEvaluationParameters
            .soilCoefficientRelativelyHigh = SOIL_COEFFICIENT_REALATIVELY_HIGH;
        s
            .sys
            .extEvaluationParameters
            .soilCoefficientRelativelyLow = SOIL_COEFFICIENT_REALATIVELY_LOW;
        s.sys.evaluationParameters.soilCoefficientLow = SOIL_COEFFICIENT_LOW;
        s.sys.evaluationParameters.baseReward = BASE_REWARD;
        s
            .sys
            .evaluationParameters
            .rainingMinBeanMaxLpGpPerBdvRatio = RAINING_MIN_BEAN_MAX_LP_GP_PER_BDV_RATIO;
        s.sys.extEvaluationParameters.belowPegSoilL2SRScalar = BELOW_PEG_SOIL_L2SR_SCALAR;
        s.sys.extEvaluationParameters.abovePegDeltaBSoilScalar = ABOVE_PEG_DELTA_B_SOIL_SCALAR;

        // Initialize soilDistributionPeriod to 24 hours (in seconds)
        s.sys.extEvaluationParameters.soilDistributionPeriod = SOIL_DISTRIBUTION_PERIOD;
        s.sys.extEvaluationParameters.minSoilSownDemand = MIN_SOIL_SOWN_DEMAND;
    }

    function initalizeFarmAndTractor() internal {
        LibTractor._resetPublisher();
        LibTractor._setVersion("1.0.0");
    }

    function initializeGauges() internal {
        initalizeSeedGauge(INIT_BEAN_TO_MAX_LP_GP_RATIO, INIT_AVG_GSPBDV);

        Gauge memory cultivationFactorGauge = Gauge(
            abi.encode(INIT_CULTIVATION_FACTOR),
            address(this),
            IGaugeFacet.cultivationFactor.selector,
            abi.encode(
                MIN_DELTA_CULTIVATION_FACTOR,
                MAX_DELTA_CULTIVATION_FACTOR,
                MIN_CULTIVATION_FACTOR,
                MAX_CULTIVATION_FACTOR,
                0,
                0
            )
        );
        LibGaugeHelpers.addGauge(GaugeId.CULTIVATION_FACTOR, cultivationFactorGauge);

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
                    runningThreshold: 0,
                    percentSupplyThresholdRate: INIT_PERCENT_SUPPLY_THRESHOLD_RATE,
                    convertDownPenaltyRate: CONVERT_DOWN_PENALTY_RATE,
                    thresholdSet: true
                })
            )
        );
        LibGaugeHelpers.addGauge(GaugeId.CONVERT_DOWN_PENALTY, convertDownPenaltyGauge);
    }
}

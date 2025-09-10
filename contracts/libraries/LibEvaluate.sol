// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Decimal} from "contracts/libraries/Decimal.sol";
import {LibWhitelistedTokens, C} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibRedundantMath32} from "contracts/libraries/Math/LibRedundantMath32.sol";
import {LibWell, IERC20Decimals} from "contracts/libraries/Well/LibWell.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {Implementation} from "contracts/beanstalk/storage/System.sol";
import {System, EvaluationParameters, Weather} from "contracts/beanstalk/storage/System.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";
import {LibTokenSilo} from "contracts/libraries/Silo/LibTokenSilo.sol";
import {ILiquidityWeightFacet} from "contracts/beanstalk/facets/sun/LiquidityWeightFacet.sol";

/**
 * @title LibEvaluate calculates the caseId based on the state of Beanstalk.
 * @dev the current parameters that beanstalk uses to evaluate its state are:
 * - DeltaB, the amount of Beans needed to be bought/sold to reach peg.
 * - PodRate, the ratio of Pods outstanding against the bean supply.
 * - Delta Soil demand, the change in demand of Soil between the current and previous Season.
 * - LpToSupplyRatio (L2SR), the ratio of liquidity to the circulating Bean supply.
 *
 * based on the caseId, Beanstalk adjusts:
 * - the Temperature
 * - the ratio of the gaugePoints per BDV of bean and the largest GpPerBdv for a given LP token.
 */

library DecimalExtended {
    uint256 private constant PERCENT_BASE = 1e18;

    function toDecimal(uint256 a) internal pure returns (Decimal.D256 memory) {
        return Decimal.D256({value: a});
    }
}

library LibEvaluate {
    using LibRedundantMath256 for uint256;
    using DecimalExtended for uint256;
    using Decimal for Decimal.D256;
    using LibRedundantMath32 for uint32;

    /// @dev If all Soil is Sown faster than this, Beanstalk considers demand for Soil to be increasing.
    uint256 internal constant SOW_TIME_DEMAND_INCR = 1200; // seconds
    uint32 internal constant SOW_TIME_STEADY_LOWER = 300; // seconds, lower means closer to the bottom of the hour
    uint32 internal constant SOW_TIME_STEADY_UPPER = 300; // seconds, upper means closer to the top of the hour
    uint256 internal constant LIQUIDITY_PRECISION = 1e12;
    uint256 internal constant HIGH_DEMAND_THRESHOLD = 1e18;
    uint256 internal constant SOIL_PRECISION = 1e6;
    uint256 internal constant MIN_BEAN_SOWN_DEMAND = 50e6;
    uint256 internal constant MIN_BEAN_SOWN_DEMAND_PERCENT = 0.05e6; // 5%

    /**
     * @notice BeanstalkState is the state of Beanstalk at the end of a season.
     * Beanstalk uses the state to determine how to adjust itself based on the state.
     * @param deltaPodDemand The change in demand for Soil between the current and previous Season.
     * @param lpToSupplyRatio The ratio of liquidity to supply.
     * @param podRate The ratio of Pods outstanding against the bean supply.
     * @param largestLiqWell The address of the largest liquidity well.
     * @param oracleFailure Whether the oracle failed.
     * @param largestLiquidWellTwapBeanPrice The price of the largest liquidity well in USD.
     * @param twaDeltaB The amount of beans needed to be bought/sold to reach peg.
     * @param caseId The caseId of the BeanstalkState.
     */
    struct BeanstalkState {
        Decimal.D256 deltaPodDemand;
        Decimal.D256 lpToSupplyRatio;
        Decimal.D256 podRate;
        address largestLiqWell;
        bool oracleFailure;
        uint256 largestLiquidWellTwapBeanPrice;
        int256 twaDeltaB;
        uint256 caseId;
    }

    event SeasonMetrics(
        uint256 indexed season,
        uint256 deltaPodDemand,
        uint256 lpToSupplyRatio,
        uint256 podRate,
        uint256 thisSowTime,
        uint256 lastSowTime
    );

    /**
     * @notice evaluates the pod rate and returns the caseId
     * @param podRate the length of the podline (debt), divided by the bean supply.
     */
    function evalPodRate(Decimal.D256 memory podRate) internal view returns (uint256 caseId) {
        EvaluationParameters storage ep = LibAppStorage.diamondStorage().sys.evaluationParameters;
        if (podRate.greaterThanOrEqualTo(ep.podRateUpperBound.toDecimal())) {
            caseId = 27;
        } else if (podRate.greaterThanOrEqualTo(ep.podRateOptimal.toDecimal())) {
            caseId = 18;
        } else if (podRate.greaterThanOrEqualTo(ep.podRateLowerBound.toDecimal())) {
            caseId = 9;
        }
    }

    /**
     * @notice updates the caseId based on the price of bean (deltaB)
     * @param deltaB the amount of beans needed to be sold or bought to get bean to peg.
     * @param beanUsdPrice the price of bean in USD.
     */
    function evalPrice(int256 deltaB, uint256 beanUsdPrice) internal view returns (uint256 caseId) {
        EvaluationParameters storage ep = LibAppStorage.diamondStorage().sys.evaluationParameters;
        if (deltaB > 0) {
            if (beanUsdPrice > ep.excessivePriceThreshold) {
                // p > excessivePriceThreshold
                return caseId = 6;
            }

            caseId = 3;
        }
        // p < 1 (caseId = 0)
    }

    /**
     * @notice Updates the caseId based on the change in Soil demand.
     * @param deltaPodDemand The change in Soil demand from the previous Season.
     */
    function evalDeltaPodDemand(
        Decimal.D256 memory deltaPodDemand
    ) internal view returns (uint256 caseId) {
        EvaluationParameters storage ep = LibAppStorage.diamondStorage().sys.evaluationParameters;
        // increasing
        if (deltaPodDemand.greaterThanOrEqualTo(ep.deltaPodDemandUpperBound.toDecimal())) {
            caseId = 2;
            // steady
        } else if (deltaPodDemand.greaterThanOrEqualTo(ep.deltaPodDemandLowerBound.toDecimal())) {
            caseId = 1;
        }
        // decreasing (caseId = 0)
    }

    /**
     * @notice Evaluates the lp to supply ratio and returns the caseId.
     * @param lpToSupplyRatio The ratio of liquidity to supply.
     *
     * @dev 'liquidity' is defined as the non-bean value in a pool that trades beans.
     */
    function evalLpToSupplyRatio(
        Decimal.D256 memory lpToSupplyRatio
    ) internal view returns (uint256 caseId) {
        EvaluationParameters storage ep = LibAppStorage.diamondStorage().sys.evaluationParameters;
        // Extremely High
        if (lpToSupplyRatio.greaterThanOrEqualTo(ep.lpToSupplyRatioUpperBound.toDecimal())) {
            caseId = 108;
            // Reasonably High
        } else if (lpToSupplyRatio.greaterThanOrEqualTo(ep.lpToSupplyRatioOptimal.toDecimal())) {
            caseId = 72;
            // Reasonably Low
        } else if (lpToSupplyRatio.greaterThanOrEqualTo(ep.lpToSupplyRatioLowerBound.toDecimal())) {
            caseId = 36;
        }
        // excessively low (caseId = 0)
    }

    /**
     * @notice Calculates the change in soil demand from the previous season.
     * @param dsoil The amount of soil sown this season.
     */
    function calcDeltaPodDemand(
        uint256 dsoil
    )
        internal
        view
        returns (Decimal.D256 memory deltaPodDemand, uint32 lastSowTime, uint32 thisSowTime)
    {
        Weather storage w = LibAppStorage.diamondStorage().sys.weather;

        // get the minimum soil sown threshold needed to calculate delta pod demand.
        uint256 minDemandThreshold = calcMinSoilDemandThreshold();

        // not enough soil sown, consider demand to be decreasing, reset sow times.
        if (dsoil < minDemandThreshold) {
            return (Decimal.zero(), w.thisSowTime, type(uint32).max);
        }

        deltaPodDemand = getDemand(dsoil, w.lastDeltaSoil);

        // `s.weather.thisSowTime` is set to the number of seconds in it took for
        // Soil to sell out during the current Season.
        //  If Soil didn't sell out, `w.thisSowTime` is set to `type(uint32).max`.
        //  If Soil is mostly sold out, `w.thisSowTime` is set to `type(uint32).max - 1`.
        //  If Soil is sold out, `w.thisSowTime` is set to the seconds it took to sell out.
        if (w.thisSowTime < type(uint32).max - 1) {
            // soil sold out this season.
            if (
                w.lastSowTime >= type(uint32).max - 1 || // Didn't Sow all last Season
                w.thisSowTime < SOW_TIME_DEMAND_INCR || // Sow'd all instantly this Season
                (w.lastSowTime > SOW_TIME_STEADY_UPPER &&
                    w.thisSowTime < w.lastSowTime.sub(SOW_TIME_STEADY_LOWER)) // Sow'd all faster
            ) {
                deltaPodDemand = Decimal.from(HIGH_DEMAND_THRESHOLD);
            } else if (w.thisSowTime <= w.lastSowTime.add(SOW_TIME_STEADY_UPPER)) {
                // Soil sold out in the same time.
                // set a floor for demand to be steady (i.e, demand can either be steady or increasing)
                if (deltaPodDemand.lessThan(Decimal.one())) {
                    deltaPodDemand = Decimal.one();
                }
            }
        }
        // if the soil didn't sell out, or sold out slower than the previous season,
        // demand for soil is a function of the amount of soil sown this season.

        lastSowTime = w.thisSowTime; // Overwrite last Season
        thisSowTime = type(uint32).max; // Reset for next Season
    }

    /**
     * @notice Calculates the change in soil demand from the previous season.
     * @param soilSownThisSeason The amount of soil sown this season.
     * @param soilSownLastSeason The amount of soil sown in the previous season.
     */
    function getDemand(
        uint256 soilSownThisSeason,
        uint256 soilSownLastSeason
    ) internal pure returns (Decimal.D256 memory deltaPodDemand) {
        if (soilSownThisSeason == 0) {
            deltaPodDemand = Decimal.zero(); // If no one Sow'd this season, ∆ demand is 0.
        } else if (soilSownLastSeason == 0) {
            deltaPodDemand = Decimal.from(HIGH_DEMAND_THRESHOLD); // If no one Sow'd last Season, ∆ demand is infinite.
        } else {
            // If both seasons had some soil sown, ∆ demand is the ratio of this season's soil sown to last season's soil sown.
            deltaPodDemand = Decimal.ratio(soilSownThisSeason, soilSownLastSeason);
        }
    }

    /**
     * @notice Calculates the liquidity to supply ratio, where liquidity is measured in USD.
     * @param beanSupply The total supply of Beans.
     * corresponding to the well addresses in the whitelist.
     * @dev No support for non-well AMMs at this time.
     */
    function calcLPToSupplyRatio(
        uint256 beanSupply
    )
        internal
        view
        returns (Decimal.D256 memory lpToSupplyRatio, address largestLiqWell, bool oracleFailure)
    {
        // prevent infinite L2SR
        if (beanSupply == 0) return (Decimal.zero(), address(0), true);

        address[] memory pools = LibWhitelistedTokens.getWhitelistedLpTokens();
        uint256[] memory twaReserves;
        uint256 totalUsdLiquidity;
        uint256 largestLiq;
        uint256 wellLiquidity;
        for (uint256 i; i < pools.length; i++) {
            // get the non-bean value in an LP.
            twaReserves = LibWell.getTwaReservesFromStorageOrBeanstalkPump(pools[i]);
            // if the twaReserves are 0, the well has no liquidity and thus can be skipped
            if (twaReserves[0] == 0 && twaReserves[1] == 0) continue;
            // calculate the non-bean usd liquidity value.
            uint256 usdLiquidity = LibWell.getWellTwaUsdLiquidityFromReserves(
                pools[i],
                twaReserves
            );

            // if the usdliquidity is 0, beanstalk assumes oracle failure.
            if (usdLiquidity == 0) {
                oracleFailure = true;
            }

            // calculate the scaled, non-bean liquidity in the pool.
            wellLiquidity = getLiquidityWeight(pools[i]).mul(usdLiquidity).div(1e18);

            // if the liquidity is the largest, update `largestLiqWell`,
            // and add the liquidity to the total.
            // `largestLiqWell` is only used to initialize `s.sopWell` upon a sop,
            // but a hot storage load to skip the block below
            // is significantly more expensive than performing the logic on every sunrise.
            if (wellLiquidity > largestLiq) {
                largestLiq = wellLiquidity;
                largestLiqWell = pools[i];
            }

            totalUsdLiquidity = totalUsdLiquidity.add(wellLiquidity);

            // If a new non-Well LP is added, functionality to calculate the USD value of the
            // liquidity should be added here.
        }

        // if there is no liquidity,
        // return 0 to save gas.
        if (totalUsdLiquidity == 0) return (Decimal.zero(), address(0), true);

        // USD liquidity is scaled down from 1e18 to match Bean precision (1e6).
        lpToSupplyRatio = Decimal.ratio(totalUsdLiquidity.div(LIQUIDITY_PRECISION), beanSupply);
    }

    /**
     * @notice Get the deltaPodDemand, lpToSupplyRatio, and podRate, and update soil demand
     * parameters.
     */
    function updateAndGetBeanstalkState(
        uint256 beanSupply
    ) internal returns (BeanstalkState memory bs) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // Calculate Delta Soil Demand
        uint256 dsoil = s.sys.beanSown;
        s.sys.beanSown = 0;
        (
            bs.deltaPodDemand,
            s.sys.weather.lastSowTime,
            s.sys.weather.thisSowTime
        ) = calcDeltaPodDemand(dsoil);
        s.sys.weather.lastDeltaSoil = uint128(dsoil); // SafeCast not necessary as `s.beanSown` is uint128.

        // Calculate Lp To Supply Ratio, fetching the twaReserves in storage:
        (bs.lpToSupplyRatio, bs.largestLiqWell, bs.oracleFailure) = calcLPToSupplyRatio(beanSupply);

        // Calculate PodRate
        bs.podRate = Decimal.ratio(
            s.sys.fields[s.sys.activeField].pods.sub(s.sys.fields[s.sys.activeField].harvestable),
            beanSupply
        ); // Pod Rate

        // Get Token:Bean Price using largest liquidity well
        bs.largestLiquidWellTwapBeanPrice = LibWell.getBeanUsdPriceForWell(bs.largestLiqWell);

        emit SeasonMetrics(
            s.sys.season.current,
            bs.deltaPodDemand.value,
            bs.lpToSupplyRatio.value,
            bs.podRate.value,
            s.sys.weather.thisSowTime,
            s.sys.weather.lastSowTime
        );
    }

    /**
     * @notice Evaluates beanstalk based on deltaB, podRate, deltaPodDemand and lpToSupplyRatio.
     * and returns the associated caseId.
     */
    function evaluateBeanstalk(
        int256 deltaB,
        uint256 beanSupply
    ) external returns (BeanstalkState memory) {
        BeanstalkState memory bs = updateAndGetBeanstalkState(beanSupply);
        bs.twaDeltaB = deltaB;
        uint256 caseId = evalPodRate(bs.podRate) // Evaluate Pod Rate
            .add(evalPrice(deltaB, bs.largestLiquidWellTwapBeanPrice))
            .add(evalDeltaPodDemand(bs.deltaPodDemand))
            .add(evalLpToSupplyRatio(bs.lpToSupplyRatio)); // Evaluate Price // Evaluate Delta Soil Demand // Evaluate LP to Supply Ratio
        bs.caseId = caseId;
        return bs;
    }

    /**
     * @notice calculates the liquidity weight of a token.
     * @dev the liquidity weight determines the percentage of
     * liquidity that is used in evaluating the liquidity of bean.
     * At 0, no liquidity is added. at 1e18, all liquidity is added.
     * The function must be a non state, viewable function that returns a uint256.
     * if failure, returns 0 (no liquidity is considered) instead of reverting.
     * if the pool does not have a target, uses address(this).
     */
    function getLiquidityWeight(address pool) internal view returns (uint256 liquidityWeight) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Implementation memory lw = s.sys.silo.assetSettings[pool].liquidityWeightImplementation;

        // if the target is 0, use address(this).
        address target = lw.target;
        if (target == address(0)) target = address(this);

        (bool success, bytes memory data) = target.staticcall(
            abi.encodeWithSelector(lw.selector, lw.data)
        );

        if (!success) return 0;
        assembly {
            liquidityWeight := mload(add(data, 0x20))
        }
    }

    /**
     * @notice Calculates the minimum Beans Sown needed to properly calculate delta pod demand.
     * Enforces a minimum threshold for delta pod demand to be calculated, ensuring no manipulation
     * occurs without substantial cost.
     * If less than this amount is sown, Beanstalk assumes demand is decreasing.
     */
    function calcMinSoilDemandThreshold() internal view returns (uint256 minDemandThreshold) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 initialSoil = s.sys.initialSoil;

        // if initial soil is less than the minimum amount of beans to measure demand,
        // set the threshold to the initial soil (all soil must be sown to measure demand)
        if (initialSoil < MIN_BEAN_SOWN_DEMAND) {
            return initialSoil;
        } else {
            // else, use maximum of the minimum bean sown demand and x% of soil
            // this means that the minimum amount of Beans needed to measure demand
            // will be `MIN_BEAN_SOWN_DEMAND` until the initial soil issued is greater than
            // `MIN_BEAN_SOWN_DEMAND` / `MIN_BEAN_SOWN_DEMAND_PERCENT`.
            uint256 soilBasedThreshold = (initialSoil * MIN_BEAN_SOWN_DEMAND_PERCENT) /
                SOIL_PRECISION;
            return
                soilBasedThreshold > MIN_BEAN_SOWN_DEMAND
                    ? MIN_BEAN_SOWN_DEMAND
                    : soilBasedThreshold;
        }
    }
}

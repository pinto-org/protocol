//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {P} from "./P.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Call, IWell, IERC20} from "../../interfaces/basin/IWell.sol";
import {IBeanstalkWellFunction} from "../../interfaces/basin/IBeanstalkWellFunction.sol";
import {C} from "../../C.sol";
import {IBeanstalk} from "../../interfaces/IBeanstalk.sol";
import {IMultiFlowPump} from "contracts/interfaces/basin/IMultiFlowPump.sol";

interface dec {
    function decimals() external view returns (uint256);
}

enum ReservesType {
    CURRENT_RESERVES,
    INSTANTANEOUS_RESERVES,
    CAPPED_RESERVES
}

contract WellPrice {
    using LibRedundantMath256 for uint256;
    using SafeCast for uint256;

    IBeanstalk immutable beanstalk;

    constructor(address _beanstalk) {
        beanstalk = IBeanstalk(_beanstalk);
    }

    uint256 private constant WELL_DECIMALS = 1e18;
    uint256 private constant PRICE_PRECISION = 1e6;

    struct Pool {
        address pool;
        address[2] tokens;
        uint256[2] balances;
        uint256 price;
        uint256 liquidity;
        uint256 beanLiquidity;
        uint256 nonBeanLiquidity;
        int256 deltaB;
        uint256 lpUsd;
        uint256 lpBdv;
    }

    struct SwapData {
        address well;
        address token;
        uint256 usdValue;
        uint256 amountOut;
    }

    /**
     * @notice Returns the non-manipulation resistant on-chain liquidity, deltaB and price data for
     * Bean in a given Well.
     * @dev No protocol should use this function to calculate manipulation resistant Bean price data.
     **/
    function getWell(address wellAddress) public view returns (P.Pool memory) {
        return getWell(wellAddress, ReservesType.CURRENT_RESERVES);
    }

    /**
     * @notice Returns the on-chain liquidity according to the passed in reservesType, deltaB and price data for
     * Bean in a given Well.
     **/
    function getWell(
        address wellAddress,
        ReservesType reservesType
    ) public view returns (P.Pool memory pool) {
        IWell well = IWell(wellAddress);
        pool.pool = wellAddress;
        IERC20[] memory wellTokens = well.tokens();
        pool.tokens = [address(wellTokens[0]), address(wellTokens[1])];
        uint256[] memory wellBalances;
        if (reservesType == ReservesType.INSTANTANEOUS_RESERVES) {
            Call memory pump = well.pumps()[0];
            // Get the readInstantaneousReserves from the pump
            wellBalances = IMultiFlowPump(pump.target).readInstantaneousReserves(
                wellAddress,
                pump.data
            );
        } else if (reservesType == ReservesType.CAPPED_RESERVES) {
            Call memory pump = well.pumps()[0];
            wellBalances = IMultiFlowPump(pump.target).readCappedReserves(wellAddress, pump.data);
        } else {
            // Current reserves
            wellBalances = well.getReserves();
        }
        if (wellBalances[0] == 0 || wellBalances[1] == 0) return pool;
        pool.balances = [wellBalances[0], wellBalances[1]];
        uint256 beanIndex = beanstalk.getBeanIndex(wellTokens);
        uint256 tknIndex = beanIndex == 0 ? 1 : 0;

        // swap 1 bean of the opposite asset to get the bean price
        // price = amtOut/tknOutPrice
        uint256 assetPrice = beanstalk.getMillionUsdPrice(pool.tokens[tknIndex], 0); // $1000000 gets assetPrice worth of tokens
        if (assetPrice > 0) {
            pool.price = well
                .getSwapOut(wellTokens[beanIndex], wellTokens[tknIndex], 1e6)
                .mul(PRICE_PRECISION * PRICE_PRECISION)
                .div(assetPrice);
            pool.nonBeanLiquidity = WELL_DECIMALS.mul(pool.balances[tknIndex]).div(assetPrice).div(
                PRICE_PRECISION
            );
        }

        // liquidity is calculated by getting the usd value of the bean portion of the pool,
        // and the usd value of the non-bean portion of the pool.

        pool.beanLiquidity = pool.balances[beanIndex].mul(pool.price).div(PRICE_PRECISION);

        pool.liquidity = pool.beanLiquidity.add(pool.nonBeanLiquidity);

        // attempt to get deltaB, if it fails, set deltaB to 0.
        try beanstalk.poolCurrentDeltaB(wellAddress) returns (int256 deltaB) {
            pool.deltaB = deltaB;
        } catch {}
        uint256 totalSupply = IERC20(wellAddress).totalSupply();
        if (totalSupply > 0) {
            pool.lpUsd = pool.liquidity.mul(WELL_DECIMALS).div(totalSupply);
        }
        try beanstalk.bdv(wellAddress, WELL_DECIMALS) returns (uint256 bdv) {
            pool.lpBdv = bdv;
        } catch {}
    }

    ////////////////////////// BEAN IN //////////////////////////

    /**
     * @notice given an amount of Beans, return the Well that will yield the
     * largest usd value.
     * @param beans the amount of Beans to consider (Bean has 6 decimals).
     * @return sd the SwapData struct containing the well, token, usd value, and amount out.
     * @dev this is an estimation and not a guarantee.
     * if the usd value is the same for multiple wells, the last well in the whitelist is returned.
     **/
    function getBestWellForBeanIn(uint256 beans) public view returns (SwapData memory sd) {
        address[] memory wells = beanstalk.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < wells.length; i++) {
            SwapData memory wellSwapData = getSwapDataBeanIn(wells[i], beans);
            if (wellSwapData.usdValue > sd.usdValue) {
                sd = wellSwapData;
            }
        }
        return sd;
    }

    /**
     * @notice given an amount of Beans, return the SwapData struct for all wells.
     * @param beans the amount of Beans to consider (Bean has 6 decimal precision).
     * @return sds the SwapData struct for all wells.
     **/
    function getSwapDataBeanInAll(uint256 beans) external view returns (SwapData[] memory sds) {
        address[] memory wells = beanstalk.getWhitelistedWellLpTokens();
        sds = new SwapData[](wells.length);
        for (uint256 i = 0; i < wells.length; i++) {
            sds[i] = getSwapDataBeanIn(wells[i], beans);
        }
        return sds;
    }

    /**
     * @notice given an amount of Beans, return the SwapData struct for a given well.
     * @param well the address of the well.
     * @param beans the amount of Beans to consider (Bean has 6 decimal precision).
     * @return sd the SwapData struct.
     **/
    function getSwapDataBeanIn(
        address well,
        uint256 beans
    ) public view returns (SwapData memory sd) {
        (
            IERC20 beanToken,
            IERC20 nonBeanToken,
            uint256 oneToken,
            uint256 nonBeanTokenUsdPrice
        ) = getTokensAndNonBeanTokenData(well);

        // calculate the token amount out of the well for the given amount of beans
        uint256 tokenAmountOut = IWell(well).getSwapOut(beanToken, nonBeanToken, beans);
        // calculate the usd value of the amount out
        uint256 usdAmountOut = (nonBeanTokenUsdPrice * tokenAmountOut) / oneToken;

        sd.well = well;
        sd.token = address(nonBeanToken);
        sd.usdValue = usdAmountOut;
        sd.amountOut = tokenAmountOut;
        return sd;
    }

    ////////////////////////// USD IN //////////////////////////

    /**
     * @notice given an amount of USD, return the address of the well that will yield the
     * largest amount of Beans.
     * @param usdAmount the amount of USD to consider (6 decimal precision).
     * @return sd the SwapData struct containing the well, token, usd value, and amount out.
     * @dev This is an estimation and not a guarantee.
     * if the amount out is the same for multiple wells, the last well in the whitelist is returned.
     **/
    function getBestWellForUsdIn(uint256 usdAmount) external view returns (SwapData memory sd) {
        address[] memory wells = beanstalk.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < wells.length; i++) {
            SwapData memory wellSwapData = getSwapDataUsdIn(wells[i], usdAmount);
            if (wellSwapData.amountOut > sd.amountOut) {
                sd = wellSwapData;
            }
        }
        return sd;
    }

    /**
     * @notice given an amount of USD, return the SwapData struct for all wells.
     * @param usdAmount the amount of USD to consider (6 decimal precision).
     * @return sds the SwapData struct for all wells.
     **/
    function getSwapDataUsdInAll(uint256 usdAmount) external view returns (SwapData[] memory sds) {
        address[] memory wells = beanstalk.getWhitelistedWellLpTokens();
        sds = new SwapData[](wells.length);
        for (uint256 i = 0; i < wells.length; i++) {
            sds[i] = getSwapDataUsdIn(wells[i], usdAmount);
        }
        return sds;
    }

    /**
     * @notice given an amount of USD, return the SwapData struct for a given well.
     * @param well the address of the well.
     * @param usdAmount the amount of USD to consider (6 decimal precision).
     * @return sd the SwapData struct.
     **/
    function getSwapDataUsdIn(
        address well,
        uint256 usdAmount
    ) public view returns (SwapData memory sd) {
        (
            IERC20 beanToken,
            IERC20 nonBeanToken,
            uint256 oneToken,
            uint256 nonBeanTokenUsdPrice
        ) = getTokensAndNonBeanTokenData(well);
        // calculate the amount out of the well for the given amount of tokens
        uint256 amountIn = (usdAmount * oneToken) / nonBeanTokenUsdPrice;
        // get the amount of beans out of the well
        uint256 beanAmountOut = IWell(well).getSwapOut(nonBeanToken, beanToken, amountIn);
        sd.well = well;
        sd.token = address(nonBeanToken);
        sd.amountOut = beanAmountOut;
        sd.usdValue = usdAmount;
        return sd;
    }

    /**
     * @notice returns the beanToken, nonBeanToken,
     * the amount of 1 non bean token and the nonBeanTokenUsdPrice for a given well.
     **/
    function getTokensAndNonBeanTokenData(
        address well
    ) internal view returns (IERC20, IERC20, uint256, uint256) {
        IERC20[] memory tokens = IWell(well).tokens();

        uint256 beanIndex = beanstalk.getBeanIndex(tokens);
        uint256 tknIndex = beanIndex == 0 ? 1 : 0;

        IERC20 beanToken = tokens[beanIndex];
        IERC20 nonBeanToken = tokens[tknIndex];

        uint256 oneToken = (10 ** dec(address(nonBeanToken)).decimals());
        uint256 nonBeanTokenUsdPrice = beanstalk.getTokenUsdPrice(address(nonBeanToken));
        return (beanToken, nonBeanToken, oneToken, nonBeanTokenUsdPrice);
    }
}

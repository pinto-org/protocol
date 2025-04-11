// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMultiFlowPump} from "contracts/interfaces/basin/IMultiFlowPump.sol";
import {Call, IWell} from "contracts/interfaces/basin/IWell.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {IWellFunction} from "contracts/interfaces/basin/IWellFunction.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title PriceManipulation
 * @author Beanstalk Farms
 * @notice Contract for checking Well deltaP values
 */
contract PriceManipulation {
    uint256 internal constant PRICE_PRECISION = 1e6;
    uint256 internal constant ONE_PINTO = 1e6;
    uint256 internal constant SLIPPAGE_PRECISION = 1e18;

    IBeanstalk public immutable protocol;

    constructor(address protocolAddress) {
        protocol = IBeanstalk(protocolAddress);
    }

    /**
     * @notice Query the well to get current and instant asset prices denominated in Pinto. Ensure
     * that the current price is within the % slippage of the instant price.
     * This price is susceptible to manipulation and this is why an additional check to
     * see if the wells instantaneous and current deltaPs are within a 1% margin is implemented.
     * @param well The well to check the prices of.
     * @param token The token to check the prices of. Must be the token paired with Pinto in the well.
     * @param slippageRatio The % slippage of the instant price. 18 decimal precision.
     * @return valid Whether the price is valid and within slippage bounds.
     */
    function isValidSlippage(
        IWell well,
        IERC20 token,
        uint256 slippageRatio
    ) external returns (bool) {
        Call memory pump = well.pumps()[0];
        Call memory wellFunction = IWell(well).wellFunction();

        (, uint256 nonBeanIndex) = protocol.getNonBeanTokenAndIndexFromWell(address(well));
        uint256 beanIndex = nonBeanIndex == 0 ? 1 : 0;

        // Call sync on well to update pump data and avoid stale reserves.
        well.sync(address(this), 0);

        // Capped reserves are the current reserves capped with the data from the pump.
        uint256[] memory currentReserves = IWell(well).getReserves();

        uint256 currentPintoPerAsset = calculateTokenBeanPriceFromReserves(
            address(token),
            beanIndex,
            nonBeanIndex,
            currentReserves,
            wellFunction
        );
        if (currentPintoPerAsset == 0) return false;

        // InstantaneousReserves are exponential moving average (EMA).
        uint256[] memory instantReserves = IMultiFlowPump(pump.target).readInstantaneousReserves(
            address(well),
            pump.data
        );
        uint256 instantPintoPerAsset = calculateTokenBeanPriceFromReserves(
            address(token),
            beanIndex,
            nonBeanIndex,
            instantReserves,
            wellFunction
        );
        if (instantPintoPerAsset == 0) return false;

        // Current rate must be within slippage bounds relative to instantaneous rate.
        uint256 lowerLimit = instantPintoPerAsset -
            (slippageRatio * instantPintoPerAsset) /
            SLIPPAGE_PRECISION;
        uint256 upperLimit = instantPintoPerAsset +
            (slippageRatio * instantPintoPerAsset) /
            SLIPPAGE_PRECISION;
        if (currentPintoPerAsset < lowerLimit || currentPintoPerAsset > upperLimit) {
            return false;
        }
        return true;
    }

    /**
     * @notice Calculates the token price in terms of Bean by increasing
     * the bean reserves of the given well by 1 and recalculating the new reserves,
     * while maintaining the same liquidity levels.
     * This essentially simulates a swap of 1 Bean for the non bean token and quotes the price.
     * @dev wrapped in a try/catch to return gracefully. 6 decimal precision.
     * @dev Copied from Pinto Protocol internal library function.
     * @return price The price of the token in terms of Pinto.
     */
    function calculateTokenBeanPriceFromReserves(
        address nonBeanToken,
        uint256 beanIndex,
        uint256 nonBeanIndex,
        uint256[] memory reserves,
        Call memory wellFunction
    ) internal view returns (uint256 price) {
        // attempt to calculate the LP token Supply.
        try
            IWellFunction(wellFunction.target).calcLpTokenSupply(reserves, wellFunction.data)
        returns (uint256 lpTokenSupply) {
            uint256 oldReserve = reserves[nonBeanIndex];
            reserves[beanIndex] = reserves[beanIndex] + 1e6; // 1e6 == 1 Pinto.

            try
                IWellFunction(wellFunction.target).calcReserve(
                    reserves,
                    nonBeanIndex,
                    lpTokenSupply,
                    wellFunction.data
                )
            returns (uint256 newReserve) {
                // Measure the delta of the non bean reserve.
                // Due to the invariant of the well function, old reserve > new reserve.
                uint256 delta = oldReserve - newReserve;
                price = (10 ** (IERC20Metadata(nonBeanToken).decimals() + 6)) / delta;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }
}

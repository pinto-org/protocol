// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMorphoOracle} from "./IMorphoOracle.sol";
import {IWell} from "./basin/IWell.sol";

/**
 * @title IPriceManipulation
 * @author Beanstalk Farms
 * @notice Interface for checking Well deltaP values and price aggregation
 */
interface IPriceManipulation is IMorphoOracle {
    /**
     * @notice Query the well to get current and instant asset prices denominated in Pinto. Ensure
     * that the current price is within the % slippage of the instant price.
     * This price is susceptible to manipulation and this is why an additional check to
     * see if the wells instantaneous and current deltaPs are within a 1% margin is implemented.
     * @param well The well to check the prices of.
     * @param slippageRatio The % slippage of the instant price. 18 decimal precision.
     * @return valid Whether the price is valid and within slippage bounds.
     */
    function isValidSlippage(IWell well, uint256 slippageRatio) external returns (bool valid);

    /**
     * @notice The EMA USDC price of Pinto.
     * @dev Price is liquidity weighted across all whitelisted wells.
     * @return pintoPerUsdc The price of one pinto in terms of USD. 24 decimals.
     */
    function aggregatePintoPerUsdc() external view returns (uint256 pintoPerUsdc);

    // Note: price() function is inherited from IMorphoOracle
}

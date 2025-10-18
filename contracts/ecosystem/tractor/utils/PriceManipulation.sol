// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMultiFlowPump} from "contracts/interfaces/basin/IMultiFlowPump.sol";
import {Call, IWell} from "contracts/interfaces/basin/IWell.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {ISiloedPinto} from "contracts/interfaces/ISiloedPinto.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceManipulation} from "contracts/interfaces/IPriceManipulation.sol";
import {LibWell} from "contracts/libraries/Well/LibWell.sol";

/**
 * @title PriceManipulation
 * @author Beanstalk Farms
 * @notice Contract for checking Well deltaP values
 */
contract PriceManipulation is IPriceManipulation {
    uint256 internal constant PINTO_DECIMALS = 1e6;
    uint256 internal constant SLIPPAGE_PRECISION = 1e18;
    uint256 internal constant MILLION = 1e6;

    // Morpho defined decimals as 36 + loan decimals (usdc, 6) - collateral decimals (sPinto, 18).
    uint256 public constant PRICE_DECIMALS = 24;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant S_PINTO = 0x00b174d66adA7d63789087F50A9b9e0e48446dc1;

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
     * @param slippageRatio The % slippage of the instant price. 18 decimal precision.
     * @return valid Whether the price is valid and within slippage bounds.
     */
    function isValidSlippage(IWell well, uint256 slippageRatio) external returns (bool) {
        Call memory pump = well.pumps()[0];
        Call memory wellFunction = well.wellFunction();

        (, uint256 nonBeanIndex) = protocol.getNonBeanTokenAndIndexFromWell(address(well));
        uint256 beanIndex = nonBeanIndex == 0 ? 1 : 0;

        // Call sync on well to update pump data and avoid stale reserves.
        well.sync(address(protocol), 0);

        // Capped reserves are the current reserves capped with the data from the pump.
        uint256[] memory currentReserves = well.getReserves();

        uint256 currentPintoPerAsset = LibWell.calculateTokenBeanPriceFromReserves(
            address(well),
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
        uint256 instantPintoPerAsset = LibWell.calculateTokenBeanPriceFromReserves(
            address(well),
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
     * @notice The EMA USDC price of Pinto.
     * @dev Price is liquidity weighted across all whitelisted wells.
     * @return pintoPerUsdc The price of one pinto in terms of USD. 24 decimals.
     */
    function aggregatePintoPerUsdc() public view returns (uint256 pintoPerUsdc) {
        address[] memory wells = protocol.getWhitelistedWellLpTokens();

        uint256[] memory wellPintoPerUsdc = new uint256[](wells.length); // 6 decimal
        // Total USD value of the well.
        uint256[] memory wellLiquidity = new uint256[](wells.length);
        uint256 totalLiquidity;

        uint256 usdcPerUsd = protocol.getUsdTokenPrice(USDC); // 6 decimal
        require(usdcPerUsd > 0, "Failed to fetch USDC price");

        // Go through each well and collect data.
        for (uint256 i; i < wells.length; i++) {
            IWell well = IWell(wells[i]);
            (address token, uint256 nonBeanIndex) = protocol.getNonBeanTokenAndIndexFromWell(
                address(well)
            );
            uint256 beanIndex = nonBeanIndex == 0 ? 1 : 0;
            uint256 tokenDecimals = IERC20Metadata(token).decimals();

            uint256 pintoPerMillionUsd;

            Call memory pump = well.pumps()[0];
            // Instant reserves are the EMA reserves.
            uint256[] memory instantReserves = IMultiFlowPump(pump.target)
                .readInstantaneousReserves(address(well), pump.data);

            // Calculate the price of the token in terms of Pinto.
            uint256 pintoPerToken = LibWell.calculateTokenBeanPriceFromReserves(
                address(well),
                beanIndex,
                nonBeanIndex,
                instantReserves,
                well.wellFunction()
            ); // 6 decimal
            if (pintoPerToken == 0) {
                continue;
            }

            uint256 tokenPerMillionUsd = protocol.getMillionUsdPrice(token, 0); // decimals match token
            if (tokenPerMillionUsd == 0) {
                continue;
            }
            pintoPerMillionUsd = (pintoPerToken * tokenPerMillionUsd) / PINTO_DECIMALS; // decimals match token
            wellLiquidity[i] =
                instantReserves[beanIndex] /
                pintoPerMillionUsd /
                MILLION /
                (10 ** tokenDecimals) +
                (instantReserves[nonBeanIndex] * MILLION) /
                tokenPerMillionUsd;

            totalLiquidity += wellLiquidity[i];
            wellPintoPerUsdc[i] =
                (10 ** (PRICE_DECIMALS - tokenDecimals) * pintoPerMillionUsd) /
                usdcPerUsd; // 24 decimals
        }

        require(totalLiquidity > 0, "failed to retrieve reserves");

        for (uint256 i; i < wells.length; i++) {
            if (wellLiquidity[i] == 0) continue;
            pintoPerUsdc += (wellPintoPerUsdc[i] * wellLiquidity[i]) / totalLiquidity; // 24 decimals
        }
    }

    /**
     * @notice The EMA USDC price of sPinto.
     * @dev Price is liquidity weighted across all whitelisted wells.
     * @dev Reference https://docs.morpho.org/morpho/contracts/oracles/
     * @return usdcPerSPinto The price of one sPinto in terms of USDC. 24 decimals.
     */
    function price() public view override returns (uint256 usdcPerSPinto) {
        uint256 pintoPerUsdc = aggregatePintoPerUsdc(); // 24 decimals
        uint256 pintoPerSPinto = ISiloedPinto(S_PINTO).previewRedeem(1e18); // 6 decimal
        usdcPerSPinto = ((10 ** (PRICE_DECIMALS * 2 - 6)) * pintoPerSPinto) / pintoPerUsdc; // 24 decimals
    }
}

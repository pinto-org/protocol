// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {C} from "contracts/C.sol";
import {LibWell} from "../Well/LibWell.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibRedundantMathSigned256} from "contracts/libraries/Math/LibRedundantMathSigned256.sol";
import {Call, IWell} from "contracts/interfaces/basin/IWell.sol";
import {ICappedReservesPump} from "contracts/interfaces/basin/pumps/ICappedReservesPump.sol";
import {IInstantaneousPump} from "contracts/interfaces/basin/pumps/IInstantaneousPump.sol";
import {IBeanstalkWellFunction} from "contracts/interfaces/basin/IBeanstalkWellFunction.sol";
import {LibAppStorage, AppStorage} from "contracts/libraries/LibAppStorage.sol";

/**
 * @title LibDeltaB
 */

library LibDeltaB {
    using LibRedundantMath256 for uint256;
    using LibRedundantMathSigned256 for int256;

    uint256 internal constant ZERO_LOOKBACK = 0;

    /**
     * @param token The token to get the deltaB of.
     * @return The deltaB of the token, for Bean it returns 0.
     */
    function getCurrentDeltaB(address token) internal view returns (int256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (token == s.sys.bean) {
            return 0;
        }

        int256 deltaB = LibDeltaB.currentDeltaB(token);
        return deltaB;
    }

    /**
     * @dev Calculates the current deltaB for a given Well address.
     * @param well The address of the Well.
     * @return The current deltaB uses the current reserves in the well.
     */
    function currentDeltaB(address well) internal view returns (int256) {
        try IWell(well).getReserves() returns (uint256[] memory reserves) {
            uint256 beanIndex = LibWell.getBeanIndex(IWell(well).tokens());
            // if less than minimum bean balance, return 0, otherwise
            // calculateDeltaBFromReserves will revert
            if (reserves[beanIndex] < C.WELL_MINIMUM_BEAN_BALANCE) {
                return 0;
            }
            return calculateDeltaBFromReserves(well, reserves, ZERO_LOOKBACK);
        } catch {
            return 0;
        }
    }

    /**
     * @notice returns the overall current deltaB for all whitelisted well tokens.
     */
    function overallCurrentDeltaB() internal view returns (int256 deltaB) {
        address[] memory tokens = LibWhitelistedTokens.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            int256 wellDeltaB = currentDeltaB(tokens[i]);
            deltaB = deltaB.add(wellDeltaB);
        }
    }

    /**
     * @notice returns the instant reserves for a given well.
     * @dev empty array is returned if the well call reverts.
     * @return instReserves The reserves for the given well.
     */
    function instantReserves(address well) internal view returns (uint256[] memory) {
        // get first pump from well
        Call[] memory pumps = IWell(well).pumps();
        address pump = pumps[0].target;

        try IInstantaneousPump(pump).readInstantaneousReserves(well, pumps[0].data) returns (
            uint256[] memory instReserves
        ) {
            return instReserves;
        } catch {
            return new uint256[](0);
        }
    }

    /**
     * @notice returns the capped reserves for a given well.
     * @dev empty array is returned if the well call reverts.
     * @return cappedReserves The capped reserves for the given well.
     */
    function cappedReserves(address well) internal view returns (uint256[] memory) {
        // get first pump from well
        Call[] memory pumps = IWell(well).pumps();
        address pump = pumps[0].target;

        try ICappedReservesPump(pump).readCappedReserves(well, pumps[0].data) returns (
            uint256[] memory reserves
        ) {
            return reserves;
        } catch {
            return new uint256[](0);
        }
    }

    /**
     * @notice returns the overall cappedReserves deltaB for all whitelisted well tokens.
     */
    function cappedReservesDeltaB(address well) internal view returns (int256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (well == s.sys.bean) {
            return 0;
        }

        uint256[] memory instReserves = cappedReserves(well);
        if (instReserves.length == 0) {
            return 0;
        }
        // if less than minimum bean balance, return 0, otherwise
        // calculateDeltaBFromReserves will revert
        if (instReserves[LibWell.getBeanIndexFromWell(well)] < C.WELL_MINIMUM_BEAN_BALANCE) {
            return 0;
        }
        // calculate deltaB.
        return calculateDeltaBFromReserves(well, instReserves, ZERO_LOOKBACK);
    }

    // Calculates overall deltaB, used by convert for stalk penalty purposes
    function overallCappedDeltaB() internal view returns (int256 deltaB) {
        address[] memory tokens = LibWhitelistedTokens.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            int256 cappedDeltaB = cappedReservesDeltaB(tokens[i]);
            deltaB = deltaB.add(cappedDeltaB);
        }
    }

    /**
     * @notice returns the LP supply for each whitelisted well
     */
    function getLpSupply() internal view returns (uint256[] memory lpSupply) {
        address[] memory tokens = LibWhitelistedTokens.getWhitelistedWellLpTokens();
        lpSupply = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            lpSupply[i] = IERC20(tokens[i]).totalSupply();
        }
    }

    /**
     * @notice returns the overall instantaneous deltaB for all whitelisted well tokens,
     * scaled by the change in LP supply.
     * @dev used in pipelineConvert.
     */
    function scaledOverallCurrentDeltaB(
        uint256[] memory lpSupply
    ) internal view returns (int256 deltaB) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        address[] memory tokens = LibWhitelistedTokens.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == s.sys.bean) continue;
            int256 wellDeltaB = scaledCurrentDeltaB(tokens[i], lpSupply[i]);
            deltaB = deltaB.add(wellDeltaB);
        }
    }

    function scaledCurrentDeltaB(
        address well,
        uint256 lpSupply
    ) internal view returns (int256 wellDeltaB) {
        wellDeltaB = currentDeltaB(well);
        if (wellDeltaB == 0) return 0; // prevent divide by zero
        wellDeltaB = scaledDeltaB(lpSupply, IERC20(well).totalSupply(), wellDeltaB);
    }

    /*
     * @notice returns the scaled deltaB, based on LP supply before and after convert
     */
    function scaledDeltaB(
        uint256 beforeLpTokenSupply,
        uint256 afterLpTokenSupply,
        int256 deltaB
    ) internal pure returns (int256) {
        return deltaB.mul(int256(beforeLpTokenSupply)).div(int(afterLpTokenSupply));
    }

    /**
     * @notice calculates the deltaB for a given well using the reserves.
     * @dev reverts if the bean reserve is less than the minimum,
     * or if the usd oracle fails.
     * This differs from the twaDeltaB, as this function should not be used within the sunrise function.
     */
    function calculateDeltaBFromReserves(
        address well,
        uint256[] memory reserves,
        uint256 lookback
    ) internal view returns (int256) {
        IERC20[] memory tokens = IWell(well).tokens();
        Call memory wellFunction = IWell(well).wellFunction();

        (uint256[] memory ratios, uint256 beanIndex, bool success) = LibWell.getRatiosAndBeanIndex(
            tokens,
            lookback
        );

        // Converts cannot be performed, if the Bean reserve is less than the minimum
        if (reserves[beanIndex] < C.WELL_MINIMUM_BEAN_BALANCE) {
            revert("Well: Bean reserve is less than the minimum");
        }

        // If the USD Oracle call fails, a deltaB cannot be determined.
        if (!success) {
            revert("Well: USD Oracle call failed");
        }

        try
            IBeanstalkWellFunction(wellFunction.target).calcReserveAtRatioSwap(
                reserves,
                beanIndex,
                ratios,
                wellFunction.data
            )
        returns (uint256 reserve) {
            return int256(reserve).sub(int256(reserves[beanIndex]));
        } catch {
            return 0;
        }
    }

    /**
     * @notice Calculates deltaB for single-sided liquidity operations (converts).
     * @dev Reverts if bean reserve < minimum or oracle fails.
     * @param well The address of the Well
     * @param reserves The reserves to calculate deltaB from
     * @param lookback The lookback period for price ratios
     * @return deltaB (target bean reserve - actual bean reserve)
     */
    function calculateDeltaBFromReservesLiquidity(
        address well,
        uint256[] memory reserves,
        uint256 lookback
    ) internal view returns (int256) {
        IERC20[] memory tokens = IWell(well).tokens();
        Call memory wellFunction = IWell(well).wellFunction();

        (uint256[] memory ratios, uint256 beanIndex, bool success) = LibWell.getRatiosAndBeanIndex(
            tokens,
            lookback
        );

        // Converts cannot be performed, if the Bean reserve is less than the minimum
        if (reserves[beanIndex] < C.WELL_MINIMUM_BEAN_BALANCE) {
            revert("Well: Bean reserve is less than the minimum");
        }

        // If the USD Oracle call fails, a deltaB cannot be determined
        if (!success) {
            revert("Well: USD Oracle call failed");
        }

        uint256 reserve = IBeanstalkWellFunction(wellFunction.target).calcReserveAtRatioLiquidity(
            reserves,
            beanIndex,
            ratios,
            wellFunction.data
        );
        return int256(reserve).sub(int256(reserves[beanIndex]));
    }

    /**
     * @notice Calculates the maximum deltaB impact for a given input amount.
     * @dev Uses capped reserves (TWAP-based) to simulate the conversion.
     * Returns |deltaB_before - deltaB_after| for the affected well.
     * @param inputToken The token being converted from (Bean or LP token)
     * @param fromAmount The amount of input token being converted
     * @param targetWell The Well involved in the conversion
     * @return maxDeltaBImpact Maximum possible deltaB change from this conversion
     */
    function calculateMaxDeltaBImpact(
        address inputToken,
        uint256 fromAmount,
        address targetWell
    ) internal view returns (uint256 maxDeltaBImpact) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        if (inputToken == s.sys.bean) {
            // Bean input: calculate deltaB impact of adding beans to targetWell

            if (!LibWell.isWell(targetWell)) return 0;

            uint256[] memory reserves = cappedReserves(targetWell);
            require(reserves.length > 0, "Convert: Failed to read capped reserves");

            uint256 beanIndex = LibWell.getBeanIndexFromWell(targetWell);
            require(
                reserves[beanIndex] >= C.WELL_MINIMUM_BEAN_BALANCE,
                "Well: Bean reserve is less than the minimum"
            );

            int256 beforeDeltaB = calculateDeltaBFromReservesLiquidity(
                targetWell,
                reserves,
                ZERO_LOOKBACK
            );

            // Simulate single sided Bean addition
            reserves[beanIndex] = reserves[beanIndex] + fromAmount;

            int256 afterDeltaB = calculateDeltaBFromReservesLiquidity(
                targetWell,
                reserves,
                ZERO_LOOKBACK
            );

            maxDeltaBImpact = _abs(beforeDeltaB - afterDeltaB);
        } else if (LibWhitelistedTokens.wellIsOrWasSoppable(inputToken)) {
            // LP input: calculate deltaB impact of removing liquidity from inputToken well
            uint256[] memory reserves = cappedReserves(inputToken);
            require(reserves.length > 0, "Convert: Failed to read capped reserves");

            uint256 beanIndex = LibWell.getBeanIndexFromWell(inputToken);
            require(
                reserves[beanIndex] >= C.WELL_MINIMUM_BEAN_BALANCE,
                "Well: Bean reserve is less than the minimum"
            );

            Call memory wellFunction = IWell(inputToken).wellFunction();

            uint256 theoreticalLpSupply = IBeanstalkWellFunction(wellFunction.target)
                .calcLpTokenSupply(reserves, wellFunction.data);

            require(theoreticalLpSupply > 0, "Convert: Theoretical LP supply is zero");

            // Calculate deltaB before removal using liquidity based calculation
            int256 beforeDeltaB = calculateDeltaBFromReservesLiquidity(
                inputToken,
                reserves,
                ZERO_LOOKBACK
            );

            if (fromAmount >= theoreticalLpSupply) {
                return _abs(beforeDeltaB);
            }

            uint256 newLpSupply = theoreticalLpSupply - fromAmount;

            // Calculate new Bean reserve using calcReserve for single sided removal
            reserves[beanIndex] = IBeanstalkWellFunction(wellFunction.target).calcReserve(
                reserves,
                beanIndex,
                newLpSupply,
                wellFunction.data
            );

            if (reserves[beanIndex] < C.WELL_MINIMUM_BEAN_BALANCE) {
                return _abs(beforeDeltaB);
            }

            int256 afterDeltaB = calculateDeltaBFromReservesLiquidity(
                inputToken,
                reserves,
                ZERO_LOOKBACK
            );

            maxDeltaBImpact = uint256(afterDeltaB - beforeDeltaB);
        } else {
            revert("Convert: inputToken must be Bean or Well");
        }
    }

    /**
     * @dev Returns the absolute value of a signed integer as an unsigned integer.
     */
    function _abs(int256 x) private pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}

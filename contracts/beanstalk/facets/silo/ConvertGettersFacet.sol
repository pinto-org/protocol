/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {AppStorage, LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibWellMinting} from "contracts/libraries/Minting/LibWellMinting.sol";
import {LibDeltaB} from "contracts/libraries/Oracle/LibDeltaB.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";
import {C} from "contracts/C.sol";
/**
 * @title ConvertGettersFacet contains view functions related to converting Deposited assets.
 **/
contract ConvertGettersFacet {
    using LibRedundantMath256 for uint256;

    /**
     * @notice Returns the maximum amount that can be converted of `tokenIn` to `tokenOut`.
     */
    function getMaxAmountIn(
        address tokenIn,
        address tokenOut
    ) external view returns (uint256 amountIn) {
        return LibConvert.getMaxAmountIn(tokenIn, tokenOut);
    }

    /**
     * @notice Returns the amount of `tokenOut` recieved from converting `amountIn` of `tokenIn`.
     */
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        return LibConvert.getAmountOut(tokenIn, tokenOut, amountIn);
    }

    function overallCappedDeltaB() external view returns (int256 deltaB) {
        return LibDeltaB.overallCappedDeltaB();
    }

    /**
     * @notice returns the overall current deltaB for all whitelisted well tokens.
     */
    function overallCurrentDeltaB() external view returns (int256 deltaB) {
        return LibDeltaB.overallCurrentDeltaB();
    }

    /*
     * @notice returns the scaled deltaB, based on LP supply before and after convert
     */
    function scaledDeltaB(
        uint256 beforeLpTokenSupply,
        uint256 afterLpTokenSupply,
        int256 deltaB
    ) external pure returns (int256) {
        return LibDeltaB.scaledDeltaB(beforeLpTokenSupply, afterLpTokenSupply, deltaB);
    }

    /**
     * @notice Returns the multi-block MEV resistant deltaB for a given token using capped reserves from the well.
     * @param well The well for which to return the capped reserves deltaB
     * @return deltaB The capped reserves deltaB for the well
     */
    function cappedReservesDeltaB(address well) external view returns (int256 deltaB) {
        return LibDeltaB.cappedReservesDeltaB(well);
    }

    /**
     * @notice calculates the deltaB for a given well using the reserves.
     * @dev reverts if the bean reserve is less than the minimum,
     * or if the usd oracle fails.
     * This differs from the twaDeltaB, as this function should not be used within the sunrise function.
     * @return deltaB The deltaB using the reserves.
     */
    function calculateDeltaBFromReserves(
        address well,
        uint256[] memory reserves,
        uint256 lookback
    ) external view returns (int256) {
        return LibDeltaB.calculateDeltaBFromReserves(well, reserves, lookback);
    }

    /**
     * @notice Returns currently available convert power for this block
     * @return convertCapacity The amount of convert power available for this block
     */
    function getOverallConvertCapacity() external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 _overallCappedDeltaB = LibConvert.abs(LibDeltaB.overallCappedDeltaB());
        uint256 overallConvertCapacityUsed = s
            .sys
            .convertCapacity[block.number]
            .overallConvertCapacityUsed;
        return
            overallConvertCapacityUsed > _overallCappedDeltaB
                ? 0
                : _overallCappedDeltaB.sub(overallConvertCapacityUsed);
    }

    /**
     * @notice returns the Convert Capacity for a given well
     * @dev the convert capacity is the amount of deltaB that can be converted in a block.
     * This is a function of the capped reserves deltaB.
     */
    function getWellConvertCapacity(address well) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return
            LibConvert.abs(LibDeltaB.cappedReservesDeltaB(well)).sub(
                s.sys.convertCapacity[block.number].wellConvertCapacityUsed[well]
            );
    }

    /**
     * @notice Calculates the bdv penalized by a convert.
     * @dev See {LibConvert.calculateStalkPenalty}.
     */
    function calculateStalkPenalty(
        LibConvert.DeltaBStorage memory dbs,
        uint256 bdvConverted,
        uint256 overallConvertCapacity,
        address inputToken,
        address outputToken
    )
        external
        view
        returns (
            uint256 stalkPenaltyBdv,
            uint256 overallConvertCapacityUsed,
            uint256 inputTokenAmountUsed,
            uint256 outputTokenAmountUsed
        )
    {
        return
            LibConvert.calculateStalkPenalty(
                dbs,
                bdvConverted,
                overallConvertCapacity,
                inputToken,
                outputToken
            );
    }

    /**
     * @notice Returns the amount of grown stalk remaining after application of down penalty.
     * @dev Germinating deposits are not penalized.
     * @dev Does not factor in other sources of stalk change during convert.
     * @return newGrownStalk Amount of grown stalk to assign the output deposit.
     * @return grownStalkLost Amount of grown stalk lost due to down penalty.
     */
    function downPenalizedGrownStalk(
        address well,
        uint256 bdvToConvert,
        uint256 grownStalkToConvert
    ) external view returns (uint256 newGrownStalk, uint256 grownStalkLost) {
        return LibConvert.downPenalizedGrownStalk(well, bdvToConvert, grownStalkToConvert);
    }

    /**
     * @notice Returns the bonus stalk per bdv and the maximum convert capacity.
     * @dev The convert up bonus kicks in after 12 seasons below peg.
     */
    function getConvertStalkPerBdvBonusAndMaximumCapacity()
        external
        view
        returns (uint256, uint256)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
            s.sys.gaugeData.gauges[GaugeId.CONVERT_UP_BONUS].value,
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );

        uint256 bonusStalkPerBdv = (gv.baseBonusStalkPerBdv * gv.convertCapacityFactor) /
            C.PRECISION;
        return (bonusStalkPerBdv, gv.maxConvertCapacity);
    }

    /**
     * @notice Returns the bonus stalk per bdv and the remaining convert capacity.
     * @dev The convert up bonus kicks in after 12 seasons below peg.
     */
    function getConvertStalkPerBdvBonusAndRemainingCapacity()
        external
        view
        returns (uint256, uint256)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
            s.sys.gaugeData.gauges[GaugeId.CONVERT_UP_BONUS].value,
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );

        LibGaugeHelpers.ConvertBonusGaugeData memory gd = abi.decode(
            s.sys.gaugeData.gauges[GaugeId.CONVERT_UP_BONUS].data,
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        uint256 bonusStalkPerBdv = (gv.baseBonusStalkPerBdv * gv.convertCapacityFactor) /
            C.PRECISION;

        if (gd.thisSeasonBdvConverted >= gv.maxConvertCapacity) {
            return (bonusStalkPerBdv, 0);
        }

        return (bonusStalkPerBdv, gv.maxConvertCapacity - gd.thisSeasonBdvConverted);
    }

    /**
     * @notice Returns the peg cross stem for a given token.
     * @dev The peg cross stem is the stem of a token when bean crossed below peg.
     */
    function getPegCrossStem(address token) external view returns (int96) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.sys.belowPegCrossStems[token];
    }

    /**
     * @notice Returns the base bonus stalk per bdv for the current season.
     */
    function getCalculatedBaseBonusStalkPerBdv() external view returns (uint256) {
        return LibConvert.getCurrentBaseBonusStalkPerBdv();
    }

    /**
     * @notice Returns the amount of grown stalk gained from the convert up bonus.
     * @dev Users start receiving a bonus for converting up when bean is below peg for at least 12 seasons.
     * @param bdvToConvert The resulting bdv of the convert.
     * @return bdvCapacityUsed The amount of bdv that got the bonus.
     * @return grownStalkGained The amount of grown stalk gained from the bonus.
     */
    function stalkBonus(
        uint256 bdvToConvert
    ) external view returns (uint256 bdvCapacityUsed, uint256 grownStalkGained) {
        return LibConvert.stalkBonus(bdvToConvert);
    }
}

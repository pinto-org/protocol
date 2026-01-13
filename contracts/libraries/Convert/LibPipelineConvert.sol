// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {C} from "contracts/C.sol";
import {LibConvert} from "./LibConvert.sol";
import {AdvancedPipeCall} from "contracts/interfaces/IPipeline.sol";
import {LibWell} from "../Well/LibWell.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {LibDeltaB} from "contracts/libraries/Oracle/LibDeltaB.sol";
import {IPipeline, PipeCall} from "contracts/interfaces/IPipeline.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {LibTokenSilo} from "contracts/libraries/Silo/LibTokenSilo.sol";
import {LibAppStorage, AppStorage} from "contracts/libraries/LibAppStorage.sol";

/**
 * @title LibPipelineConvert
 */
library LibPipelineConvert {
    using LibConvertData for bytes;
    /**
     * @notice contains data for a convert that uses Pipeline.
     */
    struct PipelineConvertData {
        uint256 grownStalk;
        LibConvert.DeltaBStorage deltaB;
        uint256 inputAmount;
        uint256 overallConvertCapacity;
        uint256 stalkPenaltyBdv;
        address user;
        uint256 newBdv;
        uint256[] initialLpSupply;
        uint256 initialGrownStalk;
        int256 beforeSpotOverallDeltaB;
    }

    function executePipelineConvert(
        address inputToken,
        address outputToken,
        uint256 fromAmount,
        uint256 fromBdv,
        uint256 initialGrownStalk,
        AdvancedPipeCall[] memory advancedPipeCalls
    ) external returns (uint256 toAmount, uint256 newGrownStalk, uint256 newBdv) {
        PipelineConvertData memory pipeData = LibPipelineConvert.populatePipelineConvertData(
            inputToken,
            outputToken
        );

        // Store the capped overall deltaB, this limits the overall convert power for the block
        pipeData.overallConvertCapacity = LibConvert.abs(LibDeltaB.overallCappedDeltaB());

        IERC20(inputToken).transfer(C.PIPELINE, fromAmount);
        IPipeline(C.PIPELINE).advancedPipe(advancedPipeCalls);

        // user MUST leave final assets in pipeline, allowing us to verify that the farm has been called successfully.
        // this also let's us know how many assets to attempt to pull out of the final type
        toAmount = transferTokensFromPipeline(outputToken);

        newBdv = LibTokenSilo.beanDenominatedValue(outputToken, toAmount);

        // Calculate stalk penalty using start/finish deltaB of pools, and the capped deltaB is
        // passed in to setup max convert power.
        pipeData.stalkPenaltyBdv = prepareStalkPenaltyCalculation(
            inputToken,
            outputToken,
            pipeData.deltaB,
            pipeData.overallConvertCapacity,
            newBdv,
            pipeData.initialLpSupply,
            pipeData.beforeSpotOverallDeltaB,
            fromAmount
        );

        // scale initial grown stalk proportionally to the bdv lost (if any)
        if (newBdv < fromBdv) {
            initialGrownStalk = (initialGrownStalk * newBdv) / fromBdv;
        }

        // Update grownStalk amount with penalty applied
        newGrownStalk = (initialGrownStalk * (newBdv - pipeData.stalkPenaltyBdv)) / newBdv;
    }

    /**
     * @notice Calculates the stalk penalty for a convert. Updates convert capacity used.
     * @dev Uses TWAP as a manipulation-resistant baseline and measures actual spot price changes
     * to determine the convert's impact on deltaB.
     */
    function prepareStalkPenaltyCalculation(
        address inputToken,
        address outputToken,
        LibConvert.DeltaBStorage memory dbs,
        uint256 overallConvertCapacity,
        uint256 toBdv,
        uint256[] memory initialLpSupply,
        int256 beforeSpotOverallDeltaB,
        uint256 inputAmount
    ) public returns (uint256) {
        {
            int256 spotAfter = LibDeltaB.scaledOverallCurrentDeltaB(initialLpSupply);
            dbs.afterOverallDeltaB =
                dbs.beforeOverallDeltaB +
                (spotAfter - beforeSpotOverallDeltaB);
        }

        // modify afterInputTokenDeltaB and afterOutputTokenDeltaB to scale using before/after LP amounts
        if (LibWell.isWell(inputToken)) {
            uint256 i = LibWhitelistedTokens.getIndexFromWhitelistedWellLpTokens(inputToken);
            // input token supply was burned, check to avoid division by zero
            uint256 currentInputTokenSupply = IERC20(inputToken).totalSupply();
            dbs.afterInputTokenDeltaB = currentInputTokenSupply == 0
                ? int256(0)
                : LibDeltaB.scaledDeltaB(
                    initialLpSupply[i],
                    currentInputTokenSupply,
                    LibDeltaB.getCurrentDeltaB(inputToken)
                );
        }

        if (LibWell.isWell(outputToken)) {
            uint256 i = LibWhitelistedTokens.getIndexFromWhitelistedWellLpTokens(outputToken);
            dbs.afterOutputTokenDeltaB = LibDeltaB.scaledDeltaB(
                initialLpSupply[i],
                IERC20(outputToken).totalSupply(),
                LibDeltaB.getCurrentDeltaB(outputToken)
            );
        }

        return
            LibConvert.applyStalkPenalty(
                dbs,
                toBdv,
                overallConvertCapacity,
                inputToken,
                outputToken,
                inputAmount
            );
    }

    /**
     * @notice Determines input token amount left in pipeline and returns to Beanstalk
     * @param tokenOut The token to pull out of pipeline
     */
    function transferTokensFromPipeline(address tokenOut) internal returns (uint256 amountOut) {
        amountOut = IERC20(tokenOut).balanceOf(C.PIPELINE);
        require(amountOut > 0, "Convert: No output tokens left in pipeline");

        PipeCall memory p;
        p.target = address(tokenOut);
        p.data = abi.encodeWithSelector(IERC20.transfer.selector, address(this), amountOut);
        C.pipeline().pipe(p);
    }

    function populatePipelineConvertData(
        address fromToken,
        address toToken
    ) internal view returns (PipelineConvertData memory pipeData) {
        // Use TWAP-based deltaB as baseline (resistant to flash loan manipulation).
        pipeData.deltaB.beforeOverallDeltaB = LibDeltaB.overallCappedDeltaB();
        // Store current spot deltaB to measure actual change after convert.
        pipeData.beforeSpotOverallDeltaB = LibDeltaB.overallCurrentDeltaB();
        pipeData.deltaB.beforeInputTokenDeltaB = LibDeltaB.getCurrentDeltaB(fromToken);
        pipeData.deltaB.beforeOutputTokenDeltaB = LibDeltaB.getCurrentDeltaB(toToken);
        pipeData.initialLpSupply = LibDeltaB.getLpSupply();
    }

    /**
     * @notice Determines the convert state and populates pipeline data if necessary
     */
    function getConvertState(
        bytes calldata convertData
    ) public view returns (PipelineConvertData memory pipeData) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LibConvertData.ConvertKind kind = convertData.convertKind();
        address toToken;
        address fromToken;
        if (
            kind == LibConvertData.ConvertKind.BEANS_TO_WELL_LP ||
            kind == LibConvertData.ConvertKind.WELL_LP_TO_BEANS
        ) {
            if (kind == LibConvertData.ConvertKind.BEANS_TO_WELL_LP) {
                (, , toToken) = convertData.convertWithAddress();
                fromToken = s.sys.bean;
                require(LibWell.isWell(toToken), "Convert: Invalid Well");
            } else {
                (, , fromToken) = convertData.convertWithAddress();
                toToken = s.sys.bean;
                require(
                    LibWhitelistedTokens.wellIsOrWasSoppable(fromToken),
                    "Convert: Invalid Well"
                );
            }

            pipeData = populatePipelineConvertData(fromToken, toToken);
        }
    }

    /**
     * @notice reverts if the convert would be penalized.
     * @dev used in {ConvertFacet.convert}
     */
    function checkForValidConvertAndUpdateConvertCapacity(
        PipelineConvertData memory pipeData,
        bytes calldata convertData,
        address fromToken,
        address toToken,
        uint256 toBdv,
        uint256 fromAmount
    ) public returns (uint256 grownStalk) {
        LibConvertData.ConvertKind kind = convertData.convertKind();
        if (
            kind == LibConvertData.ConvertKind.BEANS_TO_WELL_LP ||
            kind == LibConvertData.ConvertKind.WELL_LP_TO_BEANS
        ) {
            pipeData.overallConvertCapacity = LibConvert.abs(LibDeltaB.overallCappedDeltaB());

            pipeData.stalkPenaltyBdv = prepareStalkPenaltyCalculation(
                fromToken,
                toToken,
                pipeData.deltaB,
                pipeData.overallConvertCapacity,
                toBdv,
                pipeData.initialLpSupply,
                pipeData.beforeSpotOverallDeltaB,
                fromAmount
            );

            // apply penalty to grown stalk as a % of bdv converted. See {LibConvert.executePipelineConvert}
            grownStalk = (pipeData.grownStalk * (toBdv - pipeData.stalkPenaltyBdv)) / toBdv;
        } else {
            // apply no penalty to non BEANS_TO_WELL_LP or WELL_LP_TO_BEANS conversions.
            grownStalk = pipeData.grownStalk;
        }
    }
}

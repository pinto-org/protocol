/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import "../../beanstalk/facets/silo/PipelineConvertFacet.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";

/**
 * @title Mock Pipeline Convert Facet
 **/
contract MockPipelineConvertFacet is PipelineConvertFacet {
    function calculateConvertCapacityPenaltyE(
        uint256 overallCappedDeltaB,
        uint256 overallAmountInDirectionOfPeg,
        address inputToken,
        uint256 inputTokenAmountInDirectionOfPeg,
        address outputToken,
        uint256 outputTokenAmountInDirectionOfPeg
    )
        external
        view
        returns (
            uint256 cumulativePenalty,
            LibConvert.PenaltyData memory pdCapacity,
            address targetWell,
            uint256[] memory targetWellReserves
        )
    {
        (cumulativePenalty, pdCapacity, targetWell, targetWellReserves) = LibConvert
            .calculateConvertCapacityPenalty(
                overallCappedDeltaB,
                overallAmountInDirectionOfPeg,
                inputToken,
                inputTokenAmountInDirectionOfPeg,
                outputToken,
                outputTokenAmountInDirectionOfPeg
            );
    }
}

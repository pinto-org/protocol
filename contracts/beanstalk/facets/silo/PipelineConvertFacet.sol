/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {C} from "contracts/C.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {AdvancedPipeCall} from "contracts/interfaces/IPipeline.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibSilo} from "contracts/libraries/Silo/LibSilo.sol";
import {LibRedundantMath32} from "contracts/libraries/Math/LibRedundantMath32.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibWell} from "contracts/libraries/Well/LibWell.sol";
import {LibRedundantMathSigned256} from "contracts/libraries/Math/LibRedundantMathSigned256.sol";
import {LibPipelineConvert} from "contracts/libraries/Convert/LibPipelineConvert.sol";
import {LibDeltaB} from "contracts/libraries/Oracle/LibDeltaB.sol";

/**
 * @title PipelineConvertFacet handles converting Deposited assets within the Silo,
 * using pipeline.
 * @dev `pipelineConvert` uses a series of pipeline calls to convert assets.
 **/
contract PipelineConvertFacet is Invariable, ReentrancyGuard {
    using LibRedundantMathSigned256 for int256;
    using SafeCast for uint256;
    using LibRedundantMath256 for uint256;
    using SafeCast for uint256;
    using LibRedundantMath32 for uint32;

    event Convert(
        address indexed account,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount,
        uint256 fromBdv,
        uint256 toBdv
    );

    struct pipelineReturnParams {
        int96 toStem;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 fromBdv;
        uint256 toBdv;
    }

    /**
     * @notice See {_pipelineConvert()}.
     */
    function pipelineConvert(
        address inputToken,
        int96[] calldata stems,
        uint256[] calldata amounts,
        address outputToken,
        AdvancedPipeCall[] memory advancedPipeCalls
    )
        external
        payable
        fundsSafu
        nonReentrant
        returns (int96 toStem, uint256 fromAmount, uint256 toAmount, uint256 fromBdv, uint256 toBdv)
    {
        // set grown stalk slippage to max (i.e, the user is willing to take any stalk penalty).
        pipelineReturnParams memory returnParams = _pipelineConvert(
            inputToken,
            stems,
            amounts,
            outputToken,
            LibConvert.MAX_GROWN_STALK_SLIPPAGE,
            advancedPipeCalls
        );
        return (
            returnParams.toStem,
            returnParams.fromAmount,
            returnParams.toAmount,
            returnParams.fromBdv,
            returnParams.toBdv
        );
    }

    /**
     * @notice See {_pipelineConvert()}.
     * a variant of the pipelineConvert function that allows a
     * user to specify a grown stalk slippage tolerance.
     */
    function pipelineConvertWithStalkSlippage(
        address inputToken,
        int96[] calldata stems,
        uint256[] calldata amounts,
        address outputToken,
        uint256 grownStalkSlippage,
        AdvancedPipeCall[] memory advancedPipeCalls
    )
        external
        payable
        fundsSafu
        nonReentrant
        returns (int96 toStem, uint256 fromAmount, uint256 toAmount, uint256 fromBdv, uint256 toBdv)
    {
        pipelineReturnParams memory returnParams = _pipelineConvert(
            inputToken,
            stems,
            amounts,
            outputToken,
            grownStalkSlippage,
            advancedPipeCalls
        );
        return (
            returnParams.toStem,
            returnParams.fromAmount,
            returnParams.toAmount,
            returnParams.fromBdv,
            returnParams.toBdv
        );
    }

    /**
     * @notice Pipeline convert allows any type of convert using a series of
     * pipeline calls. A stalk penalty may be applied if the convert crosses deltaB.
     *
     * @param inputToken The token to convert from.
     * @param stems The stems of the deposits to convert from.
     * @param amounts The amounts of the deposits to convert from.
     * @param outputToken The token to convert to.
     * @param grownStalkSlippage The slippage percentage. Controls the maximum amount of grown stalk that can be lost. 100% = 1e18.
     * @param advancedPipeCalls The pipe calls to execute.
     * @return returnParams containing the return values of the convert. see {pipelineReturnParams}
     */
    function _pipelineConvert(
        address inputToken,
        int96[] calldata stems,
        uint256[] calldata amounts,
        address outputToken,
        uint256 grownStalkSlippage,
        AdvancedPipeCall[] memory advancedPipeCalls
    ) internal returns (pipelineReturnParams memory returnParams) {
        // Require that input and output tokens be wells.
        require(
            LibWell.isWell(inputToken) || inputToken == s.sys.bean,
            "Convert: Input token must be Bean or a well"
        );
        require(
            LibWell.isWell(outputToken) || outputToken == s.sys.bean,
            "Convert: Output token must be Bean or a well"
        );

        // mow input and output tokens:
        LibSilo._mow(LibTractor._user(), inputToken);
        LibSilo._mow(LibTractor._user(), outputToken);

        // Calculate the maximum amount of tokens to withdraw.
        for (uint256 i = 0; i < stems.length; i++) {
            returnParams.fromAmount = returnParams.fromAmount.add(amounts[i]);
        }

        // withdraw tokens from deposits and calculate the total grown stalk and bdv.
        uint256 deltaRainRoots;
        uint256 initialGrownStalk;
        (initialGrownStalk, returnParams.fromBdv, deltaRainRoots) = LibConvert._withdrawTokens(
            inputToken,
            stems,
            amounts,
            returnParams.fromAmount,
            LibTractor._user()
        );
        uint256 grownStalk = initialGrownStalk;

        (returnParams.toAmount, grownStalk, returnParams.toBdv) = LibPipelineConvert
            .executePipelineConvert(
                inputToken,
                outputToken,
                returnParams.fromAmount,
                returnParams.fromBdv,
                grownStalk,
                advancedPipeCalls
            );

        // apply convert penalty/bonus on grown stalk
        grownStalk = LibConvert.applyStalkModifiers(
            inputToken,
            outputToken,
            LibTractor._user(),
            returnParams.toBdv,
            grownStalk
        );

        // check for stalk slippage
        LibConvert.checkGrownStalkSlippage(grownStalk, initialGrownStalk, grownStalkSlippage);

        returnParams.toStem = LibConvert._depositTokensForConvert(
            outputToken,
            returnParams.toAmount,
            returnParams.toBdv,
            grownStalk,
            deltaRainRoots,
            LibTractor._user()
        );

        emit Convert(
            LibTractor._user(),
            inputToken,
            outputToken,
            returnParams.fromAmount,
            returnParams.toAmount,
            returnParams.fromBdv,
            returnParams.toBdv
        );
    }
}

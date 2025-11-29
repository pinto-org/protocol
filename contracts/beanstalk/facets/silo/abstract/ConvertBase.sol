/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibSilo} from "contracts/libraries/Silo/LibSilo.sol";
import {LibTokenSilo} from "contracts/libraries/Silo/LibTokenSilo.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {LibPipelineConvert} from "contracts/libraries/Convert/LibPipelineConvert.sol";

/**
 * @title ConvertBase
 * @notice Abstract contract containing internal convert logic shared between
 * ConvertFacet and ConvertBatchFacet.
 */
abstract contract ConvertBase {
    using LibConvertData for bytes;
    using SafeCast for uint256;

    event Convert(
        address indexed account,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount,
        uint256 fromBdv,
        uint256 toBdv
    );

    /**
     * @notice Internal Convert functionality.
     * 18 decimal precision for stalk slippage. 100% = 1e18.
     */
    function _convert(
        bytes calldata convertData,
        int96[] memory stems,
        uint256[] memory amounts,
        int256 grownStalkSlippage
    )
        internal
        returns (int96 toStem, uint256 fromAmount, uint256 toAmount, uint256 fromBdv, uint256 toBdv)
    {
        // if the convert is a well <> bean convert, cache the state to validate convert.
        LibPipelineConvert.PipelineConvertData memory pipeData = LibPipelineConvert.getConvertState(
            convertData
        );

        LibConvert.ConvertParams memory cp = LibConvert.convert(convertData);

        // if the account is 0, set it to `LibTractor._user()`
        // cp.account is only set upon a anti-lambda-lambda convert.
        if (cp.account == address(0)) {
            cp.account = LibTractor._user();
        }

        if (cp.decreaseBDV) {
            require(
                stems.length == 1 && amounts.length == 1,
                "Convert: DecreaseBDV only supports updating one deposit."
            );
        }

        require(cp.fromAmount > 0, "Convert: From amount is 0.");

        LibSilo._mow(cp.account, cp.fromToken);

        // If the fromToken and toToken are different, mow the toToken as well.
        if (cp.fromToken != cp.toToken) LibSilo._mow(cp.account, cp.toToken);

        // Withdraw the tokens from the deposit.
        uint256 deltaRainRoots;
        (pipeData.initialGrownStalk, fromBdv, deltaRainRoots) = LibConvert._withdrawTokens(
            cp.fromToken,
            stems,
            amounts,
            cp.fromAmount,
            cp.account
        );
        pipeData.grownStalk = pipeData.initialGrownStalk;

        // Calculate the bdv of the new deposit.
        toBdv = LibTokenSilo.beanDenominatedValue(cp.toToken, cp.toAmount);

        // If `decreaseBDV` flag is not enabled, set toBDV to the max of the two bdvs.
        toBdv = (toBdv > fromBdv || cp.decreaseBDV) ? toBdv : fromBdv;

        // check for potential penalty
        pipeData.grownStalk = LibPipelineConvert.checkForValidConvertAndUpdateConvertCapacity(
            pipeData,
            convertData,
            cp.fromToken,
            cp.toToken,
            toBdv
        );

        // if the Farmer is converting between beans and well LP, check for
        // potential germination. if the deposit is germinating, issue additional
        // grown stalk such that the deposit is no longer germinating.
        if (cp.shouldNotGerminate == true) {
            pipeData.grownStalk = LibConvert.calculateGrownStalkWithNonGerminatingMin(
                cp.toToken,
                pipeData.grownStalk,
                toBdv
            );
        }

        (pipeData.grownStalk, toStem) = LibConvert.applyStalkModifiersAndDeposit(
            cp,
            toBdv,
            pipeData.initialGrownStalk,
            pipeData.grownStalk,
            grownStalkSlippage,
            deltaRainRoots
        );

        fromAmount = cp.fromAmount;
        toAmount = cp.toAmount;

        emit Convert(
            cp.account,
            cp.fromToken,
            cp.toToken,
            cp.fromAmount,
            cp.toAmount,
            fromBdv,
            toBdv
        );
    }
}

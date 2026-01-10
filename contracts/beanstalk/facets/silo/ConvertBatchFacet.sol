/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {ConvertBase} from "./abstract/ConvertBase.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";

/**
 * @title ConvertBatchFacet
 * @notice Handles batch convert operations for deposits within the Silo.
 * @dev Enables farmers to convert multiple deposits in a single transaction,
 * reducing gas costs compared to multiple individual convert calls.
 */
contract ConvertBatchFacet is ConvertBase {
    using LibConvertData for bytes;

    /**
     * @notice Parameters for a single convert operation within a batch.
     * @param convertData Encoded convert type and parameters
     * @param stems Array of stems for deposits to convert from
     * @param amounts Array of amounts to convert from each stem
     * @param grownStalkSlippage Slippage tolerance for grown stalk (18 decimal precision)
     */
    struct ConvertParams {
        bytes convertData;
        int96[] stems;
        uint256[] amounts;
        int256 grownStalkSlippage;
    }

    /**
     * @notice Output details for a single convert operation.
     * @param convertKind The type of convert performed
     * @param toStem The stem of the converted deposit
     * @param fromAmount The amount of tokens converted from
     * @param toAmount The amount of tokens converted to
     * @param fromBdv The BDV converted from
     * @param toBdv The BDV converted to
     */
    struct ConvertOutput {
        LibConvertData.ConvertKind convertKind;
        int96 toStem;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 fromBdv;
        uint256 toBdv;
    }

    /**
     * @notice Performs multiple convert operations in a single transaction.
     * @dev All-or-nothing: if any convert fails, entire batch reverts.
     * @param converts Array of convert parameters for each operation
     * @return convertOutputs Array of results for each convert operation
     */
    function batchConvert(
        ConvertParams[] calldata converts
    )
        external
        payable
        fundsSafu
        noSupplyChange
        nonReentrant
        returns (ConvertOutput[] memory convertOutputs)
    {
        require(converts.length > 0, "ConvertBatch: Empty converts array");
        return _executeConverts(converts);
    }

    /**
     * @notice Executes multiple converts and aggregates results.
     */
    function _executeConverts(
        ConvertParams[] calldata converts
    ) private returns (ConvertOutput[] memory convertOutputs) {
        uint256 len = converts.length;
        convertOutputs = new ConvertOutput[](len);
        for (uint256 i; i < len; ) {
            ConvertParams calldata c = converts[i];
            (int96 stem, uint256 from, uint256 to, uint256 bdvFrom, uint256 bdvTo) = _convert(
                c.convertData,
                c.stems,
                c.amounts,
                c.grownStalkSlippage
            );

            convertOutputs[i] = ConvertOutput({
                convertKind: c.convertData.convertKind(),
                toStem: stem,
                fromAmount: from,
                toAmount: to,
                fromBdv: bdvFrom,
                toBdv: bdvTo
            });

            unchecked {
                ++i;
            }
        }
    }
}

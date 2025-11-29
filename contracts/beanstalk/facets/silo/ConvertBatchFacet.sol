/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {ConvertBase} from "./abstract/ConvertBase.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";

/**
 * @title ConvertBatchFacet
 * @notice Handles batch convert operations for deposits within the Silo.
 * @dev Enables farmers to convert multiple deposits in a single transaction,
 * reducing gas costs compared to multiple individual convert calls.
 */
contract ConvertBatchFacet is ConvertBase, Invariable, ReentrancyGuard {
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
     * @notice Performs multiple convert operations in a single transaction.
     * @dev All-or-nothing: if any convert fails, entire batch reverts.
     * @param converts Array of convert parameters for each operation
     * @return toStem The stem of the final converted deposit
     * @return fromAmount Total amount converted from across all operations
     * @return toAmount Total amount converted to across all operations
     * @return fromBdv Total BDV converted from across all operations
     * @return toBdv Total BDV converted to across all operations
     */
    function multiConvert(
        ConvertParams[] calldata converts
    )
        external
        payable
        fundsSafu
        noSupplyChange
        nonReentrant
        returns (int96 toStem, uint256 fromAmount, uint256 toAmount, uint256 fromBdv, uint256 toBdv)
    {
        require(converts.length > 0, "ConvertBatch: Empty converts array");
        _validateAL2L(converts);
        return _executeConverts(converts);
    }

    /**
     * @notice Validates AL2L (Anti-Lambda-Lambda) batch restrictions.
     * @dev AL2L converts can only update one deposit at a time.
     */
    function _validateAL2L(ConvertParams[] calldata converts) private {
        for (uint256 i; i < converts.length; ) {
            if (LibConvert.convert(converts[i].convertData).decreaseBDV) {
                require(converts.length == 1, "ConvertBatch: AL2L converts must be done individually");
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Executes multiple converts and aggregates results.
     */
    function _executeConverts(
        ConvertParams[] calldata converts
    ) private returns (int96 toStem, uint256 fromAmount, uint256 toAmount, uint256 fromBdv, uint256 toBdv) {
        uint256 len = converts.length;
        for (uint256 i; i < len; ) {
            ConvertParams calldata c = converts[i];
            (int96 stem, uint256 from, uint256 to, uint256 bdvFrom, uint256 bdvTo) = _convert(
                c.convertData,
                c.stems,
                c.amounts,
                c.grownStalkSlippage
            );

            fromAmount += from;
            toAmount += to;
            fromBdv += bdvFrom;
            toBdv += bdvTo;
            toStem = stem;

            unchecked {
                ++i;
            }
        }
    }
}

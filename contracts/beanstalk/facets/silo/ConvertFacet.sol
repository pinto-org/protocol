/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {ConvertBase} from "./abstract/ConvertBase.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";

/**
 * @title ConvertFacet handles converting Deposited assets within the Silo.
 **/
contract ConvertFacet is ConvertBase {

    /**
     * @notice convert allows a user to convert a deposit to another deposit,
     * given that the conversion is supported by the ConvertFacet.
     * For example, a user can convert LP into Bean, only when beanstalk is below peg,
     * or convert beans into LP, only when beanstalk is above peg.
     * @param convertData  input parameters to determine the conversion type.
     * @param stems the stems of the deposits to convert
     * @param amounts the amounts within each deposit to convert
     * @return toStem the new stems of the converted deposit
     * @return fromAmount the amount of tokens converted from
     * @return toAmount the amount of tokens converted to
     * @return fromBdv the bdv of the deposits converted from
     * @return toBdv the bdv of the deposit converted to
     */
    function convert(
        bytes calldata convertData,
        int96[] memory stems,
        uint256[] memory amounts
    )
        external
        payable
        fundsSafu
        noSupplyChange
        nonReentrant
        returns (int96 toStem, uint256 fromAmount, uint256 toAmount, uint256 fromBdv, uint256 toBdv)
    {
        return _convert(convertData, stems, amounts, int256(LibConvert.ZERO_STALK_SLIPPAGE));
    }

    /**
     * @notice convertWithStalkSlippage is a variant of the convert
     * function that allows a user to specify a grown stalk slippage tolerance.
     */
    function convertWithStalkSlippage(
        bytes calldata convertData,
        int96[] memory stems,
        uint256[] memory amounts,
        int256 grownStalkSlippage
    )
        external
        payable
        fundsSafu
        noSupplyChange
        nonReentrant
        returns (int96 toStem, uint256 fromAmount, uint256 toAmount, uint256 fromBdv, uint256 toBdv)
    {
        return _convert(convertData, stems, amounts, grownStalkSlippage);
    }
}

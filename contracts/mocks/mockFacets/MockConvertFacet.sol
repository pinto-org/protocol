/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import "../../beanstalk/facets/silo/ConvertFacet.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";

/**
 * @title Mock Convert Facet
 **/
contract MockConvertFacet is ConvertFacet {
    using LibRedundantMath256 for uint256;
    using SafeERC20 for IERC20;

    event MockConvert(uint256 stalkRemoved, uint256 bdvRemoved);

    function withdrawForConvertE(
        address token,
        int96[] memory stems,
        uint256[] memory amounts,
        uint256 maxTokens // address account
    ) external {
        LibSilo._mow(msg.sender, token);
        // if (account == address(0)) account = msg.sender;
        (uint256 stalkRemoved, uint256 bdvRemoved, ) = LibConvert._withdrawTokens(
            token,
            stems,
            amounts,
            maxTokens,
            LibTractor._user()
        );

        emit MockConvert(stalkRemoved, bdvRemoved);
    }

    function depositForConvertE(
        address token,
        uint256 amount,
        uint256 bdv,
        uint256 grownStalk,
        uint256 deltaRainRoots // address account
    ) external {
        LibSilo._mow(msg.sender, token);
        // if (account == address(0)) account = msg.sender;
        LibConvert._depositTokensForConvert(
            token,
            amount,
            bdv,
            grownStalk,
            deltaRainRoots,
            LibTractor._user()
        );
    }

    function convertInternalE(
        address tokenIn,
        uint amountIn,
        bytes calldata convertData
    )
        external
        returns (
            address toToken,
            address fromToken,
            uint256 toAmount,
            uint256 fromAmount,
            address account,
            bool decreaseBDV
        )
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        LibConvert.ConvertParams memory cp = LibConvert.convert(convertData);
        toToken = cp.toToken;
        fromToken = cp.fromToken;
        toAmount = cp.toAmount;
        fromAmount = cp.fromAmount;
        account = cp.account;
        decreaseBDV = cp.decreaseBDV;
        IERC20(toToken).safeTransfer(msg.sender, toAmount);
    }

    function setConvertDownPenaltyRate(uint256 rate) external {
        LibGaugeHelpers.ConvertDownPenaltyData memory gd = abi.decode(
            LibGaugeHelpers.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );
        gd.convertDownPenaltyRate = rate;
        LibGaugeHelpers.updateGaugeData(GaugeId.CONVERT_DOWN_PENALTY, abi.encode(gd));
    }

    function setBeansMintedAbovePeg(uint256 beansMintedAbovePeg) external {
        LibGaugeHelpers.ConvertDownPenaltyData memory gd = abi.decode(
            LibGaugeHelpers.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );
        gd.beansMintedAbovePeg = beansMintedAbovePeg;
        LibGaugeHelpers.updateGaugeData(GaugeId.CONVERT_DOWN_PENALTY, abi.encode(gd));
    }

    function setBeanMintedThreshold(uint256 beanMintedThreshold) external {
        LibGaugeHelpers.ConvertDownPenaltyData memory gd = abi.decode(
            LibGaugeHelpers.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );
        gd.beanMintedThreshold = beanMintedThreshold;
        LibGaugeHelpers.updateGaugeData(GaugeId.CONVERT_DOWN_PENALTY, abi.encode(gd));
    }

    function setThresholdSet(bool thresholdSet) external {
        LibGaugeHelpers.ConvertDownPenaltyData memory gd = abi.decode(
            LibGaugeHelpers.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );
        gd.thresholdSet = thresholdSet;
        LibGaugeHelpers.updateGaugeData(GaugeId.CONVERT_DOWN_PENALTY, abi.encode(gd));
    }

    function setRunningThreshold(uint256 runningThreshold) external {
        LibGaugeHelpers.ConvertDownPenaltyData memory gd = abi.decode(
            LibGaugeHelpers.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );
        gd.runningThreshold = runningThreshold;
        LibGaugeHelpers.updateGaugeData(GaugeId.CONVERT_DOWN_PENALTY, abi.encode(gd));
    }

    function setPenaltyRatio(uint256 penaltyRatio) external {
        LibGaugeHelpers.ConvertDownPenaltyValue memory gv = abi.decode(
            LibGaugeHelpers.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyValue)
        );
        gv.penaltyRatio = penaltyRatio;
        LibGaugeHelpers.updateGaugeValue(GaugeId.CONVERT_DOWN_PENALTY, abi.encode(gv));
    }
}

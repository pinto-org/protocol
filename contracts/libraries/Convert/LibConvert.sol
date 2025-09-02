// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibLambdaConvert} from "./LibLambdaConvert.sol";
import {LibConvertData} from "./LibConvertData.sol";
import {LibWellConvert, LibWhitelistedTokens} from "./LibWellConvert.sol";
import {LibWell} from "contracts/libraries/Well/LibWell.sol";
import {AppStorage, LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibWellMinting} from "contracts/libraries/Minting/LibWellMinting.sol";
import {C} from "contracts/C.sol";
import {LibRedundantMathSigned256} from "contracts/libraries/Math/LibRedundantMathSigned256.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LibDeltaB} from "contracts/libraries/Oracle/LibDeltaB.sol";
import {ConvertCapacity, GerminationSide, GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibSilo} from "contracts/libraries/Silo/LibSilo.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibGerminate} from "contracts/libraries/Silo/LibGerminate.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";
import {LibTokenSilo} from "contracts/libraries/Silo/LibTokenSilo.sol";
import {LibEvaluate} from "contracts/libraries/LibEvaluate.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Decimal} from "contracts/libraries/Decimal.sol";
import {IBeanstalkWellFunction} from "contracts/interfaces/basin/IBeanstalkWellFunction.sol";
import {IWell, Call} from "contracts/interfaces/basin/IWell.sol";

/**
 * @title LibConvert
 */
library LibConvert {
    using LibRedundantMath256 for uint256;
    using LibConvertData for bytes;
    using LibWell for address;
    using LibRedundantMathSigned256 for int256;
    using SafeCast for uint256;

    event ConvertDownPenalty(address account, uint256 grownStalkLost, uint256 grownStalkKept);

    struct AssetsRemovedConvert {
        LibSilo.Removed active;
        uint256[] bdvsRemoved;
        uint256[] stalksRemoved;
        uint256[] depositIds;
    }

    struct DeltaBStorage {
        int256 beforeInputTokenDeltaB;
        int256 afterInputTokenDeltaB;
        int256 beforeOutputTokenDeltaB;
        int256 afterOutputTokenDeltaB;
        int256 beforeOverallDeltaB;
        int256 afterOverallDeltaB;
    }

    struct PenaltyData {
        uint256 inputToken;
        uint256 outputToken;
        uint256 overall;
    }

    struct StalkPenaltyData {
        PenaltyData directionOfPeg;
        PenaltyData againstPeg;
        PenaltyData capacity;
        uint256 higherAmountAgainstPeg;
        uint256 convertCapacityPenalty;
    }

    struct ConvertParams {
        address toToken;
        address fromToken;
        uint256 fromAmount;
        uint256 toAmount;
        address account;
        bool decreaseBDV;
        bool shouldNotGerminate;
    }

    /**
     * @notice Takes in bytes object that has convert input data encoded into it for a particular convert for
     * a specified pool and returns the in and out convert amounts and token addresses and bdv
     * @param convertData Contains convert input parameters for a specified convert
     * note account and decreaseBDV variables are initialized at the start
     * as address(0) and false respectively and remain that way if a convert is not anti-lambda-lambda
     * If it is anti-lambda, account is the address of the account to update the deposit
     * and decreaseBDV is true
     */
    function convert(bytes calldata convertData) external returns (ConvertParams memory cp) {
        LibConvertData.ConvertKind kind = convertData.convertKind();

        if (kind == LibConvertData.ConvertKind.BEANS_TO_WELL_LP) {
            (cp.toToken, cp.fromToken, cp.toAmount, cp.fromAmount) = LibWellConvert
                .convertBeansToLP(convertData);
            cp.shouldNotGerminate = true;
        } else if (kind == LibConvertData.ConvertKind.WELL_LP_TO_BEANS) {
            (cp.toToken, cp.fromToken, cp.toAmount, cp.fromAmount) = LibWellConvert
                .convertLPToBeans(convertData);
            cp.shouldNotGerminate = true;
        } else if (kind == LibConvertData.ConvertKind.LAMBDA_LAMBDA) {
            (cp.toToken, cp.fromToken, cp.toAmount, cp.fromAmount) = LibLambdaConvert.convert(
                convertData
            );
        } else if (kind == LibConvertData.ConvertKind.ANTI_LAMBDA_LAMBDA) {
            (
                cp.toToken,
                cp.fromToken,
                cp.toAmount,
                cp.fromAmount,
                cp.account,
                cp.decreaseBDV
            ) = LibLambdaConvert.antiConvert(convertData);
        } else {
            revert("Convert: Invalid payload");
        }
    }

    function getMaxAmountIn(address fromToken, address toToken) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // Lambda -> Lambda &
        // Anti-Lambda -> Lambda
        if (fromToken == toToken) return type(uint256).max;

        // Bean -> Well LP Token
        if (fromToken == s.sys.bean && toToken.isWell()) return LibWellConvert.beansToPeg(toToken);

        // Well LP Token -> Bean
        if (LibWhitelistedTokens.wellIsOrWasSoppable(fromToken) && toToken == s.sys.bean)
            return LibWellConvert.lpToPeg(fromToken);

        revert("Convert: Tokens not supported");
    }

    /**
     * @notice Returns the maximum amount that can be converted of `fromToken` to `toToken` such that the price after the convert is equal to the rate.
     * @dev At time of writing, this is only supported for Bean -> Well LP Token (as it is the only case where applicable).
     * This function may return a value such that the price after the convert is slightly lower than the rate, due to rounding errors.
     * Developers should be cautious and provide an appropriate buffer to account for this.
     */
    function getMaxAmountInAtRate(
        address fromToken,
        address toToken,
        uint256 rate
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // Bean -> Well LP Token
        if (fromToken == s.sys.bean && toToken.isWell()) {
            (uint256 beans, ) = LibWellConvert._beansToPegAtRate(toToken, rate);
            return beans;
        }

        revert("Convert: Tokens not supported");
    }

    function getAmountOut(
        address fromToken,
        address toToken,
        uint256 fromAmount
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Lambda -> Lambda &
        // Anti-Lambda -> Lambda
        if (fromToken == toToken) return fromAmount;

        // Bean -> Well LP Token
        if (fromToken == s.sys.bean && toToken.isWell()) {
            return LibWellConvert.getLPAmountOut(toToken, fromAmount);
        }

        // Well LP Token -> Bean
        if (LibWhitelistedTokens.wellIsOrWasSoppable(fromToken) && toToken == s.sys.bean) {
            return LibWellConvert.getBeanAmountOut(fromToken, fromAmount);
        }

        revert("Convert: Tokens not supported");
    }

    /**
     * @notice applies the stalk penalty and updates convert capacity.
     */
    function applyStalkPenalty(
        DeltaBStorage memory dbs,
        uint256 bdvConverted,
        uint256 overallConvertCapacity,
        address inputToken,
        address outputToken
    ) internal returns (uint256 stalkPenaltyBdv) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 overallConvertCapacityUsed;
        uint256 inputTokenAmountUsed;
        uint256 outputTokenAmountUsed;

        (
            stalkPenaltyBdv,
            overallConvertCapacityUsed,
            inputTokenAmountUsed,
            outputTokenAmountUsed
        ) = calculateStalkPenalty(
            dbs,
            bdvConverted,
            overallConvertCapacity,
            inputToken,
            outputToken
        );

        // Update penalties in storage.
        ConvertCapacity storage convertCap = s.sys.convertCapacity[block.number];
        convertCap.overallConvertCapacityUsed = convertCap.overallConvertCapacityUsed.add(
            overallConvertCapacityUsed
        );
        convertCap.wellConvertCapacityUsed[inputToken] = convertCap
            .wellConvertCapacityUsed[inputToken]
            .add(inputTokenAmountUsed);
        convertCap.wellConvertCapacityUsed[outputToken] = convertCap
            .wellConvertCapacityUsed[outputToken]
            .add(outputTokenAmountUsed);
    }

    /**
     * @notice Calculates the percentStalkPenalty for a given convert.
     */
    function calculateStalkPenalty(
        DeltaBStorage memory dbs,
        uint256 bdvConverted,
        uint256 overallConvertCapacity,
        address inputToken,
        address outputToken
    )
        internal
        view
        returns (
            uint256 stalkPenaltyBdv,
            uint256 overallConvertCapacityUsed,
            uint256 inputTokenAmountUsed,
            uint256 outputTokenAmountUsed
        )
    {
        StalkPenaltyData memory spd;

        spd.directionOfPeg = calculateConvertedTowardsPeg(dbs);
        spd.againstPeg = calculateAmountAgainstPeg(dbs);

        spd.higherAmountAgainstPeg = max(
            spd.againstPeg.overall,
            spd.againstPeg.inputToken.add(spd.againstPeg.outputToken)
        );

        (spd.convertCapacityPenalty, spd.capacity) = calculateConvertCapacityPenalty(
            overallConvertCapacity,
            spd.directionOfPeg.overall,
            inputToken,
            spd.directionOfPeg.inputToken,
            outputToken,
            spd.directionOfPeg.outputToken
        );

        // Cap amount of bdv penalized at amount of bdv converted (no penalty should be over 100%)
        stalkPenaltyBdv = min(
            spd.higherAmountAgainstPeg.add(spd.convertCapacityPenalty),
            bdvConverted
        );

        return (
            stalkPenaltyBdv,
            spd.capacity.overall,
            spd.capacity.inputToken,
            spd.capacity.outputToken
        );
    }

    /**
     * @param overallCappedDeltaB The capped overall deltaB for all wells
     * @param overallAmountInDirectionOfPeg The amount deltaB was converted towards peg
     * @param inputToken Address of the input well
     * @param inputTokenAmountInDirectionOfPeg The amount deltaB was converted towards peg for the input well
     * @param outputToken Address of the output well
     * @param outputTokenAmountInDirectionOfPeg The amount deltaB was converted towards peg for the output well
     * @return cumulativePenalty The total Convert Capacity penalty, note it can return greater than the BDV converted
     */
    function calculateConvertCapacityPenalty(
        uint256 overallCappedDeltaB,
        uint256 overallAmountInDirectionOfPeg,
        address inputToken,
        uint256 inputTokenAmountInDirectionOfPeg,
        address outputToken,
        uint256 outputTokenAmountInDirectionOfPeg
    ) internal view returns (uint256 cumulativePenalty, PenaltyData memory pdCapacity) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        ConvertCapacity storage convertCap = s.sys.convertCapacity[block.number];

        // first check overall convert capacity, if none remaining then full penalty for amount in direction of peg
        if (convertCap.overallConvertCapacityUsed >= overallCappedDeltaB) {
            cumulativePenalty = overallAmountInDirectionOfPeg;
        } else if (
            overallAmountInDirectionOfPeg >
            overallCappedDeltaB.sub(convertCap.overallConvertCapacityUsed)
        ) {
            cumulativePenalty =
                overallAmountInDirectionOfPeg -
                overallCappedDeltaB.sub(convertCap.overallConvertCapacityUsed);
        }

        // update overall remaining convert capacity
        pdCapacity.overall = convertCap.overallConvertCapacityUsed.add(
            overallAmountInDirectionOfPeg
        );

        // update per-well convert capacity

        if (inputToken != s.sys.bean && inputTokenAmountInDirectionOfPeg > 0) {
            (cumulativePenalty, pdCapacity.inputToken) = calculatePerWellCapacity(
                inputToken,
                inputTokenAmountInDirectionOfPeg,
                cumulativePenalty,
                convertCap,
                pdCapacity.inputToken
            );
        }

        if (outputToken != s.sys.bean && outputTokenAmountInDirectionOfPeg > 0) {
            (cumulativePenalty, pdCapacity.outputToken) = calculatePerWellCapacity(
                outputToken,
                outputTokenAmountInDirectionOfPeg,
                cumulativePenalty,
                convertCap,
                pdCapacity.outputToken
            );
        }
    }

    function calculatePerWellCapacity(
        address wellToken,
        uint256 amountInDirectionOfPeg,
        uint256 cumulativePenalty,
        ConvertCapacity storage convertCap,
        uint256 pdCapacityToken
    ) internal view returns (uint256, uint256) {
        uint256 tokenWellCapacity = abs(LibDeltaB.cappedReservesDeltaB(wellToken));
        pdCapacityToken = convertCap.wellConvertCapacityUsed[wellToken].add(amountInDirectionOfPeg);
        if (pdCapacityToken > tokenWellCapacity) {
            cumulativePenalty = cumulativePenalty.add(pdCapacityToken.sub(tokenWellCapacity));
        }

        return (cumulativePenalty, pdCapacityToken);
    }

    /**
     * @notice Performs `calculateAgainstPeg` for the overall, input token, and output token deltaB's.
     */
    function calculateAmountAgainstPeg(
        DeltaBStorage memory dbs
    ) internal pure returns (PenaltyData memory pd) {
        pd.overall = calculateAgainstPeg(dbs.beforeOverallDeltaB, dbs.afterOverallDeltaB);
        pd.inputToken = calculateAgainstPeg(dbs.beforeInputTokenDeltaB, dbs.afterInputTokenDeltaB);
        pd.outputToken = calculateAgainstPeg(
            dbs.beforeOutputTokenDeltaB,
            dbs.afterOutputTokenDeltaB
        );
    }

    /**
     * @notice Takes before/after deltaB's and calculates how much was converted against peg.
     */
    function calculateAgainstPeg(
        int256 beforeDeltaB,
        int256 afterDeltaB
    ) internal pure returns (uint256 amountAgainstPeg) {
        // Check if the signs of beforeDeltaB and afterDeltaB are different,
        // indicating that deltaB has crossed zero
        if ((beforeDeltaB > 0 && afterDeltaB < 0) || (beforeDeltaB < 0 && afterDeltaB > 0)) {
            amountAgainstPeg = abs(afterDeltaB);
        } else {
            if (
                (afterDeltaB <= 0 && beforeDeltaB <= 0) || (afterDeltaB >= 0 && beforeDeltaB >= 0)
            ) {
                if (abs(beforeDeltaB) < abs(afterDeltaB)) {
                    amountAgainstPeg = abs(afterDeltaB).sub(abs(beforeDeltaB));
                }
            }
        }
    }

    /**
     * @notice Performs `calculateTowardsPeg` for the overall, input token, and output token deltaB's.
     */
    function calculateConvertedTowardsPeg(
        DeltaBStorage memory dbs
    ) internal pure returns (PenaltyData memory pd) {
        pd.overall = calculateTowardsPeg(dbs.beforeOverallDeltaB, dbs.afterOverallDeltaB);
        pd.inputToken = calculateTowardsPeg(dbs.beforeInputTokenDeltaB, dbs.afterInputTokenDeltaB);
        pd.outputToken = calculateTowardsPeg(
            dbs.beforeOutputTokenDeltaB,
            dbs.afterOutputTokenDeltaB
        );
    }

    /**
     * @notice Takes before/after deltaB's and calculates how much was converted towards, but not past, peg.
     */
    function calculateTowardsPeg(
        int256 beforeTokenDeltaB,
        int256 afterTokenDeltaB
    ) internal pure returns (uint256) {
        // Calculate absolute values of beforeInputTokenDeltaB and afterInputTokenDeltaB using the abs() function
        uint256 beforeDeltaAbs = abs(beforeTokenDeltaB);
        uint256 afterDeltaAbs = abs(afterTokenDeltaB);

        // Check if afterInputTokenDeltaB and beforeInputTokenDeltaB have the same sign
        if (
            (beforeTokenDeltaB >= 0 && afterTokenDeltaB >= 0) ||
            (beforeTokenDeltaB < 0 && afterTokenDeltaB < 0)
        ) {
            // If they have the same sign, compare the absolute values
            if (afterDeltaAbs < beforeDeltaAbs) {
                // Return the difference between beforeDeltaAbs and afterDeltaAbs
                return beforeDeltaAbs.sub(afterDeltaAbs);
            } else {
                // If afterInputTokenDeltaB is further from or equal to zero, return zero
                return 0;
            }
        } else {
            // This means it crossed peg, return how far it went towards peg, which is the abs of input token deltaB
            return beforeDeltaAbs;
        }
    }

    /**
     * @notice checks for potential germination. if the deposit is germinating,
     * issue additional grown stalk such that the deposit is no longer germinating.
     */
    function calculateGrownStalkWithNonGerminatingMin(
        address token,
        uint256 grownStalk,
        uint256 bdv
    ) internal view returns (uint256 newGrownStalk) {
        (, GerminationSide side) = LibTokenSilo.calculateStemForTokenFromGrownStalk(
            token,
            grownStalk,
            bdv
        );
        // if the side is not `NOT_GERMINATING`, calculate the grown stalk needed to
        // make the deposit non-germinating.
        if (side != GerminationSide.NOT_GERMINATING) {
            newGrownStalk = LibTokenSilo.calculateGrownStalkAtNonGerminatingStem(token, bdv);
        } else {
            newGrownStalk = grownStalk;
        }
    }

    /**
     * @notice removes the deposits from user and returns the
     * grown stalk and bdv removed.
     *
     * @dev if a user inputs a stem of a deposit that is `germinating`,
     * the function will omit that deposit. This is due to the fact that
     * germinating deposits can be manipulated and skip the germination process.
     */
    function _withdrawTokens(
        address token,
        int96[] memory stems,
        uint256[] memory amounts,
        uint256 maxTokens,
        address user
    ) internal returns (uint256, uint256, uint256) {
        require(stems.length == amounts.length, "Convert: stems, amounts are diff lengths.");

        AssetsRemovedConvert memory a;
        uint256 i = 0;
        uint256 stalkIssuedPerBdv;

        // a bracket is included here to avoid the "stack too deep" error.
        {
            a.bdvsRemoved = new uint256[](stems.length);
            a.stalksRemoved = new uint256[](stems.length);
            a.depositIds = new uint256[](stems.length);

            // calculated here to avoid stack too deep error.
            stalkIssuedPerBdv = LibTokenSilo.stalkIssuedPerBdv(token);

            // get germinating stem and stemTip for the token
            LibGerminate.GermStem memory germStem = LibGerminate.getGerminatingStem(token);

            while ((i < stems.length) && (a.active.tokens < maxTokens)) {
                // skip any stems that are germinating, due to the ability to
                // circumvent the germination process.
                if (germStem.germinatingStem <= stems[i]) {
                    i++;
                    continue;
                }

                if (a.active.tokens.add(amounts[i]) >= maxTokens) {
                    amounts[i] = maxTokens.sub(a.active.tokens);
                }

                a.bdvsRemoved[i] = LibTokenSilo.removeDepositFromAccount(
                    user,
                    token,
                    stems[i],
                    amounts[i]
                );

                a.stalksRemoved[i] = LibSilo.stalkReward(
                    stems[i],
                    germStem.stemTip,
                    a.bdvsRemoved[i].toUint128()
                );
                a.active.stalk = a.active.stalk.add(a.stalksRemoved[i]);

                a.active.tokens = a.active.tokens.add(amounts[i]);
                a.active.bdv = a.active.bdv.add(a.bdvsRemoved[i]);

                a.depositIds[i] = uint256(LibBytes.packAddressAndStem(token, stems[i]));
                i++;
            }
            for (i; i < stems.length; ++i) {
                amounts[i] = 0;
            }

            emit LibSilo.RemoveDeposits(
                user,
                token,
                stems,
                amounts,
                a.active.tokens,
                a.bdvsRemoved
            );

            emit LibTokenSilo.TransferBatch(user, user, address(0), a.depositIds, amounts);
        }

        require(a.active.tokens == maxTokens, "Convert: Not enough tokens removed.");
        LibTokenSilo.decrementTotalDeposited(token, a.active.tokens, a.active.bdv);

        // all deposits converted are not germinating.
        (, uint256 deltaRainRoots) = LibSilo.burnActiveStalk(
            user,
            a.active.stalk.add(a.active.bdv.mul(stalkIssuedPerBdv))
        );

        return (a.active.stalk, a.active.bdv, deltaRainRoots);
    }

    function _depositTokensForConvert(
        address token,
        uint256 amount,
        uint256 bdv,
        uint256 grownStalk,
        uint256 deltaRainRoots,
        address user
    ) internal returns (int96 stem) {
        require(bdv > 0 && amount > 0, "Convert: BDV or amount is 0.");

        GerminationSide side;

        // calculate the stem and germination state for the new deposit.
        (stem, side) = LibTokenSilo.calculateStemForTokenFromGrownStalk(token, grownStalk, bdv);

        // increment totals based on germination state,
        // as well as issue stalk to the user.
        // if the deposit is germinating, only the initial stalk of the deposit is germinating.
        // the rest is active stalk.
        if (side == GerminationSide.NOT_GERMINATING) {
            LibTokenSilo.incrementTotalDeposited(token, amount, bdv);
            LibSilo.mintActiveStalk(
                user,
                bdv.mul(LibTokenSilo.stalkIssuedPerBdv(token)).add(grownStalk)
            );
            // if needed, credit previously burned rain roots from withdrawal to the user.
            if (deltaRainRoots > 0) LibSilo.mintRainRoots(user, deltaRainRoots);
        } else {
            LibTokenSilo.incrementTotalGerminating(token, amount, bdv, side);
            // safeCast not needed as stalk is <= max(uint128)
            LibSilo.mintGerminatingStalk(
                user,
                uint128(bdv.mul(LibTokenSilo.stalkIssuedPerBdv(token))),
                side
            );
            LibSilo.mintActiveStalk(user, grownStalk);
        }
        LibTokenSilo.addDepositToAccount(
            user,
            token,
            stem,
            amount,
            bdv,
            LibTokenSilo.Transfer.emitTransferSingle
        );
    }

    /**
     * @notice Computes new grown stalk after downward convert penalty.
     * No penalty if P > Q or grown stalk below germination threshold.
     * @dev Inbound must not be germinating, will return germinating amount of grown stalk.
     * this function only supports grown stalk penalties for BEAN -> WELL converts.
     * @return newGrownStalk Amount of grown stalk to assign the deposit.
     * @return grownStalkLost Amount of grown stalk lost to penalty.
     */
    function downPenalizedGrownStalk(
        address well,
        uint256 bdv,
        uint256 grownStalk,
        uint256 fromAmount
    ) internal view returns (uint256 newGrownStalk, uint256 grownStalkLost) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        require(bdv > 0 && fromAmount > 0, "Convert: bdv or fromAmount is 0");

        // No penalty if output deposit germinating.
        uint256 minGrownStalk = LibTokenSilo.calculateGrownStalkAtNonGerminatingStem(well, bdv);
        if (grownStalk < minGrownStalk) {
            return (grownStalk, 0);
        }

        // Get convertDownPenaltyRate from gauge data.
        LibGaugeHelpers.ConvertDownPenaltyData memory gd = abi.decode(
            s.sys.gaugeData.gauges[GaugeId.CONVERT_DOWN_PENALTY].data,
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );

        (bool greaterThanRate, uint256 penalizedAmount) = pGreaterThanRate(
            well,
            gd.convertDownPenaltyRate,
            fromAmount
        );

        // If the price of the well is greater than the penalty rate after the convert, there is no penalty.
        if (greaterThanRate) {
            return (grownStalk, 0);
        }

        // price is lower than the penalty rate.

        // Get penalty ratio from gauge.
        (uint256 penaltyRatio, ) = abi.decode(
            s.sys.gaugeData.gauges[GaugeId.CONVERT_DOWN_PENALTY].value,
            (uint256, uint256)
        );

        // enforce penalty ratio is not greater than 100%.
        require(penaltyRatio <= C.PRECISION, "Convert: penaltyRatio is greater than 100%");

        if (penaltyRatio > 0) {
            // calculate the penalized bdv.
            // note: if greaterThanRate is false, penalizedAmount could be non-zero.
            require(
                penalizedAmount <= fromAmount,
                "Convert: penalizedAmount is greater than fromAmount"
            );
            uint256 penalizedBdv = (bdv * penalizedAmount) / fromAmount;

            // calculate the grown stalk that may be lost due to the penalty.
            uint256 penalizedGrownStalk = (grownStalk * penalizedBdv) / bdv;

            // apply the penalty to the grown stalk via the penalty ratio,
            // and calculate the new grown stalk of the deposit.
            newGrownStalk = max(
                grownStalk - (penalizedGrownStalk * penaltyRatio) / C.PRECISION,
                minGrownStalk
            );

            // calculate the amount of grown stalk lost due to the penalty.
            grownStalkLost = grownStalk - newGrownStalk;
        } else {
            // no penalty was applied.
            newGrownStalk = grownStalk;
            grownStalkLost = 0;
        }
    }

    /**
     *
     * @notice verifies that the exchange rate of the well is above a rate,
     * after an bean -> lp convert has occured with `amount`.
     * @return greaterThanRate true if the price after the convert is greater than the rate, false otherwise
     * @return beansOverRate the amount of beans that exceed the rate. 0 if `greaterThanRate` is true.
     */
    function pGreaterThanRate(
        address well,
        uint256 rate,
        uint256 amount
    ) internal view returns (bool greaterThanRate, uint256 beansOverRate) {
        // No penalty if P > rate.
        (uint256[] memory ratios, uint256 beanIndex, bool success) = LibWell
            .getRatiosAndBeanIndexAtRate(IWell(well).tokens(), 0, rate);
        require(success, "Convert: USD Oracle failed");

        uint256[] memory instantReserves = LibDeltaB.instantReserves(well);

        Call memory wellFunction = IWell(well).wellFunction();

        // increment the amount of beans in reserves by the amount of beans that would be added to liquidity.
        uint256[] memory reservesAfterAmount = new uint256[](instantReserves.length);
        uint256 tokenIndex = beanIndex == 0 ? 1 : 0;

        reservesAfterAmount[beanIndex] = instantReserves[beanIndex] + amount;
        reservesAfterAmount[tokenIndex] = instantReserves[tokenIndex];

        // used to check if the price prior to the convert is higher/lower than the target price.
        uint256 beansAtRate = IBeanstalkWellFunction(wellFunction.target)
            .calcReserveAtRatioLiquidity(instantReserves, beanIndex, ratios, wellFunction.data);

        // if the reserves `before` the convert is higher than the beans reserves at `rate`,
        // it means the price `before` the convert is lower than `rate`.
        // independent of the amount converted, the price will always be lower than `rate`.
        if (instantReserves[beanIndex] > beansAtRate) {
            return (false, amount);
        } else {
            // reserves `before` the convert is lower than the beans reserves at `rate`.
            // the price `before` the convert is higher than `rate`.

            if (reservesAfterAmount[beanIndex] < beansAtRate) {
                // if the reserves `after` the convert is lower than the beans reserves at `rate`,
                // it means the price `after` the convert is higher than `rate`.
                return (true, 0);
            } else {
                // if the reserves `after` the convert is higher than the beans reserves at `rate`,
                // it means the price `after` the convert is lower than `rate`.
                // then the amount of beans over the rate is the difference between the beans reserves at `rate` and the reserves after the convert.
                return (false, reservesAfterAmount[beanIndex] - beansAtRate);
            }
        }
    }

    function abs(int256 a) internal pure returns (uint256) {
        return a >= 0 ? uint256(a) : uint256(-a);
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

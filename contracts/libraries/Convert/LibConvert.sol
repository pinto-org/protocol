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
import {GerminationSide, GaugeId, ConvertCapacity} from "contracts/beanstalk/storage/System.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Decimal} from "contracts/libraries/Decimal.sol";
import {IBeanstalkWellFunction} from "contracts/interfaces/basin/IBeanstalkWellFunction.sol";
import {IWell, Call} from "contracts/interfaces/basin/IWell.sol";
import {LibPRBMathRoundable} from "contracts/libraries/Math/LibPRBMathRoundable.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";

/**
 * @title LibConvert
 */
library LibConvert {
    using LibRedundantMath256 for uint256;
    using LibConvertData for bytes;
    using LibWell for address;
    using LibRedundantMathSigned256 for int256;
    using SafeCast for uint256;

    uint256 internal constant ZERO_STALK_SLIPPAGE = 0;
    uint256 internal constant MAX_GROWN_STALK_SLIPPAGE = 1e18;

    // convert bonus gauge
    uint256 internal constant CAPACITY_RATE = 0.50e18; // hits 100% total capacity 50% into the season

    event ConvertDownPenalty(address account, uint256 grownStalkLost, uint256 grownStalkKept);
    event ConvertUpBonus(
        address account,
        uint256 grownStalkGained,
        uint256 newGrownStalk,
        uint256 bdvCapacityUsed,
        uint256 bdvConverted
    );

    struct AssetsRemovedConvert {
        LibSilo.Removed active;
        uint256[] bdvsRemoved;
        uint256[] stalksRemoved;
        uint256[] depositIds;
    }

    /**
     * @param shadowOverallDeltaB Post-convert overall deltaB anchored to the capped baseline
     * rather than raw spot values. Captures only the spot change caused by the convert,
     * so pre-existing spot manipulation is neutralized.
     */
    struct DeltaBStorage {
        int256 beforeInputTokenSpotDeltaB;
        int256 afterInputTokenSpotDeltaB;
        int256 beforeOutputTokenSpotDeltaB;
        int256 afterOutputTokenSpotDeltaB;
        int256 cappedOverallDeltaB;
        int256 shadowOverallDeltaB;
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
        address outputToken,
        uint256 fromAmount
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
            outputToken,
            fromAmount
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

    ////// Stalk Penalty Calculations //////

    /**
     * @notice Calculates the percentStalkPenalty for a given convert.
     */
    function calculateStalkPenalty(
        DeltaBStorage memory dbs,
        uint256 bdvConverted,
        uint256 overallConvertCapacity,
        address inputToken,
        address outputToken,
        uint256 fromAmount
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

        // Get capacity penalty, target well, and reserves in one call
        address targetWell;
        uint256[] memory targetWellReserves;
        (
            spd.convertCapacityPenalty,
            spd.capacity,
            targetWell,
            targetWellReserves
        ) = calculateConvertCapacityPenalty(
            overallConvertCapacity,
            spd.directionOfPeg.overall,
            inputToken,
            spd.directionOfPeg.inputToken,
            outputToken,
            spd.directionOfPeg.outputToken
        );

        uint256 penaltyAmount = max(spd.higherAmountAgainstPeg, spd.convertCapacityPenalty);

        uint256 pipelineConvertDeltaBImpact = LibDeltaB.calculateMaxDeltaBImpact(
            inputToken,
            fromAmount,
            targetWell,
            targetWellReserves
        );

        if (pipelineConvertDeltaBImpact > 0) {
            // This scales the penalty proportionally to how much of the theoretical max was penalized
            stalkPenaltyBdv = min(
                (penaltyAmount * bdvConverted) / pipelineConvertDeltaBImpact,
                bdvConverted
            );
        } else {
            // L2L/AL2L converts have zero deltaB impact, resulting in zero penalty.
            stalkPenaltyBdv = 0;
        }

        return (
            stalkPenaltyBdv,
            spd.capacity.overall,
            spd.capacity.inputToken,
            spd.capacity.outputToken
        );
    }

    /**
     * @notice Calculates the convert capacity penalty and determines the target well for the conversion.
     * @param overallCappedDeltaB The capped overall deltaB for all wells
     * @param overallAmountInDirectionOfPeg The amount deltaB was converted towards peg
     * @param inputToken Address of the input token
     * @param inputTokenAmountInDirectionOfPeg The amount deltaB was converted towards peg for the input well
     * @param outputToken Address of the output token
     * @param outputTokenAmountInDirectionOfPeg The amount deltaB was converted towards peg for the output well
     * @return cumulativePenalty The total Convert Capacity penalty, note it can return greater than the BDV converted
     * @return pdCapacity The penalty data for capacity tracking
     * @return targetWell The well involved in the convert (address(0) for L2L/AL2L converts)
     * @return targetWellReserves The capped reserves for targetWell (empty for L2L/AL2L converts)
     */
    function calculateConvertCapacityPenalty(
        uint256 overallCappedDeltaB,
        uint256 overallAmountInDirectionOfPeg,
        address inputToken,
        uint256 inputTokenAmountInDirectionOfPeg,
        address outputToken,
        uint256 outputTokenAmountInDirectionOfPeg
    )
        internal
        view
        returns (
            uint256 cumulativePenalty,
            PenaltyData memory pdCapacity,
            address targetWell,
            uint256[] memory targetWellReserves
        )
    {
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

        // Determine target well. For L2L/AL2L (inputToken == outputToken), skip penalty calculation.
        if (inputToken != outputToken) {
            if (inputToken == s.sys.bean) {
                targetWell = outputToken;
            } else {
                targetWell = inputToken;
            }

            // `targetWell` must be a well at this point.
            (, targetWellReserves) = LibDeltaB.cappedReservesDeltaB(targetWell);
        }

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
        (int256 deltaB, ) = LibDeltaB.cappedReservesDeltaB(wellToken);
        uint256 tokenWellCapacity = abs(deltaB);
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
        pd.overall = calculateAgainstPeg(dbs.cappedOverallDeltaB, dbs.shadowOverallDeltaB);
        pd.inputToken = calculateAgainstPeg(
            dbs.beforeInputTokenSpotDeltaB,
            dbs.afterInputTokenSpotDeltaB
        );
        pd.outputToken = calculateAgainstPeg(
            dbs.beforeOutputTokenSpotDeltaB,
            dbs.afterOutputTokenSpotDeltaB
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
        pd.overall = calculateTowardsPeg(dbs.cappedOverallDeltaB, dbs.shadowOverallDeltaB);
        pd.inputToken = calculateTowardsPeg(
            dbs.beforeInputTokenSpotDeltaB,
            dbs.afterInputTokenSpotDeltaB
        );
        pd.outputToken = calculateTowardsPeg(
            dbs.beforeOutputTokenSpotDeltaB,
            dbs.afterOutputTokenSpotDeltaB
        );
    }

    /**
     * @notice Takes before/after deltaB's and calculates how much was converted towards, but not past, peg.
     */
    function calculateTowardsPeg(
        int256 beforeTokenDeltaB,
        int256 afterTokenDeltaB
    ) internal pure returns (uint256) {
        // Calculate absolute values of beforeTokenDeltaB and afterTokenDeltaB using the abs() function
        uint256 beforeDeltaAbs = abs(beforeTokenDeltaB);
        uint256 afterDeltaAbs = abs(afterTokenDeltaB);

        // Check if afterTokenDeltaB and beforeTokenDeltaB have the same sign
        if (
            (beforeTokenDeltaB >= 0 && afterTokenDeltaB >= 0) ||
            (beforeTokenDeltaB < 0 && afterTokenDeltaB < 0)
        ) {
            // If they have the same sign, compare the absolute values
            if (afterDeltaAbs < beforeDeltaAbs) {
                // Return the difference between beforeDeltaAbs and afterDeltaAbs
                return beforeDeltaAbs.sub(afterDeltaAbs);
            } else {
                // If afterTokenDeltaB is further from or equal to zero, return zero
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
     * @notice applies the stalk modifiers to a user's grown stalk and redeposits the converted tokens.
     */
    function applyStalkModifiersAndDeposit(
        ConvertParams memory cp,
        uint256 toBdv,
        uint256 initialGrownStalk,
        uint256 grownStalk,
        int256 grownStalkSlippage,
        uint256 deltaRainRoots
    ) external returns (uint256 newGrownStalk, int96 newStem) {
        // apply convert penalty/bonus on grown stalk
        newGrownStalk = applyStalkModifiers(
            cp.fromToken,
            cp.toToken,
            cp.account,
            toBdv,
            grownStalk,
            cp.fromAmount
        );

        // check for stalk slippage
        checkGrownStalkSlippage(newGrownStalk, initialGrownStalk, grownStalkSlippage);

        newStem = _depositTokensForConvert(
            cp.toToken,
            cp.toAmount,
            toBdv,
            newGrownStalk,
            deltaRainRoots,
            cp.account
        );
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

    ////// Stalk Modifiers //////

    /**
     * @notice Applies the penalty/bonus on grown stalk for a convert.
     * @param inputToken The token being converted from.
     * @param outputToken The token being converted to.
     * @param toBdv The bdv of the deposit to convert.
     * @param grownStalk The grown stalk of the deposit to convert.
     * @param fromAmount The amount of the input token being converted (for BEAN -> WELL converts)
     * @return newGrownStalk The new grown stalk to assign the deposit, after applying the penalty/bonus.
     */
    function applyStalkModifiers(
        address inputToken,
        address outputToken,
        address account,
        uint256 toBdv,
        uint256 grownStalk,
        uint256 fromAmount
    ) internal returns (uint256 newGrownStalk) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // penalty down for BEAN -> WELL
        if (inputToken == s.sys.bean && LibWell.isWell(outputToken)) {
            uint256 grownStalkLost;
            (newGrownStalk, grownStalkLost) = downPenalizedGrownStalk(
                outputToken,
                toBdv,
                grownStalk,
                fromAmount
            );
            if (grownStalkLost > 0) {
                emit ConvertDownPenalty(account, grownStalkLost, newGrownStalk);
            }
            return newGrownStalk;
        } else if (LibWell.isWell(inputToken) && outputToken == s.sys.bean) {
            // bonus up for WELL -> BEAN
            (uint256 bdvCapacityUsed, uint256 grownStalkGained) = stalkBonus(toBdv, grownStalk);

            if (bdvCapacityUsed > 0) {
                // update how much bdv was converted this season.
                updateBdvConverted(bdvCapacityUsed);
                if (grownStalkGained > 0) {
                    // update the grown stalk by the amount of grown stalk gained
                    newGrownStalk += grownStalk + grownStalkGained;
                    emit ConvertUpBonus(
                        account,
                        grownStalkGained,
                        newGrownStalk,
                        bdvCapacityUsed,
                        toBdv
                    );
                    return newGrownStalk;
                }
            }
        }
        // if the convert is not a BEAN -> WELL or WELL -> BEAN, return the grown stalk as is.
        return grownStalk;
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

    /**
     * @notice Calculates the stalk bonus for a convert. Credits the user with bonus grown stalk.
     * @dev This function is used to calculate the bonus grown stalk for a convert.
     * @param toBdv The bdv of the deposit to convert.
     * @param grownStalk Initial grown stalk of the deposit.
     * @return bdvCapacityUsed The amount of bdv that got the bonus.
     * @return grownStalkGained The amount of grown stalk gained from the bonus.
     */
    function stalkBonus(
        uint256 toBdv,
        uint256 grownStalk
    ) internal view returns (uint256 bdvCapacityUsed, uint256 grownStalkGained) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // get gauge value: how much bonus stalk to issue per BDV
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
            s.sys.gaugeData.gauges[GaugeId.CONVERT_UP_BONUS].value,
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );

        LibGaugeHelpers.ConvertBonusGaugeData memory gd = abi.decode(
            s.sys.gaugeData.gauges[GaugeId.CONVERT_UP_BONUS].data,
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        // if the bonus stalk per bdv is 0, there is no capacity used / grown stalk gained.
        if (gv.bonusStalkPerBdv == 0) {
            return (0, 0);
        }

        uint256 convertCapacity = getConvertCapacity(gv.maxConvertCapacity);
        // if the max convert capacity has been reached, return 0
        if (gd.bdvConvertedThisSeason >= convertCapacity) {
            return (0, 0);
        }

        // limit the bdv that can get the bonus
        uint256 bdvWithBonus = min(toBdv, convertCapacity - gd.bdvConvertedThisSeason);

        // Calculate the bonus stalk based on the eligible bdv.
        grownStalkGained = gv.bonusStalkPerBdv * bdvWithBonus;

        // if the stalk of the deposit is less than the bonus stalk,
        // limit the bonus to the stalk grown.
        if (grownStalk < grownStalkGained) {
            grownStalkGained = grownStalk;
            // if this occurs, the we recalculate the effective bdv that was used.
            // example: if the bonus stalk is 10, with a bonus capacity of 5 bdv (i.e 2 grown stalk per bdv),
            // and a user converted a deposit that has 5 stalk (with 5 bdv),
            // the user converted 5 bdv, but will only get 5 stalk (due to the deposit not having enough grown stalk).
            // this is equivalent to converting a deposit with >=5 stalk and 2.5 bdv.
            // thus, to prevent the ability for other users to limit others from converting,
            // we recalculate the effective bdv that was used to deduct from the bonus capacity.
            bdvWithBonus = grownStalkGained / gv.bonusStalkPerBdv;
        }
        return (bdvWithBonus, grownStalkGained);
    }

    /**
     * @notice Gets the time weighted convert capacity for the current season
     * @dev the amount of bdv that can be converted with a bonus ramps up linearly over the course of the season,
     * allowing converts to be more efficient and incur less slippage.
     * capacity ramps up linearly to 100% of the max capacity at 50% of the season.
     */
    function getConvertCapacity(uint256 maxConvertCapacity) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        uint256 convertRampPeriod = (s.sys.season.period * CAPACITY_RATE) / C.PRECISION;
        uint256 timeElapsed = block.timestamp - s.sys.season.timestamp;
        // if the current season is past the ramp period, return the max convert capacity
        if (timeElapsed > convertRampPeriod) {
            return maxConvertCapacity;
        } else {
            return (maxConvertCapacity * timeElapsed) / convertRampPeriod;
        }
    }

    /**
     * @notice Updates the convert bonus bdv capacity in the convert bonus gauge data.
     * @dev Separated here to allow `stalkBonus` to be called as a getter without touching state.
     * @param bdvConvertedBonus The amount of bdv that was converted with a bonus.
     */
    function updateBdvConverted(uint256 bdvConvertedBonus) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Get current gauge data using the new struct
        LibGaugeHelpers.ConvertBonusGaugeData memory gd = abi.decode(
            s.sys.gaugeData.gauges[GaugeId.CONVERT_UP_BONUS].data,
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        // Update this season's converted amount
        gd.bdvConvertedThisSeason += bdvConvertedBonus;
        // Encode and store updated gauge data
        LibGaugeHelpers.updateGaugeData(GaugeId.CONVERT_UP_BONUS, abi.encode(gd));
    }

    /**
     * @notice Checks for stalk slippage.
     * @param newGrownStalk The grown stalk of the deposit after applying the various penalty/bonus.
     * @param originalGrownStalk The original grown stalk of the deposit(s) that were converted.
     * @param grownStalkSlippage The slippage percentage. 100% = 1e18.
     * @dev a negative grownStalkSlippage implies the user requires more grown stalk than they started with. (i.e a bonus)
     */
    function checkGrownStalkSlippage(
        uint256 newGrownStalk,
        uint256 originalGrownStalk,
        int256 grownStalkSlippage
    ) internal pure {
        uint256 minimumStalk;

        if (grownStalkSlippage > 0) {
            // if the slippage is greater than 100%, any grown stalk is acceptable.
            if (uint256(grownStalkSlippage) >= MAX_GROWN_STALK_SLIPPAGE) {
                return;
            }
            minimumStalk =
                (originalGrownStalk * (MAX_GROWN_STALK_SLIPPAGE - uint256(grownStalkSlippage))) /
                MAX_GROWN_STALK_SLIPPAGE;
        } else {
            // negative slippage implies the user requires more grown stalk than they started with.
            minimumStalk =
                (originalGrownStalk * (MAX_GROWN_STALK_SLIPPAGE + uint256(-grownStalkSlippage))) /
                MAX_GROWN_STALK_SLIPPAGE;
        }

        require(newGrownStalk >= minimumStalk, "Convert: Stalk slippage");
    }

    ////// Math Functions //////

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

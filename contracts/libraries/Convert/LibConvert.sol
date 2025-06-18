// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibLambdaConvert} from "./LibLambdaConvert.sol";
import {LibConvertData} from "./LibConvertData.sol";
import {LibWellConvert} from "./LibWellConvert.sol";
import {LibWell} from "contracts/libraries/Well/LibWell.sol";
import {AppStorage, LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibWellMinting} from "contracts/libraries/Minting/LibWellMinting.sol";
import {C} from "contracts/C.sol";
import {LibRedundantMathSigned256} from "contracts/libraries/Math/LibRedundantMathSigned256.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LibDeltaB} from "contracts/libraries/Oracle/LibDeltaB.sol";
import {LibSilo} from "contracts/libraries/Silo/LibSilo.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibGerminate} from "contracts/libraries/Silo/LibGerminate.sol";
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
    uint256 constant CONVERT_DEMAND_UPPER_BOUND = 1.05e6; // 5% above 1
    uint256 constant CONVERT_DEMAND_LOWER_BOUND = 0.95e6; // 5% below 1

    event ConvertDownPenalty(address account, uint256 grownStalkLost);
    event ConvertUpBonus(address account, uint256 grownStalkGained, uint256 bdvCapacityUsed);

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
        if (fromToken.isWell() && toToken == s.sys.bean) return LibWellConvert.lpToPeg(fromToken);

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
        if (fromToken.isWell() && toToken == s.sys.bean) {
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

    ////// Stalk Penalty Calculations //////

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
            max(spd.higherAmountAgainstPeg, spd.convertCapacityPenalty),
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
            grownStalk
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
     * @return newGrownStalk The new grown stalk to assign the deposit, after applying the penalty/bonus.
     */
    function applyStalkModifiers(
        address inputToken,
        address outputToken,
        address account,
        uint256 toBdv,
        uint256 grownStalk
    ) internal returns (uint256 newGrownStalk) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // penalty down for BEAN -> WELL
        if (inputToken == s.sys.bean && LibWell.isWell(outputToken)) {
            uint256 grownStalkLost;
            (newGrownStalk, grownStalkLost) = downPenalizedGrownStalk(
                outputToken,
                toBdv,
                grownStalk
            );
            if (grownStalkLost > 0) {
                emit ConvertDownPenalty(account, grownStalkLost);
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
                    emit ConvertUpBonus(account, grownStalkGained, bdvCapacityUsed);
                }
            }
        }
        return grownStalk;
    }

    /**
     * @notice Computes new grown stalk after downward convert penalty.
     * No penalty if P > Q or grown stalk below germination threshold.
     * @dev Inbound must not be germinating, will return germinating amount of grown stalk.
     * @return newGrownStalk Amount of grown stalk to assign the deposit.
     * @return grownStalkLost Amount of grown stalk lost to penalty.
     */
    function downPenalizedGrownStalk(
        address well,
        uint256 bdv,
        uint256 grownStalk
    ) internal view returns (uint256 newGrownStalk, uint256 grownStalkLost) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // No penalty if output deposit germinating.
        uint256 minGrownStalk = LibTokenSilo.calculateGrownStalkAtNonGerminatingStem(well, bdv);
        if (grownStalk < minGrownStalk) {
            return (grownStalk, 0);
        }

        // No penalty if P > Q.
        if (pGreaterThanQ(well)) {
            return (grownStalk, 0);
        }

        // Get penalty ratio from gauge.
        (uint256 penaltyRatio, ) = abi.decode(
            s.sys.gaugeData.gauges[GaugeId.CONVERT_DOWN_PENALTY].value,
            (uint256, uint256)
        );
        newGrownStalk = max(
            grownStalk -
                LibPRBMathRoundable.mulDiv(
                    grownStalk,
                    penaltyRatio,
                    C.PRECISION,
                    LibPRBMathRoundable.Rounding.Up
                ),
            minGrownStalk
        );
        grownStalkLost = grownStalk - newGrownStalk;
    }

    /**
     * @notice Checks if the price of the well is greater than Q.
     * Q is a threshold above the price target at which the protocol deems the price excessive.
     * @param well The address of the well to check.
     * @return true if the price is greater than Q, false otherwise.
     */
    function pGreaterThanQ(address well) internal view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // No penalty if P > Q.
        (uint256[] memory ratios, uint256 beanIndex, bool success) = LibWell.getRatiosAndBeanIndex(
            IWell(well).tokens(),
            0
        );
        require(success, "Convert: USD Oracle failed");

        // Scale ratio by Q.
        ratios[beanIndex] =
            (ratios[beanIndex] * 1e6) /
            s.sys.evaluationParameters.excessivePriceThreshold;

        uint256[] memory instantReserves = LibDeltaB.instantReserves(well);
        Call memory wellFunction = IWell(well).wellFunction();
        uint256 beansAtQ = IBeanstalkWellFunction(wellFunction.target).calcReserveAtRatioSwap(
            instantReserves,
            beanIndex,
            ratios,
            wellFunction.data
        );
        // Fewer Beans indicates a higher Bean price.
        if (instantReserves[beanIndex] < beansAtQ) {
            return true;
        }
        return false;
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
     * @notice Gets the bonus stalk per bdv for the current season.
     * @dev the bonus stalk per Bdv is updated based on the convert demand and the difference between the bean seeds and the max lp seeds.
     * @param bonusStalkPerBdv The bonus stalk per bdv from the previous season.
     * @param bdvConvertedThisSeason The BDV converted in the current season.
     * @param bdvConvertedLastSeason The BDV converted in the previous season.
     * @return The updated bonus stalk per bdv.
     */
    function updateBonusStalkPerBdv(
        uint256 bonusStalkPerBdv,
        uint256 bdvConvertedThisSeason,
        uint256 bdvConvertedLastSeason
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // get stem tips for all whitelisted lp tokens and get the min
        address[] memory lpTokens = LibWhitelistedTokens.getWhitelistedLpTokens();
        uint256 beanSeeds = s.sys.silo.assetSettings[s.sys.bean].stalkEarnedPerSeason;
        uint256 maxLpSeeds;
        for (uint256 i = 0; i < lpTokens.length; i++) {
            uint256 lpSeeds = s.sys.silo.assetSettings[lpTokens[i]].stalkEarnedPerSeason;
            if (lpSeeds > maxLpSeeds) maxLpSeeds = lpSeeds;
        }

        // if the bean seeds are greater than or equal to the max lp seeds,
        // the bonus is updated based on the convert demand.
        if (beanSeeds >= maxLpSeeds) {
            uint256 bonusStalkPerBdvChange = (beanSeeds - maxLpSeeds) / C.PRECISION;

            // if nothing was converted last season, and something was converted this season,
            // the bonus should increase.
            if (bdvConvertedLastSeason == 0) {
                if (bdvConvertedThisSeason > 0) {
                    // zero bdv was converted last season, and non-zero bdv was converted this season,
                    // the bonus should increase.
                    return bonusStalkPerBdv + bonusStalkPerBdvChange;
                } else {
                    // nothing was converted last season, and nothing was converted this season,
                    // the bonus should decrease.
                    return bonusStalkPerBdv - bonusStalkPerBdvChange;
                }
            } else {
                // calculate the convert demand in order to determine if the bonus should increase or decrease.
                uint256 convertDemand = (bdvConvertedThisSeason * C.PRECISION_6) /
                    bdvConvertedLastSeason;
                if (convertDemand > CONVERT_DEMAND_UPPER_BOUND) {
                    return bonusStalkPerBdv + bonusStalkPerBdvChange;
                } else if (convertDemand < CONVERT_DEMAND_LOWER_BOUND) {
                    return bonusStalkPerBdv - bonusStalkPerBdvChange;
                } else {
                    return bonusStalkPerBdv;
                }
            }
        } else {
            // if the bean seeds are less than the max lp seeds, the bonus is reset.
            // This occurs when the crop ratio is < 100%.
            return 0;
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

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, IMockFBeanstalk, C} from "test/foundry/utils/TestHelper.sol";
import {IWell, IERC20} from "contracts/interfaces/basin/IWell.sol";
import {MockConvertFacet} from "contracts/mocks/mockFacets/MockConvertFacet.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {LibPRBMathRoundable} from "contracts/libraries/Math/LibPRBMathRoundable.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";
import {LibEvaluate} from "contracts/libraries/LibEvaluate.sol";
import {Decimal} from "contracts/libraries/Decimal.sol";
import "forge-std/console.sol";

/**
 * @title ConvertTest
 * @notice Tests the `convert` functionality.
 * @dev `convert` is the ability for users to switch a deposits token
 * from one whitelisted silo token to another,
 * given valid conditions. Generally, the ability to convert is based on
 * peg maintenance. See {LibConvert} for more information on specific convert types.
 */
contract ConvertTest is TestHelper {
    int256 MAX_GROWN_STALK_SLIPPAGE = 1e18;
    struct ConvertData {
        uint256 initalWellBeanBalance;
        uint256 initalLPbalance;
        uint256 initalBeanBalance;
    }

    event Convert(
        address indexed account,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount,
        uint256 fromBdv,
        uint256 toBdv
    );

    event ConvertDownPenalty(address account, uint256 grownStalk, uint256 grownStalkLost);
    event ConvertUpBonus(
        address account,
        uint256 grownStalk,
        uint256 newGrownStalk,
        uint256 grownStalkGained,
        uint256 bdvConverted
    );
    // Interfaces.
    MockConvertFacet convert = MockConvertFacet(BEANSTALK);
    IMockFBeanstalk convertBatch = IMockFBeanstalk(BEANSTALK);
    BeanstalkPrice beanstalkPrice = BeanstalkPrice(0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E);

    // MockTokens.
    MockToken weth = MockToken(WETH);

    // test accounts
    address[] farmers;

    // well in test:
    address well;

    LibGaugeHelpers.ConvertDownPenaltyValue gv;
    LibGaugeHelpers.ConvertDownPenaltyData gd;

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        well = BEAN_ETH_WELL;
        // init user.
        farmers.push(users[1]);
        maxApproveBeanstalk(farmers);

        // Initialize well to balances. (1000 BEAN/ETH)
        addLiquidityToWell(
            well,
            10000e6, // 10,000 Beans
            10 ether // 10 ether.
        );

        addLiquidityToWell(
            BEAN_WSTETH_WELL,
            10000e6, // 10,000 Beans
            10 ether // 10 WETH of wstETH
        );
    }

    //////////// BEAN <> WELL ////////////

    /**
     * @notice validates that `getMaxAmountIn` gives the proper output.
     */
    function test_bean_Well_getters(uint256 beanAmount) public {
        multipleBeanDepositSetup();
        beanAmount = bound(beanAmount, 0, 9000e6);

        assertEq(bs.getMaxAmountIn(BEAN, well), 0, "BEAN -> WELL maxAmountIn should be 0");
        assertEq(bs.getMaxAmountIn(well, BEAN), 0, "WELL -> BEAN maxAmountIn should be 0");

        uint256 snapshot = vm.snapshot();
        // decrease bean reserves
        setReserves(well, bean.balanceOf(well) - beanAmount, weth.balanceOf(well));

        assertEq(
            bs.getMaxAmountIn(BEAN, well),
            beanAmount,
            "BEAN -> WELL maxAmountIn should be beanAmount"
        );
        assertEq(bs.getMaxAmountIn(well, BEAN), 0, "WELL -> BEAN maxAmountIn should be 0");

        vm.revertTo(snapshot);

        // increase bean reserves
        setReserves(well, bean.balanceOf(well) + beanAmount, weth.balanceOf(well));

        assertEq(bs.getMaxAmountIn(BEAN, well), 0, "BEAN -> WELL maxAmountIn should be 0");
        // convert lp amount to beans:
        uint256 lpAmountOut = bs.getMaxAmountIn(well, BEAN);
        uint256 beansOut = IWell(well).getRemoveLiquidityOneTokenOut(lpAmountOut, bean);
        assertEq(beansOut, beanAmount, "beansOut should equal beanAmount");
    }

    /**
     * @notice Convert should fail if deposit amounts != convertData.
     */
    function test_bean_Well_fewTokensRemoved(uint256 beanAmount) public {
        multipleBeanDepositSetup();
        beanAmount = bound(beanAmount, 2, 1000e6);
        setReserves(well, bean.balanceOf(well) - beanAmount, weth.balanceOf(well));

        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // well
            beanAmount, // amountIn
            0 // minOut
        );
        int96[] memory stems = new int96[](1);
        stems[0] = int96(0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = uint256(1);

        vm.expectRevert("Convert: Not enough tokens removed.");
        vm.prank(farmers[0]);
        convert.convert(convertData, stems, amounts);
    }

    /**
     * @notice Convert should fail if user does not have the required deposits.
     */
    function test_bean_Well_invalidDeposit(uint256 beanAmount) public {
        multipleBeanDepositSetup();
        beanAmount = bound(beanAmount, 2, 1000e6);
        setReserves(well, bean.balanceOf(well) - beanAmount, weth.balanceOf(well));

        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // well
            beanAmount, // amountIn
            0 // minOut
        );
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = uint256(beanAmount);

        vm.expectRevert("Silo: Crate balance too low.");
        convert.convert(convertData, new int96[](1), amounts);
    }

    //////////// BEAN -> WELL ////////////

    /**
     * @notice Bean -> Well convert cannot occur below peg.
     */
    function test_convertBeanToWell_belowPeg(uint256 beanAmount) public {
        multipleBeanDepositSetup();

        beanAmount = bound(beanAmount, 1, 1000e6);
        // increase the amount of beans in the pool (below peg).
        setReserves(well, bean.balanceOf(well) + beanAmount, weth.balanceOf(well));

        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // well
            1, // amountIn
            0 // minOut
        );

        vm.expectRevert("Convert: P must be >= 1.");
        vm.prank(farmers[0]);
        convert.convert(convertData, new int96[](1), new uint256[](1));
    }

    /**
     * @notice Bean -> Well convert cannot convert beyond peg.
     * @dev if minOut is not constrained, the convert will succeed,
     * but only to the amount of beans that can be converted to the peg.
     */
    function test_convertBeanToWell_beyondPeg(uint256 beansRemovedFromWell) public {
        multipleBeanDepositSetup();

        uint256 beanWellAmount = bound(
            beansRemovedFromWell,
            C.WELL_MINIMUM_BEAN_BALANCE,
            bean.balanceOf(well) - 1
        );

        setReserves(well, beanWellAmount, weth.balanceOf(well));

        uint256 expectedBeansConverted = 10000e6 - beanWellAmount;
        uint256 expectedAmtOut = bs.getAmountOut(BEAN, well, expectedBeansConverted);

        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // well
            type(uint256).max, // amountIn
            0 // minOut
        );

        // get from/to bdvs
        uint256 bdv = bs.bdv(BEAN, expectedBeansConverted);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        vm.expectEmit();
        emit Convert(farmers[0], BEAN, well, expectedBeansConverted, expectedAmtOut, bdv, bdv);
        vm.prank(farmers[0]);
        convert.convert(convertData, new int96[](1), amounts);

        assertEq(bs.getMaxAmountIn(BEAN, well), 0, "BEAN -> WELL maxAmountIn should be 0");
    }

    /**
     * @notice general convert test.
     */
    function test_convertBeanToWellGeneral(uint256 deltaB, uint256 beansConverted) public {
        multipleBeanDepositSetup();

        deltaB = bound(deltaB, 100, 7000e6);
        setDeltaBforWell(int256(deltaB), well, WETH);

        beansConverted = bound(beansConverted, 100, deltaB);

        uint256 expectedAmtOut = bs.getAmountOut(BEAN, well, beansConverted);

        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // well
            beansConverted, // amountIn
            0 // minOut
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = beansConverted;

        // vm.expectEmit();
        emit Convert(farmers[0], BEAN, well, beansConverted, expectedAmtOut, 0, 0);
        vm.prank(farmers[0]);
        convert.convert(convertData, new int96[](1), amounts);

        int256 newDeltaB = bs.poolCurrentDeltaB(well);

        // verify deltaB.
        // assertEq(bs.getMaxAmountIn(BEAN, well), deltaB - beansConverted, 'BEAN -> WELL maxAmountIn should be deltaB - beansConverted');
    }

    ////////////////////// Convert Down Penalty //////////////////////

    function test_convertWithDownPenaltyTwice() public {
        disableRatePenalty();
        bean.mint(farmers[0], 20_000e6);
        bean.mint(0x0000000000000000000000000000000000000001, 200_000e6);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, 10_000e6, 0);
        sowAmountForFarmer(farmers[0], 100_000e6); // Prevent flood.
        passGermination();

        // Wait some seasons to allow stem tip to advance. More grown stalk to lose.
        uint256 l2sr;
        for (uint256 i; i < 580; i++) {
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            if (i == 579) {
                l2sr = bs.getLiquidityToSupplyRatio();
            }
            bs.sunrise();
        }

        uint256 lowerL2sr = bs.getLpToSupplyRatioLowerBound();
        (uint256 rollingSeasonsAbovePegRate, uint256 rollingSeasonsAbovePegCap) = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (uint256, uint256)
        );
        assertEq(rollingSeasonsAbovePegRate, 1, "rollingSeasonsAbovePegRate should be 1");
        assertEq(rollingSeasonsAbovePegCap, 12, "rollingSeasonsAbovePegCap should be 12");

        {
            (uint256 penaltyRatio, uint256 rollingSeasonsAbovePeg) = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
                (uint256, uint256)
            );
            assertEq(rollingSeasonsAbovePeg, 0, "rollingSeasonsAbovePeg should be 0");

            uint256 expectedPenaltyRatio = (1e18 * l2sr) / lowerL2sr;
            assertGt(expectedPenaltyRatio, 0, "t=0 penaltyRatio should be greater than 0");
            assertEq(expectedPenaltyRatio, penaltyRatio, "t=0 penaltyRatio incorrect");
            assertEq(expectedPenaltyRatio, 686167548391966350, "t=0 hardcoded ratio mismatch");

            // 1.0 < P < Q.
            setDeltaBforWell(int256(100e6), BEAN_ETH_WELL, WETH);

            uint256 beansToConvert = 50e6;
            (
                bytes memory convertData,
                int96[] memory stems,
                uint256[] memory amounts
            ) = getConvertDownData(well, beansToConvert);

            (uint256 amount, ) = bs.getDeposit(farmers[0], BEAN, int96(0));
            uint256 grownStalk = bs.grownStalkForDeposit(farmers[0], BEAN, int96(0));
            uint256 grownStalkConverting = (beansToConvert *
                bs.grownStalkForDeposit(farmers[0], BEAN, int96(0))) / amount;
            uint256 grownStalkLost = (grownStalkConverting * expectedPenaltyRatio) / 1e18;
            assertGt(grownStalkLost, 0, "grownStalkLost should be greater than 0");
            console.log("expected grown stalk lost", grownStalkLost);
            console.log("grown stalk remaining", grownStalkConverting - grownStalkLost);
            // expected grown stalk lost 39934951316412442
            // grown stalk remaining 18265048683587558
            // emit ConvertDownPenalty(account: Farmer 1: [0x64525e042465D0615F51aBB2982Ce82B8568Bcc4], grownStalkLost: 39934951316412441 [3.993e16], grownStalkKept: 18265048683587559 [1.826e16])
            vm.expectEmit();
            emit ConvertDownPenalty(
                farmers[0],
                grownStalkLost,
                grownStalkConverting - grownStalkLost
            );

            vm.prank(farmers[0]);
            (int96 toStem, , , , ) = convert.convertWithStalkSlippage(
                convertData,
                stems,
                amounts,
                MAX_GROWN_STALK_SLIPPAGE
            );

            assertGt(toStem, int96(0), "toStem should be larger than initial");
            uint256 newGrownStalk = bs.grownStalkForDeposit(farmers[0], well, toStem);

            assertLe(
                newGrownStalk,
                grownStalkConverting - grownStalkLost,
                "newGrownStalk too large"
            );
        }

        warpToNextSeasonAndUpdateOracles();
        vm.roll(block.number + 1800);
        l2sr = bs.getLiquidityToSupplyRatio();
        disableRatePenalty();
        bs.sunrise();

        {
            (uint256 penaltyRatio, uint256 rollingSeasonsAbovePeg) = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
                (uint256, uint256)
            );
            assertEq(rollingSeasonsAbovePeg, 1, "rollingSeasonsAbovePeg should be 1");

            assertGt(penaltyRatio, 0, "t=1 penaltyRatio should be greater than 0");
            assertEq(penaltyRatio, 503257521242652939, "t=1 hardcoded ratio mismatch");

            uint256 beansToConvert = 50e6;
            (
                bytes memory convertData,
                int96[] memory stems,
                uint256[] memory amounts
            ) = getConvertDownData(well, beansToConvert);

            (uint256 amount, ) = bs.getDeposit(farmers[0], BEAN, int96(0));
            uint256 grownStalk = bs.grownStalkForDeposit(farmers[0], BEAN, int96(0));
            uint256 grownStalkConverting = (beansToConvert *
                bs.grownStalkForDeposit(farmers[0], BEAN, int96(0))) / amount;
            uint256 grownStalkLost = (grownStalkConverting * penaltyRatio) / 1e18;
            assertGt(grownStalkLost, 0, "grownStalkLost should be greater than 0");

            // vm.expectEmit();
            // emit ConvertDownPenalty(farmers[0], grownStalk, grownStalkLost);

            vm.prank(farmers[0]);
            (int96 toStem, , , , ) = convert.convertWithStalkSlippage(
                convertData,
                stems,
                amounts,
                MAX_GROWN_STALK_SLIPPAGE
            );

            assertGt(toStem, int96(0), "toStem should be larger than initial");
            uint256 newGrownStalk = bs.grownStalkForDeposit(farmers[0], well, toStem);

            assertLe(
                newGrownStalk,
                grownStalkConverting - grownStalkLost,
                "newGrownStalk too large"
            );
        }
    }

    /**
     * @notice test that a convert with a penalty will not create a germinating deposit.
     * @dev rate penalty is disabled for this test to preserve backward compatibility.
     */
    function test_convertWithDownPenaltyGerminating() public {
        disableRatePenalty();
        bean.mint(farmers[0], 20_000e6);
        bean.mint(0x0000000000000000000000000000000000000001, 200_000e6);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, 10_000e6, 0);
        sowAmountForFarmer(farmers[0], 100_000e6); // Prevent flood.

        // // LP is still be germinating.
        // passGermination();

        // 1.0 < P < Q.
        setDeltaBforWell(int256(100e6), BEAN_ETH_WELL, WETH);

        uint256 beansToConvert = 10e6;
        (
            bytes memory convertData,
            int96[] memory stems,
            uint256[] memory amounts
        ) = getConvertDownData(well, beansToConvert);

        // Move forward one season.
        warpToNextSeasonAndUpdateOracles();
        vm.roll(block.number + 1800);
        bs.sunrise();

        // Move forward one season.
        warpToNextSeasonAndUpdateOracles();
        vm.roll(block.number + 1800);
        bs.sunrise();

        // Convert. Bean done germinating, but LP still germinating. No penalty.
        // vm.expectEmit();
        // emit ConvertDownPenalty(farmers[0], 40000010000000, 0); // grownStalkLost, newGrownStalk
        vm.prank(farmers[0]);
        convert.convert(convertData, stems, amounts);

        // Move forward one season.
        warpToNextSeasonAndUpdateOracles();
        vm.roll(block.number + 1800);
        uint256 l2sr = bs.getLiquidityToSupplyRatio();
        bs.sunrise();

        // Convert. LP done germinating. Penalized only the gap from germinating stalk amount.
        (uint256 amount, ) = bs.getDeposit(farmers[0], BEAN, int96(0));
        uint256 grownStalk = bs.grownStalkForDeposit(farmers[0], BEAN, int96(0));
        uint256 grownStalkConverting = (beansToConvert *
            bs.grownStalkForDeposit(farmers[0], BEAN, int96(0))) / amount;
        uint256 lowerL2sr = bs.getLpToSupplyRatioLowerBound();
        uint256 maxGrownStalkLost = LibPRBMathRoundable.mulDiv(
            (1e18 * l2sr) / lowerL2sr,
            grownStalkConverting,
            1e18,
            LibPRBMathRoundable.Rounding.Up
        );
        assertGt(maxGrownStalkLost, 0, "grownStalkLost should be greater than 0");
        // vm.expectEmit(false, false, false, false);
        // emit ConvertDownPenalty(farmers[0], 40000010000000, 1); // Do not check value match.
        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convertWithStalkSlippage(
            convertData,
            stems,
            amounts,
            MAX_GROWN_STALK_SLIPPAGE
        );

        uint256 newGrownStalk = bs.grownStalkForDeposit(farmers[0], well, toStem);
        uint256 stalkLost = grownStalkConverting - newGrownStalk;

        assertGt(stalkLost, 0, "some stalk should be lost");
        assertLt(stalkLost, maxGrownStalkLost, "stalkLost should be less than maxGrownStalkLost");
    }

    function test_convertWithDownPenaltyPgtQ() public {
        bean.mint(farmers[0], 20_000e6);
        bean.mint(0x0000000000000000000000000000000000000001, 200_000e6);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, 10_000e6, 0);
        sowAmountForFarmer(farmers[0], 100_000e6); // Prevent flood.
        passGermination();

        // Wait some seasons to allow stem tip to advance. More grown stalk to lose.
        uint256 l2sr;
        for (uint256 i; i < 580; i++) {
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            l2sr = bs.getLiquidityToSupplyRatio();
            bs.sunrise();
        }

        // 1.0 < Q < P.
        setDeltaBforWell(int256(1_000e6), BEAN_ETH_WELL, WETH);

        uint256 beansToConvert = 50e6;
        (
            bytes memory convertData,
            int96[] memory stems,
            uint256[] memory amounts
        ) = getConvertDownData(well, beansToConvert);

        (uint256 amount, ) = bs.getDeposit(farmers[0], BEAN, int96(0));
        uint256 grownStalk = bs.grownStalkForDeposit(farmers[0], BEAN, int96(0));
        uint256 grownStalkConverting = (beansToConvert *
            bs.grownStalkForDeposit(farmers[0], BEAN, int96(0))) / amount;

        // vm.expectEmit();
        // account, grownStalk, grownStalkLost
        // emit ConvertDownPenalty(farmers[0], 58200000000000000, 0); // No penalty when Q < P.

        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convert(convertData, stems, amounts);

        assertGt(toStem, int96(0), "toStem should be larger than initial");
        uint256 newGrownStalk = bs.grownStalkForDeposit(farmers[0], well, toStem);

        assertLe(newGrownStalk, grownStalkConverting, "newGrownStalk too large");
    }

    /**
     * @notice general convert test and verify down convert penalty.
     * @dev rate penalty is disabled for this test to preserve backward compatibility.
     */
    function test_convertBeanToWellWithPenalty() public {
        disableRatePenalty();
        bean.mint(farmers[0], 20_000e6);
        bean.mint(0x0000000000000000000000000000000000000001, 200_000e6);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, 10_000e6, 0);
        sowAmountForFarmer(farmers[0], 100_000e6); // Prevent flood.
        passGermination();

        // Wait some seasons to allow stem tip to advance. More grown stalk to lose.
        uint256 l2sr;
        for (uint256 i; i < 580; i++) {
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            if (i == 579) {
                l2sr = bs.getLiquidityToSupplyRatio();
            }
            bs.sunrise();
        }

        setDeltaBforWell(int256(100e6), BEAN_ETH_WELL, WETH);

        // create encoding for a bean -> well convert.
        uint256 beansToConvert = 5e6;
        (
            bytes memory convertData,
            int96[] memory stems,
            uint256[] memory amounts
        ) = getConvertDownData(well, beansToConvert);

        int256 totalDeltaB = bs.totalDeltaB();
        require(totalDeltaB > 0, "totalDeltaB should be greater than 0");

        // initial penalty, when rolling count of seasons above peg is 0 is l2sr.
        (uint256 lastPenaltyRatio, uint256 rollingSeasonsAbovePeg) = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
            (uint256, uint256)
        );
        assertEq(rollingSeasonsAbovePeg, 0, "rollingSeasonsAbovePeg should be 0");

        uint256 lowerL2sr = bs.getLpToSupplyRatioLowerBound();
        assertEq(
            (1e18 * l2sr) / lowerL2sr,
            lastPenaltyRatio,
            "initial penalty ratio should be l2sr ratio at pre sunrise"
        );

        // Convert 13 times, once per season, with an increasing rolling count and a diminishing penalty.
        int96 lastStem;
        uint256 lastGrownStalkPerBdv;
        for (uint256 i; i < 13; i++) {
            (uint256 newPenaltyRatio, uint256 rollingSeasonsAbovePeg) = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
                (uint256, uint256)
            );
            assertEq(rollingSeasonsAbovePeg, i, "rollingSeasonsAbovePeg incorrect");
            l2sr = bs.getLiquidityToSupplyRatio();

            vm.prank(farmers[0]);
            (int96 toStem, , , uint256 fromBdv, ) = convert.convertWithStalkSlippage(
                convertData,
                stems,
                amounts,
                MAX_GROWN_STALK_SLIPPAGE
            );

            if (i > 0) {
                assertLt(newPenaltyRatio, lastPenaltyRatio, "penalty ought to be getting smaller");
                assertLt(toStem, lastStem, "stems ought to be getting lower, penalty smaller");
            }
            lastPenaltyRatio = newPenaltyRatio;
            lastStem = toStem;
            uint256 newGrownStalkPerBdv = bs.grownStalkForDeposit(
                farmers[0],
                BEAN_ETH_WELL,
                toStem
            ) / fromBdv;
            assertGt(
                newGrownStalkPerBdv,
                lastGrownStalkPerBdv,
                "Grown stalk per bdv should increase"
            );
            lastGrownStalkPerBdv = newGrownStalkPerBdv;
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            disableRatePenalty();
            bs.sunrise();
            require(bs.abovePeg(), "abovePeg should be true");
        }

        // Test decreasing above peg count.
        setDeltaBforWell(int256(100e6), BEAN_ETH_WELL, WETH);
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();
        (lastPenaltyRatio, rollingSeasonsAbovePeg) = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
            (uint256, uint256)
        );
        assertEq(rollingSeasonsAbovePeg, 12, "rollingSeasonsAbovePeg at max");
        assertEq(0, lastPenaltyRatio, "final penalty should be 0");
        setDeltaBforWell(int256(-4_000e6), BEAN_ETH_WELL, WETH);
        uint256 i = 12;
        while (i > 0) {
            i--;
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            bs.sunrise();
            uint256 newPenaltyRatio;
            (newPenaltyRatio, rollingSeasonsAbovePeg) = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
                (uint256, uint256)
            );
            assertEq(rollingSeasonsAbovePeg, i, "rollingSeasonsAbovePeg not decreasing");
            assertGt(newPenaltyRatio, lastPenaltyRatio, "penalty ought to be getting larger");
            lastPenaltyRatio = newPenaltyRatio;
        }
        // Confirm min of 0.
        warpToNextSeasonAndUpdateOracles();
        vm.roll(block.number + 1800);
        bs.sunrise();
        (, rollingSeasonsAbovePeg) = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
            (uint256, uint256)
        );
        assertEq(rollingSeasonsAbovePeg, 0, "rollingSeasonsAbovePeg at min of 0");

        // P > Q.
        setDeltaBforWell(int256(1_000e6), BEAN_ETH_WELL, WETH);
        (uint256 newGrownStalk, uint256 grownStalkLost) = bs.downPenalizedGrownStalk(
            BEAN_ETH_WELL,
            1_000e6,
            10_000e18,
            1_000e6
        );
        assertEq(grownStalkLost, 0, "no penalty when P > Q");
        assertEq(newGrownStalk, 10_000e18, "stalk same when P > Q");
    }

    /**
     * @notice general convert test and verify down convert penalty, checking slippage.
     */
    function test_convertBeanToWellWithPenaltySlippageRevert() public {
        bs.setConvertDownPenaltyRate(2e6);
        bean.mint(farmers[0], 20_000e6);
        bean.mint(0x0000000000000000000000000000000000000001, 200_000e6);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, 10_000e6, 0);
        sowAmountForFarmer(farmers[0], 100_000e6); // Prevent flood.
        passGermination();

        // Wait some seasons to allow stem tip to advance. More grown stalk to lose.
        for (uint256 i; i < 580; i++) {
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            bs.sunrise();
        }

        setDeltaBforWell(int256(100e6), BEAN_ETH_WELL, WETH);

        // create encoding for a bean -> well convert.
        uint256 beansToConvert = 5e6;
        (
            bytes memory convertData,
            int96[] memory stems,
            uint256[] memory amounts
        ) = getConvertDownData(well, beansToConvert);

        // verify convert succeeds with max slippage.
        uint256 snapshot = vm.snapshot();
        vm.prank(farmers[0]);
        (int96 toStem, , , uint256 fromBdv, ) = convert.convertWithStalkSlippage(
            convertData,
            stems,
            amounts,
            MAX_GROWN_STALK_SLIPPAGE
        );
        vm.revertTo(snapshot);

        // verify convert reverts with slippage > max slippage.
        vm.prank(farmers[0]);
        vm.expectRevert("Convert: Stalk slippage");
        convert.convertWithStalkSlippage(convertData, stems, amounts, 0.66e18);

        // verify convert reverts with slippage < max slippage.
        vm.prank(farmers[0]);
        convert.convertWithStalkSlippage(convertData, stems, amounts, 0.69e18);
    }

    ////////////////////// Convert Up Bonus //////////////////////

    /**
     * @notice verifies convert factors change properly with increasing/decreasing demand for converting.
     */
    function test_convertUpBonus_change() public {
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );

        LibGaugeHelpers.ConvertBonusGaugeData memory gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        uint256 bonusStalkPerBdvBefore = type(uint256).max;

        // Create BeanstalkState with different pod rates and Bean prices to test different scenarios
        LibEvaluate.BeanstalkState memory testState = LibEvaluate.BeanstalkState({
            deltaPodDemand: Decimal.zero(),
            lpToSupplyRatio: Decimal.zero(),
            podRate: Decimal.zero(),
            largestLiqWell: address(0),
            oracleFailure: false,
            largestLiquidWellTwapBeanPrice: 1e6, // $1.00 Bean price
            twaDeltaB: 0,
            caseId: 0
        });
        testState.lpToSupplyRatio.value = 0.5e18; // 50% L2SR
        testState.podRate.value = 0.15e18; // 15% pod rate
        testState.largestLiquidWellTwapBeanPrice = 1e6; // $1.00 Bean price
        testState.twaDeltaB = -1000e6; // 10000e6 deltaB
        uint256 lowerBound = bs.getPodRateLowerBound();
        uint256 upperBound = bs.getPodRateUpperBound();

        bs.mockUpdateStalkPerBdvPerSeasonForToken(BEAN, 2e6);
        bs.mockUpdateStalkPerBdvPerSeasonForToken(BEAN_ETH_WELL, 1e6);
        bs.mockUpdateStalkPerBdvPerSeasonForToken(BEAN_WSTETH_WELL, 1e6);
        vm.warp(block.timestamp + 1800);
        bs.mockUpdateStalkPerBdvBonus(1e10);

        // scenario 1: increasing demand for converting. A user sows the max amount of beans for the bonus
        // Bonus should decrease over time.
        // capacity should increase over time.
        for (uint256 i = 0; i < 20; i++) {
            bs.mockUpdateBdvConverted(
                abi
                    .decode(
                        bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
                        (LibGaugeHelpers.ConvertBonusGaugeValue)
                    )
                    .maxConvertCapacity
            );

            bs.mockStepGauges(testState);
            LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
                (LibGaugeHelpers.ConvertBonusGaugeValue)
            );
            // verify behavior:

            // see whitepaper for expected delta change.
            uint256 expectedDeltaChange = LibGaugeHelpers.linearInterpolation(
                testState.lpToSupplyRatio.value,
                true,
                bs.getLpToSupplyRatioLowerBound(),
                bs.getLpToSupplyRatioUpperBound(),
                gd.minDeltaCapacity,
                gd.maxDeltaCapacity
            );

            uint256 targetSeasons = LibGaugeHelpers.linearInterpolation(
                testState.podRate.value,
                false,
                lowerBound,
                upperBound,
                gd.minSeasonTarget,
                gd.maxSeasonTarget
            );

            // In this test loop, we're mocking that maxConvertCapacity is fully used,
            // which means capacity is FILLED, so capacity factor should INCREASE
            uint256 expectedCapacityFactor = min(
                LibGaugeHelpers.MIN_CONVERT_CAPACITY_FACTOR + (expectedDeltaChange * i),
                LibGaugeHelpers.MAX_CONVERT_CAPACITY_FACTOR
            );

            assertEq(
                gv.convertCapacityFactor,
                expectedCapacityFactor,
                "convertCapacityFactor should increase when capacity is filled"
            );

            uint256 expectedMaxConvertCapacity = (uint256(-testState.twaDeltaB) *
                gv.convertCapacityFactor) /
                targetSeasons /
                100;
            LibGaugeHelpers.ConvertBonusGaugeData memory gdCheck = abi.decode(
                bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
                (LibGaugeHelpers.ConvertBonusGaugeData)
            );
            if (expectedMaxConvertCapacity < gdCheck.minMaxConvertCapacity) {
                expectedMaxConvertCapacity = gdCheck.minMaxConvertCapacity;
            }
            assertEq(
                gv.maxConvertCapacity,
                expectedMaxConvertCapacity,
                "convertCapacity should be 100e6 * convertBonusFactor / PRECISION or minMaxConvertCapacity, whichever is greater"
            );

            assertEq(
                gv.bonusStalkPerBdv,
                bs.getCalculatedBonusStalkPerBdv(),
                "bonusStalkPerBdv should be equal to the current base bonus stalk per bdv"
            );

            assertLt(
                gv.bonusStalkPerBdv,
                bonusStalkPerBdvBefore,
                "bonusStalkPerBdv should be decreasing"
            );
            bonusStalkPerBdvBefore = gv.bonusStalkPerBdv;
        }

        gv = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );

        uint256 previousCapacityFactor = gv.convertCapacityFactor;

        // scenario 2: constant demand for converting.
        // when demand is constant, bonus should stay the same. Example: a user places a maximum amount to convert to DCA into it.
        uint256 constantBdvConverted = (abi
            .decode(
                bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
                (LibGaugeHelpers.ConvertBonusGaugeValue)
            )
            .maxConvertCapacity * 90) / 100; // 90% of the max capacity
        for (uint256 i = 0; i < 10; i++) {
            bs.mockUpdateBdvConverted(constantBdvConverted);
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            bs.mockStepGauges(testState);
            gv = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
                (LibGaugeHelpers.ConvertBonusGaugeValue)
            );
            if (i == 0) {
                // for first iteration, bonusStalkPerBdv should be increasing. (because 90% * constantBdvConverted > 100% prev max capacity)
                assertGt(
                    gv.bonusStalkPerBdv,
                    bonusStalkPerBdvBefore,
                    "bonusStalkPerBdv should be increasing"
                );
            } else {
                // else, at a constant demand, the bonus should stay the same
                assertEq(
                    gv.bonusStalkPerBdv,
                    bonusStalkPerBdvBefore,
                    "bonusStalkPerBdv should be the same"
                );
            }

            assertEq(
                gv.convertCapacityFactor,
                previousCapacityFactor,
                "capacity factor should be the same"
            );

            bonusStalkPerBdvBefore = gv.bonusStalkPerBdv;
        }

        // scenario 3: constant demand for converting, but below the current capacity.
        // when demand is constant, bonus should stay the same. Example: a user places a maximum amount to convert to DCA into it.
        // capacity factor should decrease over time to match the demand.
        constantBdvConverted =
            (abi
                .decode(
                    bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
                    (LibGaugeHelpers.ConvertBonusGaugeValue)
                )
                .maxConvertCapacity * 10) /
            100; // 10% of the max capacity
        for (uint256 i = 0; i < 30; i++) {
            uint256 mostlyFilledThreshold = (abi
                .decode(
                    bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
                    (LibGaugeHelpers.ConvertBonusGaugeValue)
                )
                .maxConvertCapacity * 80) / 100; // 80% of the max capacity
            bs.mockUpdateBdvConverted(constantBdvConverted);
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            bs.mockStepGauges(testState);
            gv = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
                (LibGaugeHelpers.ConvertBonusGaugeValue)
            );
            if (i == 0) {
                // for first iteration, bonusStalkPerBdv should be increasing (less is being converted from the last session.)
                assertGt(
                    gv.bonusStalkPerBdv,
                    bonusStalkPerBdvBefore,
                    "bonusStalkPerBdv should be the increasing"
                );
            } else {
                // but when a constant amount is being converted, bonusStalkPerBdv should stay the same.
                assertEq(
                    gv.bonusStalkPerBdv,
                    bonusStalkPerBdvBefore,
                    "bonusStalkPerBdv should stay the same"
                );
            }

            if (constantBdvConverted <= mostlyFilledThreshold) {
                // if the constantBdvConverted is less than 80% of the max capacity of the current season,
                // the capacity factor should decrease over time to match the demand.
                assertLt(
                    gv.convertCapacityFactor,
                    previousCapacityFactor,
                    "capacity factor should decrease over time to match the demand"
                );
            } else {
                // eventually, the capacity factor reaches the user's demand (unless we're already at the minimum capacity (1%))
                assertEq(
                    gv.convertCapacityFactor,
                    previousCapacityFactor,
                    "capacity factor should be the same"
                );
            }

            bonusStalkPerBdvBefore = gv.bonusStalkPerBdv;
            previousCapacityFactor = gv.convertCapacityFactor;
        }

        gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );
        uint256 lastConvertBonusTaken = gd.lastConvertBonusTaken;
        bonusStalkPerBdvBefore = gv.bonusStalkPerBdv;

        // with decreasing demand for converting, verify:
        // convert factor behavior depends on bonus effectiveness
        // convert capacity decreases.
        // see whitepaper for expected delta change.
        uint256 expectedDeltaChange = 1e12 /
            LibGaugeHelpers.linearInterpolation(
                testState.lpToSupplyRatio.value,
                true,
                bs.getLpToSupplyRatioLowerBound(),
                bs.getLpToSupplyRatioUpperBound(),
                gd.minDeltaCapacity,
                gd.maxDeltaCapacity
            );

        uint256 targetSeasons = LibGaugeHelpers.linearInterpolation(
            testState.podRate.value,
            false,
            lowerBound,
            upperBound,
            gd.minSeasonTarget,
            gd.maxSeasonTarget
        );

        // scenario 4: decreasing demand for converting.
        uint256 expectedMaxConvertCapacity;
        LibGaugeHelpers.ConvertBonusGaugeData memory gdCheck;
        for (uint256 i = 1; i < 20; i++) {
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            // Mock zero conversions (decreasing demand)
            bs.mockUpdateBdvConverted(0);
            bs.mockStepGauges(testState);

            LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
                (LibGaugeHelpers.ConvertBonusGaugeValue)
            );

            // verify behavior:
            // With decreasing demand (zero conversions) and lastConvertBonusTaken set,
            // capacity factor should now decrease since demand is decreasing but
            // current bonus < lastConvertBonusTaken (bonus will decrease over time)

            // Verify that capacity factor decreases when demand is low and bonus is ineffective
            if (lastConvertBonusTaken > bonusStalkPerBdvBefore) {
                assertEq(
                    gv.convertCapacityFactor,
                    previousCapacityFactor,
                    "capacity factor should be the same"
                );
            } else {
                if (gv.convertCapacityFactor != 1e6) {
                    assertLt(
                        gv.convertCapacityFactor,
                        previousCapacityFactor,
                        "convertCapacityFactor should be decreasing with low demand"
                    );
                } else {
                    assertEq(gv.convertCapacityFactor, 1e6, "capacity factor should be 1e6");
                }
            }

            assertGt(
                gv.bonusStalkPerBdv,
                bonusStalkPerBdvBefore,
                "bonusStalkPerBdv should be increasing"
            );

            expectedMaxConvertCapacity =
                (uint256(-testState.twaDeltaB) * gv.convertCapacityFactor) /
                targetSeasons /
                100;
            gdCheck = abi.decode(
                bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
                (LibGaugeHelpers.ConvertBonusGaugeData)
            );
            if (expectedMaxConvertCapacity < gdCheck.minMaxConvertCapacity) {
                expectedMaxConvertCapacity = gdCheck.minMaxConvertCapacity;
            }
            assertEq(
                gv.maxConvertCapacity,
                expectedMaxConvertCapacity,
                "convertCapacity should be 100e6 * convertBonusFactor / PRECISION or minMaxConvertCapacity, whichever is greater"
            );

            assertEq(
                gv.bonusStalkPerBdv,
                bs.getCalculatedBonusStalkPerBdv(),
                "bonusStalkPerBdv should be equal to the current base bonus stalk per bdv"
            );
            bonusStalkPerBdvBefore = gv.bonusStalkPerBdv;
        }
    }

    // verifies the convert capacity increases over the course of a season.
    function test_convertUpBonus_time() public {
        // set capacity and bonus stalk per bdv
        bs.mockUpdateStalkPerBdvBonus(1e10);
        bs.mockUpdateBonusBdvCapacity(1000e6);

        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );

        uint256 remainingCapacityBefore;
        (, uint256 initialCapacity) = bs.getConvertStalkPerBdvBonusAndRemainingCapacity();
        remainingCapacityBefore = initialCapacity;
        for (uint256 i = 0; i < 360; i++) {
            (, uint256 remainingCapacity) = bs.getConvertStalkPerBdvBonusAndRemainingCapacity();
            if (block.timestamp - bs.time().timestamp == 0) {
                assertEq(remainingCapacity, 0, "capacity should be 0 at the start of the season");
            } else if (block.timestamp - bs.time().timestamp <= 1800) {
                // every season, the remaining capacity should increase.
                assertGt(
                    remainingCapacity,
                    remainingCapacityBefore,
                    "capacity should be increasing as the season progresses"
                );
                if (i == 180) {
                    // halfway through the season, the remaining capacity should be the max capacity.
                    assertEq(
                        remainingCapacity,
                        gv.maxConvertCapacity,
                        "capacity should be the max capacity at halfway through the season"
                    );
                } else {
                    // before halfway through the season, the remaining capacity should always be lower than the max capacity.
                    assertLt(
                        remainingCapacity,
                        gv.maxConvertCapacity,
                        "capacity should be less than the max capacity before halfway through the season"
                    );
                }
            } else {
                // after halfway through the season, the the remaining capacity should always stay the same.
                assertEq(
                    remainingCapacity - remainingCapacityBefore,
                    0,
                    "capacity should be the same after halfway through the season"
                );
                // after halfway through the season, the remaining capacity should be the max capacity.
                assertEq(
                    remainingCapacity,
                    gv.maxConvertCapacity,
                    "capacity should be the max capacity after halfway through the season"
                );
            }
            vm.warp(block.timestamp + 10);
            remainingCapacityBefore = remainingCapacity;
        }
    }

    // verify convert up bonus is applied when converting.
    function test_convertWellToBeanGeneralWithBonus() public {
        uint256 baseStalkedGainedFromConverting = 90585590000000000;
        uint256 lpMinted = multipleWellDepositSetup();

        uint256 deltaB = 1000e6;

        // set deltaB negative (crossing peg)
        setDeltaBforWell(-int256(deltaB), BEAN_ETH_WELL, WETH);

        warpToNextSeasonAndUpdateOracles();
        vm.roll(block.number + 1800);
        bs.sunrise();

        uint256 maxLpIn = bs.getMaxAmountIn(well, BEAN);
        uint256 lpConverted = maxLpIn;

        // create encoding for a well -> bean convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            well, // well
            lpConverted, // amountIn
            0 // minOuts
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = lpConverted;

        for (uint256 i = 0; i < 50; i++) {
            warpToNextSeasonAndUpdateOracles();
            vm.roll(block.number + 1800);
            bs.sunrise();
        }
        vm.warp(block.timestamp + 180); // warp to 10% of the convert ramp

        // update bonus stalk per bdv
        bs.mockUpdateStalkPerBdvBonus(1e10);
        bs.mockUpdateBonusBdvCapacity(1000e6);
        bs.mowAll(farmers[0]);
        uint256 usersStalkBefore = bs.balanceOfStalk(farmers[0]);
        uint256 snapshot = vm.snapshot();

        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );
        uint256 amountConverted = 100000000;
        uint256 expectedBdvBonus = 32900068;
        uint256 expectedStalkBonus = 329000684615378400;

        vm.expectEmit(true, true, true, false);
        emit ConvertUpBonus(
            farmers[0],
            expectedStalkBonus,
            usersStalkBefore + expectedStalkBonus,
            expectedBdvBonus,
            expectedBdvBonus
        );
        vm.prank(farmers[0]);
        convert.convert(convertData, new int96[](1), amounts);

        uint256 usersStalkAfter = bs.balanceOfStalk(farmers[0]);

        // verify totalBdvConvertedBonus is incremented.
        LibGaugeHelpers.ConvertBonusGaugeData memory gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        assertLe(
            gd.bdvConvertedThisSeason,
            deltaB,
            "bdvConvertedThisSeason should be less than deltaB"
        );
        assertEq(
            gd.bdvConvertedThisSeason,
            expectedBdvBonus,
            "bdvConvertedThisSeason should be equal to expectedBdvBonus"
        );

        assertLe(
            (usersStalkAfter - usersStalkBefore) - baseStalkedGainedFromConverting, // 329100684615378400
            (gv.bonusStalkPerBdv * amountConverted),
            "users gained stalk should be less than or equal to bonusStalkPerBdv * expectedBdvBonus"
        );

        vm.revertTo(snapshot);
        // case where bonus < users deposit stalk
        bs.mockUpdateStalkPerBdvBonus(1e6);
        gv = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );

        vm.prank(farmers[0]);
        vm.expectEmit(true, true, true, false);
        emit ConvertUpBonus(
            farmers[0],
            gv.bonusStalkPerBdv * expectedBdvBonus,
            usersStalkBefore + expectedStalkBonus + gv.bonusStalkPerBdv * expectedBdvBonus,
            expectedBdvBonus,
            expectedBdvBonus
        );
        convert.convert(convertData, new int96[](1), amounts);
        usersStalkAfter = bs.balanceOfStalk(farmers[0]);
        gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        assertLe(
            gd.bdvConvertedThisSeason,
            deltaB,
            "bdvConvertedThisSeason should be less than deltaB"
        );
        assertEq(
            gd.bdvConvertedThisSeason,
            amountConverted,
            "bdvConvertedThisSeason should be equal to expectedBdvBonus"
        );

        assertEq(
            (usersStalkAfter - usersStalkBefore) - baseStalkedGainedFromConverting,
            (gv.bonusStalkPerBdv * amountConverted),
            "users gained stalk should be equal to bonusStalkPerBdv * expectedBdvBonus"
        );
    }

    //////////// BEAN -> WELL ////////////

    /**
     * @notice general convert test. Uses multiple deposits.
     */
    function test_convertsBeanToWellGeneral(uint256 deltaB, uint256 beansConverted) public {
        multipleBeanDepositSetup();

        deltaB = bound(deltaB, 2, bean.balanceOf(well) - C.WELL_MINIMUM_BEAN_BALANCE);
        setReserves(well, bean.balanceOf(well) - deltaB, weth.balanceOf(well));

        beansConverted = bound(beansConverted, 2, deltaB);

        uint256 expectedAmtOut = bs.getAmountOut(BEAN, well, beansConverted);

        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // well
            beansConverted, // amountIn
            0 // minOut
        );

        int96[] memory stems = new int96[](2);
        stems[0] = int96(0);
        stems[1] = int96(2e6);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = beansConverted / 2;
        amounts[1] = beansConverted - amounts[0];

        // vm.expectEmit();
        // emit Convert(farmers[0], BEAN, well, beansConverted, expectedAmtOut, 0, 0);
        vm.prank(farmers[0]);
        convert.convert(convertData, stems, amounts);

        // verify deltaB.
        assertEq(
            bs.getMaxAmountIn(BEAN, well),
            deltaB - beansConverted,
            "BEAN -> WELL maxAmountIn should be deltaB - beansConverted"
        );
    }

    function multipleBeanDepositSetup() public {
        // Create 2 deposits, each at 10000 Beans to farmer[0].
        bean.mint(farmers[0], 20000e6);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, 10000e6, 0);
        season.siloSunrise(0);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, 10000e6, 0);

        // Germinating deposits cannot convert (see {LibGerminate}).
        passGermination();
    }

    //////////// WELL -> BEAN ////////////

    /**
     * @notice Well -> Bean convert cannot occur above peg.
     */
    function test_convertWellToBean_abovePeg(uint256 beanAmount) public {
        multipleWellDepositSetup();

        beanAmount = bound(beanAmount, 1, 1000e6);
        // decrease the amount of beans in the pool (above peg).
        setReserves(well, bean.balanceOf(well) - beanAmount, weth.balanceOf(well));

        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            well, // well
            1, // amountIn
            0 // minOut
        );

        vm.expectRevert("Convert: P must be < 1.");
        vm.prank(farmers[0]);
        convert.convert(convertData, new int96[](1), new uint256[](1));
    }

    /**
     * @notice Well -> Bean convert cannot occur beyond peg.
     */
    function test_convertWellToBean_beyondPeg(uint256 beansAddedToWell) public {
        multipleWellDepositSetup();

        beansAddedToWell = bound(beansAddedToWell, 1, 10000e6);
        uint256 beanWellAmount = bean.balanceOf(well) + beansAddedToWell;

        setReserves(well, beanWellAmount, weth.balanceOf(well));

        uint256 maxLPin = bs.getMaxAmountIn(well, BEAN);

        // create encoding for a well -> bean convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            well, // well
            type(uint256).max, // amountIn
            0 // minOut
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        // vm.expectEmit();
        // emit Convert(farmers[0], well, BEAN, maxLPin, beansAddedToWell, 0, 0);
        vm.prank(farmers[0]);
        convert.convert(convertData, new int96[](1), amounts);

        assertEq(bs.getMaxAmountIn(well, BEAN), 0, "WELL -> BEAN maxAmountIn should be 0");
    }

    /**
     * @notice Well -> Bean convert must use a whitelisted well.
     */
    function test_convertWellToBean_invalidWell(uint256 i) public {
        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            address(bytes20(keccak256(abi.encode(i)))), // invalid well
            0, // amountIn
            0 // minOut
        );

        vm.expectRevert("LibWhitelistedTokens: Token not found");
        convert.convert(convertData, new int96[](1), new uint256[](1));
    }

    /**
     * @notice general convert test.
     */
    function test_convertWellToBeanGeneral(uint256 deltaB, uint256 lpConverted) public {
        uint256 minLp = getMinLPin();
        uint256 lpMinted = multipleWellDepositSetup();

        deltaB = bound(deltaB, 1e6, 1000 ether);
        setReserves(well, bean.balanceOf(well) + deltaB, weth.balanceOf(well));
        uint256 initalWellBeanBalance = bean.balanceOf(well);
        uint256 initalLPbalance = MockToken(well).totalSupply();
        uint256 initalBeanBalance = bean.balanceOf(BEANSTALK);

        uint256 maxLpIn = bs.getMaxAmountIn(well, BEAN);
        lpConverted = bound(lpConverted, minLp, lpMinted / 2);

        // if the maximum LP that can be used is less than
        // the amount that the user wants to convert,
        // cap the amount to the maximum LP that can be used.
        if (lpConverted > maxLpIn) lpConverted = maxLpIn;

        uint256 expectedAmtOut = bs.getAmountOut(well, BEAN, lpConverted);

        // create encoding for a well -> bean convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            well, // well
            lpConverted, // amountIn
            0 // minOut
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = lpConverted;

        // get from/to bdvs
        // uint256 bdv = bs.bdv(well, lpConverted);

        // vm.expectEmit();
        // emit Convert(farmers[0], well, BEAN, lpConverted, expectedAmtOut, 0, 0);
        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convert(convertData, new int96[](1), amounts);
        int96 germinatingStem = bs.getGerminatingStem(address(well));

        // the new maximum amount out should be the difference between the deltaB and the expected amount out.
        assertEq(
            bs.getAmountOut(well, BEAN, bs.getMaxAmountIn(well, BEAN)),
            deltaB - expectedAmtOut,
            "amountOut does not equal deltaB - expectedAmtOut"
        );
        assertEq(
            bean.balanceOf(well),
            initalWellBeanBalance - expectedAmtOut,
            "well bean balance does not equal initalWellBeanBalance - expectedAmtOut"
        );
        assertEq(
            MockToken(well).totalSupply(),
            initalLPbalance - lpConverted,
            "well LP balance does not equal initalLPbalance - lpConverted"
        );
        assertEq(
            bean.balanceOf(BEANSTALK),
            initalBeanBalance + expectedAmtOut,
            "bean balance does not equal initalBeanBalance + expectedAmtOut"
        );
        assertLt(toStem, germinatingStem, "toStem should be less than germinatingStem");
    }

    /**
     * @notice general convert test. multiple deposits.
     */
    function test_convertsWellToBeanGeneral(uint256 deltaB, uint256 lpConverted) public {
        uint256 minLp = getMinLPin();
        uint256 lpMinted = multipleWellDepositSetup();

        // stalk bonus gauge data

        // update bdv capacity such that any convert will get the bonus
        bs.mockUpdateBonusBdvCapacity(type(uint128).max);
        bs.mockUpdateStalkPerBdvBonus(1e6);

        LibGaugeHelpers.ConvertBonusGaugeData memory gdBefore = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        deltaB = bound(deltaB, 1e6, 1000 ether);
        setReserves(well, bean.balanceOf(well) + deltaB, weth.balanceOf(well));
        ConvertData memory convertData = ConvertData(
            bean.balanceOf(well),
            MockToken(well).totalSupply(),
            bean.balanceOf(BEANSTALK)
        );

        lpConverted = bound(lpConverted, minLp, lpMinted);

        // if the maximum LP that can be used is less than
        // the amount that the user wants to convert,
        // cap the amount to the maximum LP that can be used.
        if (lpConverted > bs.getMaxAmountIn(well, BEAN))
            lpConverted = bs.getMaxAmountIn(well, BEAN);

        uint256 expectedAmtOut = bs.getAmountOut(well, BEAN, lpConverted);
        vm.warp(block.timestamp + 1800); // warp to halfway through the season.

        int96[] memory stems = new int96[](2);
        stems[0] = int96(0);
        stems[1] = int96(4e6); // 1 season of seeds for bean-eth.
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = lpConverted / 2;
        amounts[1] = lpConverted - amounts[0];

        // todo: fix stack too deep.
        // get from/to bdvs
        // uint256 bdv = bs.bdv(well, lpConverted);

        // vm.expectEmit();
        // emit Convert(farmers[0], well, BEAN, lpConverted, expectedAmtOut, bdv, bdv);
        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convert(
            convertEncoder(
                LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
                well, // well
                lpConverted, // amountIn
                0 // minOut
            ),
            stems,
            amounts
        );

        // the new maximum amount out should be the difference between the deltaB and the expected amount out.
        assertEq(
            bs.getAmountOut(well, BEAN, bs.getMaxAmountIn(well, BEAN)),
            deltaB - expectedAmtOut,
            "amountOut does not equal deltaB - expectedAmtOut"
        );
        assertEq(
            bean.balanceOf(well),
            convertData.initalWellBeanBalance - expectedAmtOut,
            "well bean balance does not equal initalWellBeanBalance - expectedAmtOut"
        );
        assertEq(
            MockToken(well).totalSupply(),
            convertData.initalLPbalance - lpConverted,
            "well LP balance does not equal initalLPbalance - lpConverted"
        );
        assertEq(
            bean.balanceOf(BEANSTALK),
            convertData.initalBeanBalance + expectedAmtOut,
            "bean balance does not equal initalBeanBalance + expectedAmtOut"
        );
        // stack too deep.
        {
            int96 germinatingStem = bs.getGerminatingStem(address(bean));
            assertLt(toStem, germinatingStem, "toStem should be less than germinatingStem");
            // verify bdvConverted is incremented.
            LibGaugeHelpers.ConvertBonusGaugeData memory gdAfter = abi.decode(
                bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
                (LibGaugeHelpers.ConvertBonusGaugeData)
            );
            assertGt(
                gdAfter.bdvConvertedThisSeason,
                gdBefore.bdvConvertedThisSeason,
                "bdvConverted should be incremented"
            );
        }
    }

    function multipleWellDepositSetup() public returns (uint256 lpMinted) {
        // Create 2 LP deposits worth 200_000 BDV.
        // note: LP is minted with an price of 1000 beans.
        lpMinted = mintBeanLPtoUser(farmers[0], 100000e6, 1000e6);
        vm.startPrank(farmers[0]);
        MockToken(well).approve(BEANSTALK, type(uint256).max);

        bs.deposit(well, lpMinted / 2, 0);
        season.siloSunrise(0);
        bs.deposit(well, lpMinted - (lpMinted / 2), 0);

        // Germinating deposits cannot convert (see {LibGerminate}).
        passGermination();
        vm.stopPrank();
    }

    /**
     * @notice issues a bean-tkn LP to user. the amount of LP issued is based on some price ratio.
     */
    function mintBeanLPtoUser(
        address account,
        uint256 beanAmount,
        uint256 priceRatio // ratio of TKN/BEAN (6 decimal precision)
    ) internal returns (uint256 amountOut) {
        IERC20[] memory tokens = IWell(well).tokens();
        address nonBeanToken = address(tokens[0]) == BEAN ? address(tokens[1]) : address(tokens[0]);
        bean.mint(well, beanAmount);
        MockToken(nonBeanToken).mint(well, (beanAmount * 1e18) / priceRatio);
        amountOut = IWell(well).sync(account, 0);
    }

    function getMinLPin() internal view returns (uint256) {
        uint256[] memory amountIn = new uint256[](2);
        amountIn[0] = 1;
        return IWell(well).getAddLiquidityOut(amountIn);
    }

    //////////// LAMBDA/LAMBDA ////////////

    /**
     * @notice lambda_lambda convert increases BDV.
     */
    function test_lambdaLambda_increaseBDV(uint256 deltaB) public {
        uint256 lpMinted = multipleWellDepositSetup();

        // create -deltaB to well via swapping, increasing BDV.
        // note: pumps are updated prior to reserves updating,
        // due to its manipulation resistant nature.
        // Thus, A pump needs a block to elapsed to update,
        // or another transaction by the well (if using the mock pump).
        MockToken(bean).mint(well, bound(deltaB, 1, 1000e6));
        IWell(well).shift(IERC20(weth), 0, farmers[0]);
        IWell(well).shift(IERC20(weth), 0, farmers[0]);

        uint256 amtToConvert = lpMinted / 2;

        // create lambda_lambda encoding.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.LAMBDA_LAMBDA,
            well,
            amtToConvert,
            0
        );

        // convert oldest deposit of user.
        int96[] memory stems = new int96[](1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amtToConvert;

        (uint256 initalAmount, uint256 initialBdv) = bs.getDeposit(farmers[0], well, 0);

        // dont check data for event since bdvs are checked afterwards.
        // vm.expectEmit(true, true, true, false);
        // emit Convert(farmers[0], well, well, initalAmount, initalAmount, 0, 0);
        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convert(convertData, stems, amounts);

        (uint256 updatedAmount, uint256 updatedBdv) = bs.getDeposit(farmers[0], well, toStem);
        // the stem of a deposit increased, because the stalkPerBdv of the deposit decreased.
        // stalkPerBdv is calculated by (stemTip - stem).
        assertGt(toStem, int96(0), "new stem should be higher than initial stem");
        assertEq(updatedAmount, initalAmount, "amounts should be equal");
        assertGt(updatedBdv, initialBdv, "new bdv should be higher");
    }

    /**
     * @notice lambda_lambda convert does not decrease BDV.
     */
    function test_lamdaLamda_decreaseBDV(uint256 deltaB) public {
        uint256 lpMinted = multipleWellDepositSetup();

        // create +deltaB to well via swapping, decreasing BDV.
        MockToken(weth).mint(well, bound(deltaB, 1e18, 100e18));
        IWell(well).shift(IERC20(bean), 0, farmers[0]);
        // note: pumps are updated prior to reserves updating,
        // due to its manipulation resistant nature.
        // Thus, A pump needs a block to elapsed to update,
        // or another transaction by the well (if using the mock pump).
        IWell(well).shift(IERC20(bean), 0, farmers[0]);
        uint256 amtToConvert = lpMinted / 2;

        // create lambda_lambda encoding.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.LAMBDA_LAMBDA,
            well,
            amtToConvert,
            0
        );

        // convert oldest deposit of user.
        int96[] memory stems = new int96[](1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amtToConvert;

        (uint256 initalAmount, uint256 initialBdv) = bs.getDeposit(farmers[0], well, 0);
        // dont check data for event since bdvs are checked afterwards.
        // vm.expectEmit(true, true, true, false);
        // emit Convert(farmers[0], well, well, initalAmount, initalAmount, 0, 0);
        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convert(convertData, stems, amounts);

        (uint256 updatedAmount, uint256 updatedBdv) = bs.getDeposit(farmers[0], well, toStem);
        assertEq(toStem, int96(0), "stems should be equal");
        assertEq(updatedAmount, initalAmount, "amounts should be equal");
        assertEq(updatedBdv, initialBdv, "bdv should be equal");
    }

    /**
     * @notice lambda_lambda convert combines deposits.
     */
    function test_lambdaLambda_combineDeposits(uint256 lpCombined) public {
        uint256 lpMinted = multipleWellDepositSetup();
        lpCombined = bound(lpCombined, 2, lpMinted);

        // create lambda_lambda encoding.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.LAMBDA_LAMBDA,
            well,
            lpCombined,
            0
        );

        int96[] memory stems = new int96[](2);
        stems[0] = int96(0);
        stems[1] = int96(4e6);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = lpCombined / 2;
        amounts[1] = lpCombined - amounts[0];

        // convert.
        // dont check data for event since bdvs are checked afterwards.
        // vm.expectEmit(true, true, true, false);
        // emit Convert(farmers[0], well, well, lpCombined, lpCombined, 0, 0);
        vm.prank(farmers[0]);
        convert.convert(convertData, stems, amounts);

        // verify old deposits are gone.
        // see `multipleWellDepositSetup` to understand the deposits.
        (uint256 amount, uint256 bdv) = bs.getDeposit(farmers[0], well, 0);
        assertEq(amount, lpMinted / 2 - amounts[0], "incorrect old deposit amount 0");
        assertApproxEqAbs(
            bdv,
            bs.bdv(well, (lpMinted / 2 - amounts[0])),
            1,
            "incorrect old deposit bdv 0"
        );

        (amount, bdv) = bs.getDeposit(farmers[0], well, 4e6);
        assertEq(amount, (lpMinted - lpMinted / 2) - amounts[1], "incorrect old deposit amount 1");
        assertApproxEqAbs(
            bdv,
            bs.bdv(well, (lpMinted - lpMinted / 2) - amounts[1]),
            1,
            "incorrect old deposit bdv 1"
        );

        // verify new deposit.
        // combining a 2 equal deposits should equal a deposit with the an average of the two stems.
        (amount, bdv) = bs.getDeposit(farmers[0], well, 2e6);
        assertEq(amount, lpCombined, "new deposit dne lpMinted");
        assertApproxEqAbs(bdv, bs.bdv(well, lpCombined), 2, "new deposit dne bdv");
    }

    ///////////////////// CONVERT RAIN ROOTS /////////////////////

    function test_convertBeanToWell_retainRainRoots(uint256 deltaB, uint256 beansConverted) public {
        // deposit and end germination
        multipleBeanDepositSetup();

        season.rainSunrise(); // start raining
        season.rainSunrise(); // sop

        // mow to get rain roots
        bs.mow(farmers[0], BEAN);

        // bound fuzzed values
        deltaB = bound(deltaB, 100, 7000e6);
        setDeltaBforWell(int256(deltaB), well, WETH);
        beansConverted = bound(beansConverted, 100, deltaB);

        // get from/to bdvs
        uint256 bdv = bs.bdv(BEAN, beansConverted);

        // snapshot rain roots state
        uint256 expectedAmtOut = bs.getAmountOut(BEAN, well, beansConverted);
        uint256 expectedFarmerRainRoots = bs.balanceOfRainRoots(farmers[0]);
        uint256 expectedTotalRainRoots = bs.totalRainRoots();

        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // well
            beansConverted, // amountIn
            0 // minOut
        );

        // convert beans to well
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = beansConverted;
        // vm.expectEmit();
        // emit Convert(farmers[0], BEAN, well, beansConverted, expectedAmtOut, bdv, bdv);
        vm.prank(farmers[0]);
        convert.convert(convertData, new int96[](1), amounts);

        // assert that the farmer did not lose any rain roots as a result of the convert
        assertEq(
            bs.totalRainRoots(),
            expectedTotalRainRoots,
            "total rain roots should not change after convert"
        );

        assertEq(
            bs.balanceOfRainRoots(farmers[0]),
            expectedFarmerRainRoots,
            "rain roots of user should not change after convert"
        );
    }

    function test_convertWellToBean_retainRainRoots(uint256 deltaB, uint256 lpConverted) public {
        // deposit and end germination
        uint256 lpMinted = multipleWellDepositSetup();

        season.rainSunrise(); // start raining
        season.rainSunrise(); // sop

        // mow to get rain roots
        bs.mow(farmers[0], BEAN);

        // snapshot rain roots state
        uint256 expectedFarmerRainRoots = bs.balanceOfRainRoots(farmers[0]);
        uint256 expectedTotalRainRoots = bs.totalRainRoots();

        // bound the fuzzed values
        uint256 minLp = getMinLPin();
        deltaB = bound(deltaB, 1e6, 1000 ether);
        setReserves(well, bean.balanceOf(well) + deltaB, weth.balanceOf(well));

        uint256 maxLpIn = bs.getMaxAmountIn(well, BEAN);
        lpConverted = bound(lpConverted, minLp, lpMinted / 2);

        // if the maximum LP that can be used is less than
        // the amount that the user wants to convert,
        // cap the amount to the maximum LP that can be used.
        if (lpConverted > maxLpIn) lpConverted = maxLpIn;

        uint256 expectedAmtOut = bs.getAmountOut(well, BEAN, lpConverted);

        // create encoding for a well -> bean convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            well, // well
            lpConverted, // amountIn
            0 // minOut
        );

        // get from/to bdvs
        uint256 bdv = bs.bdv(well, lpConverted);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = lpConverted;

        // vm.expectEmit();
        // emit Convert(farmers[0], well, BEAN, lpConverted, expectedAmtOut, bdv, bdv);

        // convert well lp to beans
        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convert(convertData, new int96[](1), amounts);
        int96 germinatingStem = bs.getGerminatingStem(address(well));

        // assert that the farmer did not lose any rain roots as a result of the convert
        assertEq(
            bs.totalRainRoots(),
            expectedTotalRainRoots,
            "total rain roots should not change after convert"
        );

        assertEq(
            bs.balanceOfRainRoots(farmers[0]),
            expectedFarmerRainRoots,
            "rain roots of user should not change after convert"
        );
    }

    //////////// REVERT ON PENALTY ////////////

    // function test_convertWellToBeanRevert(uint256 deltaB, uint256 lpConverted) public {
    //     uint256 minLp = getMinLPin();
    //     uint256 lpMinted = multipleWellDepositSetup();

    //     deltaB = bound(deltaB, 1e6, 1000 ether);
    //     setReserves(well, bean.balanceOf(well) + deltaB, weth.balanceOf(well));
    //     uint256 initalWellBeanBalance = bean.balanceOf(well);
    //     uint256 initalLPbalance = MockToken(well).totalSupply();
    //     uint256 initalBeanBalance = bean.balanceOf(BEANSTALK);

    //     uint256 maxLpIn = bs.getMaxAmountIn(well, BEAN);
    //     lpConverted = bound(lpConverted, minLp, lpMinted / 2);

    //     // if the maximum LP that can be used is less than
    //     // the amount that the user wants to convert,
    //     // cap the amount to the maximum LP that can be used.
    //     if (lpConverted > maxLpIn) lpConverted = maxLpIn;

    //     uint256 expectedAmtOut = bs.getAmountOut(well, BEAN, lpConverted);

    //     // create encoding for a well -> bean convert.
    //     bytes memory convertData = convertEncoder(
    //         LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
    //         well, // well
    //         lpConverted, // amountIn
    //         0 // minOut
    //     );

    //     uint256[] memory amounts = new uint256[](1);
    //     amounts[0] = lpConverted;

    //     vm.expectEmit();
    //     emit Convert(farmers[0], well, BEAN, lpConverted, expectedAmtOut, 0, 0);
    //     vm.prank(farmers[0]);
    //     convert.convert(
    //         convertData,
    //         new int96[](1),
    //         amounts
    //     );

    //     // the new maximum amount out should be the difference between the deltaB and the expected amount out.
    //     assertEq(bs.getAmountOut(well, BEAN, bs.getMaxAmountIn(well, BEAN)), deltaB - expectedAmtOut, 'amountOut does not equal deltaB - expectedAmtOut');
    //     assertEq(bean.balanceOf(well), initalWellBeanBalance - expectedAmtOut, 'well bean balance does not equal initalWellBeanBalance - expectedAmtOut');
    //     assertEq(MockToken(well).totalSupply(), initalLPbalance - lpConverted, 'well LP balance does not equal initalLPbalance - lpConverted');
    //     assertEq(bean.balanceOf(BEANSTALK), initalBeanBalance + expectedAmtOut, 'bean balance does not equal initalBeanBalance + expectedAmtOut');
    // }

    /**
     * @notice create encoding for a bean -> well convert.
     */
    function getConvertDownData(
        address well,
        uint256 beansToConvert
    )
        private
        view
        returns (bytes memory convertData, int96[] memory stems, uint256[] memory amounts)
    {
        convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // well
            beansToConvert, // amountIn
            0 // minOut
        );
        stems = new int96[](1);
        stems[0] = int96(0);
        amounts = new uint256[](1);
        amounts[0] = beansToConvert;
    }

    /** disables the rate penalty for a convert */
    function disableRatePenalty() internal {
        // sets the convert penalty at 1.025e6 (1.025$)
        bs.setConvertDownPenaltyRate(1.025e6);
        bs.setBeansMintedAbovePeg(type(uint128).max);
        bs.setBeanMintedThreshold(0);
        bs.setThresholdSet(false);
    }

    //////////// NEW THRESHOLD-BASED PENALTY TESTS ////////////

    /**
     * @notice verify above peg behaviour with the convert gauge system.
     */
    function test_convertBelowMintThreshold(uint256 deltaB) public {
        uint256 supply = IERC20(bean).totalSupply();

        deltaB = bound(deltaB, 100e6, 1000e6);

        // initialize the bean amount above threshold to 10M
        bs.setBeanMintedThreshold(10_000e6);

        // Set positive deltaB for the test scenario
        setDeltaBforWell(int256(deltaB), BEAN_ETH_WELL, WETH);

        // call sunrise to update the gauge
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();
        bs.setBeanMintedThreshold(10_000e6);
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();

        // Get penalty ratio - should be max when below minting threshold
        gv = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyValue)
        );

        gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );

        // Should be max penalty (100%) since beans minted is below threshold
        assertEq(gv.penaltyRatio, 1e18, "Penalty should be 100% when below threshold");

        assertEq(gv.rollingSeasonsAbovePeg, 0, "Rolling seasons above peg should be 0");

        assertEq(gd.rollingSeasonsAbovePegRate, 1, "rollingSeasonsAbovePegRate should be 1");
        assertEq(gd.rollingSeasonsAbovePegCap, 12, "rollingSeasonsAbovePegCap should be 12");
        assertApproxEqAbs(
            gd.beansMintedAbovePeg,
            deltaB,
            1,
            "beansMintedAbovePeg should be deltaB"
        );

        assertEq(
            gd.percentSupplyThresholdRate,
            416666666666667,
            "percentSupplyThresholdRate should be 1.005e6"
        );

        assertEq(
            gd.beanMintedThreshold,
            10_000e6,
            "Bean amount above threshold should stay the same"
        );

        // verify the grown stalk is penalized properly above and below.
        bs.setConvertDownPenaltyRate(2e6); // penalty price is 2$
        (uint256 newGrownStalk, uint256 grownStalkLost) = bs.downPenalizedGrownStalk(
            well,
            1e6, // bdv
            1e16, // grownStalk
            1e6 // fromAmount
        );

        // verify penalty is ~100% (the user cannot lose the amount such that germinating stalk is lost)
        uint256 germinatingMinStalk = (4e6 + 1) * 1e6;
        assertEq(grownStalkLost, 1e16 - germinatingMinStalk, "grownStalkLost should be 1e16");
        assertEq(newGrownStalk, germinatingMinStalk, "newGrownStalk should be 0");

        // verify penalty is 0%
        bs.setConvertDownPenaltyRate(1e6); // penalty rate is 1e6 (any convert works)
        (newGrownStalk, grownStalkLost) = bs.downPenalizedGrownStalk(
            well,
            1e6, // bdv
            1e16, // grownStalk
            1e6 // fromAmount
        );

        // verify penalty is 0%
        assertEq(grownStalkLost, 0, "grownStalkLost should be 0");
        assertEq(newGrownStalk, 1e16, "newGrownStalk should be 1e16");
    }

    /**
     * @notice Test the convert gauge system when below peg.
     */
    function test_convertGaugeBelowPeg(uint256 deltaB) public {
        bs.setBeanMintedThreshold(0);
        bs.setThresholdSet(true);
        deltaB = bound(deltaB, 100e6, 1000e6);
        setDeltaBforWell(-int256(deltaB), BEAN_ETH_WELL, WETH);
        // Set negative deltaB (below peg) for multiple seasons
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();
        uint256 supply = IERC20(bean).totalSupply();
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();

        // Get penalty ratio - should be max when below minting threshold
        gv = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyValue)
        );

        gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );

        assertEq(gv.rollingSeasonsAbovePeg, 0, "Rolling seasons above peg should be 0");

        assertEq(gd.beansMintedAbovePeg, 0, "beansMintedAbovePeg should be 0");

        // verify the beans threshold increases by the correct amount.
        assertEq(
            gd.beanMintedThreshold,
            (supply * gd.percentSupplyThresholdRate) / C.PRECISION,
            "beanMintedThreshold should be equal to the deltaB * percentSupplyThresholdRate"
        );
    }

    // verify the behaviour of the gauge when we hit the threshold.
    function test_convertGaugeIncreasesBeanAmountAboveThreshold() public {
        // deltaB setup.
        setDeltaBforWell(100e6, BEAN_ETH_WELL, WETH);
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();

        // system is below peg, and crossing above.
        bs.setBeanMintedThreshold(150e6); // set to 150e6

        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();

        gv = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyValue)
        );

        gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );

        // verify
        // 1) the bean amount minted above peg is increased by the correct amount.
        // 2) the threshold hit flag is set to false.

        assertEq(gd.beansMintedAbovePeg, 100e6, "beansMintedAbovePeg should be 100e6");
        assertEq(gd.thresholdSet, true, "thresholdSet should be true");
        assertEq(gv.penaltyRatio, 1e18, "penaltyRatio should be 100%");

        // call sunrise again.
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();

        gv = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyValue)
        );

        gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );

        // the beans above peg should reset, and the threshold is un set.
        assertEq(gd.beansMintedAbovePeg, 0, "beansMintedAbovePeg should be 200e6");
        assertEq(gd.thresholdSet, false, "thresholdSet should be false");
        assertEq(gv.penaltyRatio, 1e18, "penaltyRatio should still be 100%");

        vm.snapshot();

        // verify that the penalty decays over time:
        uint256 penaltyRatio = 2e18;
        for (uint256 i; i < gd.rollingSeasonsAbovePegCap; i++) {
            console.log("season", i);
            warpToNextSeasonAndUpdateOracles();
            bs.sunrise();

            gv = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
                (LibGaugeHelpers.ConvertDownPenaltyValue)
            );

            gd = abi.decode(
                bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
                (LibGaugeHelpers.ConvertDownPenaltyData)
            );
            console.log("new penaltyRatio", gv.penaltyRatio);
            console.log("old penaltyRatio last season", penaltyRatio);

            assertLt(gv.penaltyRatio, penaltyRatio, "penaltyRatio should decay");
            penaltyRatio = gv.penaltyRatio;
            assertEq(gv.rollingSeasonsAbovePeg, i + 1, "rollingSeasonsAbovePeg should be i + 1");
            assertEq(gd.beansMintedAbovePeg, 0, "beansMintedAbovePeg should be 0");
            assertEq(gd.thresholdSet, false, "thresholdSet should be false");
        }
    }

    /**
     * @notice Test the running threshold mechanism that tracks threshold growth during extended below-peg periods
     * @dev The running threshold is used when the system crosses above peg, sets a threshold,
     * but then goes back below peg without hitting the mint threshold. If the system experiences
     * a sustained period below peg, the running threshold accumulates and eventually updates
     * the beanMintedThreshold when it exceeds it.
     */
    function test_runningThreshold() public {
        uint256 initialThreshold = 100e6;
        // Set initial threshold
        bs.setBeanMintedThreshold(initialThreshold); // 1000 beans need to be minted to hit the threshold
        bs.setThresholdSet(true); // threshold is set

        // Move system below peg to start accumulating running threshold
        setDeltaBforWell(int256(-2000e6), BEAN_ETH_WELL, WETH);

        // Track running threshold accumulation over multiple seasons below peg
        uint256 expectedRunningThreshold = 0;

        for (uint256 i = 0; i < 5; i++) {
            warpToNextSeasonAndUpdateOracles();
            uint256 supply = IERC20(bean).totalSupply();
            bs.sunrise();

            // Calculate expected running threshold increment
            expectedRunningThreshold += (supply * gd.percentSupplyThresholdRate) / C.PRECISION;

            gd = abi.decode(
                bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
                (LibGaugeHelpers.ConvertDownPenaltyData)
            );

            // Running threshold should accumulate while below peg with threshold set
            assertEq(
                gd.runningThreshold,
                expectedRunningThreshold,
                "Running threshold should accumulate"
            );
            console.log("expectedRunningThreshold", expectedRunningThreshold);
            assertEq(
                gd.beanMintedThreshold,
                initialThreshold,
                "Bean minted threshold should remain unchanged"
            );
            assertEq(gd.thresholdSet, true, "Threshold should remain set");
        }

        // Continue below peg until running threshold exceeds beanMintedThreshold
        while (gd.runningThreshold != 0) {
            warpToNextSeasonAndUpdateOracles();
            bs.sunrise();

            gd = abi.decode(
                bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
                (LibGaugeHelpers.ConvertDownPenaltyData)
            );
            console.log("runningThreshold", gd.runningThreshold);
        }

        // // Verify that beanMintedThreshold was updated to running threshold value
        assertGt(
            gd.beanMintedThreshold,
            initialThreshold,
            "Bean minted threshold should have increased"
        );
        assertEq(gd.runningThreshold, 0, "Running threshold should reset to 0");
        assertEq(gd.thresholdSet, false, "Threshold should be unset");
        uint256 newThreshold = gd.beanMintedThreshold;
        console.log("newThreshold", newThreshold);

        // verify that subsequent sunrises will increase the threshold
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();
        gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );
        assertGt(
            gd.beanMintedThreshold,
            newThreshold,
            "Bean minted threshold should have increased"
        );
        assertEq(gd.runningThreshold, 0, "Running threshold should stay to 0");
        assertEq(gd.thresholdSet, false, "Threshold should stay unset");

        // Test that crossing back above peg resets running threshold
        setDeltaBforWell(int256(10e6), BEAN_ETH_WELL, WETH);
        warpToNextSeasonAndUpdateOracles();
        bs.sunrise();

        gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );

        assertEq(gd.runningThreshold, 0, "Running threshold should remain 0 when above peg");
        assertEq(gd.thresholdSet, true, "Threshold should be set again when above peg");
    }

    //////////// EDGE CASE TESTS ////////////

    /**
     * @notice Test rapid peg crossing scenarios
     */
    function test_rapidPegCrossing() public {
        bs.setBeansMintedAbovePeg(500e6);

        // Rapidly cross peg multiple times
        for (uint256 i = 0; i < 3; i++) {
            // Below peg
            setDeltaBforWell(int256(-100e6), BEAN_ETH_WELL, WETH);
            warpToNextSeasonAndUpdateOracles();
            bs.sunrise();

            // Above peg
            setDeltaBforWell(int256(100e6), BEAN_ETH_WELL, WETH);
            warpToNextSeasonAndUpdateOracles();
            bs.sunrise();
        }

        // Check final state is consistent
        LibGaugeHelpers.ConvertDownPenaltyData memory finalData = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );

        assertGt(finalData.beansMintedAbovePeg, 0, "Should have accumulated beans");
    }

    // verifies that `getMaxAmountInAtRate` returns the correct amount of beans to convert
    // when the penalty rate is higher than the rate at which the user is converting.
    function test_getMaxAmountInAtRate(uint256 amountIn) public {
        bs.setBeanMintedThreshold(1000e6);
        bs.setBeansMintedAbovePeg(0);
        bs.setPenaltyRatio(1e18); // set penalty ratio to 100%
        bs.setConvertDownPenaltyRate(1.02e6); // increase the penalty rate to 1.02e6 for easier testing
        // set deltaB to 100e6 (lower than threshold)
        setDeltaBforWell(int256(5000e6), BEAN_ETH_WELL, WETH);
        updateAllChainlinkOraclesWithPreviousData();
        updateAllChainlinkOraclesWithPreviousData();

        uint256 maxConvertNoPenalty = bs.getMaxAmountInAtRate(BEAN, BEAN_ETH_WELL, 1.02e6); // add 1 to avoid stalk loss due to rounding errors
        uint256 maxConvertOverall = bs.getMaxAmountIn(BEAN, BEAN_ETH_WELL);
        uint256 maxBdvPenalized = maxConvertOverall - maxConvertNoPenalty;
        amountIn = bound(amountIn, 1, maxConvertOverall);

        (uint256 newGrownStalk, uint256 grownStalkLost) = bs.downPenalizedGrownStalk(
            BEAN_ETH_WELL,
            amountIn,
            10e16, // 10 grown stalk
            amountIn
        );

        // 3 cases:
        // 1. amountIn <= maxConvertNoPenalty: no penalty
        // 2. amountIn > maxConvertNoPenalty && amountIn <= maxConvertOverall: no penalty up to `maxConvertNoPenalty`, but then a penalty is applied on `amountIn - maxConvertNoPenalty`
        // 3. amountIn > maxConvertOverall: full penalty is applied.

        if (amountIn <= maxConvertNoPenalty) {
            assertEq(grownStalkLost, 0, "grownStalkLost should be 0");
            assertEq(newGrownStalk, 10e16, "newGrownStalk should be equal to amountIn");
        } else if (amountIn < maxConvertOverall) {
            // user converted from above the rate, to below the rate.
            // a partial penalty is applied.
            // penalty is applied as a function of the amount beyond the rate.
            uint256 amountBeyondRate = amountIn - maxConvertNoPenalty;
            uint256 calculatedGrownStalkLost = (10e16 * amountBeyondRate) / amountIn;
            assertEq(grownStalkLost, calculatedGrownStalkLost, "grownStalkLost should be 10e16");
        } else {
            uint256 calculatedGrownStalkLost = (10e16 * maxBdvPenalized) / amountIn;
            // full penalty is applied.
            assertEq(
                grownStalkLost,
                calculatedGrownStalkLost,
                "grownStalkLost should be 10 stalk - germination stalk"
            );
            assertEq(
                newGrownStalk,
                10e16 - calculatedGrownStalkLost,
                "newGrownStalk should be 10e16"
            );
        }
    }

    //////////// DEWHITELISTED CONVERT TESTS ////////////

    /**
     * @notice Test that converting from a dewhitelisted well to Bean succeeds.
     * This should work because you can always convert to Bean from any existing deposit.
     */
    function test_convertDewhitelistedWellToBean(uint256 beanAmount) public {
        // Setup LP deposits
        uint256 lpMinted = multipleWellDepositSetup();
        beanAmount = bound(beanAmount, 100, 1000e6);

        // Set up conditions for well to bean conversion (below  peg)
        setReserves(well, bean.balanceOf(well) + beanAmount, weth.balanceOf(well));

        // Dewhitelist the well AFTER deposits are made
        vm.prank(BEANSTALK);
        bs.dewhitelistToken(well);

        // Verify well is dewhitelisted
        assertFalse(bs.tokenSettings(well).selector != bytes4(0), "Well should be dewhitelisted");

        // Create encoding for well -> Bean convert
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            well, // dewhitelisted well
            lpMinted / 4, // amountIn (convert part of deposit)
            0 // minOut
        );

        int96[] memory stems = new int96[](1);
        stems[0] = int96(0); // first deposit stem
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = lpMinted / 4;

        // Convert should succeed
        vm.prank(farmers[0]);
        convert.convert(convertData, stems, amounts);
    }

    /**
     * @notice Test that converting from Bean to a dewhitelisted well fails.
     * This should fail because you cannot convert to dewhitelisted tokens.
     */
    function test_convertBeanToDewhitelistedWell_fails(uint256 beanAmount) public {
        // Setup Bean deposits
        multipleBeanDepositSetup();
        beanAmount = bound(beanAmount, 1, 1000e6);

        // Set up conditions for bean to well conversion (above peg)
        setReserves(well, bean.balanceOf(well) - beanAmount, weth.balanceOf(well));

        // Dewhitelist the well AFTER bean deposits are made
        vm.prank(BEANSTALK);
        bs.dewhitelistToken(well);

        // Verify well is dewhitelisted
        assertTrue(bs.tokenSettings(well).selector == bytes4(0), "Well should be dewhitelisted");

        // Create encoding for Bean -> well convert
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            well, // dewhitelisted well
            1000e6, // amountIn
            0 // minOut
        );

        int96[] memory stems = new int96[](1);
        stems[0] = int96(0); // first deposit stem
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        // Convert should fail with appropriate error
        vm.expectRevert("Convert: Invalid Well");
        vm.prank(farmers[0]);
        convert.convert(convertData, stems, amounts);
    }

    function getConvertUpData(
        address well,
        uint256 lpToConvert
    )
        private
        view
        returns (bytes memory convertData, int96[] memory stems, uint256[] memory amounts)
    {
        convertData = convertEncoder(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            well, // well
            lpToConvert, // amountIn
            0 // minOut
        );
        stems = new int96[](1);
        stems[0] = int96(0);
        amounts = new uint256[](1);
        amounts[0] = lpToConvert;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    //////////// BATCH CONVERT ////////////

    /**
     * @notice Test multiConvert with multiple separate L2L converts.
     * @dev Tests [a],[b],[c] scenario - updating 3 independent deposits.
     */
    function test_multiConvert_multipleIndependentConverts() public {
        // Create 3 deposits at different stems
        bean.mint(farmers[0], 30000e6);

        vm.startPrank(farmers[0]);

        // First deposit
        int96 stem0 = bs.stemTipForToken(BEAN);
        bs.deposit(BEAN, 10000e6, 0);

        // Second deposit (advance season first)
        season.siloSunrise(0);
        int96 stem1 = bs.stemTipForToken(BEAN);
        bs.deposit(BEAN, 10000e6, 0);

        // Third deposit (advance season first)
        season.siloSunrise(0);
        int96 stem2 = bs.stemTipForToken(BEAN);
        bs.deposit(BEAN, 10000e6, 0);

        vm.stopPrank();
        passGermination();

        uint256 numConverts = 3;
        IMockFBeanstalk.ConvertParams[] memory converts = new IMockFBeanstalk.ConvertParams[](
            numConverts
        );

        uint256[] memory convertAmounts = new uint256[](numConverts);
        convertAmounts[0] = 3000e6;
        convertAmounts[1] = 4000e6;
        convertAmounts[2] = 2000e6;

        {
            // First convert: Update first deposit
            int96[] memory stems1 = new int96[](1);
            stems1[0] = stem0;
            uint256[] memory amounts1 = new uint256[](1);
            amounts1[0] = convertAmounts[0];

            converts[0] = IMockFBeanstalk.ConvertParams({
                convertData: convertEncoder(
                    LibConvertData.ConvertKind.LAMBDA_LAMBDA,
                    BEAN,
                    convertAmounts[0],
                    0
                ),
                stems: stems1,
                amounts: amounts1,
                grownStalkSlippage: 0
            });
        }

        {
            // Second convert: Update second deposit
            int96[] memory stems2 = new int96[](1);
            stems2[0] = stem1; // Second deposit stem
            uint256[] memory amounts2 = new uint256[](1);
            amounts2[0] = convertAmounts[1];

            converts[1] = IMockFBeanstalk.ConvertParams({
                convertData: convertEncoder(
                    LibConvertData.ConvertKind.LAMBDA_LAMBDA,
                    BEAN,
                    convertAmounts[1],
                    0
                ),
                stems: stems2,
                amounts: amounts2,
                grownStalkSlippage: 0
            });
        }

        {
            // Third convert: Update third deposit
            int96[] memory stems3 = new int96[](1);
            stems3[0] = stem2; // Third deposit stem
            uint256[] memory amounts3 = new uint256[](1);
            amounts3[0] = convertAmounts[2];

            converts[2] = IMockFBeanstalk.ConvertParams({
                convertData: convertEncoder(
                    LibConvertData.ConvertKind.LAMBDA_LAMBDA,
                    BEAN,
                    convertAmounts[2],
                    0
                ),
                stems: stems3,
                amounts: amounts3,
                grownStalkSlippage: 0
            });
        }

        // Expect Convert events for each convert operation
        for (uint256 i = 0; i < numConverts; i++) {
            vm.expectEmit(true, true, true, true);
            emit Convert(
                farmers[0],
                BEAN,
                BEAN,
                convertAmounts[i],
                convertAmounts[i],
                convertAmounts[i], // bdv equals amount for Bean
                convertAmounts[i]
            );
        }

        // Execute multiConvert
        vm.prank(farmers[0]);
        IMockFBeanstalk.ConvertOutput[] memory outputs = convertBatch.multiConvert(converts);

        int96 toStem = outputs[outputs.length - 1].toStem;
        uint256 fromAmount;
        uint256 toAmount;
        for (uint256 i; i < outputs.length; ++i) {
            fromAmount += outputs[i].fromAmount;
            toAmount += outputs[i].toAmount;
        }

        // Calculate expected totals dynamically
        uint256 expectedTotal = 0;
        for (uint256 i = 0; i < convertAmounts.length; i++) {
            expectedTotal += convertAmounts[i];
        }

        // Verify aggregated results
        assertEq(fromAmount, expectedTotal, "Total fromAmount should match sum");
        assertEq(toAmount, expectedTotal, "Total toAmount should match sum");
        assertEq(toStem, stem2, "Last convert's toStem");
    }

    /**
     * @notice Test multiConvert combining different groupings of deposits.
     * @dev Tests [a,b,c], [e,f], [g] scenario - combining 3, 2, and 1 deposits respectively.
     */
    function test_multiConvert_combineGroupings() public {
        // Setup: Create 7 deposits (a,b,c,d,e,f,g) at different stems
        // We'll use deposits a,b,c,e,f,g (skipping d for the test)
        uint256 numDeposits = 7;
        bean.mint(farmers[0], numDeposits * 10000e6);

        // Create deposits across different seasons and track their stems
        int96[] memory allStems = new int96[](numDeposits);
        vm.startPrank(farmers[0]);
        for (uint i = 0; i < allStems.length; i++) {
            // Get current stem before deposit
            allStems[i] = bs.stemTipForToken(BEAN);
            bs.deposit(BEAN, 10000e6, 0);
            if (i < allStems.length - 1) season.siloSunrise(0); // Move to next season
        }
        vm.stopPrank();
        passGermination();

        // Create 3 converts: [a,b,c], [e,f], [g]
        uint256 numConverts = 3;
        IMockFBeanstalk.ConvertParams[] memory converts = new IMockFBeanstalk.ConvertParams[](
            numConverts
        );

        uint256 total1 = 30000e6;
        uint256 total2 = 20000e6;
        uint256 total3 = 10000e6;

        {
            // Convert 1: Combine deposits a,b,c (3 deposits)
            int96[] memory stems1 = new int96[](3);
            stems1[0] = allStems[0]; // Deposit a
            stems1[1] = allStems[1]; // Deposit b
            stems1[2] = allStems[2]; // Deposit c
            uint256[] memory amounts1 = new uint256[](3);
            amounts1[0] = 10000e6;
            amounts1[1] = 10000e6;
            amounts1[2] = 10000e6;

            converts[0] = IMockFBeanstalk.ConvertParams({
                convertData: convertEncoder(
                    LibConvertData.ConvertKind.LAMBDA_LAMBDA,
                    BEAN,
                    total1,
                    0
                ),
                stems: stems1,
                amounts: amounts1,
                grownStalkSlippage: 0
            });
        }

        {
            // Convert 2: Combine deposits e,f (2 deposits)
            int96[] memory stems2 = new int96[](2);
            stems2[0] = allStems[4]; // Deposit e (skipping d at index 3)
            stems2[1] = allStems[5]; // Deposit f
            uint256[] memory amounts2 = new uint256[](2);
            amounts2[0] = 10000e6;
            amounts2[1] = 10000e6;

            converts[1] = IMockFBeanstalk.ConvertParams({
                convertData: convertEncoder(
                    LibConvertData.ConvertKind.LAMBDA_LAMBDA,
                    BEAN,
                    total2,
                    0
                ),
                stems: stems2,
                amounts: amounts2,
                grownStalkSlippage: 0
            });
        }

        {
            // Convert 3: Single deposit g (1 deposit)
            int96[] memory stems3 = new int96[](1);
            stems3[0] = allStems[6]; // Deposit g
            uint256[] memory amounts3 = new uint256[](1);
            amounts3[0] = 10000e6;

            converts[2] = IMockFBeanstalk.ConvertParams({
                convertData: convertEncoder(
                    LibConvertData.ConvertKind.LAMBDA_LAMBDA,
                    BEAN,
                    total3,
                    0
                ),
                stems: stems3,
                amounts: amounts3,
                grownStalkSlippage: 0
            });
        }

        // Cache expected toStem to avoid stack too deep
        int96 expectedToStem = allStems[6];

        // Expect Convert events for each convert group
        vm.expectEmit(true, true, true, true);
        emit Convert(farmers[0], BEAN, BEAN, total1, total1, total1, total1);

        vm.expectEmit(true, true, true, true);
        emit Convert(farmers[0], BEAN, BEAN, total2, total2, total2, total2);

        vm.expectEmit(true, true, true, true);
        emit Convert(farmers[0], BEAN, BEAN, total3, total3, total3, total3);

        // Execute multiConvert
        vm.prank(farmers[0]);
        IMockFBeanstalk.ConvertOutput[] memory outputs = convertBatch.multiConvert(converts);

        int96 toStem = outputs[outputs.length - 1].toStem;
        uint256 fromAmount;
        uint256 toAmount;
        for (uint256 i; i < outputs.length; ++i) {
            fromAmount += outputs[i].fromAmount;
            toAmount += outputs[i].toAmount;
        }

        // Verify aggregated results (dynamic calculation)
        uint256 expectedTotal = total1 + total2 + total3;
        assertEq(fromAmount, expectedTotal, "Should process all deposits");
        assertEq(toAmount, expectedTotal, "Should create equivalent amount");
        // For L2L, the toStem is based on grown stalk, which for the last convert (deposit g)
        // will result in a stem based on that deposit's grown stalk
        assertEq(toStem, expectedToStem, "L2L should preserve stem based on grown stalk");
    }

    /**
     * @notice Test multiConvert with update PDV then combine pattern.
     * @dev Tests [a],[b],[c] then [a,b,c] - first update 3 deposits separately, then combine them.
     */
    function test_multiConvert_updateThenCombine() public {
        multipleBeanDepositSetup();

        // Add one more deposit for total of 3
        bean.mint(farmers[0], 10000e6);
        vm.prank(farmers[0]);
        bs.deposit(BEAN, 10000e6, 0);
        passGermination();

        // PHASE 1: Update each deposit separately [a],[b],[c]
        IMockFBeanstalk.ConvertParams[] memory updates = new IMockFBeanstalk.ConvertParams[](3);

        // Create arrays inline to reduce stack usage
        int96[] memory s1 = new int96[](1);
        s1[0] = 0;
        uint256[] memory a1 = new uint256[](1);
        a1[0] = 3000e6;

        updates[0] = IMockFBeanstalk.ConvertParams({
            convertData: convertEncoder(LibConvertData.ConvertKind.LAMBDA_LAMBDA, BEAN, 3000e6, 0),
            stems: s1,
            amounts: a1,
            grownStalkSlippage: 0
        });

        int96[] memory s2 = new int96[](1);
        s2[0] = 0;
        uint256[] memory a2 = new uint256[](1);
        a2[0] = 4000e6;

        updates[1] = IMockFBeanstalk.ConvertParams({
            convertData: convertEncoder(LibConvertData.ConvertKind.LAMBDA_LAMBDA, BEAN, 4000e6, 0),
            stems: s2,
            amounts: a2,
            grownStalkSlippage: 0
        });

        int96[] memory s3 = new int96[](1);
        s3[0] = 0;
        uint256[] memory a3 = new uint256[](1);
        a3[0] = 3000e6;

        updates[2] = IMockFBeanstalk.ConvertParams({
            convertData: convertEncoder(LibConvertData.ConvertKind.LAMBDA_LAMBDA, BEAN, 3000e6, 0),
            stems: s3,
            amounts: a3,
            grownStalkSlippage: 0
        });

        // Expect events for Phase 1 - each update emits a Convert event
        vm.expectEmit(true, true, true, true);
        emit Convert(farmers[0], BEAN, BEAN, 3000e6, 3000e6, 3000e6, 3000e6);

        vm.expectEmit(true, true, true, true);
        emit Convert(farmers[0], BEAN, BEAN, 4000e6, 4000e6, 4000e6, 4000e6);

        vm.expectEmit(true, true, true, true);
        emit Convert(farmers[0], BEAN, BEAN, 3000e6, 3000e6, 3000e6, 3000e6);

        // Execute first multiConvert - update separately
        vm.prank(farmers[0]);
        IMockFBeanstalk.ConvertOutput[] memory outputs1 = convertBatch.multiConvert(updates);
        uint256 amt1;
        for (uint256 i; i < outputs1.length; ++i) {
            amt1 += outputs1[i].fromAmount;
        }

        assertEq(amt1, 10000e6, "Phase 1: Should update all deposits");

        // PHASE 2: Combine all updated deposits [a,b,c]
        IMockFBeanstalk.ConvertParams[] memory combines = new IMockFBeanstalk.ConvertParams[](1);

        int96[] memory cs = new int96[](3);
        cs[0] = 0;
        cs[1] = 0;
        cs[2] = 0;

        uint256[] memory ca = new uint256[](3);
        ca[0] = 3000e6;
        ca[1] = 4000e6;
        ca[2] = 3000e6;

        combines[0] = IMockFBeanstalk.ConvertParams({
            convertData: convertEncoder(LibConvertData.ConvertKind.LAMBDA_LAMBDA, BEAN, 10000e6, 0),
            stems: cs,
            amounts: ca,
            grownStalkSlippage: 0
        });

        // Expect event for Phase 2 - combine emits a single Convert event
        vm.expectEmit(true, true, true, true);
        emit Convert(farmers[0], BEAN, BEAN, 10000e6, 10000e6, 10000e6, 10000e6);

        // Execute second multiConvert - combine
        vm.prank(farmers[0]);
        IMockFBeanstalk.ConvertOutput[] memory outputs2 = convertBatch.multiConvert(combines);
        int96 stem2 = outputs2[0].toStem;
        uint256 amt2 = outputs2[0].fromAmount;

        assertEq(amt2, 10000e6, "Phase 2: Should combine all deposits");
        assertEq(stem2, 0, "Phase 2: Should maintain stem");
    }

    /**
     * @notice Test multiConvert with single convert (edge case).
     */
    function test_multiConvert_singleConvert() public {
        multipleBeanDepositSetup();

        // Create single convert in batch
        IMockFBeanstalk.ConvertParams[] memory converts = new IMockFBeanstalk.ConvertParams[](1);

        int96[] memory stems1 = new int96[](1);
        stems1[0] = int96(0);
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 10000e6;

        converts[0] = IMockFBeanstalk.ConvertParams({
            convertData: convertEncoder(LibConvertData.ConvertKind.LAMBDA_LAMBDA, BEAN, 10000e6, 0),
            stems: stems1,
            amounts: amounts1,
            grownStalkSlippage: 0
        });

        // Execute multiConvert with single convert
        vm.prank(farmers[0]);
        IMockFBeanstalk.ConvertOutput[] memory outputs = convertBatch.multiConvert(converts);
        int96 toStem = outputs[0].toStem;
        uint256 fromAmount = outputs[0].fromAmount;
        uint256 toAmount = outputs[0].toAmount;

        // Verify results
        assertEq(fromAmount, 10000e6, "Should convert single deposit");
        assertEq(toAmount, 10000e6, "Should create single deposit");
        // L2L convert keeps same stem (stem 0), so toStem should be 0
        assertEq(toStem, 0, "L2L should keep same stem");
    }

    /**
     * @notice Test that empty converts array reverts.
     */
    function test_multiConvert_emptyArray_reverts() public {
        IMockFBeanstalk.ConvertParams[] memory converts = new IMockFBeanstalk.ConvertParams[](0);

        vm.prank(farmers[0]);
        vm.expectRevert("ConvertBatch: Empty converts array");
        convertBatch.multiConvert(converts);
    }

    /**
     * @notice Test all-or-nothing behavior - if one convert fails, entire batch reverts.
     */
    function test_multiConvert_allOrNothing() public {
        multipleBeanDepositSetup();

        IMockFBeanstalk.ConvertParams[] memory converts = new IMockFBeanstalk.ConvertParams[](2);

        // First convert: Valid
        int96[] memory stems1 = new int96[](1);
        stems1[0] = int96(0);
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 10000e6;

        converts[0] = IMockFBeanstalk.ConvertParams({
            convertData: convertEncoder(LibConvertData.ConvertKind.LAMBDA_LAMBDA, BEAN, 10000e6, 0),
            stems: stems1,
            amounts: amounts1,
            grownStalkSlippage: 0
        });

        // Second convert: Invalid (trying to convert more than available)
        int96[] memory stems2 = new int96[](1);
        stems2[0] = bs.stemTipForToken(BEAN);
        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = 50000e6; // More than available!

        converts[1] = IMockFBeanstalk.ConvertParams({
            convertData: convertEncoder(LibConvertData.ConvertKind.LAMBDA_LAMBDA, BEAN, 50000e6, 0),
            stems: stems2,
            amounts: amounts2,
            grownStalkSlippage: 0
        });

        // Should revert because second convert is invalid
        vm.prank(farmers[0]);
        vm.expectRevert(); // Will revert with insufficient balance or similar
        convertBatch.multiConvert(converts);
    }

    //////////// AL2L RESTRICTION TESTS ////////////

    /**
     * @notice Test AL2L (Anti-Lambda-Lambda) can update a single deposit.
     * @dev This tests requirement #4 part 1: AL2L CAN do (1) - update single deposit [a].
     */
    function test_multiConvert_AL2L_singleDeposit() public {
        multipleBeanDepositSetup();

        // Create single AL2L convert
        IMockFBeanstalk.ConvertParams[] memory converts = new IMockFBeanstalk.ConvertParams[](1);

        int96[] memory stems1 = new int96[](1);
        stems1[0] = int96(0);
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 5000e6; // Convert half of first deposit

        // AL2L encoding: (kind, amount, token, account)
        bytes memory al2lData = abi.encode(
            LibConvertData.ConvertKind.ANTI_LAMBDA_LAMBDA,
            5000e6,
            BEAN,
            farmers[0]
        );

        converts[0] = IMockFBeanstalk.ConvertParams({
            convertData: al2lData,
            stems: stems1,
            amounts: amounts1,
            grownStalkSlippage: 0
        });

        // Expect Convert event for AL2L
        vm.expectEmit(true, true, true, true);
        emit Convert(farmers[0], BEAN, BEAN, 5000e6, 5000e6, 5000e6, 5000e6);

        // Should succeed - AL2L with single deposit is allowed
        vm.prank(farmers[0]);
        IMockFBeanstalk.ConvertOutput[] memory outputs = convertBatch.multiConvert(converts);
        int96 toStem = outputs[0].toStem;
        uint256 fromAmount = outputs[0].fromAmount;
        uint256 toAmount = outputs[0].toAmount;

        assertEq(fromAmount, 5000e6, "Should convert 5000 Beans");
        assertEq(toAmount, 5000e6, "Should output 5000 Beans");
        assertEq(toStem, 0, "AL2L should maintain stem");
    }

    /**
     * @notice Test AL2L can update multiple independent deposits in a batch.
     * @dev This tests that AL2L CAN do (1) multiple times [a],[b],[c].
     */
    function test_multiConvert_multiple_AL2L_succeeds() public {
        // Create deposits at different stems
        uint256 numDeposits = 3;
        uint256 depositAmount = 10000e6;
        bean.mint(farmers[0], numDeposits * depositAmount);

        // Create deposits and track stems
        int96[] memory stems = new int96[](numDeposits);
        vm.startPrank(farmers[0]);
        for (uint i = 0; i < numDeposits; i++) {
            stems[i] = bs.stemTipForToken(BEAN);
            bs.deposit(BEAN, depositAmount, 0);
            if (i < numDeposits - 1) season.siloSunrise(0);
        }
        vm.stopPrank();
        passGermination();

        // Try to create AL2L converts - one for each deposit
        IMockFBeanstalk.ConvertParams[] memory converts = new IMockFBeanstalk.ConvertParams[](
            numDeposits
        );

        uint256[] memory convertAmounts = new uint256[](numDeposits);
        convertAmounts[0] = 3000e6;
        convertAmounts[1] = 4000e6;
        convertAmounts[2] = 3000e6;

        // Create AL2L convert for each deposit
        for (uint i = 0; i < numDeposits; i++) {
            int96[] memory stemArray = new int96[](1);
            stemArray[0] = stems[i];
            uint256[] memory amountArray = new uint256[](1);
            amountArray[0] = convertAmounts[i];

            bytes memory al2lData = abi.encode(
                LibConvertData.ConvertKind.ANTI_LAMBDA_LAMBDA,
                convertAmounts[i],
                BEAN,
                farmers[0]
            );

            converts[i] = IMockFBeanstalk.ConvertParams({
                convertData: al2lData,
                stems: stemArray,
                amounts: amountArray,
                grownStalkSlippage: 0
            });
        }

        // Should succeed - AL2L can do multiple independent converts
        vm.prank(farmers[0]);
        convertBatch.multiConvert(converts);
    }

    /**
     * @notice Test AL2L cannot combine multiple deposits.
     * @dev This tests requirement #4 part 3: AL2L CANNOT do (2) and (3) - combine deposits [a,b,c].
     */
    function test_multiConvert_AL2L_combineDeposits_reverts() public {
        // Create deposits
        uint256 numDeposits = 3;
        uint256 depositAmount = 10000e6;
        bean.mint(farmers[0], numDeposits * depositAmount);

        // Create deposits and track stems
        int96[] memory depositStems = new int96[](numDeposits);
        vm.startPrank(farmers[0]);
        for (uint i = 0; i < numDeposits; i++) {
            depositStems[i] = bs.stemTipForToken(BEAN);
            bs.deposit(BEAN, depositAmount, 0);
            if (i < numDeposits - 1) season.siloSunrise(0);
        }
        vm.stopPrank();
        passGermination();

        // Try to create single AL2L convert that combines all deposits
        IMockFBeanstalk.ConvertParams[] memory converts = new IMockFBeanstalk.ConvertParams[](1);

        uint256[] memory amounts = new uint256[](numDeposits);
        uint256 totalAmount = 0;
        for (uint i = 0; i < numDeposits; i++) {
            amounts[i] = depositAmount;
            totalAmount += depositAmount;
        }

        bytes memory al2lData = abi.encode(
            LibConvertData.ConvertKind.ANTI_LAMBDA_LAMBDA,
            totalAmount,
            BEAN,
            farmers[0]
        );

        converts[0] = IMockFBeanstalk.ConvertParams({
            convertData: al2lData,
            stems: depositStems,
            amounts: amounts,
            grownStalkSlippage: 0
        });

        // Should revert - AL2L cannot combine multiple deposits
        vm.prank(farmers[0]);
        vm.expectRevert("Convert: DecreaseBDV only supports updating one deposit.");
        convertBatch.multiConvert(converts);
    }
}

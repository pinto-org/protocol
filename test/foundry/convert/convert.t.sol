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
import "forge-std/console.sol";

/**
 * @title ConvertTest
 * @notice Tests the `convert` functionality.
 * @dev `convert` is the ability for users to switch a deposits token
 * from one whitelisted silo token to another,
 * given valid conditions. Generally, the ability to convert is based on
 * peg maintainence. See {LibConvert} for more infomation on specific convert types.
 */
contract ConvertTest is TestHelper {
    event Convert(
        address indexed account,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount
    );

    event ConvertDownPenalty(address account, uint256 grownStalkLost, uint256 grownStalkKept);

    // Interfaces.
    MockConvertFacet convert = MockConvertFacet(BEANSTALK);
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
     * @dev if minOut is not contrained, the convert will succeed,
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

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        vm.expectEmit();
        emit Convert(farmers[0], BEAN, well, expectedBeansConverted, expectedAmtOut);
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
        emit Convert(farmers[0], BEAN, well, beansConverted, expectedAmtOut);
        vm.prank(farmers[0]);
        convert.convert(convertData, new int96[](1), amounts);

        int256 newDeltaB = bs.poolCurrentDeltaB(well);

        // verify deltaB.
        // assertEq(bs.getMaxAmountIn(BEAN, well), deltaB - beansConverted, 'BEAN -> WELL maxAmountIn should be deltaB - beansConverted');
    }

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
            (int96 toStem, , , , ) = convert.convert(convertData, stems, amounts);
            console.log("done?");

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

            vm.expectEmit();
            emit ConvertDownPenalty(
                farmers[0],
                grownStalkLost,
                grownStalkConverting - grownStalkLost
            );

            vm.prank(farmers[0]);
            (int96 toStem, , , , ) = convert.convert(convertData, stems, amounts);

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
        vm.expectEmit();
        emit ConvertDownPenalty(farmers[0], 0, 40000010000000);
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
        vm.expectEmit(false, false, false, false);
        emit ConvertDownPenalty(farmers[0], 0, 40000010000000); // Do not check value match.
        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convert(convertData, stems, amounts);

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

        vm.expectEmit();
        emit ConvertDownPenalty(farmers[0], 0, 58200000000000000); // No penalty when Q < P.

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
            (int96 toStem, , , uint256 fromBdv, ) = convert.convert(convertData, stems, amounts);

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
                "Grown stalk per pdv should increase"
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

        vm.expectEmit();
        emit Convert(farmers[0], BEAN, well, beansConverted, expectedAmtOut);
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

        vm.expectEmit();
        emit Convert(farmers[0], well, BEAN, maxLPin, beansAddedToWell);
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

        vm.expectEmit();
        emit Convert(farmers[0], well, BEAN, lpConverted, expectedAmtOut);
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

        deltaB = bound(deltaB, 1e6, 1000 ether);
        setReserves(well, bean.balanceOf(well) + deltaB, weth.balanceOf(well));
        uint256 initalWellBeanBalance = bean.balanceOf(well);
        uint256 initalLPbalance = MockToken(well).totalSupply();
        uint256 initalBeanBalance = bean.balanceOf(BEANSTALK);

        uint256 maxLpIn = bs.getMaxAmountIn(well, BEAN);
        lpConverted = bound(lpConverted, minLp, lpMinted);

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

        int96[] memory stems = new int96[](2);
        stems[0] = int96(0);
        stems[1] = int96(4e6); // 1 season of seeds for bean-eth.
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = lpConverted / 2;
        amounts[1] = lpConverted - amounts[0];

        vm.expectEmit();
        emit Convert(farmers[0], well, BEAN, lpConverted, expectedAmtOut);
        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convert(convertData, stems, amounts);

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
        // stack too deep.
        {
            int96 germinatingStem = bs.getGerminatingStem(address(bean));
            assertLt(toStem, germinatingStem, "toStem should be less than germinatingStem");
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
     * @notice lamda_lamda convert increases BDV.
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

        // create lamda_lamda encoding.
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
        vm.expectEmit();
        emit Convert(farmers[0], well, well, initalAmount, initalAmount);
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
     * @notice lamda_lamda convert does not decrease BDV.
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

        // create lamda_lamda encoding.
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
        vm.expectEmit();
        emit Convert(farmers[0], well, well, initalAmount, initalAmount);
        vm.prank(farmers[0]);
        (int96 toStem, , , , ) = convert.convert(convertData, stems, amounts);

        (uint256 updatedAmount, uint256 updatedBdv) = bs.getDeposit(farmers[0], well, toStem);
        assertEq(toStem, int96(0), "stems should be equal");
        assertEq(updatedAmount, initalAmount, "amounts should be equal");
        assertEq(updatedBdv, initialBdv, "bdv should be equal");
    }

    /**
     * @notice lamda_lamda convert combines deposits.
     */
    function test_lamdaLamda_combineDeposits(uint256 lpCombined) public {
        uint256 lpMinted = multipleWellDepositSetup();
        lpCombined = bound(lpCombined, 2, lpMinted);

        // create lamda_lamda encoding.
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
        vm.expectEmit();
        emit Convert(farmers[0], well, well, lpCombined, lpCombined);
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
        vm.expectEmit();
        emit Convert(farmers[0], BEAN, well, beansConverted, expectedAmtOut);
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

        vm.expectEmit();
        emit Convert(farmers[0], well, BEAN, lpConverted, expectedAmtOut);

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
    //     emit Convert(farmers[0], well, BEAN, lpConverted, expectedAmtOut);
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
}

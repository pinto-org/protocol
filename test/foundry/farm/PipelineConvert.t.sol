// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {MockPump} from "contracts/mocks/well/MockPump.sol";
import {IWell, Call} from "contracts/interfaces/basin/IWell.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibConvert} from "contracts/libraries/Convert/LibConvert.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibDeltaB} from "contracts/libraries/Oracle/LibDeltaB.sol";
import {MockPipelineConvertFacet, AdvancedPipeCall} from "contracts/mocks/mockFacets/MockPipelineConvertFacet.sol";
import "forge-std/Test.sol";

contract MiscHelperContract {
    function returnLesser(uint256 a, uint256 b) public pure returns (uint256) {
        if (a < b) {
            return a;
        } else {
            return b;
        }
    }
}

/**
 * @title PipelineConvertTest
 * @notice Test pipeline convert.
 */
contract PipelineConvertTest is TestHelper {
    using LibRedundantMath256 for uint256;

    // Interfaces.
    MockPipelineConvertFacet pipelineConvert = MockPipelineConvertFacet(BEANSTALK);
    address beanEthWell = BEAN_ETH_WELL;
    address beanwstethWell = BEAN_WSTETH_WELL;
    MiscHelperContract miscHelper = new MiscHelperContract();

    // test accounts
    address[] farmers;

    uint256 constant MAX_UINT256 = type(uint256).max;
    uint256 constant BDV_TO_STALK = 1e10;
    address constant EXTRACT_VALUE_ADDRESS = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;

    bytes constant noData = abi.encode(0);

    struct PipelineTestData {
        address inputWell;
        address outputWell;
        uint256 wellAmountOut;
        uint256 grownStalkForDeposit;
        uint256 bdvOfAmountOut;
        int96 outputStem;
        address inputWellEthToken;
        address outputWellEthToken;
        int256 inputWellNewDeltaB;
        uint256 beansOut;
        int256 outputWellNewDeltaB;
        uint256 lpOut;
        uint256 beforeInputTokenLPSupply;
        uint256 afterInputTokenLPSupply;
        uint256 beforeOutputTokenLPSupply;
        uint256 afterOutputTokenLPSupply;
        uint256 beforeInputWellCapacity;
        uint256 beforeOutputWellCapacity;
        uint256 beforeOverallCapacity;
        uint256 newBdv;
        int96 stem;
        uint256 amountOfDepositedLP;
    }

    struct BeanToBeanTestData {
        uint256 lpAmountBefore;
        int256 calculatedDeltaBAfter;
        uint256 lpAmountOut;
        uint256 lpAmountAfter;
        uint256 bdvOfDepositedLp;
        uint256 calculatedStalkPenalty;
        int96 calculatedStem;
        uint256 grownStalkForDeposit;
    }

    // Event defs

    event Convert(
        address indexed account,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount
    );

    event RemoveDeposits(
        address indexed account,
        address indexed token,
        int96[] stems,
        uint256[] amounts,
        uint256 amount,
        uint256[] bdvs
    );

    event AddDeposit(
        address indexed account,
        address indexed token,
        int96 stem,
        uint256 amount,
        uint256 bdv
    );

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // initalize farmers.
        farmers.push(users[1]);
        farmers.push(users[2]);

        // add initial liquidity to bean eth well:
        // prank beanstalk deployer (can be anyone)
        vm.prank(users[0]);
        addLiquidityToWell(
            beanEthWell,
            10_000e6, // 10,000 bean,
            10 ether // 10 WETH
        );

        addLiquidityToWell(
            beanwstethWell,
            10_000e6, // 10,000 bean,
            10 ether // 10 WETH of wstETH
        );

        // mint 1000 beans to farmers (user 0 is the beanstalk deployer).
        mintTokensToUsers(farmers, BEAN, MAX_DEPOSIT_BOUND);

        deployExtraWells(true, true);

        addLiquidityToWell(
            BEAN_USDC_WELL,
            10_000e6, // 10,000 Beans
            10_000e6 // 10,000 USDC
        );

        addLiquidityToWell(
            BEAN_USDT_WELL,
            10_000e6, // 10,000 Beans
            10_000e6 // 10,000 USDT
        );
    }

    //////////// CONVERTS ////////////

    function testBasicConvertBeanToLP(uint256 amount) public {
        vm.pauseGasMetering();
        int96 stem;

        amount = bound(amount, 10e6, 5000e6);

        // manipulate well so we won't have a penalty applied
        setDeltaBforWell(int256(amount), beanEthWell, WETH);

        depositBeanAndPassGermination(amount, users[1]);

        // do the convert

        // Create arrays for stem and amount
        int96[] memory stems = new int96[](1);
        stems[0] = stem;

        AdvancedPipeCall[] memory beanToLPPipeCalls = createBeanToLPPipeCalls(
            amount,
            new AdvancedPipeCall[](0)
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // get well amount out if we deposit amount of beans
        uint256 wellAmountOut = getWellAmountOutForAddingBeans(amount);

        uint256 grownStalkForDeposit = bs.grownStalkForDeposit(users[1], BEAN, stem);

        uint256 newBdv = bs.bdv(beanEthWell, wellAmountOut);

        uint256 bdvOfAmountOut = bs.bdv(beanEthWell, wellAmountOut);
        (int96 outputStem, ) = bs.calculateStemForTokenFromGrownStalk(
            beanEthWell,
            (grownStalkForDeposit * newBdv) / amount, // amount is the same as the original BDV
            bdvOfAmountOut
        );

        vm.expectEmit(true, false, false, true);
        emit RemoveDeposits(users[1], BEAN, stems, amounts, amount, amounts);

        vm.expectEmit(true, false, false, true);
        emit AddDeposit(users[1], beanEthWell, outputStem, wellAmountOut, bdvOfAmountOut);

        // verify convert
        vm.expectEmit(true, false, false, true);
        emit Convert(users[1], BEAN, beanEthWell, amount, wellAmountOut);

        vm.resumeGasMetering();
        vm.prank(users[1]); // do this as user 1
        pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stems
            amounts, // amount
            beanEthWell, // token out
            beanToLPPipeCalls // pipeData
        );
    }

    function testBasicConvertLPToBean(uint256 amount) public {
        vm.pauseGasMetering();

        // well is initalized with 10000 beans. cap add liquidity
        // to reasonable amounts.
        amount = bound(amount, 1e6, 10000e6);

        (int96 stem, uint256 lpAmountOut) = depositLPAndPassGermination(amount, beanEthWell);

        // Create arrays for stem and amount. Tried just passing in [stem] and it's like nope.
        int96[] memory stems = new int96[](1);
        stems[0] = stem;

        AdvancedPipeCall[] memory beanToLPPipeCalls = createLPToBeanPipeCalls(lpAmountOut);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = lpAmountOut;

        // todo: add events verification

        vm.resumeGasMetering();
        vm.prank(users[1]); // do this as user 1
        pipelineConvert.pipelineConvert(
            beanEthWell, // input token
            stems, // stems
            amounts, // amount
            BEAN, // token out
            beanToLPPipeCalls // pipeData
        );
    }

    function testConvertLPToLP(uint256 amount, uint256 inputIndex, uint256 outputIndex) public {
        vm.pauseGasMetering();

        // well is initalized with 10000 beans. cap add liquidity
        // to reasonable amounts.
        amount = bound(amount, 10e6, 5000e6);

        inputIndex = bound(inputIndex, 0, 1); // update to 0-3 when more wells supported/whitelisted
        outputIndex = bound(outputIndex, 0, 1); // update to 0-3 when more wells supported/whitelisted

        if (inputIndex == outputIndex) {
            return; // skip converting between same wells for now, but could setup later
        }

        address[] memory convertWells = new address[](4);
        convertWells[0] = BEAN_ETH_WELL;
        convertWells[1] = BEAN_WSTETH_WELL;
        convertWells[2] = BEAN_USDC_WELL;
        convertWells[3] = BEAN_USDT_WELL;

        address[] memory convertTokens = new address[](4);
        convertTokens[0] = WETH;
        convertTokens[1] = WSTETH;
        convertTokens[2] = USDC;
        convertTokens[3] = USDT;

        PipelineTestData memory pd;
        pd.inputWell = convertWells[inputIndex];
        pd.outputWell = convertWells[outputIndex];

        pd.inputWellEthToken = convertTokens[inputIndex];
        pd.outputWellEthToken = convertTokens[outputIndex];

        // update pumps
        updateMockPumpUsingWellReserves(pd.inputWell);
        updateMockPumpUsingWellReserves(pd.outputWell);

        (pd.stem, pd.amountOfDepositedLP) = depositLPAndPassGermination(amount, pd.inputWell);

        // store convert capacities for later comparison
        pd.beforeInputWellCapacity = bs.getWellConvertCapacity(pd.inputWell);
        pd.beforeOutputWellCapacity = bs.getWellConvertCapacity(pd.outputWell);
        pd.beforeOverallCapacity = bs.getOverallConvertCapacity();

        uint256 bdvOfDepositedLp = bs.bdv(pd.inputWell, pd.amountOfDepositedLP);
        uint256[] memory bdvAmountsDeposited = new uint256[](1);
        bdvAmountsDeposited[0] = bdvOfDepositedLp;

        // modify deltaB's so that the user already owns LP token, and then perfectly even deltaB's are setup
        setDeltaBforWell(-int256(amount), pd.inputWell, pd.inputWellEthToken);
        // return;

        setDeltaBforWell(int256(amount), pd.outputWell, pd.outputWellEthToken);

        int96[] memory stems = new int96[](1);
        stems[0] = pd.stem;

        AdvancedPipeCall[] memory lpToLPPipeCalls = createLPToLPPipeCalls(
            pd.amountOfDepositedLP,
            pd.inputWell,
            pd.outputWell
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = pd.amountOfDepositedLP;

        pd.wellAmountOut = getWellAmountOutFromLPtoLP(
            pd.amountOfDepositedLP,
            pd.inputWell,
            pd.outputWell
        );

        pd.grownStalkForDeposit = bs.grownStalkForDeposit(users[1], pd.inputWell, pd.stem);
        pd.bdvOfAmountOut = bs.bdv(pd.outputWell, pd.wellAmountOut);

        // calculate new reserves for well using get swap out and manually figure out what deltaB would be
        (pd.inputWellNewDeltaB, pd.beansOut) = calculateDeltaBForWellAfterSwapFromLP(
            pd.amountOfDepositedLP,
            pd.inputWell
        );

        (pd.outputWellNewDeltaB, pd.lpOut) = calculateDeltaBForWellAfterAddingBean(
            pd.beansOut,
            pd.outputWell
        );

        pd.beforeInputTokenLPSupply = IERC20(pd.inputWell).totalSupply();
        pd.afterInputTokenLPSupply = pd.beforeInputTokenLPSupply.sub(pd.amountOfDepositedLP);
        pd.beforeOutputTokenLPSupply = IERC20(pd.outputWell).totalSupply();
        pd.afterOutputTokenLPSupply = pd.beforeOutputTokenLPSupply.add(pd.lpOut);

        IMockFBeanstalk.DeltaBStorage memory dbs;

        dbs.beforeInputTokenDeltaB = bs.poolCurrentDeltaB(pd.inputWell);

        dbs.afterInputTokenDeltaB = LibDeltaB.scaledDeltaB(
            pd.beforeInputTokenLPSupply,
            pd.afterInputTokenLPSupply,
            pd.inputWellNewDeltaB
        );
        dbs.beforeOutputTokenDeltaB = bs.poolCurrentDeltaB(pd.outputWell);

        dbs.afterOutputTokenDeltaB = LibDeltaB.scaledDeltaB(
            pd.beforeOutputTokenLPSupply,
            pd.afterOutputTokenLPSupply,
            pd.outputWellNewDeltaB
        );
        dbs.beforeOverallDeltaB = bs.overallCurrentDeltaB();
        dbs.afterOverallDeltaB = dbs.afterInputTokenDeltaB + dbs.afterOutputTokenDeltaB; // update and for scaled deltaB

        pd.newBdv = bs.bdv(pd.outputWell, pd.wellAmountOut);

        (uint256 stalkPenalty, , , ) = bs.calculateStalkPenalty(
            dbs,
            pd.newBdv,
            LibConvert.abs(bs.overallCappedDeltaB()), // overall convert capacity
            pd.inputWell,
            pd.outputWell
        );

        (pd.outputStem, ) = bs.calculateStemForTokenFromGrownStalk(
            pd.outputWell,
            (pd.grownStalkForDeposit * (pd.newBdv - stalkPenalty)) / pd.newBdv,
            pd.bdvOfAmountOut
        );

        vm.expectEmit(true, false, false, true);
        emit RemoveDeposits(
            users[1],
            pd.inputWell,
            stems,
            amounts,
            pd.amountOfDepositedLP,
            bdvAmountsDeposited
        );

        vm.expectEmit(true, false, false, true);
        emit AddDeposit(
            users[1],
            pd.outputWell,
            pd.outputStem,
            pd.wellAmountOut,
            pd.bdvOfAmountOut
        );

        // verify convert
        vm.expectEmit(true, false, false, true);
        emit Convert(
            users[1],
            pd.inputWell,
            pd.outputWell,
            pd.amountOfDepositedLP,
            pd.wellAmountOut
        );

        vm.resumeGasMetering();
        vm.prank(users[1]);

        pipelineConvert.pipelineConvert(
            pd.inputWell, // input token
            stems, // stems
            amounts, // amount
            pd.outputWell, // token out
            lpToLPPipeCalls // pipeData
        );

        // In this test overall convert capacity before and after should be 0.
        assertEq(bs.getOverallConvertCapacity(), 0);
        assertEq(pd.beforeOverallCapacity, 0);
        // Per-well capacities were used
        assertGt(bs.getWellConvertCapacity(pd.inputWell), pd.beforeInputWellCapacity);
        assertGt(bs.getWellConvertCapacity(pd.outputWell), pd.beforeOutputWellCapacity);
    }

    function testConvertDewhitelistedLPToLP(
        uint256 amount,
        uint256 inputIndex,
        uint256 outputIndex,
        uint256 dewhitelistTarget
    ) public {
        vm.pauseGasMetering();

        // well is initalized with 10000 beans. cap add liquidity
        // to reasonable amounts.
        amount = bound(amount, 10e6, 5000e6);

        inputIndex = bound(inputIndex, 0, 1); // update to 0-3 when more wells supported/whitelisted
        outputIndex = bound(outputIndex, 0, 1); // update to 0-3 when more wells supported/whitelisted
        dewhitelistTarget = bound(dewhitelistTarget, 0, 1); // 0 = dewhitelist input, 1 = dewhitelist output

        if (inputIndex == outputIndex) {
            return; // skip converting between same wells for now, but could setup later
        }

        address[] memory convertWells = new address[](4);
        convertWells[0] = BEAN_ETH_WELL;
        convertWells[1] = BEAN_WSTETH_WELL;
        convertWells[2] = BEAN_USDC_WELL;
        convertWells[3] = BEAN_USDT_WELL;

        address[] memory convertTokens = new address[](4);
        convertTokens[0] = WETH;
        convertTokens[1] = WSTETH;
        convertTokens[2] = USDC;
        convertTokens[3] = USDT;

        PipelineTestData memory pd;
        pd.inputWell = convertWells[inputIndex];
        pd.outputWell = convertWells[outputIndex];

        pd.inputWellEthToken = convertTokens[inputIndex];
        pd.outputWellEthToken = convertTokens[outputIndex];

        // update pumps
        updateMockPumpUsingWellReserves(pd.inputWell);
        updateMockPumpUsingWellReserves(pd.outputWell);

        (pd.stem, pd.amountOfDepositedLP) = depositLPAndPassGermination(amount, pd.inputWell);

        // modify deltaB's so that the user already owns LP token, and then perfectly even deltaB's are setup
        setDeltaBforWell(-int256(amount), pd.inputWell, pd.inputWellEthToken);
        setDeltaBforWell(int256(amount), pd.outputWell, pd.outputWellEthToken);

        // Dewhitelist the target well (input or output based on dewhitelistTarget)
        address wellToDewhitelist = dewhitelistTarget == 0 ? pd.inputWell : pd.outputWell;

        vm.prank(BEANSTALK);
        bs.dewhitelistToken(wellToDewhitelist);

        int96[] memory stems = new int96[](1);
        stems[0] = pd.stem;

        AdvancedPipeCall[] memory lpToLPPipeCalls = createLPToLPPipeCalls(
            pd.amountOfDepositedLP,
            pd.inputWell,
            pd.outputWell
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = pd.amountOfDepositedLP;

        vm.resumeGasMetering();

        if (dewhitelistTarget != 0) {
            // Output well is dewhitelisted - should revert when trying to convert from it
            vm.expectRevert("Convert: Output token must be Bean or a well");
        }
        // else

        vm.prank(users[1]);
        pipelineConvert.pipelineConvert(
            pd.inputWell, // input token
            stems, // stems
            amounts, // amount
            pd.outputWell, // token out
            lpToLPPipeCalls // pipeData
        );
    }

    function testBeanToLPUsingRemainingConvertCapacity(uint256 amount, uint256 tradeAmount) public {
        vm.pauseGasMetering();

        amount = bound(amount, 10e6, 5000e6);

        tradeAmount = bound(tradeAmount, 10e6, 5000e6);

        // apply a known deltaB to the well
        setDeltaBforWell(5000e6, beanEthWell, WETH);

        int96 stem = depositBeanAndPassGermination(amount, users[1]);
        int96 secondUserStem = depositBeanAndPassGermination(tradeAmount, users[2]);

        uint256 beforeCapacity = bs.getWellConvertCapacity(beanEthWell);

        // user[2] does convert
        beanToLPDoConvert(tradeAmount, secondUserStem, users[2]);

        // log convert capacity for well remaining after
        uint256 afterCapacity = bs.getWellConvertCapacity(beanEthWell);

        assertLt(afterCapacity, beforeCapacity);

        // do the convert

        // Create arrays for stem and amount
        int96[] memory stems = new int96[](1);
        stems[0] = stem;

        AdvancedPipeCall[] memory beanToLPPipeCalls = createBeanToLPPipeCallsUsingConvertCapacity(
            amount
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // get well amount out if we deposit amount of beans
        getWellAmountOutForAddingBeans(amount);

        vm.resumeGasMetering();
        vm.prank(users[1]); // do this as user 1
        pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stems
            amounts, // amount
            beanEthWell, // token out
            beanToLPPipeCalls // pipeData
        );
    }

    function testUpdatingOverallDeltaB(uint256 amount, uint256 wellIndex, uint256 both) public {
        amount = bound(amount, 1e6, 5000e6);
        wellIndex = bound(wellIndex, 0, 1);
        both = bound(both, 0, 1);

        address[] memory convertWells = new address[](2);
        convertWells[0] = BEAN_ETH_WELL;
        convertWells[1] = BEAN_WSTETH_WELL;

        int256 calculatedNewDeltaB;

        if (both == 0) {
            (calculatedNewDeltaB, ) = calculateDeltaBForWellAfterAddingBean(
                amount,
                convertWells[wellIndex]
            );
            depositLPAndPassGermination(amount, convertWells[wellIndex]);
        } else {
            (int256 firstWellDeltaB, ) = calculateDeltaBForWellAfterAddingBean(
                amount,
                convertWells[0]
            );
            (int256 secondWellDeltaB, ) = calculateDeltaBForWellAfterAddingBean(
                amount,
                convertWells[1]
            );
            calculatedNewDeltaB = firstWellDeltaB + secondWellDeltaB;

            depositLPAndPassGermination(amount, convertWells[0]);
            depositLPAndPassGermination(amount, convertWells[1]);
        }
        mineBlockAndUpdatePumps();

        int256 afterOverallDeltaB = bs.overallCurrentDeltaB();
        assertLt(afterOverallDeltaB, 0);

        assertEq(afterOverallDeltaB, calculatedNewDeltaB);
    }

    function testDeltaBChangeBeanToLP(uint256 amount) public {
        amount = bound(amount, 1e6, 5000e6);
        int256 beforeDeltaB = bs.poolCurrentDeltaB(beanEthWell);
        (int256 calculatedNewDeltaB, ) = calculateDeltaBForWellAfterAddingBean(amount, beanEthWell);

        doBasicBeanToLP(amount, users[1]);

        int256 afterDeltaB = bs.poolCurrentDeltaB(beanEthWell);
        assertTrue(afterDeltaB < beforeDeltaB);
        assertEq(afterDeltaB, calculatedNewDeltaB);
    }

    function testTotalStalkAmountDidNotIncrease(uint256 amount) public {
        amount = bound(amount, 1e6, 5000e6);

        (uint256 beforeTotalStalk, , , ) = setupStalkTests(amount);

        uint256 afterTotalStalk = bs.totalStalk();
        assertLt(afterTotalStalk, beforeTotalStalk);
    }

    function testUserStalkAmountDidNotIncrease(uint256 amount) public {
        amount = bound(amount, 1e6, 5000e6);

        (, uint256 beforeUserStalk, , ) = setupStalkTests(amount);

        uint256 afterUserStalk = bs.balanceOfStalk(users[1]);
        assertLt(afterUserStalk, beforeUserStalk);
    }

    function testUserBDVDidNotIncrease(uint256 amount) public {
        amount = bound(amount, 1e6, 5000e6);

        (, , uint256 beforeUserDeposit, ) = setupStalkTests(amount);

        uint256 afterUserDeposit = bs.balanceOfDepositedBdv(users[1], BEAN);
        assertLt(afterUserDeposit, beforeUserDeposit);
    }

    function testConvertAgainstPegAndLoseStalk(uint256 amount) public {
        amount = bound(amount, 10e6, 5000e6);

        (, , , uint256 grownStalkBefore) = setupStalkTests(amount);

        uint256 grownStalkAfter = bs.balanceOfGrownStalk(users[1], beanEthWell);

        assertEq(grownStalkAfter, 0); // all grown stalk was lost
        assertGt(grownStalkBefore, 0);
    }

    function testConvertWithPegAndKeepStalk(uint256 amount) public {
        amount = bound(amount, 10e6, 100e6);

        setDeltaBforWell(int256(amount), beanEthWell, WETH);

        int96 stem = depositBeanAndPassGermination(amount, users[1]);

        // get bdv of amount
        (, uint256 oldBdv) = bs.getDeposit(users[1], BEAN, stem);

        uint256 grownStalkBefore = bs.balanceOfGrownStalk(users[1], BEAN);

        (uint256 downConvertPenaltyRatio, ) = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
            (uint256, uint256)
        );
        assertEq(downConvertPenaltyRatio, 0, "no penalty when P > Q");

        beanToLPDoConvert(amount, stem, users[1]);

        uint256 balanceOfStalk = bs.balanceOfStalk(users[1]);
        uint256 balanceOfGerminatingStalk = bs.balanceOfGerminatingStalk(users[1]);

        // get balance of deposited bdv for this user
        uint256 newBdv = bs.balanceOfDepositedBdv(users[1], beanEthWell); // convert to stalk amount

        // calculate grown stalk haircut as a result of fewer BDV deposited
        uint256 calculatedNewStalk = (newBdv * BDV_TO_STALK) +
            ((grownStalkBefore * newBdv) / oldBdv);

        assertEq(
            balanceOfStalk + balanceOfGerminatingStalk,
            calculatedNewStalk,
            "stalk beyond the convert down penalty was lost"
        );
    }

    function testConvertWithPegAndOnlyDownConvertStalkLoss(uint256 amount) public {
        amount = bound(amount, 10e6, 100e6);

        setDeltaBforWell(int256(amount), beanEthWell, WETH);

        int96 stem = depositBeanAndPassGermination(amount, users[1]);

        // get bdv of amount
        (, uint256 oldBdv) = bs.getDeposit(users[1], BEAN, stem);

        uint256 grownStalkBefore = bs.balanceOfGrownStalk(users[1], BEAN);

        (uint256 downConvertPenaltyRatio, ) = abi.decode(
            bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
            (uint256, uint256)
        );

        beanToLPDoConvert(amount, stem, users[1]);

        uint256 balanceOfStalk = bs.balanceOfStalk(users[1]);
        uint256 balanceOfGerminatingStalk = bs.balanceOfGerminatingStalk(users[1]);

        // get balance of deposited bdv for this user
        uint256 newBdv = bs.balanceOfDepositedBdv(users[1], beanEthWell); // convert to stalk amount

        // calculate grown stalk haircut as a result of fewer BDV deposited
        uint256 calculatedNewStalk = (newBdv * BDV_TO_STALK) +
            ((grownStalkBefore * newBdv * (1e18 - downConvertPenaltyRatio)) / oldBdv / 1e18);

        assertEq(
            balanceOfStalk + balanceOfGerminatingStalk,
            calculatedNewStalk,
            "stalk beyond the convert down penalty was lost"
        );
    }

    function testFlashloanManipulationLoseGrownStalkBecauseZeroConvertCapacity(
        uint256 amount,
        uint256 ethAmount
    ) public {
        amount = bound(amount, 10e6, 5000e6);

        // the main idea is that we start at deltaB of zero, so converts should not be possible
        // we add eth to the well to push it over peg, then we convert our beans back down to lp
        // then we pull our initial eth back out and we converted when we shouldn't have been able to (if we do in one tx)

        // setup initial bean deposit
        int96 stem = depositBeanAndPassGermination(amount, users[1]);

        // mint user eth
        ethAmount = bound(ethAmount, 10e18, 500e18);
        MockToken(WETH).mint(users[1], ethAmount);

        vm.prank(users[1]);
        MockToken(WETH).approve(beanEthWell, ethAmount);

        // add liquidity to well
        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = 0;
        tokenAmountsIn[1] = ethAmount;

        vm.prank(users[1]);
        IWell(beanEthWell).addLiquidity(tokenAmountsIn, 0, users[1], type(uint256).max);

        uint256 grownStalkBefore = bs.balanceOfGrownStalk(users[1], BEAN);

        // convert beans to lp
        beanToLPDoConvert(amount, stem, users[1]);

        // it should be that we lost our grown stalk from this convert

        uint256 grownStalkAfter = bs.balanceOfGrownStalk(users[1], beanEthWell);

        assertTrue(grownStalkAfter == 0); // all grown stalk was lost
        assertTrue(grownStalkBefore > 0);
    }

    /**
     * @notice the main idea is that we start some positive deltaB, so a limited amount of converts are possible (1.2 eth worth)
     * User One does a convert down, and that uses up convert power for this block
     * someone adds more eth to the well, which means we're back too far over peg
     * then User Two tries to do a convert down, but at that point the convert power has been used up, so they lose their grown stalk
     * double convert uses up convert power so we should be left at no grown stalk after second convert
     * (but still have grown stalk after first convert)
     */
    function testFlashloanManipulationLoseGrownStalkBecauseDoubleConvert(uint256 amount) public {
        amount = bound(amount, 1000e6, 5000e6); // todo: update for range

        // setup initial bean deposit
        int96 stem = depositBeanAndPassGermination(amount, users[1]);

        // then setup a convert from user 2
        int96 stem2 = depositBeanAndPassGermination(amount, users[2]);

        // if you deposited amount of beans into well, how many eth would you get?
        uint256 ethAmount = IWell(beanEthWell).getSwapOut(IERC20(BEAN), IERC20(WETH), amount);

        // Need a better way to calculate how much eth out there should be to make sure it can swap and be over peg
        ethAmount = ethAmount.mul(15000).div(10000);

        addEthToWell(users[1], ethAmount);

        // go to next block
        vm.roll(block.number + 1);

        uint256 grownStalkBefore = bs.balanceOfGrownStalk(users[2], BEAN);

        // update pump
        updateMockPumpUsingWellReserves(beanEthWell);

        uint256 convertCapacityStage1 = bs.getOverallConvertCapacity();

        // convert beans to lp
        beanToLPDoConvert(amount, stem, users[1]);

        uint256 convertCapacityStage2 = bs.getOverallConvertCapacity();
        assertLe(convertCapacityStage2, convertCapacityStage1);

        // add more eth to well again
        addEthToWell(users[1], ethAmount);

        beanToLPDoConvert(amount, stem2, users[2]);

        uint256 convertCapacityStage3 = bs.getOverallConvertCapacity();
        assertLe(convertCapacityStage3, convertCapacityStage2);

        assertEq(convertCapacityStage3, 0);

        uint256 grownStalkAfter = bs.balanceOfGrownStalk(users[2], beanEthWell);

        assertEq(grownStalkAfter, 0); // all grown stalk was lost because no convert power left
        assertGe(grownStalkBefore, 0);
    }

    function testConvertingOutputTokenNotWell() public {
        int96[] memory stems = new int96[](1);
        stems[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        vm.expectRevert("Convert: Output token must be Bean or a well");
        // convert non-whitelisted asset to lp
        vm.prank(users[1]);
        pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stem
            amounts, // amount
            USDC, // token out
            new AdvancedPipeCall[](0) // pipeData
        );
    }

    function testConvertingInputTokenNotWell() public {
        int96[] memory stems = new int96[](1);
        stems[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        vm.expectRevert("LibWhitelistedTokens: Token not found");
        // convert non-whitelisted asset to lp
        vm.prank(users[1]);
        pipelineConvert.pipelineConvert(
            USDC, // input token
            stems, // stem
            amounts, // amount
            BEAN, // token out
            new AdvancedPipeCall[](0) // pipeData
        );
    }

    function testBeanToBeanConvert(uint256 amount) public {
        amount = bound(amount, 1000e6, 1000e6);

        int96 stem = depositBeanAndPassGermination(amount, users[1]);
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        uint256 stalkBefore = bs.balanceOfStalk(users[1]);
        uint256 grownStalk = bs.grownStalkForDeposit(users[1], BEAN, stem);

        // make a pipeline call where the only thing it does is return how many beans are in pipeline
        bytes memory callEncoded = abi.encodeWithSelector(bean.balanceOf.selector, PIPELINE);
        AdvancedPipeCall[] memory extraPipeCalls = new AdvancedPipeCall[](1);
        extraPipeCalls[0] = AdvancedPipeCall(
            BEAN, // target
            callEncoded, // calldata
            abi.encode(0) // clipboard
        );

        vm.prank(users[1]);
        pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stem
            amounts, // amount
            BEAN, // token out
            extraPipeCalls
        );

        uint256 stalkAfter = bs.balanceOfStalk(users[1]);
        assertEq(stalkAfter, stalkBefore + grownStalk);
    }

    // half of the bdv is extracted during the convert, stalk/bdv of deposits should be correct on output
    function testBeanToBeanConvertLessBdv(uint256 amount) public {
        amount = bound(amount, 1000e6, 1000e6);

        int96 stem = depositBeanAndPassGermination(amount, users[1]);
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        uint256 stalkBefore = bs.balanceOfStalk(users[1]);
        uint256 grownStalk = bs.grownStalkForDeposit(users[1], BEAN, stem);
        uint256 bdvBefore = bs.balanceOfDepositedBdv(users[1], BEAN);

        // make a pipeline call where the only thing it does is return how many beans are in pipeline
        AdvancedPipeCall[] memory extraPipeCalls = new AdvancedPipeCall[](1);

        // send half our beans from pipeline to Vitalik address (for some reason zero address gave an evm error)
        bytes memory sendBeans = abi.encodeWithSelector(
            bean.transfer.selector,
            EXTRACT_VALUE_ADDRESS,
            amount.div(2)
        );
        extraPipeCalls[0] = AdvancedPipeCall(
            BEAN, // target
            sendBeans, // calldata
            abi.encode(0) // clipboard
        );

        vm.prank(users[1]);
        pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stem
            amounts, // amount
            BEAN, // token out
            extraPipeCalls
        );

        uint256 stalkAfter = bs.balanceOfStalk(users[1]);
        assertEq(stalkAfter, stalkBefore.div(2) + grownStalk.div(2));

        uint256 bdvAfter = bs.balanceOfDepositedBdv(users[1], BEAN);
        assertEq(bdvAfter, bdvBefore.div(2));
    }

    // adds 50% more beans to the pipeline so we get extra bdv after convert
    function testBeanToBeanConvertMoreBdv(uint256 amount) public {
        amount = bound(amount, 1000e6, 1000e6);

        // mint extra beans to pipeline so we can snatch them on convert back into beanstalk
        bean.mint(PIPELINE, amount.div(2));

        int96 stem = depositBeanAndPassGermination(amount, users[1]);
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        uint256 stalkBefore = bs.balanceOfStalk(users[1]);
        uint256 grownStalk = bs.grownStalkForDeposit(users[1], BEAN, stem);
        uint256 bdvBefore = bs.balanceOfDepositedBdv(users[1], BEAN);

        // make a pipeline call where the only thing it does is return how many beans are in pipeline
        AdvancedPipeCall[] memory extraPipeCalls = new AdvancedPipeCall[](1);

        bytes memory callEncoded = abi.encodeWithSelector(bean.balanceOf.selector, PIPELINE);
        extraPipeCalls[0] = AdvancedPipeCall(
            BEAN, // target
            callEncoded, // calldata
            abi.encode(0) // clipboard
        );

        vm.prank(users[1]);
        pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stem
            amounts, // amount
            BEAN, // token out
            extraPipeCalls
        );

        uint256 stalkAfter = bs.balanceOfStalk(users[1]);
        assertEq(stalkAfter, stalkBefore + stalkBefore.div(2) + grownStalk);

        uint256 bdvAfter = bs.balanceOfDepositedBdv(users[1], BEAN);
        assertEq(bdvAfter, bdvBefore + bdvBefore.div(2));
    }

    function testBeanToBeanConvertNoneLeftInPipeline(uint256 amount) public {
        amount = bound(amount, 1000e6, 1000e6);

        int96 stem = depositBeanAndPassGermination(amount, users[1]);
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        AdvancedPipeCall[] memory extraPipeCalls = new AdvancedPipeCall[](1);

        // send all our beans away
        bytes memory sendBeans = abi.encodeWithSelector(
            bean.transfer.selector,
            0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045,
            amount
        );
        extraPipeCalls[0] = AdvancedPipeCall(
            BEAN, // target
            sendBeans, // calldata
            abi.encode(0) // clipboard
        );

        vm.expectRevert("Convert: No output tokens left in pipeline");
        vm.prank(users[1]);
        pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stem
            amounts, // amount
            BEAN, // token out
            extraPipeCalls
        );
    }

    /**
     * @notice test bean to bean convert, but deltaB is affected against them and there is convert power left in the block
     *
     * */
    function testBeanToBeanConvertAffectDeltaB(uint256 amount) public {
        amount = bound(amount, 1000e6, 1000e6);

        int96 stem = depositBeanAndPassGermination(amount, users[1]);
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // mint a weth to pipeline for later use
        uint256 ethAmount = 1 ether;
        MockToken(WETH).mint(PIPELINE, ethAmount);

        addEthToWell(users[1], 1 ether);

        updateMockPumpUsingWellReserves(beanEthWell);

        // move foward 10 seasons so we have grown stalk
        season.siloSunrise(10);

        BeanToBeanTestData memory td;
        td.grownStalkForDeposit = bs.grownStalkForDeposit(users[1], BEAN, stem);

        // calculate what the stalk penalty would be
        IMockFBeanstalk.DeltaBStorage memory dbs;

        // dbs before/after input/output token deltaB should all be zero/unchanged (because bean<>bean convert)
        // however overall deltaB will be be affected by adding eth to the well, so total affect
        // on deltaB needs to be calculated

        // store total amount of bean:eth well LP token before convert
        td.lpAmountBefore = IERC20(beanEthWell).totalSupply();
        (td.calculatedDeltaBAfter, td.lpAmountOut) = calculateDeltaBForWellAfterAddingNonBean(
            ethAmount,
            beanEthWell
        );
        td.lpAmountAfter = td.lpAmountBefore.add(td.lpAmountOut);
        dbs.beforeOverallDeltaB = bs.overallCurrentDeltaB();
        // calculate scaled overall deltaB, based on just the well affected
        dbs.afterOverallDeltaB = LibDeltaB.scaledDeltaB(
            td.lpAmountBefore,
            td.lpAmountAfter,
            td.calculatedDeltaBAfter
        );
        td.bdvOfDepositedLp = bs.bdv(beanEthWell, td.lpAmountBefore);

        (td.calculatedStalkPenalty, , , ) = bs.calculateStalkPenalty(
            dbs,
            td.bdvOfDepositedLp,
            LibConvert.abs(bs.overallCappedDeltaB()), // overall convert capacity
            BEAN,
            BEAN
        );

        // using stalk penalty, calculate what the new stem should be
        (td.calculatedStem, ) = bs.calculateStemForTokenFromGrownStalk(
            BEAN,
            (td.grownStalkForDeposit * (amount - td.calculatedStalkPenalty)) / amount,
            amount
        );

        // make a pipeline call where the only thing it does is return how many beans are in pipeline
        AdvancedPipeCall[] memory extraPipeCalls = new AdvancedPipeCall[](2);

        bytes memory approveWell = abi.encodeWithSelector(
            IERC20.approve.selector,
            beanEthWell,
            ethAmount
        );
        extraPipeCalls[0] = AdvancedPipeCall(
            WETH, // target
            approveWell, // calldata
            abi.encode(0) // clipboard
        );

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = 0;
        tokenAmountsIn[1] = ethAmount;

        // add a weth to the well to affect deltaB
        bytes memory addWeth = abi.encodeWithSelector(
            IWell(beanEthWell).addLiquidity.selector,
            tokenAmountsIn,
            0,
            PIPELINE,
            type(uint256).max
        );
        extraPipeCalls[1] = AdvancedPipeCall(
            beanEthWell, // target
            addWeth, // calldata
            abi.encode(0) // clipboard
        );

        vm.prank(users[1]);
        (int96 outputStem, , , , ) = pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stem
            amounts, // amount
            BEAN, // token out
            extraPipeCalls
        );

        assertEq(td.calculatedStem, outputStem);
    }

    function testAmountAgainstPeg() public pure {
        uint256 amountAgainstPeg;

        (amountAgainstPeg) = LibConvert.calculateAgainstPeg(-500, -400);
        assertEq(amountAgainstPeg, 0);

        (amountAgainstPeg) = LibConvert.calculateAgainstPeg(-100, 0);
        assertEq(amountAgainstPeg, 0);

        (amountAgainstPeg) = LibConvert.calculateAgainstPeg(100, 0);
        assertEq(amountAgainstPeg, 0);

        (amountAgainstPeg) = LibConvert.calculateAgainstPeg(1, 101);
        assertEq(amountAgainstPeg, 100);

        (amountAgainstPeg) = LibConvert.calculateAgainstPeg(0, 100);
        assertEq(amountAgainstPeg, 100);

        (amountAgainstPeg) = LibConvert.calculateAgainstPeg(0, -100);
        assertEq(amountAgainstPeg, 100);
    }

    function testCalculateConvertedTowardsPeg() public pure {
        int256 beforeDeltaB = -100;
        int256 afterDeltaB = 0;
        uint256 amountInDirectionOfPeg = LibConvert.calculateTowardsPeg(beforeDeltaB, afterDeltaB);
        assertEq(amountInDirectionOfPeg, 100);

        beforeDeltaB = 100;
        afterDeltaB = 0;
        amountInDirectionOfPeg = LibConvert.calculateTowardsPeg(beforeDeltaB, afterDeltaB);
        assertEq(amountInDirectionOfPeg, 100);

        beforeDeltaB = -50;
        afterDeltaB = 50;
        amountInDirectionOfPeg = LibConvert.calculateTowardsPeg(beforeDeltaB, afterDeltaB);
        assertEq(amountInDirectionOfPeg, 50);

        beforeDeltaB = 50;
        afterDeltaB = -50;
        amountInDirectionOfPeg = LibConvert.calculateTowardsPeg(beforeDeltaB, afterDeltaB);
        assertEq(amountInDirectionOfPeg, 50);

        beforeDeltaB = 0;
        afterDeltaB = 100;
        amountInDirectionOfPeg = LibConvert.calculateTowardsPeg(beforeDeltaB, afterDeltaB);
        assertEq(amountInDirectionOfPeg, 0);

        beforeDeltaB = 0;
        afterDeltaB = -100;
        amountInDirectionOfPeg = LibConvert.calculateTowardsPeg(beforeDeltaB, afterDeltaB);
        assertEq(amountInDirectionOfPeg, 0);
    }

    function testCalculateStalkPenaltyUpwardsToZero(uint256 amount) public {
        amount = bound(amount, 1, 1e8);
        addEthToWell(users[1], 1 ether);
        // Update the pump so that eth added above is reflected.
        updateMockPumpUsingWellReserves(beanEthWell);

        IMockFBeanstalk.DeltaBStorage memory dbs;
        dbs.beforeOverallDeltaB = -int256(amount);
        dbs.afterOverallDeltaB = 0;
        dbs.beforeInputTokenDeltaB = -int256(amount);
        dbs.afterInputTokenDeltaB = 0;
        dbs.beforeOutputTokenDeltaB = 0;
        dbs.afterOutputTokenDeltaB = 0;
        uint256 bdvConverted = amount;
        uint256 overallConvertCapacity = amount;
        address inputToken = beanEthWell;
        address outputToken = BEAN;

        (uint256 penalty, , , ) = bs.calculateStalkPenalty(
            dbs,
            bdvConverted,
            overallConvertCapacity,
            inputToken,
            outputToken
        );
        assertEq(penalty, 0);
    }

    function testCalculateConvertCapacityPenalty(uint256 amount) public {
        amount = bound(amount, 1, 1e8);
        addEthToWell(users[1], 1 ether);
        // Update the pump so that eth added above is reflected.
        updateMockPumpUsingWellReserves(beanEthWell);

        uint256 overallCappedDeltaB = amount;
        uint256 overallAmountInDirectionOfPeg = amount;
        address inputToken = beanEthWell;
        uint256 inputTokenAmountInDirectionOfPeg = amount;
        address outputToken = BEAN;
        uint256 outputTokenAmountInDirectionOfPeg = amount;
        (uint256 penalty, ) = pipelineConvert.calculateConvertCapacityPenaltyE(
            overallCappedDeltaB,
            overallAmountInDirectionOfPeg,
            inputToken,
            inputTokenAmountInDirectionOfPeg,
            outputToken,
            outputTokenAmountInDirectionOfPeg
        );
        assertEq(penalty, 0);

        // test with zero capped deltaB
        overallCappedDeltaB = 0;
        overallAmountInDirectionOfPeg = amount;
        inputToken = beanEthWell;
        inputTokenAmountInDirectionOfPeg = amount;
        outputToken = BEAN;
        outputTokenAmountInDirectionOfPeg = amount;
        (penalty, ) = pipelineConvert.calculateConvertCapacityPenaltyE(
            overallCappedDeltaB,
            overallAmountInDirectionOfPeg,
            inputToken,
            inputTokenAmountInDirectionOfPeg,
            outputToken,
            outputTokenAmountInDirectionOfPeg
        );
        assertEq(penalty, amount);
    }

    function testCalculateConvertCapacityPenaltyZeroOverallAmountInDirectionOfPeg(
        uint256 amount
    ) public view {
        amount = bound(amount, 1, 1e8);
        // test with zero overall amount in direction of peg
        uint256 overallCappedDeltaB = amount;
        uint256 overallAmountInDirectionOfPeg = 0;
        address inputToken = beanEthWell;
        uint256 inputTokenAmountInDirectionOfPeg = 0;
        address outputToken = BEAN;
        uint256 outputTokenAmountInDirectionOfPeg = 0;
        (uint256 penalty, ) = pipelineConvert.calculateConvertCapacityPenaltyE(
            overallCappedDeltaB,
            overallAmountInDirectionOfPeg,
            inputToken,
            inputTokenAmountInDirectionOfPeg,
            outputToken,
            outputTokenAmountInDirectionOfPeg
        );
        assertEq(penalty, 0);
    }

    function testOnePositivePoolOneNegativeZeroOverallDeltaB(uint256 amount) public view {
        amount = bound(amount, 1, 1e8);
        uint256 overallCappedDeltaB = 0;
        uint256 overallAmountInDirectionOfPeg = 0;
        address inputToken = beanEthWell;
        uint256 inputTokenAmountInDirectionOfPeg = 0;
        address outputToken = BEAN;
        uint256 outputTokenAmountInDirectionOfPeg = 0;
        (uint256 penalty, ) = pipelineConvert.calculateConvertCapacityPenaltyE(
            overallCappedDeltaB,
            overallAmountInDirectionOfPeg,
            inputToken,
            inputTokenAmountInDirectionOfPeg,
            outputToken,
            outputTokenAmountInDirectionOfPeg
        );
        assertEq(penalty, 0);

        overallCappedDeltaB = 0;
        overallAmountInDirectionOfPeg = 0;
        inputToken = beanEthWell;
        inputTokenAmountInDirectionOfPeg = amount;
        outputToken = BEAN;
        outputTokenAmountInDirectionOfPeg = 0;
        (penalty, ) = pipelineConvert.calculateConvertCapacityPenaltyE(
            overallCappedDeltaB,
            overallAmountInDirectionOfPeg,
            inputToken,
            inputTokenAmountInDirectionOfPeg,
            outputToken,
            outputTokenAmountInDirectionOfPeg
        );
        assertEq(penalty, amount);
    }

    function testCalculateConvertCapacityPenaltyCapZeroInputToken(uint256 amount) public view {
        amount = bound(amount, 1, 1e8);
        // test with input token zero convert capacity
        uint256 overallCappedDeltaB = amount;
        uint256 overallAmountInDirectionOfPeg = amount;
        address inputToken = beanEthWell;
        uint256 inputTokenAmountInDirectionOfPeg = amount;
        address outputToken = BEAN;
        uint256 outputTokenAmountInDirectionOfPeg = 0;
        (uint256 penalty, ) = pipelineConvert.calculateConvertCapacityPenaltyE(
            overallCappedDeltaB,
            overallAmountInDirectionOfPeg,
            inputToken,
            inputTokenAmountInDirectionOfPeg,
            outputToken,
            outputTokenAmountInDirectionOfPeg
        );
        assertEq(penalty, amount);
    }

    function testCalculateConvertCapacityPenaltyCapZeroOutputToken(uint256 amount) public view {
        amount = bound(amount, 1, 1e8);
        // test with input token zero convert capacity
        uint256 overallCappedDeltaB = amount;
        uint256 overallAmountInDirectionOfPeg = amount;
        address inputToken = BEAN;
        uint256 inputTokenAmountInDirectionOfPeg = 0;
        address outputToken = beanEthWell;
        uint256 outputTokenAmountInDirectionOfPeg = amount;
        (uint256 penalty, ) = pipelineConvert.calculateConvertCapacityPenaltyE(
            overallCappedDeltaB,
            overallAmountInDirectionOfPeg,
            inputToken,
            inputTokenAmountInDirectionOfPeg,
            outputToken,
            outputTokenAmountInDirectionOfPeg
        );
        assertEq(penalty, amount);
    }

    function testCalculateStalkPenaltyUpwardsNonZero() public {
        addEthToWell(users[1], 1 ether);
        updateMockPumpUsingWellReserves(beanEthWell);

        IMockFBeanstalk.DeltaBStorage memory dbs;
        dbs.beforeOverallDeltaB = -200;
        dbs.afterOverallDeltaB = -100;
        dbs.beforeInputTokenDeltaB = -100;
        dbs.afterInputTokenDeltaB = 0;
        dbs.beforeOutputTokenDeltaB = 0;
        dbs.afterOutputTokenDeltaB = 0;

        uint256 bdvConverted = 100;
        uint256 overallCappedDeltaB = 100;
        address inputToken = beanEthWell;
        address outputToken = BEAN;

        (uint256 penalty, , , ) = bs.calculateStalkPenalty(
            dbs,
            bdvConverted,
            overallCappedDeltaB,
            inputToken,
            outputToken
        );
        assertEq(penalty, 0);
    }

    function testCalculateStalkPenaltyDownwardsToZero() public {
        addEthToWell(users[1], 1 ether);
        updateMockPumpUsingWellReserves(beanEthWell);

        IMockFBeanstalk.DeltaBStorage memory dbs;
        dbs.beforeOverallDeltaB = 100;
        dbs.afterOverallDeltaB = 0;
        dbs.beforeInputTokenDeltaB = -100;
        dbs.afterInputTokenDeltaB = 0;
        dbs.beforeOutputTokenDeltaB = 0;
        dbs.afterOutputTokenDeltaB = 0;

        uint256 bdvConverted = 100;
        uint256 overallCappedDeltaB = 100;
        address inputToken = beanEthWell;
        address outputToken = BEAN;

        (uint256 penalty, , , ) = bs.calculateStalkPenalty(
            dbs,
            bdvConverted,
            overallCappedDeltaB,
            inputToken,
            outputToken
        );
        assertEq(penalty, 0);
    }

    function testCalcStalkPenaltyUpToPeg() public {
        // make beanEthWell have negative deltaB so that it has convert capacity
        setDeltaBforWell(-1000e6, beanEthWell, WETH);
        (
            IMockFBeanstalk.DeltaBStorage memory dbs,
            address inputToken,
            address outputToken,
            uint256 bdvConverted,
            uint256 overallConvertCapacity
        ) = setupTowardsPegDeltaBStorageNegative();

        (uint256 stalkPenaltyBdv, , , ) = bs.calculateStalkPenalty(
            dbs,
            bdvConverted,
            overallConvertCapacity,
            inputToken,
            outputToken
        );
        assertEq(stalkPenaltyBdv, 0);
    }

    function testCalcStalkPenaltyDownToPeg() public {
        // make beanEthWell have positive deltaB so that it has convert capacity
        setDeltaBforWell(1000e6, beanEthWell, WETH);

        (
            IMockFBeanstalk.DeltaBStorage memory dbs,
            address inputToken,
            address outputToken,
            uint256 bdvConverted,
            uint256 overallConvertCapacity
        ) = setupTowardsPegDeltaBStorageNegative();

        dbs.beforeInputTokenDeltaB = 100;
        dbs.beforeOutputTokenDeltaB = 100;

        console.log("doing calculateStalkPenalty: ", bdvConverted);

        (uint256 stalkPenaltyBdv, , , ) = bs.calculateStalkPenalty(
            dbs,
            bdvConverted,
            overallConvertCapacity,
            inputToken,
            outputToken
        );
        assertEq(stalkPenaltyBdv, 0);
    }

    function testCalcStalkPenaltyNoOverallCap() public view {
        (
            IMockFBeanstalk.DeltaBStorage memory dbs,
            address inputToken,
            address outputToken,
            uint256 bdvConverted,
            uint256 overallConvertCapacity
        ) = setupTowardsPegDeltaBStorageNegative();

        overallConvertCapacity = 0;
        dbs.beforeOverallDeltaB = -100;

        (uint256 stalkPenaltyBdv, , , ) = bs.calculateStalkPenalty(
            dbs,
            bdvConverted,
            overallConvertCapacity,
            inputToken,
            outputToken
        );
        assertEq(stalkPenaltyBdv, 100);
    }

    function testCalcStalkPenaltyNoInputTokenCap() public view {
        (
            IMockFBeanstalk.DeltaBStorage memory dbs,
            address inputToken,
            address outputToken,
            uint256 bdvConverted,
            uint256 overallConvertCapacity
        ) = setupTowardsPegDeltaBStorageNegative();

        dbs.beforeOverallDeltaB = -100;

        (uint256 stalkPenaltyBdv, , , ) = bs.calculateStalkPenalty(
            dbs,
            bdvConverted,
            overallConvertCapacity,
            inputToken,
            outputToken
        );
        assertEq(stalkPenaltyBdv, 100);
    }

    function testCalcStalkPenaltyNoOutputTokenCap() public view {
        (
            IMockFBeanstalk.DeltaBStorage memory dbs,
            address inputToken,
            address outputToken,
            uint256 bdvConverted,
            uint256 overallConvertCapacity
        ) = setupTowardsPegDeltaBStorageNegative();

        inputToken = BEAN;
        outputToken = beanEthWell;
        dbs.beforeOverallDeltaB = -100;

        (uint256 stalkPenaltyBdv, , , ) = bs.calculateStalkPenalty(
            dbs,
            bdvConverted,
            overallConvertCapacity,
            inputToken,
            outputToken
        );
        assertEq(stalkPenaltyBdv, 100);
    }

    function testConvertFromFarmCall() public {
        uint256 amount = 10e6;
        int96 stem = depositBeanAndPassGermination(amount, users[1]);

        int96[] memory stems = new int96[](1);
        stems[0] = stem;

        AdvancedPipeCall[] memory beanToLPPipeCalls = createBeanToLPPipeCalls(
            amount,
            new AdvancedPipeCall[](0)
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        bytes memory pipelineConvertEncoded = abi.encodeWithSelector(
            pipelineConvert.pipelineConvert.selector,
            BEAN, // input token
            stems, // stems
            amounts, // amount
            beanEthWell, // token out
            beanToLPPipeCalls // pipeData
        );

        IMockFBeanstalk.AdvancedFarmCall memory advancedFarmCall = IMockFBeanstalk.AdvancedFarmCall(
            pipelineConvertEncoded,
            abi.encode(0)
        );

        // make array with advancedFarmCall as only item
        IMockFBeanstalk.AdvancedFarmCall[]
            memory advancedFarmCalls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        advancedFarmCalls[0] = advancedFarmCall;

        vm.resumeGasMetering();
        vm.prank(users[1]);
        bs.advancedFarm(advancedFarmCalls);
    }

    ////// CONVERT TEST HELPERS //////

    function setupStalkTests(
        uint256 amount
    )
        private
        returns (
            uint256 beforeTotalStalk,
            uint256 beforeUserStalk,
            uint256 beforeUserDeposit,
            uint256 grownStalkBefore
        )
    {
        int96 stem = depositBeanAndPassGermination(amount, users[1]);
        beforeTotalStalk = bs.totalStalk();
        beforeUserStalk = bs.balanceOfStalk(users[1]);
        beforeUserDeposit = bs.balanceOfDepositedBdv(users[1], BEAN);
        grownStalkBefore = bs.balanceOfGrownStalk(users[1], BEAN);
        beanToLPDoConvert(amount, stem, users[1]);
    }

    function setupTowardsPegDeltaBStorageNegative()
        public
        view
        returns (
            IMockFBeanstalk.DeltaBStorage memory dbs,
            address inputToken,
            address outputToken,
            uint256 bdvConverted,
            uint256 overallConvertCapacity
        )
    {
        dbs.beforeInputTokenDeltaB = -100;
        dbs.afterInputTokenDeltaB = 0;
        dbs.beforeOutputTokenDeltaB = -100;
        dbs.afterOutputTokenDeltaB = 0;
        dbs.beforeOverallDeltaB = 0;
        dbs.afterOverallDeltaB = 0;

        inputToken = beanEthWell;
        outputToken = BEAN;

        bdvConverted = 100;
        overallConvertCapacity = 100;
    }

    function mineBlockAndUpdatePumps() public {
        // mine a block so convert power is updated
        vm.roll(block.number + 1);
        updateMockPumpUsingWellReserves(beanEthWell);
        updateMockPumpUsingWellReserves(beanwstethWell);
    }

    function updateMockPumpUsingWellReserves(address well) public {
        Call[] memory pumps = IWell(well).pumps();
        for (uint i = 0; i < pumps.length; i++) {
            address pump = pumps[i].target;
            // pass to the pump the reserves that we actually have in the well
            uint[] memory reserves = IWell(well).getReserves();
            MockPump(pump).update(well, reserves, new bytes(0));
        }
    }

    function doBasicBeanToLP(uint256 amount, address user) public {
        int96 stem = depositBeanAndPassGermination(amount, user);
        beanToLPDoConvert(amount, stem, user);
    }

    function depositBeanAndPassGermination(
        uint256 amount,
        address user
    ) public returns (int96 stem) {
        vm.pauseGasMetering();
        // amount = bound(amount, 1e6, 5000e6);
        bean.mint(user, amount);

        // setup array of addresses with user
        address[] memory users = new address[](1);
        users[0] = user;

        (amount, stem) = setUpSiloDepositTest(amount, users);

        passGermination();
    }

    /**
     * @notice Deposits into Bean:ETH well and passes germination.
     * @param amount The amount of beans added to well, single-sided.
     */
    function depositLPAndPassGermination(
        uint256 amount,
        address well
    ) public returns (int96 stem, uint256 lpAmountOut) {
        // mint beans to user 1
        bean.mint(users[1], amount);
        // user 1 deposits bean into bean:eth well, first approve
        vm.prank(users[1]);
        bean.approve(well, type(uint256).max);

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = amount;
        tokenAmountsIn[1] = 0;

        vm.prank(users[1]);
        lpAmountOut = IWell(well).addLiquidity(tokenAmountsIn, 0, users[1], type(uint256).max);

        // approve spending well token to beanstalk
        vm.prank(users[1]);
        MockToken(well).approve(BEANSTALK, type(uint256).max);

        vm.prank(users[1]);
        (, , int96 theStem) = bs.deposit(well, lpAmountOut, 0);

        stem = theStem;

        passGermination();
    }

    function beanToLPDoConvert(
        uint256 amount,
        int96 stem,
        address user
    ) public returns (int96 outputStem, uint256 outputAmount) {
        // do the convert

        // Create arrays for stem and amount. Tried just passing in [stem] and it's like nope.
        int96[] memory stems = new int96[](1);
        stems[0] = stem;

        AdvancedPipeCall[] memory beanToLPPipeCalls = createBeanToLPPipeCalls(
            amount,
            new AdvancedPipeCall[](0)
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.resumeGasMetering();
        vm.prank(user);
        (outputStem, outputAmount, , , ) = pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stems
            amounts, // amount
            beanEthWell, // token out
            beanToLPPipeCalls // pipeData
        );
    }

    function lpToBeanDoConvert(
        uint256 lpAmountOut,
        int96 stem,
        address user
    ) public returns (int96 outputStem, uint256 outputAmount) {
        // Create arrays for stem and amount. Tried just passing in [stem] and it's like nope.
        int96[] memory stems = new int96[](1);
        stems[0] = stem;

        AdvancedPipeCall[] memory beanToLPPipeCalls = createLPToBeanPipeCalls(lpAmountOut);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = lpAmountOut;

        vm.resumeGasMetering();
        vm.prank(user);
        (outputStem, outputAmount, , , ) = pipelineConvert.pipelineConvert(
            beanEthWell, // input token
            stems, // stems
            amounts, // amount
            BEAN, // token out
            beanToLPPipeCalls // pipeData
        );
    }

    function getWellAmountOutForAddingBeans(uint256 amount) public view returns (uint256) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = 0;

        uint256 wellAmountOut = IWell(beanEthWell).getAddLiquidityOut(amounts);
        return wellAmountOut;
    }

    /**
     * Calculates LP out if Bean removed from one well and added to another.
     * @param amount Amount of LP token input
     * @param fromWell Well to pull liquidity from
     * @param toWell Well to add liquidity to
     */
    function getWellAmountOutFromLPtoLP(
        uint256 amount,
        address fromWell,
        address toWell
    ) public view returns (uint256) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = 0;

        uint256 wellRemovedBeans = IWell(fromWell).getRemoveLiquidityOneTokenOut(
            amount,
            IERC20(BEAN)
        );

        uint256[] memory addAmounts = new uint256[](2);
        addAmounts[0] = wellRemovedBeans;
        addAmounts[1] = 0;

        uint256 lpAmountOut = IWell(toWell).getAddLiquidityOut(addAmounts);
        return lpAmountOut;
    }

    function addEthToWell(address user, uint256 amount) public returns (uint256 lpAmountOut) {
        MockToken(WETH).mint(user, amount);

        vm.prank(user);
        MockToken(WETH).approve(beanEthWell, amount);

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = 0;
        tokenAmountsIn[1] = amount;

        vm.prank(user);
        lpAmountOut = IWell(beanEthWell).addLiquidity(tokenAmountsIn, 0, user, type(uint256).max);

        // approve spending well token to beanstalk
        vm.prank(user);
        MockToken(beanEthWell).approve(BEANSTALK, type(uint256).max);
    }

    function removeEthFromWell(address user, uint256 amount) public returns (uint256 lpAmountOut) {
        MockToken(WETH).mint(user, amount);

        vm.prank(user);
        MockToken(WETH).approve(beanEthWell, amount);

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = 0;
        tokenAmountsIn[1] = amount;

        vm.prank(user);
        lpAmountOut = IWell(beanEthWell).removeLiquidityOneToken(
            amount,
            IERC20(WETH),
            0,
            user,
            type(uint256).max
        );

        // approve spending well token to beanstalk
        vm.prank(user);
        MockToken(beanEthWell).approve(BEANSTALK, type(uint256).max);
    }

    /**
     * @notice Creates a pipeline calls for converting a bean to LP.
     * @param amountOfBean The amount of bean to pipelineConvert.
     * @param extraPipeCalls Any additional pipe calls to add to the pipeline.
     */
    function createBeanToLPPipeCalls(
        uint256 amountOfBean,
        AdvancedPipeCall[] memory extraPipeCalls
    ) internal view returns (AdvancedPipeCall[] memory output) {
        // first setup the pipeline calls

        // setup approve max call
        bytes memory approveEncoded = abi.encodeWithSelector(
            IERC20.approve.selector,
            beanEthWell,
            MAX_UINT256
        );

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = amountOfBean;
        tokenAmountsIn[1] = 0;

        // encode Add liqudity.
        bytes memory addLiquidityEncoded = abi.encodeWithSelector(
            IWell.addLiquidity.selector,
            tokenAmountsIn, // tokenAmountsIn
            0, // min out
            PIPELINE, // recipient
            type(uint256).max // deadline
        );

        // Fabricate advancePipes:
        AdvancedPipeCall[] memory advancedPipeCalls = new AdvancedPipeCall[](100);

        uint256 callCounter = 0;

        // Action 0: approve the Bean-Eth well to spend pipeline's bean.
        advancedPipeCalls[callCounter++] = AdvancedPipeCall(
            BEAN, // target
            approveEncoded, // calldata
            abi.encode(0) // clipboard
        );

        // Action 2: Add One sided Liquidity into the well.
        advancedPipeCalls[callCounter++] = AdvancedPipeCall(
            beanEthWell, // target
            addLiquidityEncoded, // calldata
            abi.encode(0) // clipboard
        );

        // append any extra pipe calls
        for (uint j; j < extraPipeCalls.length; j++) {
            advancedPipeCalls[callCounter++] = extraPipeCalls[j];
        }

        assembly {
            mstore(advancedPipeCalls, callCounter)
        }

        return advancedPipeCalls;
    }

    function createBeanToLPPipeCallsUsingConvertCapacity(
        uint256 amount
    ) internal view returns (AdvancedPipeCall[] memory output) {
        // first setup the pipeline calls

        // setup approve max call
        bytes memory approveEncoded = abi.encodeWithSelector(
            IERC20.approve.selector,
            beanEthWell,
            MAX_UINT256
        );

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = 0; // to be overwritten
        tokenAmountsIn[1] = 0;

        // encode Add liqudity.
        bytes memory addLiquidityEncoded = abi.encodeWithSelector(
            IWell.addLiquidity.selector,
            tokenAmountsIn, // tokenAmountsIn
            0, // min out
            PIPELINE, // recipient
            type(uint256).max // deadline
        );

        // encode get convert capacity for bean:eth well
        bytes memory getConvertCapacityEncoded = abi.encodeWithSelector(
            bs.getWellConvertCapacity.selector,
            beanEthWell
        );

        // encode returnLesser on the miscHelper
        bytes memory returnLesserEncoded = abi.encodeWithSelector(
            miscHelper.returnLesser.selector,
            0, // a, to be overwritten by clipboard
            amount // b
        );

        // Fabricate advancePipes:
        AdvancedPipeCall[] memory advancedPipeCalls = new AdvancedPipeCall[](100);

        uint256 callCounter = 0;

        // Action 0: approve the Bean-Eth well to spend pipeline's bean.
        advancedPipeCalls[callCounter++] = AdvancedPipeCall(
            BEAN, // target
            approveEncoded, // calldata
            abi.encode(0) // clipboard
        );

        // Action 1: get convert capacity for bean:eth well
        advancedPipeCalls[callCounter++] = AdvancedPipeCall(
            address(bs), // target
            getConvertCapacityEncoded, // calldata
            abi.encode(0) // clipboard
        );

        bytes memory clipboardReturnLesser = abi.encodePacked(
            bytes2(0x0100), // clipboard type 1
            uint80(1), // from result of call at index 1
            uint80(32), // take the first param
            uint80(36) // paste into the 1st 32 bytes of the clipboard (plus 4 bytes)
        );

        // Action 2: returnLesser of amount or convert capacity
        advancedPipeCalls[callCounter++] = AdvancedPipeCall(
            address(miscHelper), // target
            returnLesserEncoded, // calldata
            clipboardReturnLesser // clipboard
        );

        // returnDataItemIndex, copyIndex, pasteIndex
        bytes memory clipboardAddLiquidity = abi.encodePacked(
            bytes2(0x0100), // clipboard type 1
            uint80(2), // from result of call at index 2
            uint80(32), // take the first param
            uint80(196) // paste into the 6th 32 bytes of the clipboard
        );

        // Action 2: Add One sided Liquidity into the well.
        advancedPipeCalls[callCounter++] = AdvancedPipeCall(
            beanEthWell, // target
            addLiquidityEncoded, // calldata
            clipboardAddLiquidity // clipboard
        );

        assembly {
            mstore(advancedPipeCalls, callCounter)
        }

        return advancedPipeCalls;
    }

    function createLPToBeanPipeCalls(
        uint256 amountOfLP
    ) private view returns (AdvancedPipeCall[] memory output) {
        // setup approve max call
        bytes memory approveEncoded = abi.encodeWithSelector(
            IERC20.approve.selector,
            beanEthWell,
            MAX_UINT256
        );

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = amountOfLP;
        tokenAmountsIn[1] = 0;

        // encode remove liqudity.
        bytes memory removeLiquidityEncoded = abi.encodeWithSelector(
            IWell.removeLiquidityOneToken.selector,
            amountOfLP, // tokenAmountsIn
            BEAN, // tokenOut
            0, // min out
            PIPELINE, // recipient
            type(uint256).max // deadline
        );

        // Fabricate advancePipes:
        AdvancedPipeCall[] memory advancedPipeCalls = new AdvancedPipeCall[](2);

        // Action 0: approve the Bean-Eth well to spend pipeline's bean.
        advancedPipeCalls[0] = AdvancedPipeCall(
            BEAN, // target
            approveEncoded, // calldata
            abi.encode(0) // clipboard
        );

        // Action 2: Remove One sided Liquidity into the well.
        advancedPipeCalls[1] = AdvancedPipeCall(
            beanEthWell, // target
            removeLiquidityEncoded, // calldata
            abi.encode(0) // clipboard
        );

        return advancedPipeCalls;
    }

    function createLPToLPPipeCalls(
        uint256 amountOfLP,
        address inputWell,
        address outputWell
    ) private pure returns (AdvancedPipeCall[] memory output) {
        // setup approve max call
        bytes memory approveEncoded = abi.encodeWithSelector(
            IERC20.approve.selector,
            outputWell,
            MAX_UINT256
        );

        // encode remove liqudity.
        bytes memory removeLiquidityEncoded = abi.encodeWithSelector(
            IWell.removeLiquidityOneToken.selector,
            amountOfLP, // lpAmountIn
            BEAN, // tokenOut
            0, // min out
            PIPELINE, // recipient
            type(uint256).max // deadline
        );

        uint256[] memory emptyAmountsIn = new uint256[](2);

        // encode add liquidity
        bytes memory addLiquidityEncoded = abi.encodeWithSelector(
            IWell.addLiquidity.selector,
            emptyAmountsIn, // to be pasted in
            0, // min out
            PIPELINE, // recipient
            type(uint256).max // deadline
        );

        // Fabricate advancePipes:
        AdvancedPipeCall[] memory advancedPipeCalls = new AdvancedPipeCall[](3);

        // Action 0: approve the Bean-Eth well to spend pipeline's bean.
        advancedPipeCalls[0] = AdvancedPipeCall(
            BEAN, // target
            approveEncoded, // calldata
            abi.encode(0) // clipboard
        );

        // Action 1: remove beans from well.
        advancedPipeCalls[1] = AdvancedPipeCall(
            inputWell, // target
            removeLiquidityEncoded, // calldata
            abi.encode(0) // clipboard
        );

        // returnDataItemIndex, copyIndex, pasteIndex
        bytes memory clipboard = abi.encodePacked(
            bytes2(0x0100), // clipboard type 1
            uint80(1), // from result of call at index 1
            uint80(32), // take the first param
            uint80(196) // paste into the 6th 32 bytes of the clipboard
        );

        // Action 2: add beans to wsteth:bean well.
        advancedPipeCalls[2] = AdvancedPipeCall(
            outputWell, // target
            addLiquidityEncoded, // calldata
            clipboard
        );

        return advancedPipeCalls;
    }

    function calculateDeltaBForWellAfterSwapFromLP(
        uint256 amountIn,
        address well
    ) public view returns (int256 deltaB, uint256 beansOut) {
        // calculate new reserves for well using get swap out and manually figure out what deltaB would be

        // get reserves before swap
        uint256[] memory reserves = IWell(well).getReserves();

        beansOut = IWell(well).getRemoveLiquidityOneTokenOut(amountIn, IERC20(BEAN));

        // get index of bean token
        uint256 beanIndex = bs.getBeanIndex(IWell(well).tokens());

        // remove beanOut from reserves bean index
        reserves[beanIndex] = reserves[beanIndex].sub(beansOut);

        // get new deltaB
        deltaB = bs.calculateDeltaBFromReserves(well, reserves, 0);
    }

    function calculateDeltaBForWellAfterAddingBean(
        uint256 beansIn,
        address well
    ) public view returns (int256 deltaB, uint256 lpOut) {
        // get reserves before swap
        uint256[] memory reserves = IWell(well).getReserves();

        // get index of bean token
        uint256 beanIndex = bs.getBeanIndex(IWell(well).tokens());

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = beansIn;
        lpOut = IWell(well).getAddLiquidityOut(tokenAmountsIn);

        // add to bean index (no beans out on this one)
        reserves[beanIndex] = reserves[beanIndex].add(beansIn);
        // get new deltaB
        deltaB = bs.calculateDeltaBFromReserves(well, reserves, 0);
    }

    function calculateDeltaBForWellAfterAddingNonBean(
        uint256 amountIn,
        address well
    ) public view returns (int256 deltaB, uint256 lpOut) {
        // get reserves before simulated swap
        uint256[] memory reserves = IWell(well).getReserves();

        (, uint256 nonBeanIndex) = bs.getNonBeanTokenAndIndexFromWell(well);
        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = 0;
        tokenAmountsIn[1] = amountIn;
        lpOut = IWell(well).getAddLiquidityOut(tokenAmountsIn);

        // add eth to reserves to be able to calculate new deltaB
        reserves[nonBeanIndex] = reserves[nonBeanIndex].add(amountIn);

        // get new deltaB
        deltaB = bs.calculateDeltaBFromReserves(well, reserves, 0);
    }

    // verifies there's no way to withdraw from a deposit without losing grown stalk
    function testWithdrawWithoutLosing() public {
        // users[1] is the attacker
        int96 stem;
        uint beanAmountToConvert = 2; // the amount of bean to convert
        uint beanAmountToWithdraw = 1000e6 - 2; // the amount of bean to withdraw

        // manipulate well so we won't have a penalty applied
        setDeltaBforWell(int256(beanAmountToConvert), beanEthWell, WETH);
        stem = depositBeanAndPassGermination(beanAmountToConvert + beanAmountToWithdraw, users[1]);

        uint256 grownStalkBefore = bs.grownStalkForDeposit(users[1], BEAN, stem);

        // Create arrays for stem and amount
        int96[] memory stems = new int96[](1);
        stems[0] = stem;

        AdvancedPipeCall[] memory beanToLPPipeCalls = createBeanToLPPipeCallsExtractBeans(
            beanAmountToWithdraw,
            beanAmountToConvert
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = beanAmountToConvert + beanAmountToWithdraw;

        vm.prank(users[1]); // do this as user 1
        pipelineConvert.pipelineConvert(
            BEAN, // input token
            stems, // stems
            amounts, // amount
            beanEthWell, // token out
            beanToLPPipeCalls // pipeData
        );

        uint256 grownStalkAfter = bs.grownStalkForDeposit(users[1], BEAN, stem);
        assertLt(
            grownStalkAfter,
            grownStalkBefore,
            "grown stalk should be lower after extraction convert"
        );
    }

    function createBeanToLPPipeCallsExtractBeans(
        uint256 amountOfBeanTransferredOut,
        uint256 amountOfBeanConverted
    ) internal view returns (AdvancedPipeCall[] memory output) {
        // setup transfer to myself
        bytes memory transferEncoded = abi.encodeWithSelector(
            IERC20.transfer.selector,
            users[1],
            amountOfBeanTransferredOut
        );

        // setup approve max call
        bytes memory approveEncoded = abi.encodeWithSelector(
            IERC20.approve.selector,
            beanEthWell,
            MAX_UINT256
        );

        uint256[] memory tokenAmountsIn = new uint256[](2);
        tokenAmountsIn[0] = amountOfBeanConverted;
        tokenAmountsIn[1] = 0;

        // encode Add liqudity.
        bytes memory addLiquidityEncoded = abi.encodeWithSelector(
            IWell.addLiquidity.selector,
            tokenAmountsIn, // tokenAmountsIn
            0, // min out
            PIPELINE, // recipient
            type(uint256).max // deadline
        );

        // Fabricate advancePipes:
        AdvancedPipeCall[] memory advancedPipeCalls = new AdvancedPipeCall[](100);

        uint256 callCounter = 0;

        // Action 0: approve the Bean-Eth well to spend pipeline's bean.
        advancedPipeCalls[callCounter++] = AdvancedPipeCall(
            BEAN, // target
            transferEncoded, // calldata
            abi.encode(0) // clipboard
        );

        // Action 0: approve the Bean-Eth well to spend pipeline's bean.
        advancedPipeCalls[callCounter++] = AdvancedPipeCall(
            BEAN, // target
            approveEncoded, // calldata
            abi.encode(0) // clipboard
        );

        // Action 2: Add One sided Liquidity into the well.
        advancedPipeCalls[callCounter++] = AdvancedPipeCall(
            beanEthWell, // target
            addLiquidityEncoded, // calldata
            abi.encode(0) // clipboard
        );

        assembly {
            mstore(advancedPipeCalls, callCounter)
        }

        return advancedPipeCalls;
    }
}

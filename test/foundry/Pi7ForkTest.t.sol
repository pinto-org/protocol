// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import "forge-std/console.sol";

contract Skip_Pi7ForkTest is TestHelper {
    address constant PINTO_USDC_WELL = 0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1;

    function setUp() public {
        initializeBeanstalkTestState(true, false);
    }

    function test_forkBase_convertDownPenalty() public {
        bs = IMockFBeanstalk(PINTO);
        // fork just before season 2556,
        // 24.03% Liquidity to Supply Ratio
        uint256 forkBlock = 27236527 - 1;
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock - 1);

        // Check values before upgrade
        console.log("--- Before Upgrade ---");
        console.log("twaDeltaB before upgrade:", bs.totalDeltaB());
        console.log("lpToSupplyRatio before upgrade:", bs.getLiquidityToSupplyRatio());
        console.log("pinto stem tip before upgrade: ", bs.stemTipForToken(L2_PINTO));

        // upgrade to PI7
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI7");

        // Check values after upgrade but before sunrise
        console.log("--- After Upgrade, Before Sunrise ---");
        console.log("twaDeltaB after upgrade:", bs.totalDeltaB());
        console.log("lpToSupplyRatio after upgrade:", bs.getLiquidityToSupplyRatio());
        console.log("pinto stem tip after upgrade: ", bs.stemTipForToken(L2_PINTO));

        // go forward to season 2556
        vm.roll(27236527 + 10);
        vm.warp(block.timestamp + 10 seconds);

        // call sunrise
        bs.sunrise();

        // params
        uint256 amountIn = 1_000e6;
        address farmer = address(0xFb94D3404c1d3D9D6F08f79e58041d5EA95AccfA);

        // // log deposits to find appropriate stem
        // logFarmerPintoDeposits(farmer);

        ////////////// Convert //////////////

        // create encoding for a bean -> well convert.
        bytes memory convertData = convertEncoder(
            LibConvertData.ConvertKind.BEANS_TO_WELL_LP,
            PINTO_USDC_WELL,
            amountIn, // amountIn
            0 // minOut
        );

        bs.stemTipForToken(L2_PINTO);
        int96 stem = 590486100;
        uint256 depositGrownStalk = bs.grownStalkForDeposit(farmer, L2_PINTO, stem);
        (uint256 depositAmount, ) = bs.getDeposit(farmer, L2_PINTO, stem);
        uint256 convertingStalk = (amountIn * depositGrownStalk) / depositAmount;
        int96 toStem;
        uint256 penaltyRatio;
        {
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = amountIn;
            int96[] memory stems = new int96[](1);
            stems[0] = stem;

            uint256 rollingSeasonsAbovePeg;
            (penaltyRatio, rollingSeasonsAbovePeg) = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
                (uint256, uint256)
            );
            console.log("penaltyRatio:", penaltyRatio);
            console.log("rollingSeasonsAbovePeg:", rollingSeasonsAbovePeg);
            assertEq(penaltyRatio, 438363871316702887, "Penalty ratio incorrect"); // ~ 43%
            assertEq(rollingSeasonsAbovePeg, 1, "Rolling seasons above peg should be 1");

            // convert
            vm.prank(farmer);
            (toStem, , , , ) = bs.convert(convertData, stems, amounts);
        }

        // Get final stalk after conversion
        uint256 lostGrownStalk = (convertingStalk * penaltyRatio) / 1e18;
        uint256 remainingDepositGrownStalk = bs.grownStalkForDeposit(farmer, L2_PINTO, stem);

        assertEq(bs.balanceOfGrownStalk(farmer, L2_PINTO), 0, "Farmer should have been mowed");
        assertApproxEqRel(
            remainingDepositGrownStalk,
            depositGrownStalk - convertingStalk,
            1e18 / 100_000
        );
        assertApproxEqRel(
            bs.grownStalkForDeposit(farmer, PINTO_USDC_WELL, toStem),
            convertingStalk - lostGrownStalk,
            1e18 / 100_000
        );

        // Log the stalk difference for visibility
        console.log("Grown stalk lost:", lostGrownStalk);
    }

    function test_forkBase_convertGaugeChanges() public {
        bs = IMockFBeanstalk(PINTO);

        // fork just before season 2556,
        // 24.03% Liquidity to Supply Ratio
        uint256 forkBlock = 27236527 - 1;
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock - 1);

        // upgrade to PI7
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI7");
        // go forward to season 2556
        vm.roll(27236527 + 10);
        vm.warp(block.timestamp + 10 seconds);

        for (uint256 i; i < 35; i++) {
            warpToNextSeasonTimestamp();

            // call sunrise
            bs.sunrise();

            // Log season number
            console.log("season:", bs.time().current);

            // Log cultivationFactor
            (uint256 convertDownPenalty, uint256 rollingSeasonsAbovePeg) = abi.decode(
                bs.getGaugeValue(GaugeId.CONVERT_DOWN_PENALTY),
                (uint256, uint256)
            );
            console.log(
                "penalty %:",
                convertDownPenalty,
                ", rolling seasons above peg:",
                rollingSeasonsAbovePeg
            );
        }
    }

    function logFarmerPintoDeposits(address farmer) public {
        // get stems of farmer deposits
        IMockFBeanstalk.TokenDepositId memory deposits = bs.getTokenDepositsForAccount(
            farmer,
            address(L2_PINTO)
        );

        int96[] memory depStems = new int96[](deposits.depositIds.length);
        uint256[] memory depAmounts = new uint256[](deposits.depositIds.length);
        uint256 sumAmounts;
        for (uint256 i = 0; i < deposits.depositIds.length; i++) {
            // get stem from deposit id
            (, int96 stem) = LibBytes.unpackAddressAndStem(deposits.depositIds[i]);
            depStems[i] = stem;
            console.log("--------------Deposit------------------");
            console.log("stem:", stem);
            // get the amount from the deposit list
            uint256 amount = deposits.tokenDeposits[i].amount;
            depAmounts[i] = amount;
            console.log("amount:", amount);
            sumAmounts += amount;
            console.log("--------------------------------");
        }
    }
}

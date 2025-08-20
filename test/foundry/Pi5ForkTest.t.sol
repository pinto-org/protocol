// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {IBean} from "contracts/interfaces/IBean.sol";
import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

/**
 * @dev This test is marked as LEGACY because upon PI-6, a new variable `maxTotalGaugePoints` was added to the `SeedGauge` contract.
 * and thus this suite is no longer relevant.
 */
contract LEGACY_Pi5ForkTest is TestHelper {
    function setUp() public {
        initializeBeanstalkTestState(true, false);
    }

    /*function test_forkBase_scaleSoilAbovePeg_relativelyHigh() public {
        bs = IMockFBeanstalk(PINTO);
        // fork just before season 668,
        // twadeltab = 8521007570
        // Pod Rate: 22.45%
        // new harvestable pods: 4132688671
        // newSoil : 3443907225
        uint256 forkBlock = 23836327 - 1;

        // upgrade to PI5
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI5");

        // go forward to season 669
        vm.roll(23836327 + 10);
        vm.warp(block.timestamp + 10 seconds);

        // call sunrise
        bs.sunrise();

        uint256 soilAfterUpgrade = bs.initialSoil();

        // pod rate is 22.45% so soilCoefficientRelativelyHigh is used
        uint256 soilCoefficientRelativelyHigh = 0.5e18;

        // soil that would result in the same number of Beans as were minted to the Field
        uint256 newSoil = 3443907225;

        // calc expected soil
        uint256 expectedSoil = (newSoil * soilCoefficientRelativelyHigh) / 1e18;

        assertEq(soilAfterUpgrade, expectedSoil);
    }

    function test_forkBase_scaleSoilAbovePeg_relativelyLow() public {
        bs = IMockFBeanstalk(PINTO);
        // fork just before season 429,
        // twadeltab = 6364785927
        // Pod Rate: 11.42%
        // new harvestable pods: 3086921174
        // newSoil : 2832037774
        uint256 forkBlock = 23406130 - 1;

        // upgrade to PI5
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI5");

        // go forward to season 669
        vm.roll(23406130 + 10);
        vm.warp(block.timestamp + 10 seconds);

        // call sunrise
        bs.sunrise();

        uint256 soilAfterUpgrade = bs.initialSoil();

        uint256 soilCoefficientRelativelyLow = 1e18;
        // soil that would result in the same number of Beans as were minted to the Field
        uint256 newSoil = 2832037774;
        uint256 expectedSoil = (newSoil * soilCoefficientRelativelyLow) / 1e18;

        assertEq(soilAfterUpgrade, expectedSoil);
    }

    // fork Base when instDeltaB is positive and twaDeltaB is negative
    // call sunrise and verify soil is issued as a percentage of twaDeltaB
    // scaled by the pod rate scalar
    function test_forkBase_twa_inst_deltab_fix() public {
        bs = IMockFBeanstalk(PINTO);
        // fork just before season 681,
        // where ∆P was +3k for 5+ minutes going into the end of the season,
        // but TWA∆P was at -9k.
        uint256 forkBlock = 23859727 - 1;

        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock);

        // upgrade to PI5
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI5");

        // go forward to season 681
        vm.roll(23859727 + 10);
        vm.warp(block.timestamp + 10 seconds);

        // get twaDeltaB
        int256 twaDeltaB = bs.totalDeltaB();
        console.log("twaDeltaB", twaDeltaB);

        // get instDeltaB
        int256 instDeltaB = bs.totalInstantaneousDeltaB();
        console.log("instDeltaB", instDeltaB);

        // call sunrise
        bs.sunrise();

        uint256 soilAfterUpgrade = bs.initialSoil();
        console.log("soilAfterUpgrade", soilAfterUpgrade);

        uint256 abovePegDeltaBSoilScalar = 0.01e6; // (1% of twaDeltaB)

        // calculate expected soil
        uint256 expectedSoil = (uint256(-twaDeltaB) * (abovePegDeltaBSoilScalar)) / 1e6;

        // further scale soil above peg
        uint256 caseId = 92; // case id was 92 for season 681
        expectedSoil = scaleSoilAbovePeg(expectedSoil, caseId);

        assertEq(soilAfterUpgrade, expectedSoil);
    }*/

    function test_forkBase_new_eval_params() public view {
        // new extra evaluation parameters
        IMockFBeanstalk.ExtEvaluationParameters memory extEvaluationParameters = bs
            .getExtEvaluationParameters();
        assertEq(extEvaluationParameters.belowPegSoilL2SRScalar, 1.0e6);
        assertEq(extEvaluationParameters.soilCoefficientRelativelyHigh, 0.5e18);
        assertEq(extEvaluationParameters.soilCoefficientRelativelyLow, 1e18);
        assertEq(extEvaluationParameters.abovePegDeltaBSoilScalar, 0.01e6);

        // old changed evaluation parameters
        IMockFBeanstalk.EvaluationParameters memory evaluationParameters = bs
            .getEvaluationParameters();
        assertEq(evaluationParameters.soilCoefficientHigh, 0.25e18);
        assertEq(evaluationParameters.soilCoefficientLow, 1.2e18);
    }

    // test soil issuance below peg
    // Currently commented out, due to new updates in PI-6
    /*function test_forkBase_soil_issuance_below_peg() public {
        bs = IMockFBeanstalk(PINTO);
        // fork just before season 24415927, which is when season 990 happened
        uint256 forkBlock = 24415927 - 1;

        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock);

        vm.roll(forkBlock + 10);
        vm.warp(block.timestamp + 10 seconds);

        // call sunrise
        bs.sunrise();

        // Get the soil amount that will actually be used in the calculation
        uint256 soilBeforeUpgrade = bs.initialSoil();

        uint256 l2sr = bs.getLiquidityToSupplyRatio();

        // roll back to before season 990 and deploy the upgrade
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock);

        // upgrade to PI5
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI5");

        uint256 emittedL2sr;
        // call sunrise and capture event data, calling l2sr later gave us a different value. This ensures we use the exact same one that happened on sunrise.
        vm.recordLogs();
        bs.sunrise();

        // Get the recorded logs
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Find and decode SeasonMetrics event
        bytes32 expectedSig = keccak256(
            "SeasonMetrics(uint256,uint256,uint256,uint256,uint256,uint256)"
        );

        // Find the SeasonMetrics event
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == expectedSig) {
                (
                    uint256 deltaPodDemand,
                    uint256 l2sr,
                    uint256 podRate,
                    uint256 thisSowTime,
                    uint256 lastSowTime
                ) = abi.decode(entries[i].data, (uint256, uint256, uint256, uint256, uint256));

                emittedL2sr = l2sr;
                break;
            }
        }

        uint256 soilAfterUpgrade = bs.initialSoil();

        assertLt(soilAfterUpgrade, soilBeforeUpgrade);

        IMockFBeanstalk.ExtEvaluationParameters memory extEvaluationParameters = bs
            .getExtEvaluationParameters();
        uint256 scalar = extEvaluationParameters.belowPegSoilL2SRScalar;

        uint256 decimalScalar = (scalar * 1e18) / 1e6;
        uint256 scaledL2SR = (emittedL2sr * decimalScalar + 1e18 / 2) / 1e18; // the 1e18 / 2 is for rounding

        uint256 multiplier = 1e18 - scaledL2SR;
        uint256 expectedSoil = (soilBeforeUpgrade * multiplier) / 1e18;

        assertEq(soilAfterUpgrade, expectedSoil);
    }*/

    /**
     * @notice scales soil issued above peg according to pod rate and the soil coefficients
     * @dev see {Sun.sol}.
     */
    function scaleSoilAbovePeg(uint256 soilIssued, uint256 caseId) internal pure returns (uint256) {
        if (caseId % 36 >= 27) {
            soilIssued = (soilIssued * 0.25e18) / 1e18; // exessively high podrate
        } else if (caseId % 36 >= 18) {
            soilIssued = (soilIssued * 0.5e18) / 1e18; // reasonably high podrate
        } else if (caseId % 36 >= 9) {
            soilIssued = (soilIssued * 1e18) / 1e18; // reasonably low podrate
        } else {
            soilIssued = (soilIssued * 1.2e18) / 1e18; // exessively low podrate
        }
        return soilIssued;
    }
}

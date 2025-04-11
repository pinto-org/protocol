// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk, IERC20} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import "forge-std/console.sol";

contract Pi8ForkTest is TestHelper {
    address constant PINTO_USDC_WELL = 0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1;

    function setUp() public {
        initializeBeanstalkTestState(true, false);
    }

    // note: this was marked as legacy because the min sown demand was removed in PI9
    function LEGACY_test_forkBase_pi8() public {
        // address testAccount = address(0xC795b5FCAe55F29DD9eF555d3AbBE85bCC162DB5);
        // address usdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        // bs = IMockFBeanstalk(PINTO);
        // // fork a recent block
        // uint256 forkBlock = 28596600;
        // vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock - 1);
        // // upgrade to PI8
        // forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI8");
        // // verify that the crop scalar is 66%
        // console.log("crop scalar:", bs.getBeanToMaxLpGpPerBdvRatio());
        // console.log("crop ratio:", bs.getBeanToMaxLpGpPerBdvRatioScaled());
        // IMockFBeanstalk.ExtEvaluationParameters memory extEvalParams = bs
        //     .getExtEvaluationParameters();
        // console.log("min soil sown demand:", extEvalParams.minSoilSownDemand);
        // IMockFBeanstalk.EvaluationParameters memory evalParams = bs.getEvaluationParameters();
        // console.log("max bean max lp gp per bdv ratio:", evalParams.maxBeanMaxLpGpPerBdvRatio);
        // uint256[] memory depositIds = new uint256[](5);
        // depositIds[
        //     4
        // ] = 80257261365260160448180297953543637015013860948612032607643216503657925303411;
        // depositIds[
        //     3
        // ] = 80257261365260160448180297953543637015013860948612032607643216503657354165390;
        // depositIds[
        //     2
        // ] = 80257261365260160448180297953543637015013860948612032607643216503657330206036;
        // depositIds[
        //     1
        // ] = 80257261365260160448180297953543637015013860948612032607643216503657241688664;
        // depositIds[
        //     0
        // ] = 80257261365260160448180297953543637015013860948612032607643216503656210056716;
        // // get an account and verify that the deposit ids can be sorted
        // vm.prank(address(0xC795b5FCAe55F29DD9eF555d3AbBE85bCC162DB5));
        // bs.updateSortedDepositIds(
        //     address(0xC795b5FCAe55F29DD9eF555d3AbBE85bCC162DB5),
        //     address(0xb170000aeeFa790fa61D6e837d1035906839a3c8),
        //     depositIds
        // );
        // // verify that the deposit ids are sorted
        // uint256[] memory sortedDepositIds = bs.getTokenDepositIdsForAccount(
        //     testAccount,
        //     address(0xb170000aeeFa790fa61D6e837d1035906839a3c8)
        // );
        // for (uint256 i = 1; i < sortedDepositIds.length; i++) {
        //     assertGt(sortedDepositIds[i], sortedDepositIds[i - 1]);
        // }
        // // verify you can transfer tokens to an internal balance.
        // vm.prank(testAccount);
        // IERC20(usdc).approve(PINTO, 100e6);
        // vm.prank(testAccount);
        // bs.sendTokenToInternalBalance(usdc, testAccount, 100e6);
        // // verify that the internal balance is 100e6
        // assertEq(bs.getInternalBalance(testAccount, usdc), 100e6);
    }
}

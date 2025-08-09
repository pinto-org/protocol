// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import "forge-std/console.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";

/**
 * @dev forks base and tests different cultivation factor scenarios
 * PI-11 adds the convert down penalty v1.2, and dewhitelists the WSOL and WETH pool.
 **/
contract Pi11ForkTest is TestHelper {
    // Real addresses from InitWhitelistRebalance
    address constant PINTO_WETH_LP = 0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3;
    address constant PINTO_CBETH_LP = 0x3e111115A82dF6190e36ADf0d552880663A4dBF1;
    address constant PINTO_CBBTC_LP = 0x3e11226fe3d85142B734ABCe6e58918d5828d1b4;
    address constant PINTO_USDC_LP = 0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1;
    address constant PINTO_WSOL_LP = 0x3e11444c7650234c748D743D8d374fcE2eE5E6C9;

    // Expected allocations (33% each for remaining 3 tokens)
    uint64 constant EXPECTED_ALLOCATION = 33_333333;

    function setUp() public {
        bs = IMockFBeanstalk(PINTO);
    }

    function test_forkBase_pi11_values() public {
        // fork a recent block, above the value target
        uint256 forkBlock = 33351517;
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock - 1);

        // upgrade to PI11
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI11");
        // verify that the convert down penalty gauge is initialized correctly
        LibGaugeHelpers.ConvertDownPenaltyData memory gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_DOWN_PENALTY),
            (LibGaugeHelpers.ConvertDownPenaltyData)
        );

        assertEq(gd.rollingSeasonsAbovePegRate, 1);
        assertEq(gd.rollingSeasonsAbovePegCap, 12);
        assertEq(gd.beansMintedAbovePeg, 0);
        assertEq(gd.beanMintedThreshold, 15007159669041);
        assertEq(gd.runningThreshold, 0);
        assertEq(gd.percentSupplyThresholdRate, 416666666666667);
        assertEq(gd.convertDownPenaltyRate, 1.005e6);
        assertEq(gd.thresholdSet, true);
    }

    function test_forkBase_whitelistRebalance() public {
        // Fork recent block
        uint256 forkBlock = 33192980;
        vm.createSelectFork(vm.envString("BASE_RPC"), forkBlock);

        console.log("=== BEFORE UPGRADE ===");
        _logWhitelistedTokens("Before");

        address[] memory whitelistedTokensBefore = bs.getWhitelistedTokens();
        for (uint256 i = 0; i < whitelistedTokensBefore.length; i++) {
            address token = whitelistedTokensBefore[i];
            console.log("Token: ", _getTokenName(token));
            console.log("Stalk Earned Per Season: ", bs.tokenSettings(token).stalkEarnedPerSeason);
            console.log(
                "Optimal Percent Deposited BDV: ",
                bs.tokenSettings(token).optimalPercentDepositedBdv
            );
            console.log("-------------------------------");
        }

        // Upgrade to InitWhitelistRebalance
        forkMainnetAndUpgradeAllFacets(forkBlock, vm.envString("BASE_RPC"), PINTO, "InitPI11");

        console.log("\n=== AFTER UPGRADE ===");
        _logWhitelistedTokens("After");

        // Verify tokens were dewhitelisted
        assertFalse(_isTokenWhitelisted(PINTO_WETH_LP), "WETH LP should be dewhitelisted");
        assertFalse(_isTokenWhitelisted(PINTO_WSOL_LP), "WSOL LP should be dewhitelisted");

        // Verify remaining tokens have correct allocations
        assertEq(
            bs.tokenSettings(PINTO_CBETH_LP).optimalPercentDepositedBdv,
            EXPECTED_ALLOCATION,
            "CBETH LP allocation incorrect"
        );
        assertEq(
            bs.tokenSettings(PINTO_CBBTC_LP).optimalPercentDepositedBdv,
            EXPECTED_ALLOCATION,
            "CBBTC LP allocation incorrect"
        );
        assertEq(
            bs.tokenSettings(PINTO_USDC_LP).optimalPercentDepositedBdv,
            EXPECTED_ALLOCATION,
            "USDC LP allocation incorrect"
        );

        // Verify total allocation is 99% (3 × 33%)
        address[] memory whitelistedTokens = bs.getWhitelistedTokens();
        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            // Skip PINTO token (index 0) as it has 0% optimal allocation
            if (i > 0) {
                totalAllocation += uint256(
                    bs.tokenSettings(whitelistedTokens[i]).optimalPercentDepositedBdv
                );
            }
        }
        assertEq(totalAllocation, 99999999, "Total allocation should be 99%");

        // get the stalkEarnedPerSeason for each token, including the dewhitelisted tokens
        console.log("\n=== SEEDS AFTER UPGRADE ===");
        for (uint256 i = 0; i < whitelistedTokensBefore.length; i++) {
            address token = whitelistedTokensBefore[i];
            console.log("Token: ", _getTokenName(token));
            console.log("Stalk Earned Per Season: ", bs.tokenSettings(token).stalkEarnedPerSeason);
            console.log(
                "Optimal Percent Deposited BDV: ",
                bs.tokenSettings(token).optimalPercentDepositedBdv
            );
            console.log("-------------------------------");
        }

        console.log("\n=== VERIFICATION COMPLETE ===");
    }

    function _logWhitelistedTokens(string memory stage) internal {
        address[] memory whitelistedTokens = bs.getWhitelistedTokens();
        console.log("Whitelisted tokens count (%s):", stage, whitelistedTokens.length);

        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            address token = whitelistedTokens[i];
            uint64 allocation = bs.tokenSettings(token).optimalPercentDepositedBdv;
            totalAllocation += allocation;

            string memory tokenName = _getTokenName(token);
            console.log("Token: ", tokenName);
            console.log("Optimal Percent Deposited BDV: ", allocation);
            console.log("-------------------------------");
        }
        console.log("Total allocation (%s): %d bp", stage, totalAllocation);
    }

    function _getTokenName(address token) internal pure returns (string memory) {
        if (token == PINTO_WETH_LP) return "WETH-LP";
        if (token == PINTO_CBETH_LP) return "CBETH-LP";
        if (token == PINTO_CBBTC_LP) return "CBBTC-LP";
        if (token == PINTO_USDC_LP) return "USDC-LP";
        if (token == PINTO_WSOL_LP) return "WSOL-LP";
        if (token == 0xb170000aeeFa790fa61D6e837d1035906839a3c8) return "PINTO";
        return "UNKNOWN";
    }

    function _isTokenWhitelisted(address token) internal view returns (bool) {
        address[] memory whitelistedTokens = bs.getWhitelistedTokens();
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            if (whitelistedTokens[i] == token) {
                return true;
            }
        }
        return false;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {IBean} from "contracts/interfaces/IBean.sol";
import {Vm} from "forge-std/Vm.sol";
import {Decimal} from "contracts/libraries/Decimal.sol";
import {LibWellMinting} from "contracts/libraries/Minting/LibWellMinting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import "forge-std/console.sol";

contract Legacy_Pi6ForkTest is TestHelper {
    using Decimal for Decimal.D256;
    using Strings for uint256;

    // LP token name mapping
    mapping(address => string) internal lpTokenNames;
    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        farmers = createUsers(1);

        // Initialize LP token names
        lpTokenNames[0x3e11444c7650234c748D743D8d374fcE2eE5E6C9] = "PINTOWSOL";
        lpTokenNames[0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3] = "PINTOWETH";
        lpTokenNames[0x3e111115A82dF6190e36ADf0d552880663A4dBF1] = "PINTOcbETH";
        lpTokenNames[0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1] = "PINTOUSDC";
        lpTokenNames[0x3e11226fe3d85142B734ABCe6e58918d5828d1b4] = "PINTOcbBTC";
    }

    function test_forkBase_checkSoilBelowPeg() public {
        bs = IMockFBeanstalk(PINTO);

        // fork just before season 2546 (which happened in block 27218527)
        uint256 seasonBlock = 27218527;

        // Fork base at seasonBlock+1
        vm.createSelectFork(vm.envString("BASE_RPC"), seasonBlock - 1);

        // Check values before upgrade
        console.log("--- Before Upgrade ---");
        console.log("twaDeltaB before upgrade:", bs.totalDeltaB());
        console.log("lpToSupplyRatio before upgrade:", bs.getLiquidityToSupplyRatio());

        // get soil before upgrade
        uint256 soilBeforeUpgrade = bs.initialSoil();

        // upgrade to PI6
        forkMainnetAndUpgradeAllFacets(seasonBlock - 1, vm.envString("BASE_RPC"), PINTO, "InitPI6");
        console.log("lpToSupplyRatio after upgrade:", bs.getLiquidityToSupplyRatio());

        // Update oracle timeouts to ensure they're not stale
        updateOracleTimeouts(L2_PINTO, false);

        // Check values after upgrade but before sunrise
        console.log("--- After Upgrade, Before Sunrise ---");
        console.log("twaDeltaB after upgrade:", bs.totalDeltaB());

        // go forward to season 2547
        vm.roll(seasonBlock + 10);
        vm.warp(block.timestamp + 10 seconds);
        console.log(
            "lpToSupplyRatio after upgrade and after sunrise:",
            bs.getLiquidityToSupplyRatio()
        );

        // Check values after time advancement but before sunrise
        console.log("--- After Time Advancement, Before Sunrise ---");
        console.log("twaDeltaB before sunrise:", bs.totalDeltaB());
        // console.log("lpToSupplyRatio before sunrise:", bs.getLiquidityToSupplyRatio());

        // Get the necessary parameters for calculation
        int256 twaDeltaB = bs.totalDeltaB();
        console.log("twaDeltaB:", twaDeltaB);

        // Get instantaneous deltaB
        int256 instDeltaB = bs.totalInstantaneousDeltaB();
        console.log("instDeltaB:", instDeltaB);

        // Get L2SR (LP to Supply Ratio)
        uint256 lpToSupplyRatio = 236033315962430520; // Asking for the actual L2SR gives us a different value, so using the known value from time of fork.

        // call sunrise
        bs.sunrise();

        uint256 soilAfterUpgrade = bs.initialSoil();

        console.log("--- After Sunrise ---");
        console.log("soilBeforeUpgrade:", soilBeforeUpgrade);
        console.log("soilAfterUpgrade:", soilAfterUpgrade);

        // Note: In PI6, soil amount may increase or decrease depending on the formula
        // We're not asserting the direction of change, just that the calculation is correct
        console.log("Soil change:", int256(soilAfterUpgrade) - int256(soilBeforeUpgrade));

        // Get cultivationFactor
        uint256 cultivationFactor = uint256(
            abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (int256))
        );
        console.log("cultivationFactor:", cultivationFactor);

        // Use the helper function from TestHelper.sol to calculate expected soil
        uint256 expectedSoil = calculateExpectedSoil(twaDeltaB, lpToSupplyRatio, cultivationFactor);
        console.log("Calculated expected soil:", expectedSoil);

        // Assert that the actual soil is close to the expected soil (allowing for small rounding differences)
        // assertApproxEqRel(soilAfterUpgrade, expectedSoil, 0.01e18); // 1% tolerance
        assertEq(soilAfterUpgrade, expectedSoil);

        // Fast forward until cultivationFactor drops to min
        for (uint256 i; i < 35; i++) {
            warpToNextSeasonTimestamp();

            // call sunrise
            bs.sunrise();

            // Log season number
            console.log("season number:", bs.time().current);

            // Log cultivationFactor
            uint256 cultivationFactor = uint256(
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (int256))
            );
            console.log("cultivationFactor:", cultivationFactor);

            // Log soil
            uint256 soil = bs.initialSoil();
            console.log("soil:", soil);
        }

        // Do max approval from farmer to pinto protocol contract
        vm.prank(farmers[0]);
        IBean(L2_PINTO).approve(PINTO, type(uint256).max);

        // Mint beans to farmer to sow
        vm.prank(PINTO);
        IBean(L2_PINTO).mint(farmers[0], 1000000000e6);

        // Fast forward until cultivationFactor increases to max
        for (uint256 i; i < 55; i++) {
            warpToNextSeasonTimestamp();

            // call sunrise
            bs.sunrise();

            // Log season number
            console.log("season number:", bs.time().current);

            // Log cultivationFactor
            uint256 cultivationFactor = uint256(
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (int256))
            );
            console.log("cultivationFactor:", cultivationFactor);

            // Log soil
            uint256 soil = bs.initialSoil();
            console.log("soil:", soil);

            // Sow all the soil
            vm.prank(farmers[0]);
            bs.sow(soil, 1e6, uint8(LibTransfer.From.EXTERNAL));

            // Log soil availabe now
            // console.log("soil available now:", bs.totalSoil());
        }
    }

    function test_forkBase_min_soil_issuance() public {
        bs = IMockFBeanstalk(PINTO);

        // fork just before season 1484 (which happened in block 25305128)
        // Season 2542 also should hit the min soil issuance case.
        uint256 seasonBlock = 27211327;

        forkMainnetAndUpgradeAllFacets(seasonBlock - 1, vm.envString("BASE_RPC"), PINTO, "InitPI6");
        vm.roll(seasonBlock + 10);
        vm.warp(block.timestamp + 10 seconds);

        // call sunrise
        bs.sunrise();

        // Check new soil issuance
        uint256 soilAfterUpgrade = bs.initialSoil();

        // Soil after upgrade should be 50e6
        assertEq(soilAfterUpgrade, 50e6);
    }

    function test_forkBase_new_eval_params() public view {
        // new extra evaluation parameters
        IMockFBeanstalk.ExtEvaluationParameters memory extEvaluationParameters = bs
            .getExtEvaluationParameters();

        // PI6 new parameters
        assertEq(
            extEvaluationParameters.soilDistributionPeriod,
            24 * 60 * 60,
            "soilDistributionPeriod should be 24 hours"
        );
        assertEq(extEvaluationParameters.minSoilIssuance, 50e6, "minSoilIssuance should be 50e6");
    }

    function test_forkBase_cultivation_factor_gauge() public view {
        // Check that the cultivation factor gauge exists
        bytes memory gaugeValue = bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR);
        uint256 cultivationFactor = abi.decode(gaugeValue, (uint256));

        // Check initial value
        assertEq(cultivationFactor, 50e6, "Initial cultivation factor should be 50%");

        // Get gauge parameters
        bytes memory gaugeParams = bs.getGauge(GaugeId.CULTIVATION_FACTOR).data;
        (
            uint256 minDeltaCultivationFactor,
            uint256 maxDeltaCultivationFactor,
            uint256 minCultivationFactor,
            uint256 maxCultivationFactor
        ) = abi.decode(gaugeParams, (uint256, uint256, uint256, uint256));

        // Check parameters
        assertEq(minDeltaCultivationFactor, 0.5e6, "Min delta cultivation factor should be 0.5%");
        assertEq(maxDeltaCultivationFactor, 2e6, "Max delta cultivation factor should be 2%");
        assertEq(minCultivationFactor, 1e6, "Min cultivation factor should be 1%");
        assertEq(maxCultivationFactor, 100e6, "Max cultivation factor should be 100%");
    }

    function test_forkBase_checkSeedsAfterUpgrade() public {
        bs = IMockFBeanstalk(PINTO);

        // Middle of season 2662
        uint256 seasonBlock = 27428000;

        vm.createSelectFork(vm.envString("BASE_RPC"), seasonBlock - 1);

        console.log("--- Seeds (Grown Stalk Per BDV Per Season) Before Upgrade ---");

        // Use hardcoded L2_PINTO address for Bean token
        address beanToken = L2_PINTO;
        console.log("Bean token address:", beanToken);

        // Create array with Bean token
        address[] memory beanArray = new address[](1);
        beanArray[0] = beanToken;

        // Get Bean seeds
        uint256[] memory beanSeeds = bs.stalkEarnedPerSeason(beanArray);
        console.log("Bean \tSeeds:", formatSeedsValue(beanSeeds[0]));

        // Get all whitelisted LP tokens
        address[] memory lpTokens = bs.getWhitelistedWellLpTokens();
        console.log("Number of whitelisted LP tokens:", lpTokens.length);

        // Get and log seeds for all LP tokens before upgrade
        uint256[] memory seedsBeforeUpgrade = getAndLogLpTokenSeeds(lpTokens, new uint256[](0));

        uint256 maxBeanMaxLpGpPerBdvRatio = bs.getMaxBeanMaxLpGpPerBdvRatio();
        console.log("maxBeanMaxLpGpPerBdvRatio before upgrade:", maxBeanMaxLpGpPerBdvRatio);

        // upgrade to PI6
        forkMainnetAndUpgradeAllFacets(seasonBlock - 1, vm.envString("BASE_RPC"), PINTO, "InitPI6");

        // Verify that maxBeanMaxLpGpPerBdvRatio is 150e18
        assertEq(
            bs.getMaxBeanMaxLpGpPerBdvRatio(),
            150e18,
            "maxBeanMaxLpGpPerBdvRatio should be 150e18"
        );

        // Verify that beanToMaxLpGpPerBdvRatio is 67e18
        assertEq(
            bs.getBeanToMaxLpGpPerBdvRatio(),
            67e18,
            "beanToMaxLpGpPerBdvRatio should be 67e18"
        );

        // UPdate oracles
        updateOracleTimeouts(L2_PINTO, false);

        for (uint256 i; i < 35; i++) {
            warpToNextSeasonTimestamp();

            // call sunrise
            bs.sunrise();

            // Log season number
            console.log("season number:", bs.time().current);

            console.log("--- Seeds (Grown Stalk Per BDV Per Season) After Upgrade ---");

            // Get Bean seeds after upgrade
            uint256[] memory beanSeedsAfter = bs.stalkEarnedPerSeason(beanArray);
            console.log(
                "Pinto\t\t Seeds:",
                formatSeedsValue(beanSeedsAfter[0]),
                "\tSeeds difference:",
                formatSeedsValue(uint256(int256(beanSeedsAfter[0]) - int256(beanSeeds[0])))
            );

            // Get and log seeds for all LP tokens after upgrade, with comparison to before
            getAndLogLpTokenSeeds(lpTokens, seedsBeforeUpgrade);

            maxBeanMaxLpGpPerBdvRatio = bs.getMaxBeanMaxLpGpPerBdvRatio();
            console.log("maxBeanMaxLpGpPerBdvRatio sunrise:", maxBeanMaxLpGpPerBdvRatio);

            // Log beanToMaxLpGpPerBdvRatio
            uint256 beanToMaxLpGpPerBdvRatio = bs.getBeanToMaxLpGpPerBdvRatio();
            console.log("beanToMaxLpGpPerBdvRatio sunrise:", beanToMaxLpGpPerBdvRatio);
        }

        // Now fork from a block where we're over peg, continue sunrising until beanToMaxLpGpPerBdvRatio drops to min
        seasonBlock = 27225727;
        forkMainnetAndUpgradeAllFacets(seasonBlock - 1, vm.envString("BASE_RPC"), PINTO, "InitPI6");
        updateOracleTimeouts(L2_PINTO, false);

        for (uint256 i; i < 35; i++) {
            warpToNextSeasonTimestamp();

            // call sunrise
            bs.sunrise();

            // Log season number
            console.log("season number:", bs.time().current);

            console.log("--- Seeds (Grown Stalk Per BDV Per Season) After Upgrade ---");

            // Get Bean seeds after upgrade
            uint256[] memory beanSeedsAfter = bs.stalkEarnedPerSeason(beanArray);
            console.log(
                "Pinto\t\t Seeds:",
                formatSeedsValue(beanSeedsAfter[0]),
                "\tSeeds difference:",
                formatSeedsValue(uint256(int256(int256(beanSeeds[0]) - int256(beanSeedsAfter[0]))))
            );

            // Get and log seeds for all LP tokens after upgrade, with comparison to before
            getAndLogLpTokenSeeds(lpTokens, seedsBeforeUpgrade);

            maxBeanMaxLpGpPerBdvRatio = bs.getMaxBeanMaxLpGpPerBdvRatio();
            console.log("maxBeanMaxLpGpPerBdvRatio sunrise:", maxBeanMaxLpGpPerBdvRatio);

            // Log beanToMaxLpGpPerBdvRatio
            uint256 beanToMaxLpGpPerBdvRatio = bs.getBeanToMaxLpGpPerBdvRatio();
            console.log("beanToMaxLpGpPerBdvRatio sunrise:", beanToMaxLpGpPerBdvRatio);
        }
    }

    /**
     * @notice Helper function to format seeds value with a decimal point
     * @param seedsValue The seeds value to format (e.g., 1835240)
     * @return A string representation with decimal point (e.g., "1.835240")
     */
    function formatSeedsValue(uint256 seedsValue) internal pure returns (string memory) {
        // Handle the case where seedsValue is 0
        if (seedsValue == 0) return "0.000000";

        // Convert to string
        string memory valueStr = seedsValue.toString();

        // Get the length of the string
        uint256 length = bytes(valueStr).length;

        if (length <= 6) {
            // If less than 6 digits, pad with leading zeros
            string memory result = "0.";
            for (uint256 i = 0; i < 6 - length; i++) {
                result = string(abi.encodePacked(result, "0"));
            }
            return string(abi.encodePacked(result, valueStr));
        } else {
            // If more than 6 digits, insert decimal point
            bytes memory valueBytes = bytes(valueStr);
            bytes memory resultBytes = new bytes(length + 1); // +1 for the decimal point

            for (uint256 i = 0; i < length - 6; i++) {
                resultBytes[i] = valueBytes[i];
            }
            resultBytes[length - 6] = ".";
            for (uint256 i = length - 6; i < length; i++) {
                resultBytes[i + 1] = valueBytes[i];
            }

            return string(resultBytes);
        }
    }

    /**
     * @notice Helper function to get LP token name from address
     * @param lpToken The LP token address
     * @return The name of the LP token, or "Unknown LP" if not found
     */
    function getLpTokenName(address lpToken) internal view returns (string memory) {
        bytes memory nameBytes = bytes(lpTokenNames[lpToken]);
        if (nameBytes.length > 0) {
            return lpTokenNames[lpToken];
        }
        return "Unknown LP";
    }

    /**
     * @notice Helper function to get and log seeds for LP tokens
     * @param lpTokens Array of LP token addresses
     * @param previousSeeds Optional array of previous seeds values for comparison
     * @return Array of seeds values for each LP token
     */
    function getAndLogLpTokenSeeds(
        address[] memory lpTokens,
        uint256[] memory previousSeeds
    ) internal view returns (uint256[] memory) {
        // Get seeds for all LP tokens
        uint256[] memory seeds = bs.stalkEarnedPerSeason(lpTokens);

        for (uint256 i; i < lpTokens.length; i++) {
            // Format and log token info
            string memory tokenInfo = string(abi.encodePacked(getLpTokenName(lpTokens[i])));
            // console.log(tokenInfo);

            // Format the seeds value
            string memory seedsValue = formatSeedsValue(seeds[i]);

            // If previous seeds are provided, calculate and log the difference on the same line
            if (previousSeeds.length > 0) {
                int256 seedsDiff = int256(seeds[i]) - int256(previousSeeds[i]);
                string memory diffValue;

                if (seedsDiff >= 0) {
                    diffValue = string(
                        abi.encodePacked("Seeds difference: ", formatSeedsValue(uint256(seedsDiff)))
                    );
                } else {
                    diffValue = string(
                        abi.encodePacked(
                            "Seeds difference: -",
                            formatSeedsValue(uint256(-seedsDiff))
                        )
                    );
                }

                // Log seeds and difference on the same line with tab separation
                console.log(
                    string(abi.encodePacked(tokenInfo, "\t Seeds: ", seedsValue, "\t", diffValue))
                );
            } else {
                // Just log seeds if no comparison is needed
                console.log(string(abi.encodePacked("Seeds: ", seedsValue)));
            }
        }

        return seeds;
    }
}

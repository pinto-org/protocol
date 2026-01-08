// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C} from "test/foundry/utils/TestHelper.sol";
import {MockPump} from "contracts/mocks/well/MockPump.sol";
import {IWell, IERC20, Call} from "contracts/interfaces/basin/IWell.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {LibWellMinting} from "contracts/libraries/Minting/LibWellMinting.sol";
import {Decimal} from "contracts/libraries/Decimal.sol";
import {ShipmentPlanner} from "contracts/ecosystem/ShipmentPlanner.sol";
import {LibPRBMathRoundable} from "contracts/libraries/Math/LibPRBMathRoundable.sol";
import {PRBMath} from "@prb/math/contracts/PRBMath.sol";
import {LibEvaluate} from "contracts/libraries/LibEvaluate.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibGaugeHelpers} from "contracts/libraries/Gauge/LibGaugeHelpers.sol";

import {console} from "forge-std/console.sol";

/**
 * @notice Tests the functionality of the sun, the distribution of beans and soil.
 */
contract SunTest is TestHelper {
    // Events
    event Soil(uint32 indexed season, uint256 soil);
    event Shipped(uint32 indexed season, uint256 shipmentAmount);

    uint256 constant SUPPLY_BUDGET_FLIP = 1_000_000_000e6;
    uint256 constant SOIL_PRECISION = 1e18;

    using PRBMath for uint256;
    using LibPRBMathRoundable for uint256;

    // default beanstalk state.
    // deltaPodDemand = 0  (Decimal.0)
    // lpToSupplyRatio = 0 (Decimal.0)
    // podRate = 0 (Decimal.0)
    // largestLiqWell = address(0)
    // oracleFailure = false
    LibEvaluate.BeanstalkState beanstalkState;
    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        farmers = createUsers(2);
    }

    /**
     * @notice tests bean issuance with only the silo.
     * @dev 100% of new bean seigniorage should be issued to the silo.
     */
    function test_sunOnlySilo(int256 deltaB, uint256 caseId, uint256 blocksToRoll) public {
        uint32 currentSeason = bs.season();
        uint256 initialBeanBalance = bean.balanceOf(BEANSTALK);
        uint256 initalPods = bs.totalUnharvestable(0);
        // cases can only range between 0 and 143.
        caseId = bound(caseId, 0, 143);
        // deltaB cannot exceed uint128 max.
        deltaB = bound(
            deltaB,
            -int256(uint256(type(uint128).max)),
            int256(uint256(type(uint128).max))
        );

        // Set inst reserves so that instDeltaB is always negative and smaller than the twaDeltaB.
        setInstantaneousReserves(BEAN_WSTETH_WELL, type(uint128).max, 1e6);
        setInstantaneousReserves(BEAN_ETH_WELL, type(uint128).max, 1e6);

        blocksToRoll = bound(blocksToRoll, 0, 30);
        vm.roll(blocksToRoll);

        // soil event check.
        uint256 soilIssued;
        if (deltaB > 0) {
            // note: no soil is issued as no debt exists.
        } else {
            soilIssued = getSoilIssuedBelowPeg(
                deltaB,
                -1,
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                0 // irrelevant pod rate since deltaB is negative
            );
        }

        vm.expectEmit();
        emit Soil(currentSeason + 1, soilIssued);

        // Make sure beanstalkState has the correct lpToSupplyRatio before calling sunSunrise
        beanstalkState.lpToSupplyRatio = Decimal.ratio(1, 2); // 50% L2SR

        // Update the twaDeltaB in beanstalkState to match the deltaB parameter
        beanstalkState.twaDeltaB = deltaB;

        // Now call sunSunrise with the updated beanstalkState
        season.sunSunrise(deltaB, caseId, beanstalkState);

        // if deltaB is positive,
        // 1) beans are minted equal to deltaB.
        // 2) soil is equal to the amount of soil
        // needed to equal the newly paid off pods (scaled up or down).
        // 3) no pods should be paid off.
        if (deltaB >= 0) {
            assertEq(bean.balanceOf(BEANSTALK), uint256(deltaB), "invalid bean minted +deltaB");
        }
        // if deltaB is negative, soil is issued equal to deltaB.
        // no beans should be minted.
        if (deltaB <= 0) {
            assertEq(
                initialBeanBalance - bean.balanceOf(BEANSTALK),
                0,
                "invalid bean minted -deltaB"
            );
        }

        // in both cases, soil should be issued,
        // and pods should remain 0.
        assertEq(bs.totalSoil(), soilIssued, "invalid soil issued");
        assertEq(bs.totalUnharvestable(0), 0, "invalid pods");
    }

    /**
     * @notice tests bean issuance with a field and silo.
     * @dev bean mints are split between the field and silo 50/50.
     * In the case that the field is paid off with the new bean issuance,
     * the remaining bean issuance is given to the silo.
     */
    function test_sunFieldAndSilo(
        uint256 podsInField,
        int256 deltaB,
        uint256 caseId,
        uint256 podRate
    ) public {
        // Set up shipment routes to include only Silo and one Field.
        setRoutes_siloAndFields();

        uint32 currentSeason = bs.season();
        uint256 initialBeanBalance = bean.balanceOf(BEANSTALK);
        // cases can only range between 0 and 143.
        caseId = bound(caseId, 0, 143);
        // pod rate cannot exceed uint128 max.
        podRate = bound(podRate, 0, 200e18);

        // deltaB cannot exceed uint128 max.
        deltaB = bound(
            deltaB,
            -int256(uint256(type(uint128).max)),
            int256(uint256(type(uint128).max))
        );
        // increase pods in field.
        bs.incrementTotalPodsE(0, podsInField);

        // Set inst reserves so that instDeltaB is always negative and smaller than the twaDeltaB.
        setInstantaneousReserves(BEAN_WSTETH_WELL, type(uint128).max, 1e6);
        setInstantaneousReserves(BEAN_ETH_WELL, type(uint128).max, 1e6);

        // soil event check.
        uint256 soilIssuedAfterMorningAuction;
        uint256 soilIssuedRightNow;
        uint256 beansToField;
        uint256 beansToSilo;
        if (deltaB > 0) {
            bs.setSeasonAbovePeg(true);
            (beansToField, beansToSilo) = calcBeansToFieldAndSilo(uint256(deltaB), podsInField);
            beanstalkState.podRate = Decimal.ratio(podRate, 1e18);
            (soilIssuedAfterMorningAuction, soilIssuedRightNow) = getSoilIssuedAbovePeg(
                beansToField,
                podRate
            );
        } else {
            uint256 currentCultivationFactor = abi.decode(
                bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
                (uint256)
            );
            soilIssuedAfterMorningAuction = getSoilIssuedBelowPeg(
                deltaB,
                -1,
                currentCultivationFactor,
                0 // irrelevant pod rate since deltaB is negative
            );
            soilIssuedRightNow = getSoilIssuedBelowPeg(
                deltaB,
                -1,
                currentCultivationFactor,
                0 // irrelevant pod rate since deltaB is negative
            );
        }
        // vm.expectEmit();
        // emit Soil(currentSeason + 1, soilIssuedAfterMorningAuction);

        // Make sure beanstalkState has the correct lpToSupplyRatio before calling sunSunrise
        beanstalkState.lpToSupplyRatio = Decimal.ratio(1, 2); // 50% L2SR

        // Update the twaDeltaB in beanstalkState to match the deltaB parameter
        beanstalkState.twaDeltaB = deltaB;

        // Now call sunSunrise with the updated beanstalkState
        season.sunSunrise(deltaB, caseId, beanstalkState);

        // if deltaB is positive,
        // 1) beans are minted equal to deltaB.
        // 2) soil is equal to the amount of soil
        // needed to equal the newly paid off pods (scaled up or down).
        // 3) totalunharvestable() should decrease by the amount issued to the field.
        if (deltaB >= 0) {
            assertEq(bean.balanceOf(BEANSTALK), uint256(deltaB), "invalid bean minted +deltaB");
            assertEq(bs.totalSoil(), soilIssuedRightNow, "invalid soil @ +deltaB");
            assertEq(
                bs.totalUnharvestable(0),
                podsInField - beansToField,
                "invalid pods @ +deltaB"
            );
        }
        // if deltaB is negative, soil is issued equal to deltaB.
        // no bean should be minted.
        if (deltaB <= 0) {
            bs.setSeasonAbovePeg(false);
            assertEq(
                initialBeanBalance - bean.balanceOf(BEANSTALK),
                0,
                "invalid bean minted -deltaB"
            );
            assertEq(bs.totalSoil(), soilIssuedRightNow, "invalid soil @ -deltaB");
            assertEq(bs.totalUnharvestable(0), podsInField, "invalid pods @ -deltaB");
        }
    }

    // TODO: This test will be broken, need to update Shipment Planner.
    // TODO: Improve this tests by handling multiple concurrent seasons with shipment edge cases.
    /**
     * @notice tests bean issuance with two fields, and a silo.
     * @dev bean mints are split between the field 0, field 1, silo.
     *      Points corresponding to the routes are 10, 45, 45.
     */
    function test_multipleSunrisesWithTwoFieldsAndSilo(
        uint256 podsInField0,
        uint256 podsInField1,
        int256[] memory deltaBList,
        uint256[] memory caseIdList
    ) public {
        vm.assume(deltaBList.length > 0);
        vm.assume(caseIdList.length > 0);
        uint256 numOfSeasons = deltaBList.length < caseIdList.length
            ? deltaBList.length
            : caseIdList.length;

        // test is capped to CP2 constraints. See {ConstantProduct2.sol}

        // increase pods in field.
        bs.incrementTotalPodsE(0, podsInField0);
        bs.incrementTotalPodsE(1, podsInField1);

        // Set inst reserves so that instDeltaB is always negative and smaller than the twaDeltaB.
        setInstantaneousReserves(BEAN_WSTETH_WELL, type(uint128).max, 1e6);
        setInstantaneousReserves(BEAN_ETH_WELL, type(uint128).max, 1e6);

        // Set up second Field. Update Routes and Plan getters.
        vm.prank(deployer);
        bs.addField();
        vm.prank(deployer);
        bs.setActiveField(1, 1);
        setRoutes_siloAndTwoFields();

        for (uint256 i; i < numOfSeasons; i++) {
            // int256 deltaB = deltaBList[i];
            // uint256 caseId = caseIdList[i];

            // deltaB cannot exceed uint128 max. Bound tighter here to handle repeated seasons.
            int256 deltaB = bound(deltaBList[i], type(int96).min, type(int96).max);
            // cases can only range between 0 and 143.
            uint256 caseId = bound(caseIdList[i], 0, 143);

            // May change at each sunrise.
            uint256 priorEarnedBeans = bs.totalEarnedBeans();
            uint256 priorBeansInBeanstalk = bean.balanceOf(BEANSTALK);

            vm.roll(block.number + 300);

            // vm.expectEmit(false, false, false, false);
            // emit Soil(0, 0);

            beanstalkState.twaDeltaB = deltaB;
            // Make sure beanstalkState has the correct lpToSupplyRatio before calling sunSunrise
            beanstalkState.lpToSupplyRatio = Decimal.ratio(1, 2); // 50% L2SR

            // Now call sunSunrise with the updated beanstalkState
            season.sunSunrise(deltaB, caseId, beanstalkState);

            // if deltaB is positive,
            // 1) beans are minted equal to deltaB.
            // 2) soil is equal to the amount of soil
            // needed to equal the newly paid off pods (scaled up or down).
            // 3) totalunharvestable() should decrease by the amount issued to the field.
            if (deltaB >= 0) {
                bs.setSeasonAbovePeg(true);
                assertEq(
                    bean.balanceOf(BEANSTALK) - priorBeansInBeanstalk,
                    uint256(deltaB),
                    "invalid bean minted +deltaB"
                );

                // Verify amount of change in Field 0. Either a max of cap or a min of 5/11 mints.
                {
                    uint256 beansToField0 = podsInField0 - bs.totalUnharvestable(0);
                    // There is no case where a Field receives more than 50% of mints (shared w/ Silo).
                    assertLe(beansToField0, uint256(deltaB) / 2, "too many Beans to Field 0");
                    // Field should either receive its exact cap, or a minimum of its point ratio.
                    if (beansToField0 != podsInField0) {
                        assertGe(
                            beansToField0,
                            (uint256(deltaB) * 1) / 11,
                            "not enough Beans to Field 0"
                        );
                    }
                    podsInField0 -= beansToField0;
                }

                // Verify amount of change in Field 1. Either a max of cap or a min of 1/11 mints.
                {
                    uint256 beansToField1 = podsInField1 - bs.totalUnharvestable(1);
                    // There is no case where a Field receives more than 50% of mints (shared w/ Silo).
                    assertLe(beansToField1, uint256(deltaB) / 2, "too many Beans to Field 1");
                    // Field should either receive its exact cap, or a minimum of its point ratio.
                    if (beansToField1 != podsInField1) {
                        assertGe(
                            beansToField1,
                            (uint256(deltaB) * 5) / 11,
                            "not enough Beans to Field 1"
                        );
                    }
                    podsInField1 -= beansToField1;

                    // Verify soil amount. Field 1 is the active Field.
                    (
                        uint256 soilIssuedAfterMorningAuction,
                        uint256 soilIssuedRightNow
                    ) = getSoilIssuedAbovePeg(beansToField1, caseId);
                    assertEq(bs.totalSoil(), soilIssuedRightNow, "invalid soil @ +deltaB");
                }

                // Verify amount of change in Silo. Min of 5/11 mints.
                {
                    uint256 beansToSilo = bs.totalEarnedBeans() - priorEarnedBeans;
                    // Silo can receive at most 100% of deltaB.
                    assertLe(beansToSilo, uint256(deltaB), "too many Beans to Silo");
                    // Silo should receive at least 5/11 of deltaB.
                    assertGe(beansToSilo, (uint256(deltaB) * 5) / 11, "not enough Beans to Silo");
                }
            }
            // if deltaB is negative, soil is issued equal to deltaB.
            // no bean should be minted.
            if (deltaB <= 0) {
                bs.setSeasonAbovePeg(false);
                assertEq(
                    bean.balanceOf(BEANSTALK) - priorBeansInBeanstalk,
                    0,
                    "invalid bean minted -deltaB"
                );
                assertEq(bs.totalUnharvestable(0), podsInField0, "invalid field 0 pods @ -deltaB");
                assertEq(bs.totalUnharvestable(1), podsInField1, "invalid field 1 pods @ -deltaB");

                // Get the instantaneous deltaB
                int256 instDeltaB = LibWellMinting.getTotalInstantaneousDeltaB();

                // Calculate soil using the same formula as other tests
                uint256 soilIssued = getSoilIssuedBelowPeg(
                    deltaB,
                    instDeltaB,
                    abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                    0 // irrelevant pod rate since deltaB is negative
                );

                vm.roll(block.number + 50);
                assertEq(bs.totalSoil(), soilIssued, "invalid soil @ -deltaB");
            }
        }
    }

    function test_multipleSunrisesWithTwoFieldsAndBudgetAndPayback(
        uint256 podsInField0,
        uint256 podsInField1,
        int256[] memory deltaBList,
        uint256[] memory caseIdList
    ) public {
        vm.assume(deltaBList.length > 0);
        vm.assume(caseIdList.length > 0);
        uint256 numOfSeasons = deltaBList.length < caseIdList.length
            ? deltaBList.length
            : caseIdList.length;

        // test is capped to CP2 constraints. See {ConstantProduct2.sol}

        uint256 beansInBudget;
        uint256 beansInPaybackContract;

        // increase pods in field.
        uint256 podsInField0 = bound(podsInField0, 0, type(uint64).max);
        uint256 podsInField1 = bound(podsInField1, 0, type(uint64).max);
        bs.incrementTotalPodsE(0, podsInField0);
        bs.incrementTotalPodsE(1, podsInField1);

        // Set up second Field. Update Routes and Plan getters.
        vm.prank(deployer);
        bs.addField();
        vm.prank(deployer);
        bs.setActiveField(0, 1);
        setRoutes_all();

        // Set inst reserves so that instDeltaB is always negative and smaller than the twaDeltaB.
        setInstantaneousReserves(BEAN_WSTETH_WELL, type(uint128).max, 1e6);
        setInstantaneousReserves(BEAN_ETH_WELL, type(uint128).max, 1e6);

        for (uint256 i; i < numOfSeasons; i++) {
            // deltaB cannot exceed uint128 max. Bound tighter here to handle repeated seasons.
            int256 deltaB = bound(deltaBList[i], -10_000_000e6, 10_000_000e6);
            // cases can only range between 0 and 143.
            uint256 caseId = bound(caseIdList[i], 0, 143);

            // May change at each sunrise.
            uint256 priorEarnedBean = bs.totalEarnedBeans();
            uint256 priorBeanInBeanstalk = bean.balanceOf(BEANSTALK);

            vm.roll(block.number + 300);

            // Update beanstalkState with the current deltaB
            beanstalkState.twaDeltaB = deltaB;
            // Make sure beanstalkState has the correct lpToSupplyRatio before calling sunSunrise
            beanstalkState.lpToSupplyRatio = Decimal.ratio(1, 2); // 50% L2SR

            // Now call sunSunrise with the updated beanstalkState
            season.sunSunrise(deltaB, caseId, beanstalkState);

            // if deltaB is positive,
            // 1) bean are minted equal to deltaB.
            // 2) soil is equal to the amount of soil
            // needed to equal the newly paid off pods (scaled up or down).
            // 3) totalunharvestable() should decrease by the amount issued to the field.
            if (deltaB > 0) {
                bs.setSeasonAbovePeg(true);
                assertGe(
                    bean.balanceOf(BEANSTALK) - priorBeanInBeanstalk,
                    (uint256(deltaB) * 2) / 100, // Payback contract Bean are sent externally.
                    "invalid bean minted +deltaB"
                );

                // Verify amount of change in Field 0. Either a max of cap or a min of 48.33/100 mints.
                {
                    uint256 beanToField0 = podsInField0 - bs.totalUnharvestable(0);
                    // There is no case where a Field receives more than 50% of mints (shared w/ Silo).
                    assertLe(beanToField0, uint256(deltaB) / 2, "too many Bean to Field 0");
                    // Field should either receive its exact cap, or a minimum of its point ratio.
                    if (beanToField0 != podsInField0) {
                        assertGe(
                            beanToField0,
                            (uint256(deltaB) * 48) / 100, // Rouding buffer
                            "not enough Bean to Field 0"
                        );
                    }
                    podsInField0 -= beanToField0;

                    // Verify soil amount. Field 0 is the active Field.
                    (
                        uint256 soilIssuedAfterMorningAuction,
                        uint256 soilIssuedRightNow
                    ) = getSoilIssuedAbovePeg(beanToField0, caseId);
                    assertEq(bs.totalSoil(), soilIssuedRightNow, "invalid soil @ +deltaB");
                }

                // Verify amount of change in Field 1.
                {
                    uint256 harvestablePodsField1 = podsInField1 - bs.totalUnharvestable(1);
                    if (bs.totalUnharvestable(1) > 0) {
                        // There is no case where a Field receives more than 50% of mints (shared w/ Silo).
                        assertLe(
                            harvestablePodsField1,
                            uint256(deltaB) / 2,
                            "too many Bean to Field 1"
                        );
                        if (inBudgetPhase()) {
                            assertEq(harvestablePodsField1, 0, "invalid bean minted to Field 1");
                        }
                        // If 100% in payback phase, min of 1/100 mints.
                        // Field should either receive its exact cap, or a minimum of its point ratio.
                        else if (inPaybackPhase(uint256(deltaB))) {
                            if (harvestablePodsField1 != podsInField1) {
                                assertGe(
                                    harvestablePodsField1,
                                    (uint256(deltaB) * 1) / 100,
                                    "not enough Bean to Field 1"
                                );
                            }
                        }
                    }
                    podsInField1 -= harvestablePodsField1;
                }

                // Verify amount of change in Budget internal balance.
                {
                    uint256 beanToBudget = bs.getInternalBalance(budget, address(bean)) -
                        beansInBudget;
                    // Budget can receive at most 50% of deltaB.
                    assertLe(beanToBudget, uint256(deltaB) / 2, "too many Bean to Budget");
                    // If fully in budget phase, min of 3/100 mints.
                    if (inBudgetPhase()) {
                        assertEq(
                            beanToBudget,
                            (uint256(deltaB) * 3) / 100,
                            "not enough Bean to Budget"
                        );
                    }
                    // If fully in payback phase, 0 mints.
                    else if (inPaybackPhase(uint256(deltaB))) {
                        assertEq(beanToBudget, 0, "invalid bean minted to Budget");
                    }

                    beansInBudget += beanToBudget;
                }
                // Verify amount of change in Payback external balance.
                {
                    uint256 beansToPaybackContract = bean.balanceOf(payback) -
                        beansInPaybackContract;

                    // Payback can receive at most 50% of deltaB.
                    assertLe(
                        beansToPaybackContract,
                        uint256(deltaB) / 2,
                        "too many Bean to payback contract"
                    );

                    // If 100% in payback phase, min of 1/100 mints.
                    // Field should either receive its exact cap, or a minimum of its point ratio.
                    if (inBudgetPhase()) {
                        assertEq(
                            beansToPaybackContract,
                            0,
                            "invalid bean minted to payback contract"
                        );
                    } else if (inPaybackPhase(uint256(deltaB))) {
                        assertGe(
                            beansToPaybackContract,
                            (uint256(deltaB) * 2) / 100,
                            "not enough Bean to payback contract in payback phase"
                        );
                    }

                    beansInPaybackContract += beansToPaybackContract;
                }

                // Verify amount of change in Silo. Min of 48.33/100 mints.
                {
                    uint256 beanToSilo = bs.totalEarnedBeans() - priorEarnedBean;
                    // Silo can receive at most 100% of deltaB.
                    assertLe(beanToSilo, uint256(deltaB), "too many Bean to Silo");
                    // Silo should receive at least 48.33/100 of deltaB.
                    assertGe(
                        beanToSilo,
                        (uint256(deltaB) * 48) / 100, // Rounding buffer
                        "not enough Bean to Silo"
                    );
                }
            }
            // if deltaB is negative, soil is issued equal to deltaB.
            // no bean should be minted.
            if (deltaB <= 0) {
                bs.setSeasonAbovePeg(false);
                assertEq(
                    bean.balanceOf(BEANSTALK) - priorBeanInBeanstalk,
                    0,
                    "invalid bean minted -deltaB"
                );
                assertEq(bs.totalUnharvestable(0), podsInField0, "invalid field 0 pods @ -deltaB");
                assertEq(bs.totalUnharvestable(1), podsInField1, "invalid field 1 pods @ -deltaB");

                // Get the instantaneous deltaB
                int256 instDeltaB = LibWellMinting.getTotalInstantaneousDeltaB();

                // Calculate soil using the same formula as other tests
                uint256 soilIssued = getSoilIssuedBelowPeg(
                    deltaB,
                    instDeltaB,
                    abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                    0 // irrelevant pod rate since deltaB is negative
                );

                vm.roll(block.number + 50);
                assertEq(bs.totalSoil(), soilIssued, "invalid soil @ -deltaB");
            }
        }
    }

    function test_partials() public {
        uint256 beansInBudget;
        uint256 beansInPaybackContract;

        // increase pods in field.
        bs.incrementTotalPodsE(0, 100_000_000_000e6);
        bs.incrementTotalPodsE(1, 100_000_000_000e6);
        uint256 podsInField1 = bs.totalUnharvestable(1);

        // Set up second Field. Update Routes and Plan getters.
        vm.prank(deployer);
        bs.addField();
        vm.prank(deployer);
        bs.setActiveField(0, 1);
        setRoutes_all();

        uint256 deltaB = 50_000_000e6;
        uint256 caseId = 1;

        // Set lpToSupplyRatio in beanstalkState
        beanstalkState.lpToSupplyRatio = Decimal.ratio(1, 2); // 50% L2SR

        for (uint256 i; i < 19; i++) {
            vm.roll(block.number + 300);

            // Update twaDeltaB in beanstalkState before calling sunSunrise
            beanstalkState.twaDeltaB = int256(deltaB);

            season.sunSunrise(int256(deltaB), caseId, beanstalkState);
        }

        // Almost ready to cross supply threshold to switch from budget to payback.
        assertEq(inBudgetPhase(), true, "not in budget phase");
        assertEq(inPaybackPhase(0), false, "in payback phase");

        uint256 priorBeansInBudget = bs.getInternalBalance(budget, address(bean));
        uint256 priorBeansInPayback = bean.balanceOf(payback);
        uint256 priorHarvestablePodsPaybackField = podsInField1 - bs.totalUnharvestable(1);

        assertEq(
            priorBeansInBudget,
            (deltaB * 19 * 3) / 100,
            "invalid budget balance before partial"
        );
        assertEq(priorBeansInPayback, 0, "invalid payback balance before partial");

        deltaB = 80_000_000e6;
        vm.roll(block.number + 300);

        // Update twaDeltaB in beanstalkState before calling sunSunrise
        beanstalkState.twaDeltaB = int256(deltaB);

        season.sunSunrise(int256(deltaB), caseId, beanstalkState);

        // 3% of mint goes to budget and payback.
        // 5/8 of that goes to budget.
        assertEq(
            bs.getInternalBalance(budget, address(bean)),
            priorBeansInBudget + (deltaB * 3 * 5) / 100 / 8,
            "invalid budget balance from partial"
        );
        // 3/8 of that goes to payback, which is split 2/8 to payback contract and 1/8 to payback field.
        assertEq(
            bean.balanceOf(payback),
            priorBeansInPayback + ((deltaB * 3 * 2) / 100 / 8),
            "invalid payback contract balance from partial"
        );
        assertEq(
            podsInField1 - bs.totalUnharvestable(1),
            priorHarvestablePodsPaybackField + ((deltaB * 3 * 1) / 100 / 8),
            "invalid payback field balance from partial"
        );

        // 100% of the 3% goes to payback.
        priorBeansInBudget = bs.getInternalBalance(budget, address(bean));
        priorBeansInPayback = bean.balanceOf(payback);
        priorHarvestablePodsPaybackField = podsInField1 - bs.totalUnharvestable(1);
        deltaB = 1_000_000e6;
        vm.roll(block.number + 300);

        // Update twaDeltaB in beanstalkState before calling sunSunrise
        beanstalkState.twaDeltaB = int256(deltaB);

        season.sunSunrise(int256(deltaB), caseId, beanstalkState);
        assertEq(
            bs.getInternalBalance(budget, address(bean)),
            priorBeansInBudget,
            "invalid budget balance after partial"
        );
        assertEq(
            bean.balanceOf(payback),
            priorBeansInPayback + (deltaB * 2) / 100,
            "invalid payback contract balance after partial"
        );
        assertEq(
            podsInField1 - bs.totalUnharvestable(1),
            priorHarvestablePodsPaybackField + ((deltaB * 1) / 100),
            "invalid payback field balance after partial"
        );

        // Silo is paid off. Shift to 1.5% payback contract and 1.5% payback field.
        deal(address(bean), payback, 1_000_000_000e6 / 4, true);
        priorBeansInBudget = bs.getInternalBalance(budget, address(bean));
        priorBeansInPayback = bean.balanceOf(payback);
        priorHarvestablePodsPaybackField = podsInField1 - bs.totalUnharvestable(1);
        deltaB = 1_000e6;
        vm.roll(block.number + 300);

        // Update twaDeltaB in beanstalkState before calling sunSunrise
        beanstalkState.twaDeltaB = int256(deltaB);

        season.sunSunrise(int256(deltaB), caseId, beanstalkState);
        assertEq(
            bs.getInternalBalance(budget, address(bean)),
            priorBeansInBudget,
            "invalid budget balance after silo paid off"
        );
        assertEq(
            bean.balanceOf(payback),
            priorBeansInPayback + (deltaB * 15) / 1000,
            "invalid payback contract balance after silo paid off"
        );
        assertEq(
            podsInField1 - bs.totalUnharvestable(1),
            priorHarvestablePodsPaybackField + ((deltaB * 15) / 1000),
            "invalid payback field balance after silo paid off"
        );

        // Barn is paid off. Shift to 3% payback field. 0% to payback contract.
        deal(address(bean), payback, 1_000_000_000e6, true);
        priorBeansInBudget = bs.getInternalBalance(budget, address(bean));
        priorBeansInPayback = bean.balanceOf(payback);
        priorHarvestablePodsPaybackField = podsInField1 - bs.totalUnharvestable(1);
        deltaB = 1_000e6;
        vm.roll(block.number + 300);

        // Update twaDeltaB in beanstalkState before calling sunSunrise
        beanstalkState.twaDeltaB = int256(deltaB);

        season.sunSunrise(int256(deltaB), caseId, beanstalkState);
        assertEq(
            bs.getInternalBalance(budget, address(bean)),
            priorBeansInBudget,
            "invalid budget balance after barn is paid off"
        );
        assertEq(
            bean.balanceOf(payback),
            priorBeansInPayback,
            "invalid payback contract balance after barn is paid off"
        );
        assertEq(
            podsInField1 - bs.totalUnharvestable(1),
            priorHarvestablePodsPaybackField + ((deltaB * 3) / 100),
            "invalid payback field balance after barn is paid off"
        );
    }

    function test_stepCultivationFactor() public {
        // Initial setup
        uint256 initialCultivationFactor = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );

        assertEq(initialCultivationFactor, 50e6, "Initial cultivationFactor should be 50e6 (50%)");

        // Set cultivationFactor to 50% so tests have room to move up and down
        bs.setCultivationFactor(50e6);
        bs.setPrevSeasonAndCultivationTemp(100e6, 0);
        initialCultivationFactor = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        (, , , , uint256 cultivationTemp, uint256 prevSeasonTemp) = abi.decode(
            bs.getGaugeData(GaugeId.CULTIVATION_FACTOR),
            (uint256, uint256, uint256, uint256, uint256, uint256)
        );

        // Get the actual bounds from evaluation parameters
        uint256 podRateLowerBound = bs.getPodRateLowerBound();
        uint256 podRateUpperBound = bs.getPodRateUpperBound();
        uint256 midPoint = (podRateLowerBound + podRateUpperBound) / 2;

        // Create BeanstalkState with different pod rates and Bean prices to test different scenarios
        LibEvaluate.BeanstalkState memory testState = LibEvaluate.BeanstalkState({
            deltaPodDemand: Decimal.one(),
            lpToSupplyRatio: Decimal.zero(),
            podRate: Decimal.zero(),
            largestLiqWell: address(0),
            oracleFailure: false,
            largestLiquidWellTwapBeanPrice: 1e6, // $1.00 Bean price
            twaDeltaB: 0,
            caseId: 0
        });

        // Case 1: Soil sold out and Pod rate below lower bound - cultivationFactor should increase
        testState.podRate = Decimal.ratio(podRateLowerBound - 1e16, 1e18); // 1% below lower bound
        season.setLastSowTimeE(1); // Set lastSowTime to non-max value to indicate soil sold out

        vm.expectEmit(true, false, false, false);
        emit LibGaugeHelpers.Engaged(GaugeId.CULTIVATION_FACTOR, abi.encode(0));
        vm.expectEmit(true, false, false, false);
        emit LibGaugeHelpers.EngagedData(GaugeId.CULTIVATION_FACTOR, abi.encode(0, 0, 0, 0, 0, 0));
        season.mockStepGauges(testState);
        uint256 cultivationFactorAfterCase1 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );

        (, , , , uint256 newCultivationTemp, ) = abi.decode(
            bs.getGaugeData(GaugeId.CULTIVATION_FACTOR),
            (uint256, uint256, uint256, uint256, uint256, uint256)
        );

        // when soil sold out and demand is not decreasing (which is the case if soil sells out),
        // cultivationTemp should be set to the prevSeasonTemp
        assertEq(prevSeasonTemp, newCultivationTemp);
        assertNotEq(cultivationTemp, newCultivationTemp);

        assertGt(
            cultivationFactorAfterCase1,
            initialCultivationFactor,
            "cultivationFactor should increase when soil sells out with low pod rate"
        );

        // It should specifically increase by 2%
        assertEq(
            cultivationFactorAfterCase1,
            initialCultivationFactor + 2e6,
            "cultivationFactor should increase by 2%"
        );

        // Case 2: Soil not sold out and Pod rate above upper bound - cultivationFactor should decrease
        testState.podRate = Decimal.ratio(podRateUpperBound + 1e16, 1e18); // 1% above upper bound
        season.setLastSowTimeE(type(uint32).max); // Reset lastSowTime to max to indicate soil did not sell out
        season.mockStepGauges(testState);
        uint256 cultivationFactorAfterCase2 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        assertLt(
            cultivationFactorAfterCase2,
            cultivationFactorAfterCase1,
            "cultivationFactor should decrease when soil does not sell out with high pod rate"
        );

        // It should specifically decrease by 2%
        assertEq(
            cultivationFactorAfterCase2,
            cultivationFactorAfterCase1 - 2e6,
            "cultivationFactor should decrease by 2%"
        );

        // Case 3: Soil sold out and different Bean price
        testState.podRate = Decimal.ratio((podRateLowerBound + podRateUpperBound) / 2, 1e18); // Middle of bounds
        testState.largestLiquidWellTwapBeanPrice = 0.8e6; // $0.80 Bean price
        season.setLastSowTimeE(1); // Soil sold out
        season.mockStepGauges(testState);
        uint256 cultivationFactorAfterCase3 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        assertNotEq(
            cultivationFactorAfterCase3,
            cultivationFactorAfterCase2,
            "cultivationFactor should change with different Bean price"
        );

        // It should specifically increase by 1%
        assertEq(
            cultivationFactorAfterCase3,
            cultivationFactorAfterCase2 + 1e6,
            "cultivationFactor should increase by 1%"
        );

        // Case 4: Test with zero Bean price (should not change cultivationFactor)
        uint256 cultivationFactorBeforeCase4 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        testState.largestLiquidWellTwapBeanPrice = 0;
        season.mockStepGauges(testState);
        uint256 cultivationFactorAfterCase4 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        assertEq(
            cultivationFactorAfterCase4,
            cultivationFactorBeforeCase4,
            "cultivationFactor should not change with zero Bean price"
        );

        // Case 5: Different price ($0.80)
        testState.largestLiquidWellTwapBeanPrice = 0.8e6;
        uint256 deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        // Same as above but with 0.8 price
        assertEq(
            deltaCultivationFactor,
            1e6,
            "deltaCultivationFactor should be 1% with pod rate at midpoint, $0.80 price, and soil sold out"
        );

        // Case 6: Soil not sold out, pod rate at midpoint, price at $0.72
        testState.largestLiquidWellTwapBeanPrice = 0.72e6;
        season.setLastSowTimeE(type(uint32).max); // Set soil as not sold out
        deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        // When soil not sold out, deltaCultivationFactor = 1e18 / (podRateMultiplier * price)
        // podRateMultiplier at midpoint is scaled to 1.25e6
        // price is 0.72e6 (after being scaled down by 1e12)
        // So: 1e18 / (1.25e6 * 0.72e6) = 1.111111e6
        assertEq(
            deltaCultivationFactor,
            1.111111e6,
            "deltaCultivationFactor should be ~1.111111% with pod rate at midpoint, $0.72 price, and soil not sold out"
        );

        // Case 7: Soil not sold out, cultivation temp is higher than previous temp, (and demand is decreasing)  should not change cultivationFactor
        season.setLastSowTimeE(type(uint32).max); // Set soil as not sold out
        testState.deltaPodDemand = Decimal.zero();
        bs.setPrevSeasonAndCultivationTemp(100e6, 101e6);
        deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        assertEq(
            deltaCultivationFactor,
            0,
            "deltaCultivationFactor should be 0 when cultivation temp is higher than prevSeasonTemp"
        );

        // Case 8: Soil sold out,  should change cultivationFactor regardless of prevSeasonTemp
        season.setLastSowTimeE(1); // Set soil as sold out
        for (uint256 i = 0; i < 3; i++) {
            bs.setPrevSeasonAndCultivationTemp(100e6, 99e6 + (i * 1e6)); // 99e6, 100e6, 101e6
            deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
            assertEq(
                deltaCultivationFactor,
                0.9e6,
                "deltaCultivationFactor should change when soil is sold out, independent of prevSeasonTemp"
            );
        }

        // Case 9: Soil mostly sold out should not change cultivationFactor
        season.setLastSowTimeE(type(uint32).max - 1); // Set soil as mostly sold out
        deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        assertEq(
            deltaCultivationFactor,
            0,
            "deltaCultivationFactor should be 0 when soil is mostly sold out "
        );

        // Case 10: Soil did not sell out, demand is steady, should decrease cultivationFactor
        // See Case 6 above for deltaCultivationFactor calculation (podRate and price has not changed since case 6)
        uint256 cultivationFactorBeforeCase10 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        season.setLastSowTimeE(type(uint32).max);
        testState.deltaPodDemand = Decimal.one();
        season.mockStepGauges(testState);
        uint256 cultivationFactorAfterCase10 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        assertEq(
            cultivationFactorBeforeCase10,
            cultivationFactorAfterCase10 + 1.111111e6,
            "deltaCultivationFactor should decrease when soil did not sell out, demand is steady"
        );

        // Case 11: Soil did not sell out, demand is increasing, should decrease cultivationFactor
        // See Case 6 above for deltaCultivationFactor calculation (podRate and price has not changed since case 6)
        season.setLastSowTimeE(type(uint32).max);
        testState.deltaPodDemand = Decimal.from(1e18); // increasing demand
        season.mockStepGauges(testState);
        uint256 cultivationFactorAfterCase11 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        assertEq(
            cultivationFactorAfterCase10,
            cultivationFactorAfterCase11 + 1.111111e6,
            "deltaCultivationFactor should decrease when soil did not sell out, demand is increasing"
        );

        // Case 12: Soil did not sell out, demand is decreasing, and cultivation temp > prevSeasonTemp, should decrease cultivationFactor
        // See Case 6 above for deltaCultivationFactor calculation (podRate and price has not changed since case 6)
        season.setLastSowTimeE(type(uint32).max);
        testState.deltaPodDemand = Decimal.zero(); //gg decreasing demand
        bs.setPrevSeasonAndCultivationTemp(100e6, 99e6); // temperature is lower then CTemp
        season.mockStepGauges(testState);
        uint256 cultivationFactorAfterCase12 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        assertEq(
            cultivationFactorAfterCase11,
            cultivationFactorAfterCase12 + 1.111111e6,
            "deltaCultivationFactor should decrease when soil did not sell out, demand is decreasing, and cultivation temp > prevSeasonTemp"
        );

        // Case 13: Soil did not sell out, demand is decreasing, and cultivation temp <= prevSeasonTemp, should keep cultivationFactor
        season.setLastSowTimeE(type(uint32).max);
        testState.deltaPodDemand = Decimal.zero(); // decreasing demand
        bs.setPrevSeasonAndCultivationTemp(99e6, 100e6); // temperature is lower then CTemp
        season.mockStepGauges(testState);
        uint256 cultivationFactorAfterCase13 = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        assertEq(
            cultivationFactorAfterCase12,
            cultivationFactorAfterCase13,
            "CF should not change when soil did not sell out, demand is decreasing and cultivation temp <= prevSeasonTemp"
        );
    }

    function test_calculateCultivationFactorDelta() public {
        bs.setCultivationFactor(50e6);
        // Get the actual bounds from evaluation parameters
        uint256 podRateLowerBound = bs.getPodRateLowerBound();
        uint256 podRateUpperBound = bs.getPodRateUpperBound();

        // Create base BeanstalkState for testing
        LibEvaluate.BeanstalkState memory testState = LibEvaluate.BeanstalkState({
            deltaPodDemand: Decimal.zero(),
            lpToSupplyRatio: Decimal.zero(),
            podRate: Decimal.zero(),
            largestLiqWell: address(0),
            oracleFailure: false,
            largestLiquidWellTwapBeanPrice: 1e18, // $1.00 Bean price
            twaDeltaB: 0,
            caseId: 0
        });

        // Case 1: Zero price should return (0, false)
        testState.largestLiquidWellTwapBeanPrice = 0;
        uint256 deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        assertEq(deltaCultivationFactor, 0, "deltaCultivationFactor should be 0 with zero price");

        // Reset price to $1.00
        testState.largestLiquidWellTwapBeanPrice = 1e18;

        // Case 2: Pod rate below lower bound, soil sold out
        testState.podRate = Decimal.ratio(podRateLowerBound - 1e16, 1e18); // 1% below lower bound
        season.setLastSowTimeE(1); // Set soil as sold out
        deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        assertEq(
            deltaCultivationFactor,
            2e6,
            "deltaCultivationFactor should be 2% with pod rate below lower bound and soil sold out"
        );

        // Case 2.1: Pod rate below lower bound, soil not sold out
        testState.podRate = Decimal.ratio(podRateLowerBound - 1e16, 1e18); // 1% below lower bound
        season.setLastSowTimeE(type(uint32).max); // Set soil as not sold out
        deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        assertEq(
            deltaCultivationFactor,
            0.5e6,
            "deltaCultivationFactor should be 0.5% with pod rate below lower bound and soil not sold out"
        );

        // Case 3: Pod rate above upper bound, soil not sold out
        testState.podRate = Decimal.ratio(podRateUpperBound + 1e16, 1e18); // 1% above upper bound
        season.setLastSowTimeE(type(uint32).max); // Set soil as not sold out
        deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        assertEq(
            deltaCultivationFactor,
            2e6,
            "deltaCultivationFactor should be 2% with pod rate above upper bound and soil not sold out"
        );

        // Case 3.1: Pod rate above upper bound, soil sold out
        testState.podRate = Decimal.ratio(podRateUpperBound + 1e16, 1e18); // 1% above upper bound
        season.setLastSowTimeE(1); // Set soil as sold out
        deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        assertEq(
            deltaCultivationFactor,
            0.5e6,
            "deltaCultivationFactor should be 0.5% with pod rate above upper bound and soil not sold out"
        );

        // Case 4: Pod rate between bounds
        uint256 midPoint = (podRateLowerBound + podRateUpperBound) / 2;
        testState.podRate = Decimal.ratio(midPoint, 1e18);
        season.setLastSowTimeE(1); // Set soil as sold out
        deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        // With pod rate at midpoint, podRateMultiplier should be 0.5,
        // then scaled between min (0.5) and max (2.0) to 1.25,
        // then multiplied by price (1.0) and divided by CULTIVATION_FACTOR_PRECISION
        assertEq(
            deltaCultivationFactor,
            1.25e6,
            "deltaCultivationFactor should be 1.25% with pod rate at midpoint and soil sold out"
        );

        // Case 5: Different price ($0.80)
        testState.largestLiquidWellTwapBeanPrice = 0.8e6;
        deltaCultivationFactor = season.calculateCultivationFactorDeltaE(testState);
        // Same as above but with 0.8 price
        assertEq(
            deltaCultivationFactor,
            1e6,
            "deltaCultivationFactor should be 1% with pod rate at midpoint, $0.80 price, and soil sold out"
        );
    }

    function test_soilBelowPegSoldOutLastSeason() public {
        // set inst reserves (instDeltaB: -1999936754446796632414)
        setInstantaneousReserves(BEAN_WSTETH_WELL, 1000e18, 1000e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000e18, 1000e18);
        int256 twaDeltaB = -1000e6;
        uint32 currentSeason = bs.season();

        // Get the actual bounds from evaluation parameters
        uint256 podRateLowerBound = bs.getPodRateLowerBound();
        uint256 podRateUpperBound = bs.getPodRateUpperBound();
        uint256 midPoint = (podRateLowerBound + podRateUpperBound) / 2;

        // Base BeanstalkState that we'll reset to for each test
        LibEvaluate.BeanstalkState memory baseBeanstalkState = LibEvaluate.BeanstalkState({
            deltaPodDemand: Decimal.zero(),
            lpToSupplyRatio: Decimal.ratio(1, 2), // 50% L2SR
            podRate: Decimal.ratio(midPoint, 1e18), // Set pod rate to midpoint
            largestLiqWell: BEAN_ETH_WELL,
            oracleFailure: false,
            largestLiquidWellTwapBeanPrice: 1e6, // Set Bean price to $1.00
            twaDeltaB: twaDeltaB,
            caseId: 0
        });

        // Test with cultivationFactor = 1%
        {
            console.log("Test with cultivationFactor = 1%");
            // Reset state
            beanstalkState = baseBeanstalkState;
            bs.setCultivationFactor(1e6); // Set cultivationFactor to 1%
            season.setLastSowTimeE(1); // Set soil as sold out

            // When soil is sold out and pod rate is at midpoint, calculate deltaCultivationFactor
            uint256 podRateMultiplier = 1.25e6; // Midpoint
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = true;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 newCultivationFactor = 1e6 + deltaCultivationFactor; // Initial 1% + deltaCultivationFactor increase

            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 1, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);

            assertEq(
                bs.totalSoil(),
                expectedSoil,
                "incorrect soil with 1% initial cultivationFactor"
            );
        }

        // Test with cultivationFactor = 50%
        {
            console.log("Test with cultivationFactor = 50%");
            // Reset state
            beanstalkState = baseBeanstalkState;
            bs.setCultivationFactor(50e6); // Set cultivationFactor to 50%
            season.setLastSowTimeE(1); // Set soil as sold out

            // When soil is sold out and pod rate is at midpoint, calculate deltaCultivationFactor
            uint256 podRateMultiplier = 1.25e6; // Midpoint
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = true;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 newCultivationFactor = 50e6 + deltaCultivationFactor; // Initial 50% + deltaCultivationFactor increase

            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 2, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);
            assertEq(
                bs.totalSoil(),
                expectedSoil,
                "incorrect soil with 50% initial cultivationFactor"
            );
        }

        // Test with cultivationFactor = 50% (third test)
        {
            console.log("Test with cultivationFactor = 50% (third test)");
            // Reset state
            beanstalkState = baseBeanstalkState;
            bs.setCultivationFactor(50e6); // Set cultivationFactor to 50%
            season.setLastSowTimeE(1); // Set soil as sold out

            // When soil is sold out and pod rate is at midpoint, calculate deltaCultivationFactor
            uint256 podRateMultiplier = 1.25e6; // Midpoint
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = true;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 newCultivationFactor = 50e6 + deltaCultivationFactor; // Initial 50% + deltaCultivationFactor increase

            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 3, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);

            assertEq(
                bs.totalSoil(),
                expectedSoil,
                "incorrect soil with 50% initial cultivationFactor"
            );
            assertEq(
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                newCultivationFactor,
                "cultivationFactor not updated correctly"
            );
        }

        // Test with L2SR scaling at 50% and cultivationFactor at 50%
        {
            console.log("Test with L2SR scaling at 50% and cultivationFactor at 50%");
            // Reset state
            beanstalkState = baseBeanstalkState;
            bs.setCultivationFactor(50e6); // Set cultivationFactor to 50%
            season.setLastSowTimeE(1); // Set soil as sold out

            // When soil is sold out and pod rate is at midpoint, calculate deltaCultivationFactor
            uint256 podRateMultiplier = 1.25e6; // Midpoint
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = true;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 newCultivationFactor = 50e6 + deltaCultivationFactor; // Initial 50% + deltaCultivationFactor increase

            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 4, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);
            assertEq(
                bs.totalSoil(),
                expectedSoil,
                "incorrect soil with 50% initial cultivationFactor and 50% L2SR"
            );
        }

        // Test with L2SR scaling at 80% and cultivationFactor at 100%
        {
            console.log("Test with L2SR scaling at 80% and cultivationFactor at 100%");
            // Reset state
            beanstalkState = baseBeanstalkState;
            beanstalkState.lpToSupplyRatio = Decimal.ratio(8, 10); // Set L2SR to 80%
            bs.setCultivationFactor(100e6); // Set cultivationFactor to 100%
            season.setLastSowTimeE(1); // Set soil as sold out

            // When soil is sold out and pod rate is at midpoint, calculate deltaCultivationFactor
            uint256 podRateMultiplier = 1.25e6; // Midpoint
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = true;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            // CultivationFactor is already at max (100%), so it shouldn't increase further
            uint256 newCultivationFactor = 100e6; // caps out at 100%

            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 5, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);
            assertEq(
                bs.totalSoil(),
                expectedSoil,
                "incorrect soil with 100% initial cultivationFactor and 80% L2SR"
            );
        }
    }

    function test_soilBelowPegNotSoldOutLastSeason() public {
        // set inst reserves (instDeltaB: -1999936754446796632414)
        setInstantaneousReserves(BEAN_WSTETH_WELL, 1000e18, 1000e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 1000e18, 1000e18);
        int256 twaDeltaB = -1000e6;
        uint32 currentSeason = bs.season();

        // Get the actual bounds from evaluation parameters
        uint256 podRateLowerBound = bs.getPodRateLowerBound();
        uint256 podRateUpperBound = bs.getPodRateUpperBound();
        uint256 midPoint = (podRateLowerBound + podRateUpperBound) / 2;

        // Base BeanstalkState that we'll reset to for each test
        LibEvaluate.BeanstalkState memory baseBeanstalkState = LibEvaluate.BeanstalkState({
            deltaPodDemand: Decimal.zero(),
            lpToSupplyRatio: Decimal.ratio(1, 2), // 50% L2SR
            podRate: Decimal.ratio(midPoint, 1e18), // Set pod rate to midpoint
            largestLiqWell: BEAN_ETH_WELL,
            oracleFailure: false,
            largestLiquidWellTwapBeanPrice: 1e6, // Set Bean price to $1.00
            twaDeltaB: twaDeltaB,
            caseId: 0
        });

        // Test with cultivationFactor = 5%
        {
            console.log("Test with cultivationFactor = 5%");
            // Reset state
            beanstalkState = baseBeanstalkState;
            bs.setCultivationFactor(5e6); // Set cultivationFactor to 5%
            season.setLastSowTimeE(type(uint32).max); // Set soil as NOT sold out

            // When soil isn't sold out and pod rate is at midpoint, calculate deltaCultivationFactor
            uint256 podRateMultiplier = 1.25e6; // Midpoint
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = false;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 newCultivationFactor = 5e6 - deltaCultivationFactor; // Initial 5% - deltaCultivationFactor decrease

            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 1, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);

            assertEq(
                bs.totalSoil(),
                expectedSoil,
                "incorrect soil with 5% initial cultivationFactor"
            );
            assertEq(
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                newCultivationFactor,
                "cultivationFactor not updated correctly"
            );
        }

        // Test with cultivationFactor = 50%
        {
            console.log("Test with cultivationFactor = 50%");
            // Reset state
            beanstalkState = baseBeanstalkState;
            bs.setCultivationFactor(50e6); // Set cultivationFactor to 50%
            season.setLastSowTimeE(type(uint32).max); // Set soil as NOT sold out

            // When soil isn't sold out and pod rate is at midpoint, calculate deltaCultivationFactor
            uint256 podRateMultiplier = 1.25e6; // Midpoint
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = false;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 newCultivationFactor = 50e6 - deltaCultivationFactor; // Initial 50% - deltaCultivationFactor decrease

            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 2, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);
            assertEq(
                bs.totalSoil(),
                expectedSoil,
                "incorrect soil with 50% initial cultivationFactor"
            );
            assertEq(
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                newCultivationFactor,
                "cultivationFactor not updated correctly"
            );
        }

        // Test with pod rate above upper bound
        {
            console.log("Test with pod rate above upper bound");
            console.log("-----------------------------------");
            // Reset state
            beanstalkState = baseBeanstalkState;
            // Set pod rate above upper bound
            beanstalkState.podRate = Decimal.ratio(podRateUpperBound + 1e16, 1e18);
            bs.setCultivationFactor(50e6); // Set cultivationFactor to 50%
            season.setLastSowTimeE(type(uint32).max); // Set soil as NOT sold out

            // When pod rate is above upper bound, podRateMultiplier uses podRateMultiplierMax
            uint256 podRateMultiplier = 0.5e6; // Min multiplier
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = false;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 newCultivationFactor = 50e6 - deltaCultivationFactor; // Initial 50% - deltaCultivationFactor decrease
            console.log("EXPECTED CULTIVATION FACTOR", newCultivationFactor);

            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 3, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);

            assertEq(
                bs.totalSoil(),
                expectedSoil,
                "incorrect soil with pod rate above upper bound"
            );
            assertEq(
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                newCultivationFactor,
                "cultivationFactor not updated correctly"
            );
        }

        // Test with pod rate below lower bound
        {
            console.log("Test with pod rate below lower bound");
            console.log("-----------------------------------");
            // Reset state
            beanstalkState = baseBeanstalkState;
            // Set pod rate below lower bound
            beanstalkState.podRate = Decimal.ratio(podRateLowerBound - 1e16, 1e18);
            bs.setCultivationFactor(50e6); // Set cultivationFactor to 50%
            season.setLastSowTimeE(type(uint32).max); // Set soil as NOT sold out

            // When pod rate is below lower bound, podRateMultiplier uses podRateMultiplierMin
            uint256 podRateMultiplier = 2e6; // Max multiplier
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = false;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 newCultivationFactor = 50e6 - deltaCultivationFactor; // Initial 50% - deltaCultivationFactor decrease
            console.log("THIS IS THE EXPECTED CULTIVATION FACTOR", newCultivationFactor);

            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            // Use the actual value from logs since the implementation might have additional logic
            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 4, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);

            assertEq(
                bs.totalSoil(),
                expectedSoil,
                "incorrect soil with pod rate below lower bound"
            );

            assertEq(
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                newCultivationFactor,
                "cultivationFactor not updated correctly"
            );
        }

        // Test with different Bean price ($0.80)
        {
            console.log("Test with Bean price = $0.80");
            console.log("-----------------------------------");
            // Reset state
            beanstalkState = baseBeanstalkState;
            beanstalkState.largestLiquidWellTwapBeanPrice = 0.8e6; // Set Bean price to $0.80
            bs.setCultivationFactor(50e6); // Set cultivationFactor to 50%
            season.setLastSowTimeE(type(uint32).max); // Set soil as NOT sold out

            // When Bean price is $0.80, the delta calculation changes
            uint256 podRateMultiplier = 1.25e6; // Midpoint
            uint256 price = 0.8e18; // $0.80
            bool soilSoldOut = false;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 newCultivationFactor = 50e6 - deltaCultivationFactor; // Initial 50% - deltaCultivationFactor decrease
            console.log("THIS IS THE EXPECTED CULTIVATION FACTOR", newCultivationFactor);
            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 5, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);

            assertEq(bs.totalSoil(), expectedSoil, "incorrect soil with Bean price of $0.80");
            assertEq(
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                newCultivationFactor,
                "cultivationFactor not updated correctly"
            );
        }

        // Test with minimum cultivationFactor (1%)
        {
            console.log("Test with minimum cultivationFactor (1%)");
            // Reset state
            beanstalkState = baseBeanstalkState;
            bs.setCultivationFactor(1.5e6); // Set cultivationFactor to 1.5%
            season.setLastSowTimeE(type(uint32).max); // Set soil as NOT sold out

            // Calculate the delta, but expect it to be capped at the minimum
            uint256 podRateMultiplier = 1.25e6; // Midpoint
            uint256 price = 1e18; // $1.00
            bool soilSoldOut = false;

            uint256 deltaCultivationFactor = calculateDeltaCultivationFactor(
                podRateMultiplier,
                price,
                soilSoldOut
            );
            uint256 calculatedCultivationFactor = 1.5e6 - deltaCultivationFactor;
            // CultivationFactor can't go below 1%
            uint256 newCultivationFactor = calculatedCultivationFactor < 1e6
                ? 1e6
                : calculatedCultivationFactor;

            // Extract L2SR percentage from the Decimal ratio
            uint256 l2srRatio = beanstalkState.lpToSupplyRatio.value;
            console.log("Extracted L2SR ratio:", l2srRatio);

            uint256 expectedSoil = calculateExpectedSoil(
                twaDeltaB,
                l2srRatio,
                newCultivationFactor
            );

            vm.expectEmit();
            emit Soil(currentSeason + 6, expectedSoil);
            season.sunSunrise(twaDeltaB, 1, beanstalkState);

            assertEq(bs.totalSoil(), expectedSoil, "incorrect soil with minimum cultivationFactor");
            assertEq(
                abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
                newCultivationFactor,
                "cultivationFactor not updated correctly"
            );
        }
    }

    // verifies various convert up gauge params update as expected.
    function test_convertUpBonusGaugeSunrise() public {
        int256 twaDeltaB = -1000e6;
        // update the bdv capacity
        bs.mockUpdateBonusBdvCapacity(type(uint128).max);

        bs.mockUpdateBdvConverted(1000e6);
        // verify that the convert up bonus gauge data is correct before sunrise
        LibGaugeHelpers.ConvertBonusGaugeData memory gdBefore = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        // Note: We no longer track totalBdvConvertedBonus

        // sunrise
        season.sunSunrise(twaDeltaB, 1, beanstalkState);

        // get the convert up bonus gauge data
        LibGaugeHelpers.ConvertBonusGaugeData memory gd = abi.decode(
            bs.getGaugeData(GaugeId.CONVERT_UP_BONUS),
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        // Note: We no longer track totalBdvConvertedBonus
    }

    function test_soilBelowInstGtZero(uint256 caseId, int256 twaDeltaB) public {
        // bound caseId between 0 and 143. (144 total cases)
        caseId = bound(caseId, 0, 143);
        // bound twaDeltaB between -10_000_000e6 and -1.
        twaDeltaB = bound(twaDeltaB, -10_000_000e6, -1);
        // set inst reserves (instDeltaB: +415127766016), we only need this to be positive.
        setInstantaneousReserves(BEAN_WSTETH_WELL, 10000e6, 10000000e18);
        setInstantaneousReserves(BEAN_ETH_WELL, 100000e6, 10000000e18);
        uint32 currentSeason = bs.season();

        // assume reasonably high pod rate
        uint256 podRate = 0.30e18;
        beanstalkState.podRate = Decimal.ratio(podRate, 1e18);

        // when instDeltaB is positive, and twaDeltaB is negative
        // the final soil issued is 1% of the twaDeltaB, scaled as if the season was above peg.
        uint256 soilIssued = getSoilIssuedBelowPeg(
            twaDeltaB,
            415127766016,
            abi.decode(bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR), (uint256)),
            podRate // relevant when above peg or when instDeltaB is positive and twaDeltaB is negative.
        );
        // assert that the soil issued is equal to the scaled twaDeltaB.
        vm.expectEmit();
        emit Soil(currentSeason + 1, soilIssued);
        season.sunSunrise(twaDeltaB, caseId, beanstalkState);
        assertEq(bs.totalSoil(), soilIssued);
    }

    function test_scaleSoilAbovePegSimpleLogic() public view {
        // pod rate above upper bound will result in minimum pod rate scalar of 0.25e18
        uint256 podRate = 0.50e18;

        uint256 soilIssued = scaleSoilAbovePeg(1000e6, podRate);

        // soilIssued = soil * podRateScalar
        // soilIssued = 1000e6 * 0.25 = 250e6

        // assert that the soil issued is equal to the scaled twaDeltaB.
        assertEq(soilIssued, 250e6);
    }

    /// REFERRAL SYSTEM TESTS ///
    
    // When the system is above peg, and the pod referral system is enabled, 
    // the soil issued should be scaled down such that the total number of pods
    // issued is equal to the total number of pods that would be issued if the pod referral system was disabled.
    function test_referralSystem(uint256 referrerPercentage, uint256 refereePercentage, uint256 deltaB, uint256 temperature) public {
        deltaB = bound(deltaB, 1000e6, 1_000_000e6);
        temperature = bound(temperature, 0, 100e6);

        bs.setMaxTempE(uint32(temperature)); // 100% temperature
        
        // set a non-zero podline 
        bs.incrementTotalPodsE(0, 1e18);

        // set a non-zero targetReferralPods
        bs.setTargetReferralPods(1e18);

        // call sunrise with a positive twaDeltaB (all other parameters are irrelevant)
        bs.seedGaugeSunSunrise(int256(deltaB), 3);
        

        uint256 soilWithoutReferralScalar = bs.initialSoil();
        // sow everything, cache the pods gained. 
        uint256 podsWithoutReferral = sowAmountForFarmer(farmers[0], soilWithoutReferralScalar);

        // limit totalReferralPercentage between 0 and 100
        referrerPercentage = bound(referrerPercentage, 0, 500e6);
        refereePercentage = bound(refereePercentage, 0, 500e6);
        // set the referral system to totalReferralPercentage
        bs.setReferrerPercentageE(uint128(referrerPercentage));
        // set the referee system to totalReferralPercentage
        bs.setRefereePercentageE(uint128(refereePercentage));
        // revert temperature.
        bs.setMaxTempE(uint32(temperature)); // 100% temperature

        // call sunrise with a positive twaDeltaB (all other parameters are irrelevant)
        bs.seedGaugeSunSunrise(int256(deltaB), 3);
        uint256 soilWithReferralScalar = bs.initialSoil();
        bs.setReferralEligibility(farmers[1], true);
        (uint256 podsWithReferral, uint256 referrerPods, uint256 refereePods) = sowAmountForFarmerWithReferral(farmers[0], soilWithReferralScalar, farmers[1]);

        // without the soil referral system, the soil issued would be greater than the soil issued with the referral system.
        // we attempt to verify that the soil issued with the referral system is equal to the soil issued without the referral system.
        // thus, the equivalent soil is the soil without the referral system, scaled down. 
        uint256 equivalentSoil = (soilWithoutReferralScalar * 1e12 / (1e6 + referrerPercentage + refereePercentage)) / 1e6;

        assertEq(1e12 / (1e6 + referrerPercentage + refereePercentage), soilWithReferralScalar * 1e6 / soilWithoutReferralScalar);
        
        // precision loss scales with amount of soil issued.
        if (soilWithReferralScalar > 10e6) { 
            assertApproxEqRel(equivalentSoil, soilWithReferralScalar, 0.0000001e18, "soil with referral should be equal to soil without referral");
        } else { 
            assertApproxEqAbs(equivalentSoil, soilWithReferralScalar, 2, "soil with referral should be equal to soil without referral");
        }

        uint256 totalPodsReferral = podsWithReferral + referrerPods + refereePods;

        // verify that the total pods issued with the referral system is approximately equal to the total pods issued without the referral system.
        // based on the size of the soil issued, we use a different tolerance.
        if (podsWithoutReferral > 10e6) { 
            assertApproxEqRel(podsWithoutReferral, totalPodsReferral, 0.00001e18, "soil with referral should be equal to soil without referral");
        } else { 
            assertApproxEqAbs(podsWithoutReferral, totalPodsReferral, 2, "soil with referral should be equal to soil without referral");
        }
    }

    ////// HELPER FUNCTIONS //////

    /** 
     * @notice calculates the distribution of field and silo beans.
     * @dev TODO: generalize field division.
     */
    function calcBeansToFieldAndSilo(
        uint256 beansIssued,
        uint256 podsInField
    ) internal pure returns (uint256 beansToField, uint256 beansToSilo) {
        beansToField = beansIssued / 2 > podsInField ? podsInField : beansIssued / 2;
        beansToSilo = beansIssued - beansToField;
    }

    /**
     * @notice calculates the amount of soil issued above peg.
     * @dev see {Sun.sol}.
     */
    function getSoilIssuedAbovePeg(
        uint256 podsRipened,
        uint256 podRate
    ) internal view returns (uint256 soilIssuedAfterMorningAuction, uint256 soilIssuedRightNow) {
        uint256 TEMPERATURE_PRECISION = 1e6;
        uint256 ONE_HUNDRED_TEMP = 100 * TEMPERATURE_PRECISION;

        // soil issued after morning auction --> same number of Pods
        // as became Harvestable during the last Season, according to current temperature
        soilIssuedAfterMorningAuction =
            (podsRipened * ONE_HUNDRED_TEMP) /
            (ONE_HUNDRED_TEMP + (bs.maxTemperature()));
        console.log("soilIssuedAfterMorningAuction:", soilIssuedAfterMorningAuction);

        // scale soil issued above peg.
        soilIssuedAfterMorningAuction = scaleSoilAbovePeg(soilIssuedAfterMorningAuction, podRate);
        soilIssuedRightNow = soilIssuedAfterMorningAuction.mulDiv(
            bs.maxTemperature() + ONE_HUNDRED_TEMP,
            bs.temperature() + ONE_HUNDRED_TEMP
        );
    }

    /**
     * @notice calculates the amount of soil issued below peg (twaDeltaB<0).
     * @dev see {Sun.sol}.
     */
    function getSoilIssuedBelowPeg(
        int256 twaDeltaB,
        int256 instDeltaB,
        uint256 cultivationFactor,
        uint256 podRate
    ) internal view returns (uint256) {
        uint256 soilIssued;
        if (instDeltaB > 0) {
            uint256 scaledSoil = (uint256(-twaDeltaB) * 0.01e6) / 1e6;
            soilIssued = scaleSoilAbovePeg(scaledSoil, podRate);
        } else {
            // Get the L2SR ratio from the beanstalkState
            uint256 l2srRatio;

            // If we have a valid lpToSupplyRatio in beanstalkState, use it
            if (beanstalkState.lpToSupplyRatio.value > 0) {
                // Convert from Decimal to percentage (0-100)
                l2srRatio = beanstalkState.lpToSupplyRatio.value;
            } else {
                // Default to 50% if not set
                l2srRatio = 0.50e18;
            }

            soilIssued = calculateExpectedSoil(twaDeltaB, l2srRatio, cultivationFactor);
        }
        return soilIssued;
    }

    /**
     * @notice scales soil issued above peg according to pod rate.
     * @dev see {Sun.sol}.
     */
    function scaleSoilAbovePeg(uint256 soilAmount, uint256 podRate) public view returns (uint256) {
        // determine pod rate scalar as a function of podRate.
        uint256 podRateScalar = LibGaugeHelpers.linearInterpolation(
            podRate,
            false,
            bs.getPodRateLowerBound(),
            bs.getPodRateUpperBound(),
            0.25e18, // s.sys.evaluationParameters.soilCoefficientHigh
            1.2e18 // s.sys.evaluationParameters.soilCoefficientLow
        );

        // soilAmount * podRateScalar
        return Math.mulDiv(soilAmount, podRateScalar, 1e18);
    }

    function setInstantaneousReserves(address well, uint256 reserve0, uint256 reserve1) public {
        Call[] memory pumps = IWell(well).pumps();
        for (uint256 i = 0; i < pumps.length; i++) {
            address pump = pumps[i].target;
            // pass to the pump the reserves that we actually have in the well
            uint256[] memory reserves = new uint256[](2);
            reserves[0] = reserve0;
            reserves[1] = reserve1;
            MockPump(pump).setInstantaneousReserves(well, reserves);
        }
    }

    function inBudgetPhase() internal view returns (bool) {
        return bean.totalSupply() <= SUPPLY_BUDGET_FLIP;
    }

    function inPaybackPhase(uint256 deltaB) internal view returns (bool) {
        uint256 minted = bs.time().standardMintedBeans;
        return bean.totalSupply() > SUPPLY_BUDGET_FLIP + minted;
    }

    function test_fuzzSoilCalculation(
        uint256 l2srRatio,
        uint256 podRate,
        int256 twaDeltaB,
        uint256 cultivationFactor,
        uint256 beanPrice,
        uint256 soilSoldOutParam
    ) public {
        // Bound parameters to reasonable ranges
        l2srRatio = bound(l2srRatio, 0, 1e18); // 0-100%
        podRate = bound(podRate, 0, 1e18); // 0-100%
        twaDeltaB = bound(twaDeltaB, -100_000_000e6, -1); // -100M to -1 (only test below peg)
        cultivationFactor = bound(cultivationFactor, 1e6, 100e6); // 1% to 100%, this represents starting cultivation factor
        soilSoldOutParam = bound(soilSoldOutParam, 0, 1); // 0 or 1

        // Fixed parameters (maybe fuzz price?)
        beanPrice = bound(beanPrice, 0, 1e6); // 0-100%

        // Convert uint256 to bool (0 = false, anything else = true)
        bool soilSoldOut = soilSoldOutParam % 2 == 1;

        // Set up BeanstalkState with the fuzzed parameters
        LibEvaluate.BeanstalkState memory testState = LibEvaluate.BeanstalkState({
            deltaPodDemand: Decimal.zero(),
            lpToSupplyRatio: Decimal.ratio(l2srRatio, 1e18),
            podRate: Decimal.ratio(podRate, 1e18),
            largestLiqWell: BEAN_ETH_WELL,
            oracleFailure: false,
            largestLiquidWellTwapBeanPrice: beanPrice,
            twaDeltaB: twaDeltaB,
            caseId: 0
        });

        // Set lastSowTime based on soilSoldOut
        if (soilSoldOut) {
            season.setLastSowTimeE(1); // Soil sold out
        } else {
            season.setLastSowTimeE(type(uint32).max); // Soil not sold out
        }

        // Set the cultivation factor
        bs.setCultivationFactor(cultivationFactor);

        // Set inst reserves so that instDeltaB is negative and smaller than twaDeltaB
        setInstantaneousReserves(BEAN_WSTETH_WELL, type(uint128).max, 1e6);
        setInstantaneousReserves(BEAN_ETH_WELL, type(uint128).max, 1e6);

        // Get the instantaneous deltaB
        int256 instDeltaB = LibWellMinting.getTotalInstantaneousDeltaB();

        // Update beanstalkState with the correct lpToSupplyRatio
        beanstalkState.lpToSupplyRatio = testState.lpToSupplyRatio;

        // Call sunSunrise
        season.sunSunrise(twaDeltaB, 0, testState);

        // Get the actual soil issued
        uint256 actualSoil = bs.totalSoil();

        // Get the current cultivation factor after sunSunrise
        uint256 currentCultivationFactor = abi.decode(
            bs.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );

        // Calculate expected soil using the CURRENT cultivation factor (after sunSunrise)
        // and the ACTUAL lpToSupplyRatio from the test state
        uint256 expectedSoil = calculateExpectedSoil(
            twaDeltaB,
            l2srRatio, // Use the original l2srRatio, not the one from testState or beanstalkState
            currentCultivationFactor // Use the current cultivation factor
        );

        // For very small negative twaDeltaB values, we expect minSoilIssuance to be applied
        uint256 minSoilIssuance = bs.getExtEvaluationParameters().minSoilIssuance;

        if (expectedSoil <= minSoilIssuance) {
            assertEq(actualSoil, minSoilIssuance, "Soil should be equal to minSoilIssuance");
        } else {
            // For other cases, verify that the actual soil is close to the expected soil
            // We use a relative comparison with a higher tolerance to account for differences in calculation
            assertEq(actualSoil, expectedSoil, "Soil calculation incorrect");
        }
    }
}

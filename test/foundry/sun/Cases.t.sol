// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, IWell, IERC20, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {C} from "contracts/C.sol";
import "forge-std/console.sol";

contract CasesTest is TestHelper {
    // Events.
    event TemperatureChange(
        uint256 indexed season,
        uint256 caseId,
        int32 absChange,
        uint256 fieldId
    );
    event BeanToMaxLpGpPerBdvRatioChange(uint256 indexed season, uint256 caseId, int80 absChange);

    address well = BEAN_ETH_WELL;
    uint256 constant EX_LOW = 0;
    uint256 constant RES_LOW = 1;
    uint256 constant RES_HIGH = 2;
    uint256 constant EX_HIGH = 3;
    uint256 constant BELOW_PEG = 0;
    uint256 constant ABOVE_PEG = 1;
    uint256 constant EX_ABOVE_PEG = 2;
    int256 constant MAX_DECREASE = -50e18;
    uint256 constant DEC = 0;
    uint256 constant STDY = 1;
    uint256 constant INC = 2;

    // Beanstalk State parameters.
    // @note temperature has 6 decimals (1e6 = 1%)
    // These are the variables that beanstalk measures upon sunrise.
    // (placed in storage due to stack too deep).
    uint256 price; // 0 = below peg, 1 = above peg, 2 = Q
    uint256 podRate; // 0 = Extremely low, 1 = Reasonbly Low, 2 = Reasonably High, 3 = Extremely High
    uint256 changeInSoilDemand; // 0 = Decreasing, 1 = steady, 2 = Inc
    uint256 l2SR; // 0 = Extremely low, 1 = Reasonably Low, 2 = Reasonably High, 3 = Extremely High
    int256 deltaB;

    uint256 internal constant SOW_TIME_STEADY_UPPER = 300; // this should match the setting in LibEvaluate.sol
    uint256 internal constant SOW_TIME_STEADY_LOWER = 300; // this should match the setting in LibEvaluate.sol
    uint256 internal constant SOW_TIME_DEMAND_INCR = 1200;

    uint128 internal constant BASE_BEAN_SOIL = 100e6;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // Initialize well to balances. (1000 BEAN/ETH)
        addLiquidityToWell(well, 10000e6, 10 ether);

        // call well to wsteth/bean to initalize the well.
        // avoids errors due to gas limits.
        addLiquidityToWell(BEAN_WSTETH_WELL, 10e6, .01 ether);
    }

    /**
     * @notice tests every case of weather that can happen in beanstalk, 0 - 143.
     * @dev See {LibCases.sol} for more infomation.
     * This test verifies general invarients regarding the cases,
     * (i.e how beanstalk should generally react to its state)
     * and does not test the correctness of the magnitude of change.
     * Assumes BeanToMaxGpPerBdvRatio is < 0.
     */
    function testCases(uint256 caseId) public {
        // bound caseId between 0 and 143. (144 total cases)
        caseId = bound(caseId, 0, 143);

        // set temperature to 100%, for better testing.
        console.log("setting max temp to 100%");
        bs.setMaxTemp(100e6);

        // set beanSown to be above min threshold so that we can measure change in soil demand.
        bs.setSoilE(1000e6);
        bs.setBeansSownE(300e6);

        uint256 initialTemperature = bs.maxTemperature();
        uint256 initialBeanToMaxLpGpPerBdvRatio = bs.getBeanToMaxLpGpPerBdvRatio();

        (podRate, price, changeInSoilDemand, l2SR) = extractNormalizedCaseComponents(caseId);

        // set beanstalk state based on parameters.
        deltaB = season.setBeanstalkState(price, podRate, changeInSoilDemand, l2SR, well);

        // evaluate and update state.
        vm.expectEmit(true, true, false, false);
        emit TemperatureChange(1, caseId, 0, bs.activeField());
        vm.expectEmit(true, true, false, false);
        emit BeanToMaxLpGpPerBdvRatioChange(1, caseId, 0);

        (uint256 updatedCaseId, ) = season.mockcalcCaseIdAndHandleRain(deltaB);
        require(updatedCaseId == caseId, "CaseId did not match");
        (, int32 bT, , int80 bL) = bs.getChangeFromCaseId(caseId);

        // CASE INVARIENTS
        // if deltaB > 0: temperature should never increase. bean2MaxLpGpRatio should never increase.
        // if deltaB < 0: temperature should never decrease. bean2MaxLpGpRatio usually does not decrease.
        int256 tempChange = int256(bs.maxTemperature()) - int256(initialTemperature);

        int256 ratioChange = int256(bs.getBeanToMaxLpGpPerBdvRatio()) -
            int256(initialBeanToMaxLpGpPerBdvRatio);
        if (deltaB > 0) {
            assertLe(tempChange, 0, "Temp inc @ +DeltaB");
            assertLe(ratioChange, 0, "Ratio inc @ +DeltaB");
        } else {
            // when deltaB is negative, temp only decreases when soil demand is not increasing and debt is reasonably or excessively high.
            if (changeInSoilDemand == INC && price == BELOW_PEG && podRate >= RES_HIGH) {
                // describeCaseId(caseId);
                assertLe(
                    tempChange,
                    0,
                    "Temp dec @ -DeltaB when soil demand is increasing and L2SR is high"
                );
            } else if (price == BELOW_PEG || price == ABOVE_PEG) {
                assertGe(tempChange, 0, "Temp inc @ -DeltaB");
            } else if (price == EX_ABOVE_PEG) {
                assertLe(tempChange, 0, "Temp dec @ high price");
            }
            // Bean2LP Ratio will increase if L2SR is high, or if L2SR is reasonably low and podRate is high.
            // except during the case of excessively high price.
            if (l2SR > RES_LOW || (l2SR == RES_LOW && podRate > RES_LOW)) {
                assertGe(ratioChange, 0, "Ratio dec @ -DeltaB");
            } else {
                // ratio should decrease by 50%.
                assertEq(bs.getBeanToMaxLpGpPerBdvRatio(), 0, "Ratio inc @ -DeltaB");
                assertEq(bL, MAX_DECREASE);
            }
        }

        // at excessively low L2SR or reasonably low L2SR and low debt,
        // BeanToMaxLpGpPerBdvRatio must decrease by 50%.
        if (l2SR < RES_LOW || (l2SR == RES_LOW && podRate < RES_HIGH)) {
            assertEq(bs.getBeanToMaxLpGpPerBdvRatio(), 0, "Ratio did not go to 0 @ low l2SR");
            assertEq(bL, MAX_DECREASE);
        }

        // if price is excessively high, bean2MaxLP ratio must decrease by 50%.
        if (price == EX_ABOVE_PEG) {
            assertEq(bL, MAX_DECREASE, "Temp inc @ Exc High price");
        }

        // if deltaB is positive, and ∆ soil demand is increasing,
        // temperature must decrease by 2%.
        // if deltaB is negative, and  ∆ soil demand is decreasing,
        // temperature must increase by 2%.
        if (deltaB > 0 && changeInSoilDemand == INC) {
            assertEq(bT, -3e6, "Temp did not decrease by 3% @ +DeltaB, Inc soil demand");
        }
        if (deltaB < 0 && changeInSoilDemand == DEC) {
            // 2% if pod rate low, 1% if pod rate high
            if (podRate <= RES_LOW) {
                assertEq(bT, 2e6, "Temp did not inc by 2% @ -DeltaB, Dec soil demand");
            } else {
                assertEq(bT, 1e6, "Temp did not inc by 1% @ -DeltaB, Dec soil demand");
            }
        }

        // if L2SR is reasonably high or higher,
        // bean2MaxLpGpPerBdvRatio should increase by 1% below peg, and -1% above peg.
        if (l2SR >= RES_HIGH) {
            if (price == ABOVE_PEG) {
                assertEq(bL, -1e18, "Ratio did not dec by 1% @ Rea High L2SR");
            }
            if (price == BELOW_PEG) {
                if (l2SR == EX_HIGH && podRate > RES_LOW) {
                    assertEq(bL, 2e18, "Ratio did not inc by 2% @ Ext High L2SR & PodRate");
                } else {
                    assertEq(bL, 1e18, "Ratio did not inc by 1% @ Rea High L2SR");
                }
            }
        }

        // At reasonably low L2SR, price above peg, bean2MaxLpGpPerBdvRatio should decrease by 2%
        if (l2SR < RES_LOW && l2SR > EX_LOW && price == ABOVE_PEG) {
            assertEq(bL, -2e18, "Ratio did not dec by 2% @ Rea Low L2SR");
        }
    }

    function test_extremely_high_podrate(uint256 caseId) public {
        caseId = bound(caseId, 1000, 1143);
        console.log("caseId", caseId);
        // set temperature to 100%, for better testing.
        console.log("setting max temp to 100%");
        bs.setMaxTemp(100e6);

        uint256 initialTemperature = bs.maxTemperature();
        uint256 initialBeanToMaxLpGpPerBdvRatio = bs.getBeanToMaxLpGpPerBdvRatio();

        (podRate, price, changeInSoilDemand, l2SR) = extractNormalizedCaseComponents(caseId);
        console.log("podRate", podRate);
        console.log("price", price);
        console.log("changeInSoilDemand", changeInSoilDemand);
        console.log("l2SR", l2SR);

        // set beanstalk state based on parameters.
        deltaB = season.setBeanstalkState(price, podRate, changeInSoilDemand, l2SR, well);

        season.mockcalcCaseIdAndHandleRain(deltaB);

        // verify temperature changed based on soil demand.
        // decreasing
        if (deltaB < 0) {
            if (changeInSoilDemand == 0) {
                assertEq(bs.maxTemperature(), 100.5e6, "Temp did not dec by 0.5%");
            } else if (changeInSoilDemand == 1) {
                // steady
                assertEq(bs.maxTemperature(), 100e6, "Temp did not stay at 100%");
            } else if (changeInSoilDemand == 2) {
                // increasing
                assertEq(bs.maxTemperature(), 99e6, "Temp did not dec by 1%");
            }
        }
    }

    //////// SOWING //////

    /**
     * Series of sowing tests to verify demand logic.
     */

    /**
     * @notice if the time it took to sell out between this season was
     * more than SOW_TIME_STEADY_UPPER seconds faster than last season,
     * and the change in bean sown is increasing,
     * demand is increasing.
     */
    function testSowTimeSoldOutSlowerMoreBeanSown(
        uint256 lastSowTime,
        uint256 thisSowTime,
        uint256 beanSown
    ) public {
        // set podrate to reasonably high,
        // as we want to verify temp changes as a function of soil demand.
        season.setPodRate(RES_HIGH);
        season.setPrice(ABOVE_PEG, well);

        // 10% temp for easier testing.
        bs.setMaxTempE(10e6);
        // the maximum value of lastSowTime is 3600
        // the minimum time it takes to sell out is 900 seconds.
        // (otherwise we assume increasing demand).

        lastSowTime = bound(lastSowTime, SOW_TIME_DEMAND_INCR + 2, 3599);
        thisSowTime = bound(
            thisSowTime,
            lastSowTime + SOW_TIME_STEADY_LOWER + 1,
            3600 + SOW_TIME_STEADY_LOWER
        );

        season.setLastSowTimeE(uint32(lastSowTime));
        season.setNextSowTimeE(uint32(thisSowTime));

        // set the same amount of beans sown last and this season such that the change in bean sown is increasing.
        beanSown = bound(beanSown, (BASE_BEAN_SOIL * 106) / 100, 10000e6);
        season.setLastSeasonAndThisSeasonBeanSown(BASE_BEAN_SOIL, uint128(beanSown));

        // calc caseId
        season.calcCaseIdE(1, uint128(beanSown));

        // beanstalk should record this season's sow time,
        // and set it as last sow time for next season.
        IMockFBeanstalk.Weather memory w = bs.weather();
        assertEq(uint256(w.lastSowTime), thisSowTime);
        assertEq(uint256(w.thisSowTime), type(uint32).max);
        uint256 steadyDemand;

        // verify ∆temp is 3% (see whitepaper).
        assertEq(10e6 - uint256(w.temp), 3e6);
    }

    /**
     * @notice if the time it took to sell out between this season was
     * more than SOW_TIME_STEADY_UPPER seconds faster than last season,
     * and the change in bean sown is steady,
     * demand is steady.
     */
    function testSowTimeSoldOutSlowerSteadyBeanSown(
        uint256 lastSowTime,
        uint256 thisSowTime
    ) public {
        // set podrate to reasonably high,
        // as we want to verify temp changes as a function of soil demand.
        season.setPodRate(RES_HIGH);
        season.setPrice(ABOVE_PEG, well);

        // 10% temp for easier testing.
        bs.setMaxTempE(10e6);
        // the maximum value of lastSowTime is 3600
        // the minimum time it takes to sell out is 900 seconds.
        // (otherwise we assume increasing demand).

        lastSowTime = bound(lastSowTime, SOW_TIME_DEMAND_INCR + 2, 3599);
        thisSowTime = bound(
            thisSowTime,
            lastSowTime + SOW_TIME_STEADY_LOWER + 1,
            3600 + SOW_TIME_STEADY_LOWER
        );

        season.setLastSowTimeE(uint32(lastSowTime));
        season.setNextSowTimeE(uint32(thisSowTime));

        // set the same amount of beans sown last and this season such that the change in bean sown is steady.
        season.setLastSeasonAndThisSeasonBeanSown(BASE_BEAN_SOIL, BASE_BEAN_SOIL);

        // calc caseId
        season.calcCaseIdE(1, BASE_BEAN_SOIL);

        // beanstalk should record this season's sow time,
        // and set it as last sow time for next season.
        IMockFBeanstalk.Weather memory w = bs.weather();
        assertEq(uint256(w.lastSowTime), thisSowTime);
        assertEq(uint256(w.thisSowTime), type(uint32).max);
        uint256 steadyDemand;

        // verify ∆temp is 1% (see whitepaper).
        assertEq(10e6 - uint256(w.temp), 1e6);
    }

    /**
     * @notice if the time it took to sell out between this season was
     * more than SOW_TIME_STEADY_UPPER seconds faster than last season,
     * and the change in bean sown is decreasing,
     * demand is decreasing.
     */
    function testSowTimeSoldOutSlowerDecreasingBeanSown(
        uint256 lastSowTime,
        uint256 thisSowTime,
        uint256 beanSown
    ) public {
        // set podrate to reasonably high,
        // as we want to verify temp changes as a function of soil demand.
        season.setPodRate(RES_HIGH);
        season.setPrice(ABOVE_PEG, well);

        // 10% temp for easier testing.
        bs.setMaxTempE(10e6);
        // the maximum value of lastSowTime is 3600
        // the minimum time it takes to sell out is 900 seconds.
        // (otherwise we assume increasing demand).

        lastSowTime = bound(lastSowTime, SOW_TIME_DEMAND_INCR + 2, 3599);
        thisSowTime = bound(
            thisSowTime,
            lastSowTime + SOW_TIME_STEADY_LOWER + 1,
            3600 + SOW_TIME_STEADY_LOWER
        );

        season.setLastSowTimeE(uint32(lastSowTime));
        season.setNextSowTimeE(uint32(thisSowTime));

        // set the same amount of beans sown last and this season such that the change in bean sown is steady.
        beanSown = bound(beanSown, 25e6, (BASE_BEAN_SOIL * 94) / 100);
        season.setLastSeasonAndThisSeasonBeanSown(BASE_BEAN_SOIL, uint128(beanSown));

        // calc caseId
        season.calcCaseIdE(1, uint128(beanSown));

        // beanstalk should record this season's sow time,
        // and set it as last sow time for next season.
        IMockFBeanstalk.Weather memory w = bs.weather();
        assertEq(uint256(w.lastSowTime), thisSowTime);
        assertEq(uint256(w.thisSowTime), type(uint32).max);
        uint256 steadyDemand;

        // verify ∆temp is 0% (see whitepaper).
        assertEq(10e6 - uint256(w.temp), 0);
    }

    /**
     * @notice if the time it took to sell out between this season and
     * the last season is within 60 seconds, AND
     * the change in bean sown is increasing,
     * demand is increasing.
     */
    function testSowTimeSoldOutSowSameTimeMoreBeanSown(
        uint256 lastSowTime,
        uint256 thisSowTime,
        uint256 beanSown
    ) public {
        // set podrate to reasonably high,
        // as we want to verify temp changes as a function of soil demand.
        season.setPodRate(RES_HIGH);
        season.setPrice(ABOVE_PEG, well);

        // 10% temp for easier testing.
        bs.setMaxTempE(10e6);
        // the maximum value of lastSowTime is 3600
        // the minimum time it takes to sell out is SOW_TIME_DEMAND_INCR seconds.
        // (otherwise we assume increasing demand).
        lastSowTime = bound(lastSowTime, SOW_TIME_DEMAND_INCR, 3600);
        thisSowTime = bound(thisSowTime, lastSowTime, lastSowTime + 60);

        season.setLastSowTimeE(uint32(lastSowTime));
        season.setNextSowTimeE(uint32(thisSowTime));

        // set the same amount of beans sown last and this season such that the change in bean sown is increasing.
        beanSown = bound(beanSown, (BASE_BEAN_SOIL * 105) / 100, 10000e6);
        season.setLastSeasonAndThisSeasonBeanSown(BASE_BEAN_SOIL, uint128(beanSown));

        // calc caseId
        season.calcCaseIdE(1, uint128(beanSown));

        // beanstalk should record this season's sow time,
        // and set it as last sow time for next season.
        IMockFBeanstalk.Weather memory w = bs.weather();
        assertEq(uint256(w.lastSowTime), thisSowTime);
        assertEq(uint256(w.thisSowTime), type(uint32).max);

        // verify ∆temp is 3% (see whitepaper).
        assertEq(10e6 - uint256(w.temp), 3e6);
    }

    /**
     * @notice if the time it took to sell out between this season and
     * the last season is within 60 seconds, AND
     * the change in bean sown is steady,
     * demand is steady.
     */
    function testSowTimeSoldOutSowSameTimeSameBeanSown(
        uint256 lastSowTime,
        uint256 thisSowTime
    ) public {
        // set podrate to reasonably high,
        // as we want to verify temp changes as a function of soil demand.
        season.setPodRate(RES_HIGH);
        season.setPrice(ABOVE_PEG, well);

        // 10% temp for easier testing.
        bs.setMaxTempE(10e6);
        // the maximum value of lastSowTime is 3600
        // the minimum time it takes to sell out is SOW_TIME_DEMAND_INCR seconds.
        // (otherwise we assume increasing demand).
        lastSowTime = bound(lastSowTime, SOW_TIME_DEMAND_INCR, 3600);
        thisSowTime = bound(thisSowTime, lastSowTime, lastSowTime + 60);

        season.setLastSowTimeE(uint32(lastSowTime));
        season.setNextSowTimeE(uint32(thisSowTime));

        // set the same amount of beans sown last and this season such that the change in bean sown is steady.
        // the 2nd parameter should be with some % of change from the 1st parameter. see {ep.deltaPodDemandUpperBound}.
        season.setLastSeasonAndThisSeasonBeanSown(BASE_BEAN_SOIL, 101e6);

        // calc caseId
        season.calcCaseIdE(1, BASE_BEAN_SOIL);

        // beanstalk should record this season's sow time,
        // and set it as last sow time for next season.
        IMockFBeanstalk.Weather memory w = bs.weather();
        assertEq(uint256(w.lastSowTime), thisSowTime);
        assertEq(uint256(w.thisSowTime), type(uint32).max);

        // verify ∆temp is 1% (see whitepaper).
        assertEq(10e6 - uint256(w.temp), 1e6);
    }

    /**
     * @notice if the time it took to sell out between this season and
     * the last season is within 60 seconds, AND
     * the change in bean sown is decreasing,
     * demand is steady.
     */
    function testSowTimeSoldOutSowSameTimeDecreasingBeanSown(
        uint256 lastSowTime,
        uint256 thisSowTime,
        uint256 beanSown
    ) public {
        // set podrate to reasonably high,
        // as we want to verify temp changes as a function of soil demand.
        season.setPodRate(RES_HIGH);
        season.setPrice(ABOVE_PEG, well);

        // 10% temp for easier testing.
        bs.setMaxTempE(10e6);
        // the maximum value of lastSowTime is 3600
        // the minimum time it takes to sell out is SOW_TIME_DEMAND_INCR seconds.
        // (otherwise we assume increasing demand).
        lastSowTime = bound(lastSowTime, SOW_TIME_DEMAND_INCR, 3600);
        thisSowTime = bound(thisSowTime, lastSowTime, lastSowTime + 60);

        season.setLastSowTimeE(uint32(lastSowTime));
        season.setNextSowTimeE(uint32(thisSowTime));

        // set the same amount of beans sown last and this season such that the change in bean sown is increasing.
        beanSown = bound(beanSown, 25e6, (BASE_BEAN_SOIL * 94) / 100);
        season.setLastSeasonAndThisSeasonBeanSown(BASE_BEAN_SOIL, uint128(beanSown));

        // calc caseId
        season.calcCaseIdE(1, uint128(beanSown));

        // beanstalk should record this season's sow time,
        // and set it as last sow time for next season.
        IMockFBeanstalk.Weather memory w = bs.weather();
        assertEq(uint256(w.lastSowTime), thisSowTime);
        assertEq(uint256(w.thisSowTime), type(uint32).max);

        // verify ∆temp is 1% (see whitepaper).
        assertEq(10e6 - uint256(w.temp), 1e6);
    }

    /**
     * @notice if the time it took to sell out between this season was
     * more than SOW_TIME_STEADY_LOWER seconds faster than last season, demand is increasing.
     */
    function testSowTimeSoldOutFaster(uint256 lastSowTime, uint256 thisSowTime) public {
        // set podrate to reasonably high,
        // as we want to verify temp changes as a function of soil demand.
        season.setPodRate(RES_HIGH);
        season.setPrice(ABOVE_PEG, well);

        // 10% temp for easier testing.
        bs.setMaxTempE(10e6);
        // the maximum value of lastSowTime is 3600 - SOW_TIME_STEADY - 2 due to steady demand constant
        // the minimum time it takes to sell out is 600 seconds.
        // (otherwise we assume increasing demand).
        lastSowTime = bound(lastSowTime, SOW_TIME_STEADY_LOWER + 2, 3600);
        thisSowTime = bound(thisSowTime, 1, lastSowTime - SOW_TIME_STEADY_LOWER - 1);

        season.setLastSowTimeE(uint32(lastSowTime));
        season.setNextSowTimeE(uint32(thisSowTime));

        season.setLastSeasonAndThisSeasonBeanSown(BASE_BEAN_SOIL, BASE_BEAN_SOIL);

        // calc caseId
        season.calcCaseIdE(1, BASE_BEAN_SOIL);

        // beanstalk should record this season's sow time,
        // and set it as last sow time for next season.
        IMockFBeanstalk.Weather memory w = bs.weather();
        assertEq(uint256(w.lastSowTime), thisSowTime);
        assertEq(uint256(w.thisSowTime), type(uint32).max);
        uint256 steadyDemand;

        // verify ∆temp is 3% (see whitepaper).
        assertEq(10e6 - uint256(w.temp), 3e6, "delta temp is not 3%");
    }

    /**
     * @notice if the soil sown in the season is below the minimum demand threshold,
     * of max(max(0,001% of supply, 10), 25% of soil issued) demand is considered decreasing.
     */
    function testDeltaPodDemandDecreasingBelowThreshold(
        uint256 soilSown,
        uint256 initialSoil,
        uint256 beanSupply
    ) public {
        // init total supply = 10k beans
        uint256 beanSupply = bound(beanSupply, 10_000e6, 10_000_000e6);
        // mint beanSupply to increase
        deal(address(bean), address(1), beanSupply);
        beanSupply = bean.totalSupply();
        // bound initial soil to 0 - beanSupply
        initialSoil = bound(initialSoil, 4, beanSupply);

        uint256 minDemandThreshold = calcMinSoilDemandThreshold(beanSupply, initialSoil);

        // soil sown is less than the min threashold to measure demand
        soilSown = bound(soilSown, 0, minDemandThreshold - 1);

        // set podrate to reasonably high,
        // as we want to verify temp changes as a function of soil demand.
        season.setPodRate(RES_HIGH);
        season.setPrice(ABOVE_PEG, well);

        // 10% temp for easier testing.
        bs.setMaxTempE(10e6);
        // set initial soil
        bs.setSoilE(initialSoil);

        // calc caseId  (deltaB, beanSown==dsoil)
        season.calcCaseIdE(1, uint128(soilSown));

        // if soil sown is below the threshold, demand is decreasing.
        // beanstalk should record this season's sow time,
        // and set it as last sow time for next season.
        IMockFBeanstalk.Weather memory w = bs.weather();
        assertEq(uint256(w.thisSowTime), type(uint32).max);
        uint256 steadyDemand;
        // reasonably high pod rate, above peg price, soil demand decreasing
        // so temperature should stay the same, see https://docs.pinto.money/advanced/cases
        assertEq(10e6 - uint256(w.temp), 0, "delta temp is not 0%");
    }

    /**
     * @notice Extracts and normalizes the individual evaluation components from a caseId
     * @param caseId The full case ID
     * @return podRateCase The normalized pod rate evaluation (0, 1, 2, or 3 from original 0, 9, 18, or 27)
     * @return priceCase The normalized price evaluation (0, 1, or 2 from original 0, 3, or 6)
     * @return deltaPodDemandCase The delta pod demand evaluation (0, 1, or 2 - unchanged)
     * @return lpToSupplyRatioCase The normalized LP to supply ratio evaluation (0, 1, 2, or 3 from original 0, 36, 72, or 108)
     */
    function extractNormalizedCaseComponents(
        uint256 caseId
    )
        public
        view
        returns (
            uint256 podRateCase,
            uint256 priceCase,
            uint256 deltaPodDemandCase,
            uint256 lpToSupplyRatioCase
        )
    {
        // L2SR
        lpToSupplyRatioCase = caseId / 36;

        // Pod Rate: ((caseId % 36) / 9)
        podRateCase = (caseId % 36) / 9;

        // Price: Get the range 0-8 first ((caseId % 36) % 9), then divide by 3
        priceCase = ((caseId % 36) % 9) / 3;

        // Soil Demand: simple modulo
        deltaPodDemandCase = caseId % 3;

        if (caseId >= 1000) {
            podRateCase = 4;
        }
    }

    function calcMinSoilDemandThreshold(
        uint256 beanSupply,
        uint256 initialSoil
    ) internal view returns (uint256 minDemandThreshold) {
        // calculate the minimum threshold of bean to calculate delta pod demand.
        uint256 calculatedThreshold = (beanSupply * 0.00001e6) / 1e6;

        uint256 beanSupplyThreshold = calculatedThreshold > 10e6 ? calculatedThreshold : 10e6;

        // scale s.sys.initialSoil by the initialSoilPodDemandScalar, currently 25%.
        uint256 scaledInitialSoil = (initialSoil * 0.25e6) / 1e6;

        minDemandThreshold = beanSupplyThreshold < scaledInitialSoil
            ? beanSupplyThreshold
            : scaledInitialSoil;
    }

    /**
     * @notice Logs a human readable description of each component of a case ID
     * @param caseId The full case ID to decode and log
     */
    /*function describeCaseId(uint256 caseId) public view {
        (
            uint256 podRateCase,
            uint256 priceCase,
            uint256 deltaPodDemandCase,
            uint256 lpToSupplyRatioCase
        ) = extractNormalizedCaseComponents(caseId);
        console.log("Case ID:", caseId);

        // Log LP to Supply Ratio
        if (lpToSupplyRatioCase == 0) console.log("L2SR: Excessively Low L2SR (0)");
        else if (lpToSupplyRatioCase == 1) console.log("L2SR: Reasonably Low L2SR (1)");
        else if (lpToSupplyRatioCase == 2) console.log("L2SR: Reasonably High L2SR (2)");
        else console.log("L2SR: Excessively High L2SR (3)");

        // Log Pod Rate
        if (podRateCase == 0) console.log("Pod Rate: Excessively Low Debt (0)");
        else if (podRateCase == 1) console.log("Pod Rate: Reasonably Low Debt (1)");
        else if (podRateCase == 2) console.log("Pod Rate: Reasonably High Debt (2)");
        else console.log("Pod Rate: Excessively Debt (3)");

        // Log Price
        if (priceCase == 0) console.log("Price: Below Peg (P < 1) (0)");
        else if (priceCase == 1) console.log("Price: Above Peg (P > 1) (1)");
        else console.log("Price: Excessively Above Peg (P >> 1) (2)");

        // Log Delta Pod Demand
        if (deltaPodDemandCase == 0) console.log("Demand: Decreasing Pod Demand (0)");
        else if (deltaPodDemandCase == 1) console.log("Demand: Steady Pod Demand (1)");
        else console.log("Demand: Increasing Pod Demand (2)");
    }*/
}

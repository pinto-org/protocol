// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {MockFieldFacet} from "contracts/mocks/mockFacets/MockFieldFacet.sol";
import {C} from "contracts/C.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

contract FieldTest is TestHelper {
    // events
    event Harvest(address indexed account, uint256 fieldId, uint256[] plots, uint256 beans);
    event Sow(address indexed account, uint256 fieldId, uint256 index, uint256 beans, uint256 pods);

    // Interfaces.
    MockFieldFacet field = MockFieldFacet(BEANSTALK);

    // test accounts
    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // initializes farmers from farmers (farmer0 == diamond deployer)
        farmers.push(users[1]);
        farmers.push(users[2]);

        // max approve.
        maxApproveBeanstalk(farmers);

        // set max temperature to 1% = 1e6
        bs.setMaxTempE(1e6);
    }

    //////////////// REVERTS ////////////////

    /**
     * farmer cannot sow if there is no soil.
     */
    function test_sowNoSoil(uint256 beans) public {
        beans = bound(beans, 1, type(uint256).max);
        // issue `beans` to farmers
        bean.mint(farmers[0], beans);
        vm.prank(farmers[0]);
        vm.expectRevert("Field: Soil Slippage");
        field.sow(
            beans, // amt
            1e6, // min temperature
            LibTransfer.From.EXTERNAL
        );
    }

    /**
     * @notice min soil cannot be greater than soil.
     */
    function test_sowSoilBelowMinSoil(uint256 beans, uint256 soil) public {
        beans = bound(beans, 2, type(uint128).max); // soil casted to uint128.
        soil = bound(soil, 1, beans - 1); // beans less than soil.

        // issue `beans` to farmers
        bean.mint(farmers[0], beans);
        season.setSoilE(soil - 1);
        vm.prank(farmers[0]);
        vm.expectRevert("Field: Soil Slippage");
        field.sowWithMin(
            beans, // amt
            1e6, // min temperature
            soil, // min soil
            LibTransfer.From.EXTERNAL
        );
    }

    /**
     * @notice `beans` cannot be lower than `minSoil`.
     */
    function test_sowBeansBelowMinSoil(uint256 beans, uint256 soil) public {
        soil = bound(soil, 1, type(uint128).max); // soil casted to uint128.
        beans = bound(beans, 0, soil - 1); // beans less than soil.

        // issue `beans` to farmers
        bean.mint(farmers[0], beans);
        vm.prank(farmers[0]);
        vm.expectRevert("Field: Soil Slippage");
        field.sowWithMin(
            beans, // amt
            1e6, // min temperature
            soil, // min soil
            LibTransfer.From.EXTERNAL
        );
    }

    /**
     * @notice tests that farmer can sow all the soil.
     * Checks state after sowing.
     * @param from 0 = external, 1 = internal
     */
    function testSowAllSoil(uint256 soil, bool from) public {
        soil = bound(soil, 100, type(uint128).max);
        bean.mint(farmers[0], soil);
        uint256 beanBalanceBefore = bs.getBalance(farmers[0], BEAN);
        uint256 totalBeanSupplyBefore = bean.totalSupply();
        if (from) {
            // if internal, transferToken to internal balances.
            vm.prank(farmers[0]);
            bs.transferToken(BEAN, farmers[0], soil, 0, 1);
        }

        _beforeEachSow(soil, soil, from == true ? 1 : 0);
        sowAssertEq(farmers[0], beanBalanceBefore, totalBeanSupplyBefore, soil, _minPods(soil));
        assertEq(field.totalSoil(), 0, "total Soil");

        // verify sowThisTime is set.
        assertLe(uint256(bs.weather().thisSowTime), type(uint32).max);
    }

    /**
     * @notice verify that farmer can correctly sows a portion of soil.
     * @param from 0 = external, 1 = internal
     */
    function test_SowSoil(uint256 beansToSow, uint256 soil, bool from) public {
        soil = bound(soil, 100, type(uint128).max); // soil casted to uint128.
        beansToSow = bound(beansToSow, 1, soil); // bounded by soil.
        bean.mint(farmers[0], beansToSow);

        if (from) {
            // if internal, transferToken to internal balances.
            vm.prank(farmers[0]);
            bs.transferToken(BEAN, farmers[0], beansToSow, 0, 1);
        }

        uint256 beanBalanceBefore = bs.getBalance(farmers[0], BEAN);
        uint256 totalBeanSupplyBefore = bean.totalSupply();

        _beforeEachSow(soil, beansToSow, from == true ? 1 : 0);
        sowAssertEq(
            farmers[0],
            beanBalanceBefore,
            totalBeanSupplyBefore,
            beansToSow,
            _minPods(beansToSow)
        );
        assertEq(uint256(field.totalSoil()), soil - beansToSow, "total Soil");
    }

    /**
     * sow soil from internal tolerant mode.
     * @dev internal tolerant will receive tokens
     * from the farmer's Internal Balance and will not fail
     * if there is not enough in their Internal Balance.
     */
    function test_SowSoilFromInternalTolerant(
        uint256 beansToSow,
        uint256 soil,
        uint256 beansToInternal
    ) public {
        soil = bound(soil, 100, type(uint128).max); // soil casted to uint128.
        beansToSow = bound(beansToSow, 1, soil); // bounded by soil.
        beansToInternal = bound(beansToInternal, 1, beansToSow); // internal beans < beansToSow
        bean.mint(farmers[0], beansToInternal);

        vm.prank(farmers[0]);

        // transfer to their internal balance.
        bs.transferToken(BEAN, farmers[0], beansToInternal, 0, 1);
        uint256 beanBalanceBefore = bs.getBalance(farmers[0], BEAN);
        uint256 totalBeanSupplyBefore = bean.totalSupply();

        _beforeEachSowInternalTolerant(soil, beansToSow, beansToInternal);
        if (beansToSow > beansToInternal) beansToSow = beansToInternal;
        sowAssertEq(
            farmers[0],
            beanBalanceBefore,
            totalBeanSupplyBefore,
            beansToSow,
            _minPods(beansToSow)
        );
        assertEq(field.totalSoil(), soil - beansToSow, "total Soil");
    }

    /**
     * in cases where a farmer wants to sow more beans than soil available,
     * beanstalk introduces a `minSoil` parameter, which allows the farmer to
     * specify the minimum amount of soil they are willing to sow.
     */
    function testSowMin(uint256 minSoil, uint256 beans) public prank(farmers[0]) {
        // bound variables s.sys.t beans >= amount
        minSoil = bound(minSoil, 100, type(uint128).max);
        beans = bound(beans, minSoil, type(uint128).max);
        bean.mint(farmers[0], beans);

        uint256 beanBalanceBefore = bean.balanceOf(farmers[0]);
        uint256 totalBeanSupplyBefore = bean.totalSupply();

        bs.setSoilE(minSoil);
        field.sowWithMin(
            beans, // amount to sow
            0, // min.t
            0, // farmer is willing to min any amount of soil.
            LibTransfer.From.EXTERNAL
        );

        uint256 amountSown = beans > minSoil ? minSoil : beans;

        sowAssertEq(
            farmers[0],
            beanBalanceBefore,
            totalBeanSupplyBefore,
            amountSown,
            _minPods(amountSown)
        );

        assertEq(field.totalSoil(), 0);
    }

    /**
     * test ensures that multiple sows correctly
     * updates plot index, total pods, and total soil.
     */
    function testSowFrom2farmers(
        uint256 soilAvailable,
        uint256 farmer1Sow,
        uint256 farmer2Sow
    ) public {
        soilAvailable = bound(soilAvailable, 2, type(uint128).max);
        farmer1Sow = bound(farmer1Sow, 1, soilAvailable / 2);
        farmer2Sow = bound(farmer2Sow, 1, soilAvailable / 2);
        uint256 farmer1BeansBeforeSow;
        uint256 farmer2BeansBeforeSow;

        (
            farmer1Sow,
            farmer2Sow,
            farmer1BeansBeforeSow,
            farmer2BeansBeforeSow
        ) = beforeEachSow2farmers(soilAvailable, farmers[0], farmer1Sow, farmers[1], farmer2Sow);

        uint256 totalAmountSown = farmer1Sow + farmer2Sow;
        uint256 farmer1Pods = _minPods(farmer1Sow);
        uint256 farmer2Pods = _minPods(farmer2Sow);
        uint256 totalPodsIssued = farmer1Pods + farmer2Pods;

        assertEq(
            bean.balanceOf(farmers[0]),
            farmer1BeansBeforeSow - farmer1Sow,
            "farmer 1 invalid balance"
        );
        assertEq(field.plot(farmers[0], 0, 0), farmer1Pods, "farmer 1 invalid pods");

        assertEq(
            bean.balanceOf(farmers[1]),
            farmer2BeansBeforeSow - farmer2Sow,
            "farmer 2 invalid balance"
        );
        assertEq(field.plot(farmers[1], 0, farmer1Pods), farmer2Pods, "farmer 2 invalid pods");
        assertEq(
            bean.totalSupply(),
            farmer1BeansBeforeSow + farmer2BeansBeforeSow - totalAmountSown,
            "invalid bean supply"
        );
        assertEq(bean.balanceOf(BEANSTALK), 0, "beans remaining in beanstalk");

        assertEq(field.totalPods(0), totalPodsIssued, "invalid total pods");
        assertEq(field.totalUnharvestable(0), totalPodsIssued, "invalid unharvestable");
        assertEq(field.podIndex(0), totalPodsIssued, "invalid pod index");

        assertEq(field.totalSoil(), soilAvailable - totalAmountSown);
    }

    /**
     * Checking next sow time, with more than 1 soil above the dynamic mostly sold out threshold.
     * @dev Verifies that `thisSowTime` is at the max value
     */
    function testComplexDPDMoreThan1SoilMostlySoldOut(
        uint256 initialSoil,
        uint256 farmerSown
    ) public {
        initialSoil = bound(initialSoil, 2e6, type(uint128).max);
        // calculate threshold
        uint256 soilSoldOutThreshold = (initialSoil < 500e6) ? (initialSoil * 0.1e6) / 1e6 : 50e6;
        uint256 mostlySoldOutThreshold = (((initialSoil - soilSoldOutThreshold) * 0.2e6) / 1e6) +
            soilSoldOutThreshold;
        // ensure at least `soilSoldOutThreshold + 1` remains after sowing
        farmerSown = bound(farmerSown, 1, initialSoil - (mostlySoldOutThreshold + 1));
        // set initial soil
        bs.setSoilE(initialSoil);
        bean.mint(farmers[0], farmerSown);
        uint256 beans = bean.balanceOf(farmers[0]);
        // Simulate sowing
        vm.prank(farmers[0]);
        field.sow(beans, 0, LibTransfer.From.EXTERNAL);
        IMockFBeanstalk.Weather memory w = bs.weather();
        // otherwise, soil is not sold out
        assertEq(uint256(w.thisSowTime), type(uint32).max);
    }

    /**
     * Checking next sow time, with more than at least 1 soil + soldOut threshold.
     */
    function testComplexDPDMoreThan1SoilSoldOut(uint256 initialSoil, uint256 farmerSown) public {
        initialSoil = bound(initialSoil, 2e6, type(uint128).max);
        // calculate threshold
        uint256 soilSoldOutThreshold = (initialSoil < 500e6) ? (initialSoil * 0.1e6) / 1e6 : 50e6;
        uint256 mostlySoldOutThreshold = (((initialSoil - soilSoldOutThreshold) * 0.2e6) / 1e6) +
            soilSoldOutThreshold;
        // ensure at least `soilSoldOutThreshold + 1` remains after sowing
        farmerSown = bound(farmerSown, 1, initialSoil - (soilSoldOutThreshold + 1));
        // set initial soil
        bs.setSoilE(initialSoil);
        bean.mint(farmers[0], farmerSown);
        uint256 beans = bean.balanceOf(farmers[0]);
        // Simulate sowing
        vm.prank(farmers[0]);
        field.sow(beans, 0, LibTransfer.From.EXTERNAL);
        IMockFBeanstalk.Weather memory w = bs.weather();

        // if user sowed some amount such that soil is mostly sold out,
        if (initialSoil - mostlySoldOutThreshold <= farmerSown) {
            assertEq(uint256(w.thisSowTime), type(uint32).max - 1);
        } else {
            // Verify that `thisSowTime` was not set
            assertEq(uint256(w.thisSowTime), type(uint32).max);
        }
    }

    function _minPods(uint256 sowAmount) internal view returns (uint256) {
        // 1% of max temperature.
        return sowAmount + (sowAmount * bs.maxTemperature()) / 100e6 / 100;
    }

    function _beforeEachSow(uint256 soilAmount, uint256 sowAmount, uint8 from) public {
        // vm.roll(30);
        season.setSoilE(soilAmount);
        vm.expectEmit();
        emit Sow(farmers[0], 0, 0, sowAmount, _minPods(sowAmount)); // 1% of 1%
        vm.prank(farmers[0]);
        if (from == 0) {
            field.sow(sowAmount, 0, LibTransfer.From.EXTERNAL);
        } else if (from == 1) {
            field.sow(sowAmount, 0, LibTransfer.From.INTERNAL);
        } else if (from == 3) {
            field.sow(sowAmount, 0, LibTransfer.From.INTERNAL_TOLERANT);
        }
    }

    /**
     * @notice INTERNAL_TOLERANT is a mode where will receive tokens from the
     * farmer's Internal Balance and will not fail if there is not enough in their Internal Balance.
     *
     * In this example, a farmer can input a balance larger than their internal balance, but beanstalk will only credit up to their internal balance.
     * This prevents reverts.
     */
    function _beforeEachSowInternalTolerant(
        uint256 soilAmount,
        uint256 sowAmount,
        uint256 internalBalance
    ) public {
        // vm.roll(30);
        season.setSoilE(soilAmount);
        vm.expectEmit();
        if (internalBalance > sowAmount) internalBalance = sowAmount;
        emit Sow(farmers[0], 0, 0, internalBalance, _minPods(internalBalance));
        vm.prank(farmers[0]);
        field.sow(sowAmount, 0, LibTransfer.From.INTERNAL_TOLERANT);
    }

    function beforeEachSow2farmers(
        uint256 soil,
        address farmer0,
        uint256 amount0,
        address farmer1,
        uint256 amount1
    ) public returns (uint256, uint256, uint256, uint256) {
        season.setSoilE(soil);
        bean.mint(farmer0, amount0);
        uint256 initalBeanBalance0 = bean.balanceOf(farmer0);
        if (amount0 > soil) amount0 = soil;
        soil -= amount0;

        uint256 expectedPodsFarmer0 = _minPods(amount0);
        vm.startPrank(farmer0);
        vm.expectEmit(true, true, true, true);
        emit Sow(farmer0, 0, 0, amount0, expectedPodsFarmer0);
        field.sowWithMin(amount0, 0, 0, LibTransfer.From.EXTERNAL);
        vm.stopPrank();

        bean.mint(farmer1, amount1);
        uint256 initalBeanBalance1 = bean.balanceOf(farmer1);
        if (amount1 > soil) amount1 = soil;
        soil -= amount1;

        uint256 expectedPodsFarmer1 = _minPods(amount1);
        vm.startPrank(farmer1);
        vm.expectEmit(true, true, true, true);
        emit Sow(farmer1, 0, expectedPodsFarmer0, amount1, expectedPodsFarmer1);
        field.sowWithMin(amount1, 0, 0, LibTransfer.From.EXTERNAL);
        vm.stopPrank();

        return (amount0, amount1, initalBeanBalance0, initalBeanBalance1);
    }

    // // helper function to reduce clutter, asserts that the state of the field is as expected
    function sowAssertEq(
        address account,
        uint256 preBeanBalance,
        uint256 preTotalBalance,
        uint256 sowedAmount,
        uint256 expectedPods
    ) public view {
        assertEq(bs.getBalance(account, BEAN), preBeanBalance - sowedAmount, "balanceOf");
        assertEq(bean.balanceOf(BEANSTALK), 0, "field balanceOf");
        assertEq(bean.totalSupply(), preTotalBalance - sowedAmount, "total supply");

        //// FIELD STATE ////
        assertEq(field.plot(account, 0, 0), expectedPods, "plot");
        assertEq(field.totalPods(0), expectedPods, "total Pods");
        assertEq(field.totalUnharvestable(0), expectedPods, "totalUnharvestable");
        assertEq(field.podIndex(0), expectedPods, "podIndex");
        assertEq(field.harvestableIndex(0), 0, "harvestableIndex");
    }

    /**
     * @notice verifies that a farmer's plot index is updated correctly.
     * @dev partial harvests and transfers are tested here. full harvests/transfers can be seen in `test_plotIndexMultiple`.
     */
    function test_plotIndexList(uint256 sowAmount, uint256 portion) public {
        uint256 activeField = field.activeField();
        uint256[] memory plotIndexes = field.getPlotIndexesFromAccount(farmers[0], activeField);
        MockFieldFacet.Plot[] memory plots = field.getPlotsFromAccount(farmers[0], activeField);
        assertEq(plotIndexes.length, plots.length, "plotIndexes length");
        assertEq(plotIndexes.length, 0, "plotIndexes length");

        sowAmount = bound(sowAmount, 100, type(uint128).max);
        uint256 pods = _minPods(sowAmount);
        portion = bound(portion, 1, pods - 1);
        field.incrementTotalHarvestableE(activeField, portion);
        sowAmountForFarmer(farmers[0], sowAmount);

        plotIndexes = field.getPlotIndexesFromAccount(farmers[0], activeField);
        plots = field.getPlotsFromAccount(farmers[0], activeField);
        assertEq(plotIndexes.length, plots.length, "plotIndexes length");
        assertEq(plotIndexes.length, 1, "plotIndexes length");
        assertEq(plots[0].index, 0, "plotIndexes[0]");
        assertEq(plots[0].pods, pods, "plotIndexes[0]");

        uint256 snapshot = vm.snapshot();

        // transfer a portion of the plot.

        vm.prank(farmers[0]);
        bs.transferPlot(farmers[0], farmers[1], activeField, 0, 0, portion);

        // verify sender plot index.
        plotIndexes = field.getPlotIndexesFromAccount(farmers[0], activeField);
        plots = field.getPlotsFromAccount(farmers[0], activeField);
        assertEq(plotIndexes.length, plots.length, "plotIndexes length");
        assertEq(plotIndexes.length, 1, "plotIndexes length");
        assertEq(plots[0].index, portion, "plotIndexes[0]");
        assertEq(plots[0].pods, pods - portion, "plotIndexes[0]");

        // verify receiver plot index.
        plotIndexes = field.getPlotIndexesFromAccount(farmers[1], activeField);
        plots = field.getPlotsFromAccount(farmers[1], activeField);
        assertEq(plotIndexes.length, plots.length, "plotIndexes length");
        assertEq(plotIndexes.length, 1, "plotIndexes length");
        assertEq(plots[0].index, 0, "plotIndexes[0]");
        assertEq(plots[0].pods, portion, "plotIndexes[0]");

        // revert to snapshot, harvest portion of plot.
        vm.revertTo(snapshot);

        plotIndexes = field.getPlotIndexesFromAccount(farmers[0], activeField);
        vm.prank(farmers[0]);
        field.harvest(activeField, plotIndexes, LibTransfer.To.EXTERNAL);

        plotIndexes = field.getPlotIndexesFromAccount(farmers[0], activeField);
        plots = field.getPlotsFromAccount(farmers[0], activeField);
        assertEq(plotIndexes.length, plots.length, "plotIndexes length");
        assertEq(plotIndexes.length, 1, "plotIndexes length");
        assertEq(plots[0].index, portion, "plotIndexes[0]");
        assertEq(plots[0].pods, pods - portion, "plotIndexes[0]");
    }

    /**
     * @notice performs a series of actions to verify sows multiple times and verifies that the plot index is updated correctly.
     * 1. sowing properly increments the plot index.
     * 2. transferring a plot properly decrements the senders' plot index,
     * and increments the recipients' plot index.
     * 3. harvesting a plot properly decrements the senders' plot index.
     */
    function test_plotIndexMultiple() public {
        uint256 activeField = field.activeField();
        //////////// SOWING ////////////

        uint256 sowAmount = rand(0, 10e6);
        uint256 sows = rand(1, 1000);
        for (uint256 i; i < sows; i++) {
            sowAmountForFarmer(farmers[0], sowAmount);
        }
        verifyPlotIndexAndPlotLengths(farmers[0], activeField, sows);
        uint256 pods = _minPods(sowAmount);
        MockFieldFacet.Plot[] memory plots = field.getPlotsFromAccount(farmers[0], activeField);
        for (uint256 i; i < sows; i++) {
            assertEq(plots[i].index, i * pods, "plotIndexes");
            assertEq(plots[i].pods, pods, "plotIndexes");
        }

        //////////// TRANSFER ////////////

        // transfers a random amount of plots to farmer[1].
        uint256 transfers = rand(1, ((sows - 1) / 2) + 1);

        uint256[] memory plotIndexes = field.getPlotIndexesFromAccount(farmers[0], activeField);
        assembly {
            mstore(plotIndexes, transfers)
        }
        uint256[] memory ends = new uint256[](transfers);

        for (uint256 i; i < transfers; i++) {
            ends[i] = pods;
        }

        vm.startPrank(farmers[0]);
        bs.transferPlots(
            farmers[0],
            farmers[1],
            activeField,
            plotIndexes,
            new uint256[](transfers),
            ends
        );
        vm.stopPrank();
        verifyPlotIndexAndPlotLengths(farmers[0], activeField, sows - transfers);

        // upon a transfer/burn, the list of plots are not ordered.
        plots = field.getPlotsFromAccount(farmers[0], activeField);
        for (uint256 i; i < plots.length; i++) {
            assertTrue(plots[i].index % pods == 0);
            assertEq(plots[i].pods, pods, "pods");
        }

        verifyPlotIndexAndPlotLengths(farmers[1], activeField, transfers);

        plots = field.getPlotsFromAccount(farmers[1], activeField);
        for (uint256 i; i < plots.length; i++) {
            assertTrue(plots[i].index % pods == 0);
            assertEq(plots[i].pods, pods, "pods");
        }

        //////////// HARVESTING ////////////

        // verify that a user is able to harvest all plots from calling their `getPlotIndexesFromAccount`
        // assuming all valid indexes are returned.
        field.incrementTotalHarvestableE(field.activeField(), 1000 * pods);

        uint256[] memory accountPlots = field.getPlotIndexesFromAccount(farmers[0], activeField);
        vm.prank(farmers[0]);
        field.harvest(activeField, accountPlots, LibTransfer.To.EXTERNAL);
        verifyPlotIndexAndPlotLengths(farmers[0], activeField, 0);
        // verify that plots are empty.
        plots = field.getPlotsFromAccount(farmers[0], activeField);

        accountPlots = field.getPlotIndexesFromAccount(farmers[1], activeField);
        vm.prank(farmers[1]);
        field.harvest(activeField, accountPlots, LibTransfer.To.EXTERNAL);
        // verify that plots are empty.
        verifyPlotIndexAndPlotLengths(farmers[1], activeField, 0);
    }

    function test_multipleFields(uint256 sowsPerField, uint256 sowAmount) public {
        uint256 sowAmount = bound(sowAmount, 1, type(uint32).max);
        uint256 sowsPerField = bound(sowsPerField, 1, 20);

        vm.prank(deployer);
        field.addField();
        vm.prank(deployer);
        field.addField();

        for (uint256 j; j < field.fieldCount(); j++) {
            vm.prank(deployer);
            field.setActiveField(j, 101e6);
            uint256 activeField = field.activeField();
            for (uint256 i; i < sowsPerField; i++) {
                sowAmountForFarmer(farmers[0], sowAmount);
            }
        }

        uint256 pods = _minPods(sowAmount);
        MockFieldFacet.Plot[] memory plots;
        for (uint256 j; j < field.fieldCount(); j++) {
            verifyPlotIndexAndPlotLengths(farmers[0], j, sowsPerField);
            plots = field.getPlotsFromAccount(farmers[0], j);
            for (uint256 i; i < sowsPerField; i++) {
                assertEq(plots[i].index, i * pods, "plots.index unexpected");
                assertEq(plots[i].pods, pods, "plot.pods unexpected");
            }
        }

        uint256 activeField = field.activeField();
        field.incrementTotalHarvestableE(activeField, 1000 * pods);
        uint256[] memory accountPlots = field.getPlotIndexesFromAccount(farmers[0], activeField);
        vm.prank(farmers[0]);
        field.harvest(activeField, accountPlots, LibTransfer.To.EXTERNAL);
        verifyPlotIndexAndPlotLengths(farmers[0], activeField, 0);

        assertGt(field.fieldCount(), 1, "field count");
    }

    function test_morningAuctionTemperature() public {
        bool verbose = false;
        uint256 temperature = field.temperature();
        uint256 maxTemperature = bs.maxTemperature();
        for (uint256 i; i < 605; i++) {
            uint256 temperature = field.temperature();
            assertGe(temperature, temperature, "temperature is not increasing");
            if (i >= 600) {
                assertEq(temperature, maxTemperature, "temperature != max temperature");
            } else {
                assertLe(temperature, maxTemperature, "temperature > max temperature");
            }
            vm.warp(block.timestamp + 1);
        }
    }

    // field helpers.

    function verifyPlotIndexAndPlotLengths(
        address farmer,
        uint256 fieldId,
        uint256 expectedLength
    ) public view {
        uint256[] memory plotIndexes = field.getPlotIndexesFromAccount(farmer, fieldId);
        MockFieldFacet.Plot[] memory plots = field.getPlotsFromAccount(farmer, fieldId);
        assertEq(plotIndexes.length, plots.length, "plotIndexes length != plots length");
        assertEq(plotIndexes.length, expectedLength, "plotIndexes length unexpected");
    }

    function test_transferPlotUnauthorized(uint256 sowAmount, uint256 transferAmount) public {
        uint256 activeField = field.activeField();
        sowAmount = bound(sowAmount, 1, type(uint32).max);
        transferAmount = bound(transferAmount, 1, sowAmount);

        // Farmer 0 sows some plots
        sowAmountForFarmer(farmers[0], sowAmount);
        uint256 pods = _minPods(sowAmount);

        // Farmer 1 tries to transfer farmer 0's plot without permission
        vm.prank(farmers[1]);
        vm.expectRevert("Field: Insufficient approval.");
        bs.transferPlot(farmers[0], farmers[1], activeField, 0, 0, transferAmount);
    }

    function test_transferPlotsUnauthorized(uint256 sowAmount, uint256 transferAmount) public {
        uint256 activeField = field.activeField();
        sowAmount = bound(sowAmount, 1, type(uint32).max);
        transferAmount = bound(transferAmount, 1, sowAmount);

        // Farmer 0 sows some plots
        sowAmountForFarmer(farmers[0], sowAmount);
        uint256 pods = _minPods(sowAmount);

        // Set up arrays for transferPlots
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        uint256[] memory starts = new uint256[](1);
        starts[0] = 0;
        uint256[] memory ends = new uint256[](1);
        ends[0] = transferAmount;

        // Farmer 1 tries to transfer farmer 0's plot without permission
        vm.prank(farmers[1]);
        vm.expectRevert("Field: Insufficient approval.");
        bs.transferPlots(farmers[0], farmers[1], activeField, indexes, starts, ends);
    }

    /////////// Merge plots ///////////

    /**
     * @notice  Tests merging of plots from a farmer with 10 sows of 100 beans each at 1% temp
     */
    function test_mergeAdjacentPlotsSimple() public {
        uint256 activeField = bs.activeField();
        mintTokensToUser(farmers[0], BEAN, 1000e6);
        uint256[] memory plotIndexes = setUpMultipleConsecutiveAccountPlots(farmers[0], 1000e6, 10);
        IMockFBeanstalk.Plot[] memory plots = bs.getPlotsFromAccount(farmers[0], bs.activeField());
        uint256 totalPodsBeforeCombine = 0;
        for (uint256 i = 0; i < plots.length; i++) {
            totalPodsBeforeCombine += plots[i].pods;
        }
        assertEq(plots.length, 10);
        // combine all plots into one
        vm.prank(farmers[0]);
        bs.combinePlots(activeField, plotIndexes);

        // assert user has 1 plot
        plots = bs.getPlotsFromAccount(farmers[0], activeField);
        assertEq(plots.length, 1);
        assertEq(plots[0].index, 0);
        assertEq(plots[0].pods, totalPodsBeforeCombine);

        // assert plot indexes length is 1
        assertEq(bs.getPlotIndexesLengthFromAccount(farmers[0], activeField), 1);

        // assert plot indexes is 0
        uint256[] memory plotIndexesAfterCombine = bs.getPlotIndexesFromAccount(
            farmers[0],
            activeField
        );
        assertEq(plotIndexesAfterCombine.length, 1);
        assertEq(plotIndexesAfterCombine[0], 0);

        // assert piIndex for combined plot is correct
        assertEq(bs.getPiIndexFromAccount(farmers[0], activeField, 0), 0);
    }

    /**
     * @notice Tests merging 2 sets of multiple non-adjacent plots
     */
    function test_mergeAdjacentPlotsMultiple() public {
        // setup non-adjacent plots for farmer 1
        uint256 sowAmount = 1000e6;
        uint256 firstAccountSows = 3; // plots 1-3 for farmer 0
        uint256 lastAccountSows = 2; // plots 5-6 for farmer 0
        uint256 gapSows = 2; // plots 3-5 for farmer 1
        uint256[] memory account1PlotIndexes = setUpNonAdjacentPlots(
            farmers[0],
            farmers[1],
            sowAmount,
            firstAccountSows,
            lastAccountSows,
            gapSows
        );
        uint256 totalPodsBefore = getTotalPodsFromAccount(farmers[0]);

        // try to combine plots, expect revert since plots are not adjacent
        uint256 activeField = bs.activeField();
        vm.prank(farmers[0]);
        vm.expectRevert("Field: Plots to combine not adjacent");
        bs.combinePlots(activeField, account1PlotIndexes);

        // merge adjacent plots in pairs (indexes 1-3)
        uint256[] memory adjacentPlotIndexes = new uint256[](3);
        adjacentPlotIndexes[0] = account1PlotIndexes[0];
        adjacentPlotIndexes[1] = account1PlotIndexes[1];
        adjacentPlotIndexes[2] = account1PlotIndexes[2];
        vm.prank(farmers[0]);
        bs.combinePlots(activeField, adjacentPlotIndexes);
        // assert user has 3 plots (1 from the 3 merged, 2 from the original)
        assertEq(bs.getPlotIndexesLengthFromAccount(farmers[0], activeField), 3);
        // assert first plot index is 0 after merge
        assertEq(bs.getPlotIndexesFromAccount(farmers[0], activeField)[0], 0);
        // assert piIndex for first combined plot is correct
        assertEq(bs.getPiIndexFromAccount(farmers[0], activeField, 0), 0);

        // plots for farmer 2 should remain unchanged in the middle of the queue
        assertEq(bs.getPlotIndexesLengthFromAccount(farmers[1], activeField), 2);

        // merge adjacent plots in pairs (indexes 5-6)
        adjacentPlotIndexes = new uint256[](2);
        adjacentPlotIndexes[0] = account1PlotIndexes[3];
        adjacentPlotIndexes[1] = account1PlotIndexes[4];
        vm.prank(farmers[0]);
        bs.combinePlots(activeField, adjacentPlotIndexes);
        // assert user has 2 plots (1 from the 2 merged, 1 from the 3 original merged)
        assertEq(bs.getPlotIndexesLengthFromAccount(farmers[0], activeField), 2);
        // assert first plot index remains the same after 2nd merge
        assertEq(bs.getPlotIndexesFromAccount(farmers[0], activeField)[0], 0);
        // final plot should start from the next to last previous plot index
        assertEq(bs.getPlotIndexesFromAccount(farmers[0], activeField)[1], 5000500000);
        // assert piIndex for both final plots are correct
        assertEq(bs.getPiIndexFromAccount(farmers[0], activeField, 0), 0);
        assertEq(bs.getPiIndexFromAccount(farmers[0], activeField, 5000500000), 1);

        // get total pods from account 1
        uint256 totalPodsAfter = getTotalPodsFromAccount(farmers[0]);
        // assert total pods after merge is the same as before merge
        assertEq(totalPodsAfter, totalPodsBefore);
    }

    /**
     * @notice Tests merging of adjacent plots but with unordered plotIndexes in storage
     */
    function test_mergeAdjacentPlotsWithUnorderedPlotIndexes() public {
        uint256 activeField = bs.activeField();
        mintTokensToUser(farmers[0], BEAN, 1000e6);
        uint256[] memory plotIndexes = setUpMultipleConsecutiveAccountPlots(farmers[0], 1000e6, 10);
        assertTrue(isArrayOrdered(plotIndexes), "Original plot indexes should be ordered");

        // Store original plot indexes for verification
        uint256[] memory originalPlotIndexes = new uint256[](plotIndexes.length);
        for (uint256 i = 0; i < plotIndexes.length; i++) {
            originalPlotIndexes[i] = plotIndexes[i];
        }

        // Get total pods before merge
        uint256 totalPodsBefore = getTotalPodsFromAccount(farmers[0]);

        // Create reordered array by copying and swapping elements
        uint256[] memory newPlotIndexes = new uint256[](plotIndexes.length);
        for (uint256 i = 0; i < plotIndexes.length; i++) {
            newPlotIndexes[i] = plotIndexes[i];
        }

        // Swap some elements to create unordered array (but still consecutive plots)
        swapArrayElementPositions(newPlotIndexes, 1, 5);
        swapArrayElementPositions(newPlotIndexes, 3, 7);
        swapArrayElementPositions(newPlotIndexes, 0, 9);

        // Reorder the plot indexes in storage to test merge with unordered array
        bs.reorderPlotIndexes(newPlotIndexes, activeField, farmers[0]);

        // Verify that plot indexes are now unordered in storage
        uint256[] memory reorderedIndexes = bs.getPlotIndexesFromAccount(farmers[0], activeField);
        assertTrue(!isArrayOrdered(reorderedIndexes), " New plot indexes should be unordered");

        // Combine plots using original indexes (irrelevant of plotIndexes order in storage)
        vm.prank(farmers[0]);
        bs.combinePlots(activeField, originalPlotIndexes);

        // Verify merge succeeded - should have only 1 plot left
        assertEq(bs.getPlotIndexesLengthFromAccount(farmers[0], activeField), 1);
        assertEq(bs.getPlotIndexesFromAccount(farmers[0], activeField)[0], originalPlotIndexes[0]);
        assertEq(bs.getPiIndexFromAccount(farmers[0], activeField, originalPlotIndexes[0]), 0);

        // Verify that merged plots have piIndex set to uint256.max (except the first one which should be 0)
        assertEq(bs.getPiIndexFromAccount(farmers[0], activeField, originalPlotIndexes[0]), 0);
        for (uint256 i = 1; i < originalPlotIndexes.length; i++) {
            assertEq(
                bs.getPiIndexFromAccount(farmers[0], activeField, originalPlotIndexes[i]),
                type(uint256).max
            );
        }

        // Verify total pods remained the same
        uint256 totalPodsAfter = getTotalPodsFromAccount(farmers[0]);
        assertEq(totalPodsAfter, totalPodsBefore);
    }

    /**
     * @notice Tests that combining plots requires caller to be the plot owner
     */
    function test_combinePlotsUnauthorized() public {
        uint256 activeField = bs.activeField();
        mintTokensToUser(farmers[0], BEAN, 1000e6);
        uint256[] memory plotIndexes = setUpMultipleConsecutiveAccountPlots(farmers[0], 1000e6, 3);

        // Farmer 1 tries to combine farmer 0's plots - should fail
        vm.prank(farmers[1]);
        vm.expectRevert("Field: Plot not owned by caller");
        bs.combinePlots(activeField, plotIndexes);

        // Verify plots are unchanged
        assertEq(bs.getPlotIndexesLengthFromAccount(farmers[0], activeField), 3);
    }

    /**
     * @dev Creates multiple consecutive plots for an account of size totalSoil/sowCount
     */
    function setUpMultipleConsecutiveAccountPlots(
        address account,
        uint256 totalSoil,
        uint256 sowCount
    ) internal returns (uint256[] memory plotIndexes) {
        // set soil to totalSoil
        bs.setSoilE(totalSoil);
        // sow totalSoil beans sowCount times of totalSoil/sowCount each
        uint256 sowAmount = totalSoil / sowCount;
        for (uint256 i = 0; i < sowCount; i++) {
            vm.prank(account);
            bs.sow(sowAmount, 0, uint8(LibTransfer.From.EXTERNAL));
        }
        plotIndexes = bs.getPlotIndexesFromAccount(account, bs.activeField());
        return plotIndexes;
    }

    /**
     * @dev Creates non-adjacent plots by having account1 sow, then account2 sow in between
     */
    function setUpNonAdjacentPlots(
        address account1,
        address account2,
        uint256 sowAmount,
        uint256 firstAccountSows,
        uint256 lastAccountSows,
        uint256 gapSows
    ) internal returns (uint256[] memory plotIndexes) {
        // Account1 sows 3 consecutive plots
        setSoilAndSow(account1, firstAccountSows, sowAmount);
        // Account2 sows 2 plots to create gaps in account1's sequence
        setSoilAndSow(account2, gapSows, sowAmount);
        // Account1 sows 2 more plots (now non-adjacent to first 3)
        setSoilAndSow(account1, lastAccountSows, sowAmount);
        // Get plot indexes
        plotIndexes = bs.getPlotIndexesFromAccount(account1, bs.activeField());
        return plotIndexes;
    }

    function getTotalPodsFromAccount(address account) internal view returns (uint256 totalPods) {
        uint256[] memory plotIndexes = bs.getPlotIndexesFromAccount(account, bs.activeField());
        for (uint256 i = 0; i < plotIndexes.length; i++) {
            totalPods += bs.plot(account, bs.activeField(), plotIndexes[i]);
        }
        return totalPods;
    }

    function setSoilAndSow(address account, uint256 iterations, uint256 sowAmount) internal {
        mintTokensToUser(account, BEAN, sowAmount * iterations);
        vm.prank(account);
        IERC20(BEAN).approve(address(bs), type(uint256).max);
        bs.setSoilE(sowAmount * iterations);
        for (uint256 i = 0; i < iterations; i++) {
            vm.prank(account);
            bs.sow(sowAmount, 0, uint8(LibTransfer.From.EXTERNAL));
        }
    }

    function swapArrayElementPositions(
        uint256[] memory array,
        uint256 index1,
        uint256 index2
    ) internal pure {
        require(index1 < array.length && index2 < array.length, "Field: Index out of bounds");
        uint256 temp = array[index1];
        array[index1] = array[index2];
        array[index2] = temp;
    }

    function isArrayOrdered(uint256[] memory array) internal pure returns (bool) {
        for (uint256 i = 1; i < array.length; i++) {
            if (array[i] < array[i - 1]) {
                return false;
            }
        }
        return true;
    }

    /////////// Referral Tests ///////////

    /**
     * @notice Test that sowWithReferral correctly allocates pods to sower (referee), referrer, and provides bonus to referee
     * @dev Verifies that referrer receives percentage of pods based on referrerPercentage, and referee gets bonus based on refereePercentage
     */
    function test_sowWithReferral(uint256 sowAmount) public {
        // Bound to uint64 max to avoid overflow issues with soil calculation

        // set temperature to 100%
        bs.setMaxTempE(100e6);

        // skip morning auction
        vm.roll(block.number + 500);
        vm.warp(block.timestamp + 600);

        sowAmount = bound(sowAmount, 100, type(uint64).max);

        // Set referrer percentage to 10% (0.1 * 1e18)
        bs.setReferrerPercentageE(0.1e6);

        // Set referee percentage to 5% (0.05 * 1e18)
        bs.setRefereePercentageE(0.1e6);

        // Setup: mint beans and set soil
        bean.mint(farmers[0], sowAmount);
        season.setSoilE(sowAmount + 1); // Add 1 to ensure enough soil

        // Get initial state
        uint256 farmer0BeansBefore = bean.balanceOf(farmers[0]);
        uint256 totalBeanSupplyBefore = bean.totalSupply();
        uint256 activeFieldPodIndexBefore = field.podIndex(field.activeField());

        // Calculate expected pods
        uint256 expectedFarmerPods = calcPods(sowAmount, 100e6);
        uint256 expectedReferrerPods;
        uint256 expectedRefereePods;

        // if the referrer is not valid, the function will silently return 0 for referrerPods and refereePods.

        // Sow with referral
        vm.prank(farmers[0]);
        uint256 snapshot = vm.snapshotState();
        (uint256 actualFarmerPods, uint256 actualReferrerPods, uint256 actualRefereePods) = field
            .sowWithReferral(
                sowAmount,
                0, // minTemperature
                0, // minSoil
                LibTransfer.From.EXTERNAL,
                farmers[1] // referrer address (who gets commission)
            );

        console.log("Actual Pods:", actualFarmerPods, actualReferrerPods, actualRefereePods);
        console.log(
            "Expected Pods:",
            expectedFarmerPods,
            expectedReferrerPods,
            expectedRefereePods
        );

        // Verify return values
        assertApproxEqAbs(actualFarmerPods, expectedFarmerPods, 1, "Farmer pods mismatch");
        assertEq(actualReferrerPods, expectedReferrerPods, "Referrer pods mismatch");
        assertEq(actualRefereePods, expectedRefereePods, "Referee pods mismatch");

        vm.revertToState(snapshot);
        field.setReferralEligibility(farmers[1], true);
        expectedReferrerPods = (expectedFarmerPods * field.getReferrerPercentage()) / 1e18;
        expectedRefereePods = (expectedFarmerPods * field.getRefereePercentage()) / 1e18;
        vm.prank(farmers[0]);
        (actualFarmerPods, actualReferrerPods, actualRefereePods) = field.sowWithReferral(
            sowAmount,
            0,
            0,
            LibTransfer.From.EXTERNAL,
            address(0)
        );

        // Verify farmer state
        assertEq(
            bean.balanceOf(farmers[0]),
            farmer0BeansBefore - sowAmount,
            "Farmer bean balance incorrect"
        );
        assertEq(
            field.plot(farmers[0], field.activeField(), activeFieldPodIndexBefore),
            actualFarmerPods,
            "Farmer plot pods incorrect"
        );

        // Verify referrer state
        assertEq(
            field.plot(
                farmers[1],
                field.activeField(),
                activeFieldPodIndexBefore + actualFarmerPods
            ),
            actualReferrerPods,
            "Referrer plot pods incorrect"
        );

        // Verify total supply decreased by sowAmount (referrer and referee bonus pods are minted from protocol, not farmer)
        assertEq(
            bean.totalSupply(),
            totalBeanSupplyBefore - sowAmount,
            "Total bean supply incorrect"
        );

        // Verify total pods increased correctly
        assertEq(
            field.totalPods(field.activeField()),
            actualFarmerPods + actualReferrerPods + actualRefereePods,
            "Total pods incorrect"
        );

        // Verify pod index advanced correctly
        assertEq(
            field.podIndex(field.activeField()),
            activeFieldPodIndexBefore + actualFarmerPods + actualReferrerPods + actualRefereePods,
            "Pod index incorrect"
        );
    }

    /**
     * @notice Test that sowWithReferral with address(0) works like regular sow
     */
    function test_sowWithReferralZeroAddress(uint256 sowAmount) public {
        uint256 activeField = field.activeField();
        // Bound to uint64 max to avoid overflow issues
        sowAmount = bound(sowAmount, 100, type(uint64).max);

        // Set referrer commission percentage
        bs.setReferrerPercentageE(0.1e6);

        // Setup
        bean.mint(farmers[0], sowAmount);
        season.setSoilE(sowAmount + 100); // Ensure enough soil

        uint256 farmer0BeansBefore = bean.balanceOf(farmers[0]);
        uint256 expectedPods = _minPods(sowAmount);

        // Sow with zero address referrer (no commission)
        vm.prank(farmers[0]);
        (uint256 actualPods, uint256 referrerPods, uint256 refereePods) = field.sowWithReferral(
            sowAmount,
            0,
            0,
            LibTransfer.From.EXTERNAL,
            address(0) // no referrer
        );

        // Verify farmer gets pods, no referrer commission or referee bonus
        assertEq(actualPods, expectedPods, "Farmer pods mismatch");
        assertEq(referrerPods, 0, "Referrer pods should be zero");
        assertEq(refereePods, 0, "Referee pods should be zero");
        assertEq(
            bean.balanceOf(farmers[0]),
            farmer0BeansBefore - sowAmount,
            "Farmer bean balance incorrect"
        );
        assertEq(field.plot(farmers[0], activeField, 0), expectedPods, "Farmer plot incorrect");
    }

    function test_referralEligibility_fuzz(address referrer, uint256 sowAmount) public {
        // Avoid 0-address and sender self-referrals
        vm.assume(referrer != address(0));

        bool defaultEligibility = field.isValidReferrer(referrer);
        assertEq(defaultEligibility, false, "Referrer should not be eligible by default");

        // Bound sowAmount to a reasonable range to avoid overflows and to make the logic meaningful
        sowAmount = bound(sowAmount, 1, 10_000e6);

        bean.mint(referrer, sowAmount);
        season.setSoilE(sowAmount + 10);

        vm.startPrank(referrer);
        IERC20(BEAN).approve(BEANSTALK, sowAmount);
        field.sowWithReferral(sowAmount, 0, 0, LibTransfer.From.EXTERNAL, address(0));

        bool newEligibility = field.isValidReferrer(referrer);

        if (sowAmount >= 1000e6) {
            assertEq(newEligibility, true, "Referrer should be eligible when sowAmount >= 1000e6");
        } else {
            assertEq(
                newEligibility,
                false,
                "Referrer should not be eligible when sowAmount < 1000e6"
            );
        }
    }

    function calcPods(uint256 beans, uint256 temperature) public pure returns (uint256) {
        return (beans * (100e6 + temperature)) / 100e6;
    }

    //////////// DELEGATION TESTS ////////////

    /**
     * @notice Test that a user can properly delegate their referral rewards to another address
     * @dev The USER must have sown >= threshold to be able to delegate.
     * The DELEGATE must not already be eligible.
     */
    function test_delegateReferralRewards_success() public {
        uint256 threshold = field.getBeanSownEligibilityThreshold();

        // Farmer 0 (USER) sows enough beans to earn the right to delegate
        sowAmountForFarmer(farmers[0], threshold);

        // Verify farmer 0 has sown enough and became eligible
        assertGe(
            field.getBeansSownForReferral(farmers[0]),
            threshold,
            "User should have sown threshold"
        );
        assertTrue(field.isValidReferrer(farmers[0]), "User should be eligible after sowing");

        // Farmer 1 (DELEGATE) should not be eligible yet
        assertFalse(field.isValidReferrer(farmers[1]), "Delegate should not be eligible");

        // Farmer 0 delegates to farmer 1
        vm.prank(farmers[0]);
        field.delegateReferralRewards(farmers[1]);

        // Verify delegation was set
        assertEq(field.getDelegate(farmers[0]), farmers[1], "Delegate should be set to farmers[1]");

        // verify farmer 1 is eligible
        assertTrue(field.isValidReferrer(farmers[1]), "Delegate should be eligible");
    }

    /**
     * @notice Test that delegation fails if the USER hasn't sown enough beans
     * @dev The error message says "delegate is not eligible" but it's actually checking
     * if the USER has sown enough, not the delegate.
     */
    function test_delegateReferralRewards_userNotEligible(uint256 insufficientAmount) public {
        uint256 threshold = field.getBeanSownEligibilityThreshold();

        // Bound to less than threshold
        insufficientAmount = bound(insufficientAmount, 0, threshold - 1);

        // Farmer 0 (USER) sows less than threshold
        if (insufficientAmount > 0) {
            sowAmountForFarmer(farmers[0], insufficientAmount);
        }

        // Verify farmer 0 hasn't sown enough
        assertLt(
            field.getBeansSownForReferral(farmers[0]),
            threshold,
            "User should not have sown threshold"
        );

        // Farmer 0 tries to delegate to farmer 1 - should fail
        vm.prank(farmers[0]);
        vm.expectRevert("Field: user cannot delegate");
        field.delegateReferralRewards(farmers[1]);

        // verify farmer 1 is not eligible
        assertFalse(field.isValidReferrer(farmers[1]), "Delegate should not be eligible");
    }

    /**
     * @notice Test that a user can change their delegation from one delegate to another
     */
    function test_delegateReferralRewards_changeDelegation() public {
        uint256 threshold = field.getBeanSownEligibilityThreshold();
        address farmer2 = users[3]; // Use users[3] since only farmers[0] and farmers[1] exist

        // Farmer 0 (USER) sows enough beans to earn the right to delegate
        sowAmountForFarmer(farmers[0], threshold);

        // Verify farmer 0 has sown enough
        assertGe(
            field.getBeansSownForReferral(farmers[0]),
            threshold,
            "User should have sown threshold"
        );

        // Farmer 1 and farmer2 should not be eligible (they are potential delegate targets)
        assertFalse(field.isValidReferrer(farmers[1]), "Delegate 1 should not be eligible");
        assertFalse(field.isValidReferrer(farmer2), "Delegate 2 should not be eligible");

        // Farmer 0 delegates to farmer 1
        vm.prank(farmers[0]);
        field.delegateReferralRewards(farmers[1]);

        assertEq(
            field.getDelegate(farmers[0]),
            farmers[1],
            "Initial delegate should be farmers[1]"
        );
        assertTrue(field.isValidReferrer(farmers[1]), "Delegate 1 should be eligible");

        // Now farmer 0 changes delegation to farmer2
        vm.prank(farmers[0]);
        field.delegateReferralRewards(farmer2);

        assertEq(field.getDelegate(farmers[0]), farmer2, "New delegate should be farmer2");
        assertTrue(field.isValidReferrer(farmer2), "Delegate 2 should be eligible");

        // Verify old delegate (farmer 1) had their eligibility reset to false
        assertFalse(
            field.isValidReferrer(farmers[1]),
            "Old delegate should have eligibility reset"
        );
    }

    /**
     * @notice Test that delegation to address(0) is blocked
     * @dev Delegation to address(0) could cause storage pollution and is conceptually incorrect.
     * This test verifies the fix for the address(0) delegation vulnerability.
     */
    function test_delegateReferralRewards_cannotDelegateToZeroAddress() public {
        uint256 threshold = field.getBeanSownEligibilityThreshold();

        // Farmer 0 (USER) sows enough beans to earn the right to delegate
        sowAmountForFarmer(farmers[0], threshold);

        // Verify farmer 0 has sown enough
        assertGe(
            field.getBeansSownForReferral(farmers[0]),
            threshold,
            "User should have sown threshold"
        );

        // Try to delegate to address(0) - should fail
        vm.prank(farmers[0]);
        vm.expectRevert("Field: delegate cannot be the zero address");
        field.delegateReferralRewards(address(0));
    }

    /**
     * @notice Test that changing delegation does NOT remove independently-earned eligibility from old delegate
     * @dev This is the key test for the griefing attack vulnerability fix.
     *
     * VULNERABILITY SCENARIO (before fix):
     * 1. Attacker (Alice) sows threshold beans, becomes eligible
     * 2. Alice delegates to Victim (Bob), making Bob eligible through delegation
     * 3. Bob independently sows threshold beans (Bob has now earned eligibility on their own)
     * 4. Alice changes delegation to Carol
     * 5. BEFORE FIX: Bob loses eligibility even though he earned it independently
     * 6. AFTER FIX: Bob keeps eligibility because he earned it through his own sowing
     *
     * This prevents a DDoS attack where an attacker could repeatedly delegate to someone
     * and then change delegation to remove their legitimately-earned eligibility.
     */
    function test_delegateReferralRewards_griefingAttackPrevented() public {
        uint256 threshold = field.getBeanSownEligibilityThreshold();
        address attacker = farmers[0];
        address victim = farmers[1];
        address carol = users[3];

        // Setup: ensure enough soil for multiple sows
        season.setSoilE(threshold * 5);

        // Step 1: Attacker sows threshold beans, becomes eligible
        bean.mint(attacker, threshold);
        vm.prank(attacker);
        field.sowWithReferral(threshold, 0, 0, LibTransfer.From.EXTERNAL, address(0));
        assertTrue(field.isValidReferrer(attacker), "Attacker should be eligible after sowing");

        // Step 2: Attacker delegates to victim, making victim eligible through delegation
        vm.prank(attacker);
        field.delegateReferralRewards(victim);
        assertTrue(field.isValidReferrer(victim), "Victim should be eligible through delegation");
        assertEq(field.getDelegate(attacker), victim, "Delegation should be set");

        // Step 3: Victim independently sows threshold beans (earns eligibility on their own)
        bean.mint(victim, threshold);
        vm.prank(victim);
        field.sowWithReferral(threshold, 0, 0, LibTransfer.From.EXTERNAL, address(0));

        // Verify victim has sown enough beans independently
        assertGe(
            field.getBeansSownForReferral(victim),
            threshold,
            "Victim should have sown threshold beans independently"
        );
        assertTrue(field.isValidReferrer(victim), "Victim should still be eligible");

        // Step 4: Attacker changes delegation to Carol
        vm.prank(attacker);
        field.delegateReferralRewards(carol);

        // Step 5 (AFTER FIX): Victim should KEEP eligibility because they earned it independently
        assertTrue(
            field.isValidReferrer(victim),
            "GRIEFING ATTACK PREVENTED: Victim should keep eligibility because they sowed enough beans independently"
        );

        // Carol should now be eligible through delegation
        assertTrue(field.isValidReferrer(carol), "Carol should be eligible through delegation");
        assertEq(field.getDelegate(attacker), carol, "Delegation should now be to Carol");
    }

    /**
     * @notice Test that changing delegation DOES remove eligibility when old delegate hasn't earned it independently
     * @dev This ensures the normal delegation change behavior still works correctly.
     * When changing delegation, if the old delegate hasn't earned eligibility through their own sowing,
     * their eligibility should be removed.
     */
    function test_delegateReferralRewards_changeDelegationRemovesUnearned() public {
        uint256 threshold = field.getBeanSownEligibilityThreshold();
        address delegator = farmers[0];
        address oldDelegate = farmers[1];
        address newDelegate = users[3];

        // Setup: delegator sows threshold beans
        sowAmountForFarmer(delegator, threshold);
        assertTrue(field.isValidReferrer(delegator), "Delegator should be eligible");

        // Delegator delegates to oldDelegate (who hasn't sown anything)
        vm.prank(delegator);
        field.delegateReferralRewards(oldDelegate);
        assertTrue(field.isValidReferrer(oldDelegate), "Old delegate should be eligible through delegation");

        // Verify old delegate has NOT sown enough beans independently
        assertLt(
            field.getBeansSownForReferral(oldDelegate),
            threshold,
            "Old delegate should not have sown threshold beans"
        );

        // Delegator changes delegation to newDelegate
        vm.prank(delegator);
        field.delegateReferralRewards(newDelegate);

        // Old delegate should LOSE eligibility because they didn't earn it independently
        assertFalse(
            field.isValidReferrer(oldDelegate),
            "Old delegate should lose eligibility because they didn't earn it independently"
        );

        // New delegate should be eligible
        assertTrue(field.isValidReferrer(newDelegate), "New delegate should be eligible");
    }

    /**
     * @notice Fuzz test for griefing attack prevention
     * @dev Tests various amounts to ensure the griefing protection works regardless of sow amounts
     */
    function test_delegateReferralRewards_griefingAttackPrevented_fuzz(uint256 victimSowAmount) public {
        uint256 threshold = field.getBeanSownEligibilityThreshold();

        // Victim sows at least the threshold (this is what earns them independent eligibility)
        victimSowAmount = bound(victimSowAmount, threshold, threshold * 10);

        address attacker = farmers[0];
        address victim = farmers[1];
        address newTarget = users[3];

        // Setup: ensure enough soil
        season.setSoilE(threshold + victimSowAmount + 100);

        // Attacker sows and becomes eligible
        bean.mint(attacker, threshold);
        vm.prank(attacker);
        field.sowWithReferral(threshold, 0, 0, LibTransfer.From.EXTERNAL, address(0));

        // Attacker delegates to victim
        vm.prank(attacker);
        field.delegateReferralRewards(victim);
        assertTrue(field.isValidReferrer(victim), "Victim eligible through delegation");

        // Victim sows enough to earn independent eligibility
        bean.mint(victim, victimSowAmount);
        vm.prank(victim);
        field.sowWithReferral(victimSowAmount, 0, 0, LibTransfer.From.EXTERNAL, address(0));

        // Attacker changes delegation
        vm.prank(attacker);
        field.delegateReferralRewards(newTarget);

        // Victim should keep eligibility (griefing prevented)
        assertTrue(
            field.isValidReferrer(victim),
            "Victim should keep eligibility regardless of attacker's delegation change"
        );
    }

    /**
     * @notice Test that a user cannot delegate to themselves
     */
    function test_delegateReferralRewards_cannotDelegateToSelf() public {
        uint256 threshold = field.getBeanSownEligibilityThreshold();

        // Farmer 0 (USER) sows enough to meet threshold
        sowAmountForFarmer(farmers[0], threshold);

        // Verify farmer 0 has sown enough
        assertGe(
            field.getBeansSownForReferral(farmers[0]),
            threshold,
            "User should have sown threshold"
        );

        // Try to delegate to self - should fail
        vm.prank(farmers[0]);
        vm.expectRevert("Field: delegate cannot be the user");
        field.delegateReferralRewards(farmers[0]);
    }

    /**
     * @notice Test that delegation fails if the delegate is already eligible
     * @dev Per the design, farmers who are already eligible cannot become delegate targets.
     * This prevents circular or conflicting delegation scenarios.
     */
    function test_delegateReferralRewards_delegateAlreadyEligible() public {
        uint256 threshold = field.getBeanSownEligibilityThreshold();

        // Farmer 0 (USER) sows enough to earn the right to delegate
        bean.mint(farmers[0], threshold);
        season.setSoilE(threshold * 3);
        vm.prank(farmers[0]);
        field.sowWithReferral(threshold, 0, 0, LibTransfer.From.EXTERNAL, address(0));

        // Farmer 1 (DELEGATE) also sows enough and becomes eligible
        bean.mint(farmers[1], threshold);
        vm.prank(farmers[1]);
        field.sowWithReferral(threshold, 0, 0, LibTransfer.From.EXTERNAL, address(0));

        // Verify both are eligible
        assertTrue(field.isValidReferrer(farmers[0]), "User should be eligible");
        assertTrue(field.isValidReferrer(farmers[1]), "Delegate should be eligible");

        // Farmer 0 tries to delegate to farmer 1 - should fail because farmer 1 is already eligible
        vm.prank(farmers[0]);
        vm.expectRevert("Field: delegate is already eligible");
        field.delegateReferralRewards(farmers[1]);

        // farmer 0 delegates to to address(123890123)
        vm.prank(farmers[0]);
        field.delegateReferralRewards(address(123890123));

        // verify farmer 1 cannot delegate to address(123890123)
        vm.prank(farmers[1]);
        vm.expectRevert("Field: delegate is already eligible");
        field.delegateReferralRewards(address(123890123));

        // verify farmer 1 is still eligible
        assertTrue(field.isValidReferrer(farmers[1]), "Delegate should still be eligible");
    }

    function test_sowWithReferral_targetReferralPodsReached() public {
        bs.setReferrerPercentageE(0.1e6);
        bs.setRefereePercentageE(0.1e6);
        bs.setTargetReferralPods(100);
        bs.setTotalReferralPods(0);
        bs.setReferralEligibility(farmers[1], true);
        assertTrue(field.isReferralSystemEnabled(), "Referral system should be enabled");
        sowAmountForFarmerWithReferral(farmers[0], 100e6, farmers[1]);
        assertFalse(field.isReferralSystemEnabled(), "Referral system should be disabled");
    }
}

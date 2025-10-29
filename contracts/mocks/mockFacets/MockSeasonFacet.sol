/*
 SPDX-License-Identifier: MIT*/

pragma solidity ^0.8.20;

import "contracts/libraries/Math/LibRedundantMath256.sol";
import "contracts/beanstalk/facets/sun/SeasonFacet.sol";
import {AssetSettings, Deposited, Field, GerminationSide} from "contracts/beanstalk/storage/System.sol";
import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "../MockToken.sol";
import "contracts/libraries/LibBytes.sol";
import {LibChainlinkOracle} from "contracts/libraries/Oracle/LibChainlinkOracle.sol";
import {LibUsdOracle} from "contracts/libraries/Oracle/LibUsdOracle.sol";
import {LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibRedundantMathSigned256} from "contracts/libraries/Math/LibRedundantMathSigned256.sol";
import {Decimal} from "contracts/libraries/Decimal.sol";
import {LibGauge} from "contracts/libraries/LibGauge.sol";
import {LibRedundantMath32} from "contracts/libraries/Math/LibRedundantMath32.sol";
import {LibWellMinting} from "contracts/libraries/Minting/LibWellMinting.sol";
import {LibWeather} from "contracts/libraries/Sun/LibWeather.sol";
import {LibEvaluate} from "contracts/libraries/LibEvaluate.sol";
import {LibTokenSilo} from "contracts/libraries/Silo/LibTokenSilo.sol";
import {IWell, Call} from "contracts/interfaces/basin/IWell.sol";
import {ShipmentRecipient} from "contracts/beanstalk/storage/System.sol";
import {LibReceiving} from "contracts/libraries/LibReceiving.sol";
import {LibFlood} from "contracts/libraries/Silo/LibFlood.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";
import {LibEvaluate} from "contracts/libraries/LibEvaluate.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";
import {GaugeId, Gauge} from "contracts/beanstalk/storage/System.sol";

/**
 * @title Mock Season Facet
 *
 */
interface ResetPool {
    function reset_cumulative() external;
}

interface IMockPump {
    function update(uint256[] memory _reserves, bytes memory) external;

    function update(address well, uint256[] memory _reserves, bytes memory) external;

    function readInstantaneousReserves(
        address well,
        bytes memory data
    ) external view returns (uint256[] memory reserves);
}

contract MockSeasonFacet is SeasonFacet {
    using LibRedundantMath256 for uint256;
    using LibRedundantMath32 for uint32;
    using LibRedundantMathSigned256 for int256;

    event DeltaB(int256 deltaB);

    address constant BEAN_ETH_WELL = 0xBEA0e11282e2bB5893bEcE110cF199501e872bAd;

    function reentrancyGuardTest() public nonReentrant {
        reentrancyGuardTest();
    }

    function setYieldE(uint256 t) public {
        s.sys.weather.temp = uint32(t);
    }

    function siloSunrise(uint256 amount) public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.timestamp = block.timestamp;
        s.sys.season.sunriseBlock = uint64(block.number);
        mockStepSilo(amount);
        LibGerminate.endTotalGermination(
            s.sys.season.current,
            LibWhitelistedTokens.getWhitelistedTokens()
        );
    }

    function mockStepSilo(uint256 amount) public {
        BeanstalkERC20(s.sys.bean).mint(address(this), amount);
        LibReceiving.receiveShipment(ShipmentRecipient.SILO, amount, bytes(""));
    }

    function rainSunrise() public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.sunriseBlock = uint64(block.number);
        // update last snapshot in beanstalk.
        stepOracle();
        LibGerminate.endTotalGermination(
            s.sys.season.current,
            LibWhitelistedTokens.getWhitelistedTokens()
        );
        mockStartSop();
    }

    function rainSunrises(uint256 amount) public {
        require(!s.sys.paused, "Season: Paused.");
        for (uint256 i; i < amount; ++i) {
            s.sys.season.current += 1;
            stepOracle();
            LibGerminate.endTotalGermination(
                s.sys.season.current,
                LibWhitelistedTokens.getWhitelistedTokens()
            );
            mockStartSop();
        }
        s.sys.season.sunriseBlock = uint64(block.number);
    }

    function droughtSunrise() public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.sunriseBlock = uint64(block.number);
        // update last snapshot in beanstalk.
        stepOracle();
        LibGerminate.endTotalGermination(
            s.sys.season.current,
            LibWhitelistedTokens.getWhitelistedTokens()
        );
        LibFlood.handleRain(2);
    }

    function rainSiloSunrise(uint256 amount) public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.sunriseBlock = uint64(block.number);
        // update last snapshot in beanstalk.
        stepOracle();
        LibGerminate.endTotalGermination(
            s.sys.season.current,
            LibWhitelistedTokens.getWhitelistedTokens()
        );
        mockStartSop();
        mockStepSilo(amount);
    }

    function droughtSiloSunrise(uint256 amount) public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.sunriseBlock = uint64(block.number);
        // update last snapshot in beanstalk.
        stepOracle();
        LibGerminate.endTotalGermination(
            s.sys.season.current,
            LibWhitelistedTokens.getWhitelistedTokens()
        );
        mockStartSop();
        mockStepSilo(amount);
    }

    function sunSunriseWithL2srScaling(int256 deltaB, uint256 caseId) public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.sunriseBlock = uint64(block.number);
        (, LibEvaluate.BeanstalkState memory bs) = calcCaseIdAndHandleRain(deltaB);
        stepSun(caseId, bs);
    }

    function sunSunrise(
        int256 deltaB,
        uint256 caseId,
        LibEvaluate.BeanstalkState memory bs
    ) public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.sunriseBlock = uint64(block.number);
        bs.twaDeltaB = deltaB;
        stepGauges(bs);
        stepSun(caseId, bs);
    }

    function seedGaugeSunSunrise(int256 deltaB, uint256 caseId, bool oracleFailure) public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.sunriseBlock = uint64(block.number);
        LibEvaluate.BeanstalkState memory bs = LibEvaluate.BeanstalkState({
            deltaPodDemand: Decimal.zero(),
            lpToSupplyRatio: Decimal.zero(),
            podRate: Decimal.zero(),
            largestLiqWell: address(0),
            oracleFailure: false,
            largestLiquidWellTwapBeanPrice: 0,
            twaDeltaB: deltaB
        });
        LibWeather.updateTemperatureAndBeanToMaxLpGpPerBdvRatio(caseId, bs, oracleFailure);
        stepSun(caseId, bs); // Do not scale soil down using L2SR
    }

    function seedGaugeSunSunrise(int256 deltaB, uint256 caseId) public {
        seedGaugeSunSunrise(deltaB, caseId, false);
    }

    function sunTemperatureSunrise(int256 deltaB, uint256 caseId, uint32 t) public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.weather.temp = t;
        s.sys.season.sunriseBlock = uint64(block.number);
        stepSun(
            caseId,
            LibEvaluate.BeanstalkState({
                deltaPodDemand: Decimal.zero(),
                lpToSupplyRatio: Decimal.zero(),
                podRate: Decimal.zero(),
                largestLiqWell: address(0),
                oracleFailure: false,
                largestLiquidWellTwapBeanPrice: 0,
                twaDeltaB: deltaB
            })
        ); // Do not scale soil down using L2SR
    }

    function lightSunrise() public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.sunriseBlock = uint64(block.number);
    }

    /**
     * @dev Mocks the stepSeason function.
     */
    function mockStepSeason() public returns (uint32 season) {
        s.sys.season.current += 1;
        season = s.sys.season.current;
        s.sys.season.sunriseBlock = uint64(block.number); // Note: Will overflow in the year 3650.
        emit Sunrise(season);
    }

    function fastForward(uint32 _s) public {
        // teleport current sunrise 2 seasons ahead,
        // end germination,
        // then teleport remainder of seasons.
        if (_s >= 2) {
            s.sys.season.current += 2;
            LibGerminate.endTotalGermination(
                s.sys.season.current,
                LibWhitelistedTokens.getWhitelistedTokens()
            );
            s.sys.season.current += _s - 2;
        } else {
            s.sys.season.current += _s;
        }
    }

    function teleportSunrise(uint32 _s) public {
        s.sys.season.current = _s;
        s.sys.season.sunriseBlock = uint64(block.number);
    }

    function farmSunrise() public {
        require(!s.sys.paused, "Season: Paused.");
        s.sys.season.current += 1;
        s.sys.season.timestamp = block.timestamp;
        s.sys.season.sunriseBlock = uint64(block.number);
        LibGerminate.endTotalGermination(
            s.sys.season.current,
            LibWhitelistedTokens.getWhitelistedTokens()
        );
    }

    function farmSunrises(uint256 number) public {
        require(!s.sys.paused, "Season: Paused.");
        for (uint256 i; i < number; ++i) {
            s.sys.season.current += 1;
            s.sys.season.timestamp = block.timestamp;
            // ending germination only needs to occur for the first two loops.
            if (i < 2) {
                LibGerminate.endTotalGermination(
                    s.sys.season.current,
                    LibWhitelistedTokens.getWhitelistedTokens()
                );
            }
        }
        s.sys.season.sunriseBlock = uint64(block.number);
    }

    function setMaxTempE(uint32 number) public {
        s.sys.weather.temp = number;
    }

    function setAbovePegE(bool peg) public {
        s.sys.season.abovePeg = peg;
    }

    function setLastDSoilE(uint128 number) public {
        s.sys.weather.lastDeltaSoil = number;
    }

    function setNextSowTimeE(uint32 _time) public {
        s.sys.weather.thisSowTime = _time;
    }

    function setLastSowTimeE(uint32 number) public {
        s.sys.weather.lastSowTime = number;
    }

    function setSoilE(uint256 amount) public {
        setSoil(amount);
    }

    function resetState() public {
        for (uint256 i; i < s.sys.fieldCount; i++) {
            s.sys.fields[i].pods = 0;
            s.sys.fields[i].harvested = 0;
            s.sys.fields[i].harvestable = 0;
        }
        delete s.sys.silo;
        delete s.sys.weather;
        s.sys.weather.lastSowTime = type(uint32).max;
        s.sys.weather.thisSowTime = type(uint32).max;
        delete s.sys.rain;
        delete s.sys.season;
        s.sys.season.start = block.timestamp;
        s.sys.season.timestamp = block.timestamp;
        s.sys.silo.stalk = 0;
        s.sys.season.current = 1;
        s.sys.paused = false;
        BeanstalkERC20(s.sys.bean).burn(BeanstalkERC20(s.sys.bean).balanceOf(address(this)));
    }

    function calcCaseIdE(int256 deltaB, uint128 endSoil) external {
        s.sys.soil = endSoil;
        s.sys.beanSown = endSoil;
        calcCaseIdAndHandleRain(deltaB);
    }

    function setCurrentSeasonE(uint32 _season) public {
        s.sys.season.current = _season;
    }

    function calcCaseIdWithParams(
        uint256 pods,
        uint256 _lastDeltaSoil,
        uint128 beanSown,
        uint128 endSoil,
        int256 deltaB,
        bool raining,
        bool rainRoots,
        bool aboveQ,
        uint256 L2SRState
    ) public {
        // L2SR
        // 3 = exs high, 1 = rea high, 2 = rea low, 3 = exs low
        uint256[] memory reserves = new uint256[](2);
        if (L2SRState == 3) {
            // reserves[1] = 0.8e1
            reserves[1] = uint256(801e18);
        } else if (L2SRState == 2) {
            // reserves[1] = 0.8e18 - 1;
            reserves[1] = uint256(799e18);
        } else if (L2SRState == 1) {
            // reserves[1] = 0.4e18 - 1;
            reserves[1] = uint256(399e18);
        } else if (L2SRState == 0) {
            // reserves[1] = 0.12e18 - 1;
            reserves[1] = uint256(119e18);
        }
        uint256 beanEthPrice = 1000e6;
        uint256 l2srBean = beanEthPrice.mul(1000);
        reserves[0] = reserves[1].mul(beanEthPrice).div(1e18);
        if (l2srBean > BeanstalkERC20(s.sys.bean).totalSupply()) {
            BeanstalkERC20(s.sys.bean).mint(
                address(this),
                l2srBean - BeanstalkERC20(s.sys.bean).totalSupply()
            );
        }
        Call[] memory pump = IWell(BEAN_ETH_WELL).pumps();
        IMockPump(pump[0].target).update(pump[0].target, reserves, pump[0].data);
        s.sys.twaReserves[BEAN_ETH_WELL].reserve0 = uint128(reserves[0]);
        s.sys.twaReserves[BEAN_ETH_WELL].reserve1 = uint128(reserves[1]);
        s.sys.usdTokenPrice[BEAN_ETH_WELL] = 0.001e18;
        if (aboveQ) {
            // increase bean price
            s.sys.twaReserves[BEAN_ETH_WELL].reserve0 = uint128(reserves[0].mul(10).div(11));
        } else {
            // decrease bean price
            s.sys.twaReserves[BEAN_ETH_WELL].reserve0 = uint128(reserves[0]);
        }

        /// FIELD ///
        s.sys.season.raining = raining;
        s.sys.rain.roots = rainRoots ? 1 : 0;
        s.sys.fields[s.sys.activeField].pods = (pods.mul(BeanstalkERC20(s.sys.bean).totalSupply()) /
            1000); // previous tests used 1000 as the total supply.
        s.sys.weather.lastDeltaSoil = uint128(_lastDeltaSoil);
        s.sys.beanSown = beanSown;
        s.sys.soil = endSoil;
        mockcalcCaseIdAndHandleRain(deltaB);
    }

    function resetSeasonStart(uint256 amount) public {
        s.sys.season.start = block.timestamp.sub(amount + 3600 * 2);
    }

    function captureE() external returns (int256 deltaB) {
        deltaB = stepOracle();
        emit DeltaB(deltaB);
    }

    function captureWellE(address well) external returns (int256 deltaB) {
        deltaB = LibWellMinting.capture(well);
        s.sys.season.timestamp = block.timestamp;
        emit DeltaB(deltaB);
    }

    function resetPools(address[] calldata pools) external {
        for (uint256 i; i < pools.length; ++i) {
            ResetPool(pools[i]).reset_cumulative();
        }
    }

    function setSunriseBlock(uint256 _block) external {
        s.sys.season.sunriseBlock = uint64(_block);
    }

    function mockSetMilestoneStem(address token, int96 stem) external {
        s.sys.silo.assetSettings[token].milestoneStem = stem;
    }

    function mockSetMilestoneSeason(address token, uint32 season) external {
        s.sys.silo.assetSettings[token].milestoneSeason = season;
    }

    //constants for old seeds values

    function lastDeltaSoil() external view returns (uint256) {
        return uint256(s.sys.weather.lastDeltaSoil);
    }

    function lastSowTime() external view returns (uint256) {
        return uint256(s.sys.weather.lastSowTime);
    }

    function thisSowTime() external view returns (uint256) {
        return uint256(s.sys.weather.thisSowTime);
    }

    function getT() external view returns (uint256) {
        return uint256(s.sys.weather.temp);
    }

    function setBeanToMaxLpGpPerBdvRatio(uint128 percent) external {
        s.sys.seedGauge.beanToMaxLpGpPerBdvRatio = percent;
    }

    function setUsdEthPrice(uint256 price) external {
        s.sys.usdTokenPrice[BEAN_ETH_WELL] = price;
    }

    function mockStepGauges(LibEvaluate.BeanstalkState memory bs) external {
        LibGaugeHelpers.engage(abi.encode(bs));
    }

    function calculateCultivationFactorDeltaE(
        LibEvaluate.BeanstalkState memory bs
    ) external view returns (uint256) {
        uint256 cultivationFactor = abi.decode(
            LibGaugeHelpers.getGaugeValue(GaugeId.CULTIVATION_FACTOR),
            (uint256)
        );
        Gauge memory g = s.sys.gaugeData.gauges[GaugeId.CULTIVATION_FACTOR];
        (bytes memory newCultivationFactorBytes, ) = LibGaugeHelpers.getGaugeResult(
            g,
            abi.encode(bs)
        );
        uint256 newCultivationFactor = abi.decode(newCultivationFactorBytes, (uint256));
        if (newCultivationFactor > cultivationFactor) {
            return newCultivationFactor - cultivationFactor;
        } else {
            return cultivationFactor - newCultivationFactor;
        }
    }

    function mockStepGauge() external {
        (
            uint256 maxLpGpPerBdv,
            LibGauge.LpGaugePointData[] memory lpGpData,
            uint256 totalGaugePoints,
            uint256 totalLpBdv
        ) = LibGauge.updateGaugePoints();
        if (totalLpBdv == type(uint256).max) return;
        LibGauge.updateGrownStalkEarnedPerSeason(
            maxLpGpPerBdv,
            lpGpData,
            totalGaugePoints,
            totalLpBdv
        );
    }

    function stepGauge() external {
        LibGauge.stepGauge();
    }

    function mockSetAverageGrownStalkPerBdvPerSeason(
        uint128 _averageGrownStalkPerBdvPerSeason
    ) external {
        s.sys.seedGauge.averageGrownStalkPerBdvPerSeason = _averageGrownStalkPerBdvPerSeason;
    }

    /**
     * @notice Mocks the updateGrownStalkEarnedPerSeason function.
     * @dev used to test the updateGrownStalkPerSeason updating.
     */
    function mockUpdateAverageGrownStalkPerBdvPerSeason() external {
        LibGauge.updateGrownStalkEarnedPerSeason(0, new LibGauge.LpGaugePointData[](0), 100e18, 0);
    }

    function gaugePointsNoChange(
        uint256 currentGaugePoints,
        uint256,
        uint256
    ) external pure returns (uint256) {
        return currentGaugePoints;
    }

    function mockinitializeGaugeForToken(
        address token,
        bytes4 gaugePointSelector,
        bytes4 liquidityWeightSelector,
        uint96,
        uint64 optimalPercentDepositedBdv
    ) external {
        AssetSettings storage ss = LibAppStorage.diamondStorage().sys.silo.assetSettings[token];
        ss.gaugePointImplementation.selector = gaugePointSelector;
        ss.liquidityWeightImplementation.selector = liquidityWeightSelector;
        ss.optimalPercentDepositedBdv = optimalPercentDepositedBdv;
    }

    function mockEndTotalGerminationForToken(address token) external {
        // increment total deposited and amounts for each token.
        GerminationSide side = LibGerminate.getSeasonGerminationSide();
        LibTokenSilo.incrementTotalDeposited(
            token,
            s.sys.silo.germinating[side][token].amount,
            s.sys.silo.germinating[side][token].bdv
        );
        delete s.sys.silo.germinating[side][token];
    }

    function mockUpdateAverageStalkPerBdvPerSeason() external {
        LibGauge.updateAverageStalkPerBdvPerSeason();
    }

    function mockStartSop() internal {
        LibFlood.handleRain(3);
    }

    function mockIncrementGermination(
        address,
        address token,
        uint128 amount,
        uint128 bdv,
        GerminationSide side
    ) external {
        LibTokenSilo.incrementTotalGerminating(token, amount, bdv, side);
    }

    /**
     * @notice simulates beanstalk state based on the parameters.
     * @param price below, above, significant above peg.
     * @param podRate extremely low, low, high, extremely high.
     * @param changeInSoilDemand decreasing, steady, increasing.
     * @param liquidityToSupplyRatio extremely low, low, high, extremely high.
     * @dev
     * assumes the initial L2SR is >80%.
     * assumes only one well with beans.
     */
    function setBeanstalkState(
        uint256 price,
        uint256 podRate,
        uint256 changeInSoilDemand,
        uint256 liquidityToSupplyRatio,
        address targetWell
    ) external returns (int256 deltaB) {
        ////////// PRICE //////////
        deltaB = setPrice(price, targetWell);

        ////////// L2SR //////////
        setL2SR(liquidityToSupplyRatio, targetWell);

        // POD RATE
        setPodRate(podRate);

        ////// DELTA POD DEMAND //////
        setChangeInSoilDemand(changeInSoilDemand);
    }

    /**
     * @notice sets the price state of beanstalk.
     * @dev 0 = below peg, 1 = above peg, 2 = significantly above peg.
     */
    function setPrice(uint256 price, address targetWell) public returns (int256 deltaB) {
        // initalize beanTknPrice, and reserves.
        uint256 ethPrice = 1000e6;
        s.sys.usdTokenPrice[targetWell] = 1e24 / ethPrice;
        uint256[] memory reserves = IWell(targetWell).getReserves();
        s.sys.twaReserves[targetWell].reserve0 = uint128(reserves[0]);
        s.sys.twaReserves[targetWell].reserve1 = uint128(reserves[1]);
        if (price == 0) {
            // below peg
            deltaB = -1;
            s.sys.season.abovePeg = false;
        } else {
            // above peg
            deltaB = 1;
            s.sys.season.abovePeg = true;
            if (price == 2) {
                // excessively above peg

                // to get Q, decrease s.sys.reserve0 of the well to be >1.05.
                s.sys.twaReserves[targetWell].reserve0 = uint128(reserves[0].mul(90).div(100));
            }
        }
    }

    /**
     * @notice sets the pod rate state of beanstalk.
     * @dev 0 = Extremely low, 1 = Reasonably Low, 2 = Reasonably High, 3 = Extremely High.
     */
    function setPodRate(uint256 podRate) public {
        uint256 beanSupply = BeanstalkERC20(s.sys.bean).totalSupply();
        if (podRate == 0) {
            // < 5%
            s.sys.fields[s.sys.activeField].pods = beanSupply.mul(49).div(1000);
        } else if (podRate == 1) {
            // < 15%
            s.sys.fields[s.sys.activeField].pods = beanSupply.mul(149).div(1000);
        } else if (podRate == 2) {
            // < 25%
            s.sys.fields[s.sys.activeField].pods = beanSupply.mul(249).div(1000);
        } else if (podRate == 3) {
            // > 25%
            s.sys.fields[s.sys.activeField].pods = beanSupply.mul(251).div(1000);
        } else {
            // > 100%
            s.sys.fields[s.sys.activeField].pods = beanSupply.mul(1001).div(1000);
        }
    }

    /**
     * @notice sets the change in soil demand state of beanstalk.
     * @dev 0 = decreasing, 1 = steady, 2 = increasing.
     */
    function setChangeInSoilDemand(uint256 changeInSoilDemand) public {
        if (changeInSoilDemand == 0) {
            // decreasing demand
            // 200 beans sown last season, 100 beans sown this season
            setLastSeasonAndThisSeasonBeanSown(200e6, 100e6);
            s.sys.weather.lastSowTime = 600; // last season, everything was sown in 10 minutes.
            s.sys.weather.thisSowTime = 2400; // this season, everything was sown in 40 minutes.
        } else if (changeInSoilDemand == 1) {
            // steady demand
            // 100 beans sown last season, 100 beans sown this season
            setLastSeasonAndThisSeasonBeanSown(100e6, 100e6);
            s.sys.weather.lastSowTime = 60 * 21; // last season, everything was sown in 21 minutes, this is past the 20 minute increasing window
            s.sys.weather.thisSowTime = 60 * 21; // this season, everything was sown in 21 minutes.
        } else {
            // increasing demand
            // 100 beans sown last season, 200 beans sown this season
            setLastSeasonAndThisSeasonBeanSown(100e6, 200e6);
            s.sys.weather.lastSowTime = type(uint32).max; // last season, no one sow'd
            s.sys.weather.thisSowTime = type(uint32).max - 1; // this season, someone sow'd
        }
    }

    /**
     * @notice sets the L2SR state of beanstalk.
     * @dev 0 = extremely low, 1 = low, 2 = high, 3 = extremely high.
     */
    function setL2SR(uint256 liquidityToSupplyRatio, address targetWell) public {
        uint256 beansInWell = BeanstalkERC20(s.sys.bean).balanceOf(targetWell);
        uint256 beanSupply = BeanstalkERC20(s.sys.bean).totalSupply();
        uint256 currentL2SR = beansInWell.mul(1e18).div(beanSupply);

        // issue beans to sender based on ratio and supply of well.
        uint256 ratio = 1e18;
        if (liquidityToSupplyRatio == 0) {
            // < 12%
            ratio = 0.119e18;
        } else if (liquidityToSupplyRatio == 1) {
            // < 40%
            ratio = 0.399e18;
        } else if (liquidityToSupplyRatio == 2) {
            // < 80%
            ratio = 0.799e18;
        } else {
            ratio = 0.801e18;
        }

        // mint new beans outside of the well for the L2SR to change.
        uint256 newSupply = beansInWell.mul(currentL2SR).div(ratio).sub(beansInWell);
        beanSupply += newSupply;

        BeanstalkERC20(s.sys.bean).mint(msg.sender, newSupply);
    }

    /**
     * @notice mock updates case id and beanstalk state. disables oracle failure.
     */
    function mockcalcCaseIdAndHandleRain(
        int256 deltaB
    ) public returns (uint256 caseId, LibEvaluate.BeanstalkState memory bs) {
        uint256 beanSupply = BeanstalkERC20(s.sys.bean).totalSupply();
        // prevents infinite L2SR and podrate
        if (beanSupply == 0) {
            s.sys.weather.temp = 1e6;
            return (9, bs); // Reasonably low
        }
        // Calculate Case Id
        (caseId, bs) = LibEvaluate.evaluateBeanstalk(deltaB, beanSupply);
        LibWeather.updateTemperatureAndBeanToMaxLpGpPerBdvRatio(caseId, bs, false);
        LibFlood.handleRain(caseId);
    }

    function getSeasonStart() external view returns (uint256) {
        return s.sys.season.start;
    }

    /**
     * @notice returns the timestamp in which the next sunrise can be called.
     */
    function getNextSeasonStart() external view returns (uint256) {
        uint256 currentSeason = s.sys.season.current;
        return s.sys.season.start + ((currentSeason + 1) * 3600);
    }

    /**
     * @notice intializes the oracle for all whitelisted well lp tokens.
     * @dev should only be used if the oracle has not been initialized.
     */
    function initOracleForAllWhitelistedWells() external {
        address[] memory lp = LibWhitelistedTokens.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < lp.length; i++) {
            initOracleForWell(lp[i]);
        }
    }

    function initOracleForWell(address well) internal {
        require(s.sys.wellOracleSnapshots[well].length == 0, "Season: Oracle already initialized.");
        LibWellMinting.initializeOracle(well);
    }

    function getPoolDeltaBWithoutCap(address well) external view returns (int256 deltaB) {
        bytes memory lastSnapshot = LibAppStorage.diamondStorage().sys.wellOracleSnapshots[well];
        // If the length of the stored Snapshot for a given Well is 0,
        // then the Oracle is not initialized.
        if (lastSnapshot.length > 0) {
            (deltaB, , , ) = LibWellMinting.twaDeltaB(well, lastSnapshot);
        }
    }

    function captureWellEInstantaneous(address well) external returns (int256 instDeltaB) {
        instDeltaB = LibWellMinting.instantaneousDeltaB(well);
        s.sys.season.timestamp = block.timestamp;
        emit DeltaB(instDeltaB);
    }

    function setLastSeasonAndThisSeasonBeanSown(
        uint128 lastSeasonBeanSown,
        uint128 thisSeasonBeanSown
    ) public {
        s.sys.weather.lastDeltaSoil = lastSeasonBeanSown;
        s.sys.beanSown = thisSeasonBeanSown;
    }

    function setMinSoilSownDemand(uint256 minSoilSownDemand) public {
        s.sys.extEvaluationParameters.minSoilSownDemand = minSoilSownDemand;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import "forge-std/console.sol";
import {Deposit} from "contracts/beanstalk/storage/Account.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWell, Call} from "contracts/interfaces/basin/IWell.sol";
import "forge-std/StdUtils.sol";
import {BeanstalkPrice, WellPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {P} from "contracts/ecosystem/price/P.sol";
import {ShipmentPlanner} from "contracts/ecosystem/ShipmentPlanner.sol";
import {ILiquidityWeightFacet} from "contracts/beanstalk/facets/sun/LiquidityWeightFacet.sol";

interface IBeanstalkPrice {
    function price() external view returns (P.Prices memory p);
}

interface IBeanstalkERC20 {
    function totalSupply() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

/**
 * @notice Verfifies the deployment parameters of Pinto
 * @dev This test is marked as LEGACY because it is not used in the current deployment process.
 */
contract Legacy_VerifyDeploymentTest is TestHelper {
    // contracts for testing:
    address constant PRICE = address(0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E);

    address constant PINTO_DEPLOYER = address(0x183926c42993478F6b2eb8CDEe0BEa524B119ab2);
    address constant PCM = address(0x2cf82605402912C6a79078a9BBfcCf061CbfD507);

    uint256 constant FIELD_ID = 0;
    uint256 constant PAYBACK_FIELD_ID = 1;

    address constant DEV_BUDGET = address(0xb0cdb715D8122bd976a30996866Ebe5e51bb18b0);
    address constant FIVE_PERCENT_RESERVES = address(0x4FAE5420F64c282FD908fdf05930B04E8e079770);

    IMockFBeanstalk pinto;

    string constant HEX_PREFIX = "0x";

    address constant realUser = 0xC2820F702Ef0fBd8842c5CE8A4FCAC5315593732;

    mapping(address => uint256) public optimalPercentDepositedBdvs;
    mapping(address => uint256) public tokenGaugePoints;

    address[] whitelistedTokens = [
        L2_PINTO,
        address(0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3), // PINTO/WETH
        address(0x3e111115A82dF6190e36ADf0d552880663A4dBF1), // PINTO/cbETH
        address(0x3e11226fe3d85142B734ABCe6e58918d5828d1b4), // PINTO/cbBTC
        address(0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1), // PINTO/USDC
        address(0x3e11444c7650234c748D743D8d374fcE2eE5E6C9) // PINTO/WSOL
    ];

    address[] pintoAndNonBeanTokens = [
        L2_PINTO,
        address(0x4200000000000000000000000000000000000006), // WETH
        address(0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22), // cbETH
        address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf), // cbBTC
        address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913), // USDC
        address(0x1C61629598e4a901136a81BC138E5828dc150d67) // WSOL
    ];

    address[] whiteListedWellTokens = [
        address(0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3), // PINTO/WETH
        address(0x3e111115A82dF6190e36ADf0d552880663A4dBF1), // PINTO/cbETH
        address(0x3e11226fe3d85142B734ABCe6e58918d5828d1b4), // PINTO/cbBTC
        address(0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1), // PINTO/USDC
        address(0x3e11444c7650234c748D743D8d374fcE2eE5E6C9) // PINTO/WSOL
    ];

    enum ShipmentRecipient {
        NULL,
        SILO,
        FIELD,
        INTERNAL_BALANCE,
        EXTERNAL_BALANCE
    }

    function setUp() public {
        pinto = IMockFBeanstalk(PINTO);
        // set optimal percent deposited bdvs
        optimalPercentDepositedBdvs[address(0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3)] = 12500000;
        optimalPercentDepositedBdvs[address(0x3e111115A82dF6190e36ADf0d552880663A4dBF1)] = 12500000;
        optimalPercentDepositedBdvs[address(0x3e11226fe3d85142B734ABCe6e58918d5828d1b4)] = 25000000;
        optimalPercentDepositedBdvs[address(0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1)] = 25000000;
        optimalPercentDepositedBdvs[address(0x3e11444c7650234c748D743D8d374fcE2eE5E6C9)] = 25000000;
        // set token gauge points
        tokenGaugePoints[address(0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3)] = 250e18;
        tokenGaugePoints[address(0x3e111115A82dF6190e36ADf0d552880663A4dBF1)] = 250e18;
        tokenGaugePoints[address(0x3e11226fe3d85142B734ABCe6e58918d5828d1b4)] = 500e18;
        tokenGaugePoints[address(0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1)] = 500e18;
        tokenGaugePoints[address(0x3e11444c7650234c748D743D8d374fcE2eE5E6C9)] = 500e18;
    }

    function test_verifyEvaluationParams() public {
        IMockFBeanstalk.EvaluationParameters memory evalParams = pinto.getEvaluationParameters();
        IMockFBeanstalk.ExtEvaluationParameters memory extEvalParams = pinto
            .getExtEvaluationParameters();
        // log all params
        console.log("-------------------------------");
        console.log("Evaluation Parameters");
        console.log("-------------------------------");
        console.log("maxBeanMaxLpGpPerBdvRatio: ", evalParams.maxBeanMaxLpGpPerBdvRatio);
        console.log("minBeanMaxLpGpPerBdvRatio: ", evalParams.minBeanMaxLpGpPerBdvRatio);
        console.log("targetSeasonsToCatchUp: ", evalParams.targetSeasonsToCatchUp);
        console.log("podRateLowerBound: ", evalParams.podRateLowerBound);
        console.log("podRateOptimal: ", evalParams.podRateOptimal);
        console.log("podRateUpperBound: ", evalParams.podRateUpperBound);
        console.log("deltaPodDemandLowerBound: ", evalParams.deltaPodDemandLowerBound);
        console.log("deltaPodDemandUpperBound: ", evalParams.deltaPodDemandUpperBound);
        console.log("lpToSupplyRatioUpperBound: ", evalParams.lpToSupplyRatioUpperBound);
        console.log("lpToSupplyRatioOptimal: ", evalParams.lpToSupplyRatioOptimal);
        console.log("lpToSupplyRatioLowerBound: ", evalParams.lpToSupplyRatioLowerBound);
        console.log("excessivePriceThreshold: ", evalParams.excessivePriceThreshold);
        console.log("soilCoefficientHigh: ", evalParams.soilCoefficientHigh);
        console.log("soilCoefficientLow: ", evalParams.soilCoefficientLow);
        console.log("baseReward: ", evalParams.baseReward);
        console.log("minAvgGsPerBdv: ", evalParams.minAvgGsPerBdv);
        console.log("");
        console.log("belowPegSoilL2SRScalar: ", extEvalParams.belowPegSoilL2SRScalar);
        console.log("-------------------------------");
        assertEq(
            evalParams.maxBeanMaxLpGpPerBdvRatio,
            getGlobalPropertyUint("evaluationParameters.maxBeanMaxLpGpPerBdvRatio")
        );
        assertEq(
            evalParams.minBeanMaxLpGpPerBdvRatio,
            getGlobalPropertyUint("evaluationParameters.minBeanMaxLpGpPerBdvRatio")
        );
        assertEq(
            evalParams.targetSeasonsToCatchUp,
            getGlobalPropertyUint("evaluationParameters.targetSeasonsToCatchUp")
        );
        assertEq(
            evalParams.podRateLowerBound,
            getGlobalPropertyUint("evaluationParameters.podRateLowerBound")
        );
        assertEq(
            evalParams.podRateOptimal,
            getGlobalPropertyUint("evaluationParameters.podRateOptimal")
        );
        assertEq(
            evalParams.podRateUpperBound,
            getGlobalPropertyUint("evaluationParameters.podRateUpperBound")
        );
        assertEq(
            evalParams.deltaPodDemandLowerBound,
            getGlobalPropertyUint("evaluationParameters.deltaPodDemandLowerBound")
        );
        assertEq(
            evalParams.deltaPodDemandUpperBound,
            getGlobalPropertyUint("evaluationParameters.deltaPodDemandUpperBound")
        );
        assertEq(
            evalParams.lpToSupplyRatioUpperBound,
            getGlobalPropertyUint("evaluationParameters.lpToSupplyRatioUpperBound")
        );
        assertEq(
            evalParams.lpToSupplyRatioOptimal,
            getGlobalPropertyUint("evaluationParameters.lpToSupplyRatioOptimal")
        );
        assertEq(
            evalParams.lpToSupplyRatioLowerBound,
            getGlobalPropertyUint("evaluationParameters.lpToSupplyRatioLowerBound")
        );
        assertEq(
            evalParams.excessivePriceThreshold,
            getGlobalPropertyUint("evaluationParameters.excessivePriceThreshold")
        );
        assertEq(
            evalParams.soilCoefficientHigh,
            getGlobalPropertyUint("evaluationParameters.soilCoefficientHigh")
        );
        assertEq(
            evalParams.soilCoefficientLow,
            getGlobalPropertyUint("evaluationParameters.soilCoefficientLow")
        );
        assertEq(evalParams.baseReward, getGlobalPropertyUint("evaluationParameters.baseReward"));
        assertEq(
            evalParams.minAvgGsPerBdv,
            getGlobalPropertyUint("evaluationParameters.minAvgGsPerBdv")
        );
        assertEq(
            extEvalParams.belowPegSoilL2SRScalar,
            getGlobalPropertyUint("extEvaluationParameters.belowPegSoilL2SRScalar")
        );
    }

    function test_verifySeedGauge() public {
        IMockFBeanstalk.SeedGauge memory seedGauge = pinto.getSeedGauge();
        console.log("-------------------------------");
        console.log("Seed Gauge");
        console.log("-------------------------------");
        console.log(
            "averageGrownStalkPerBdvPerSeason: ",
            seedGauge.averageGrownStalkPerBdvPerSeason
        );
        console.log("beanToMaxLpGpPerBdvRatio: ", seedGauge.beanToMaxLpGpPerBdvRatio);
        console.log("-------------------------------");
        assertEq(
            seedGauge.averageGrownStalkPerBdvPerSeason,
            getGlobalPropertyUint("seedGauge.averageGrownStalkPerBdvPerSeason")
        );
        assertEq(
            seedGauge.beanToMaxLpGpPerBdvRatio,
            getGlobalPropertyUint("seedGauge.beanToMaxLpGpPerBdvRatio")
        );
    }

    function test_assetSettings() public view {
        uint32 defaultStalkEarnedPerSeason = 1;
        uint48 defaultStalkIssuedPerBdv = 1e10;
        uint32 defaultMilestoneSeason = 1;
        int96 defaultMilestoneStem = 0;
        int32 defaultDeltaStalkEarnedPerSeason = 0;
        uint128 defaultGaugePoints = 500e18;
        uint64 defaultOptimalPercentDepositedBdv = 0;

        console.log("-------------------------------");
        console.log("Asset Settings bdv selectors");
        console.log("-------------------------------");
        console.log("beanToBDV.selector");
        console.logBytes4(IMockFBeanstalk.beanToBDV.selector);
        console.log("wellBDV.selector");
        console.logBytes4(IMockFBeanstalk.wellBdv.selector);
        console.log("-------------------------------");

        // get AssetSettings of L2BEAN
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            IMockFBeanstalk.AssetSettings memory assetSettings = pinto.tokenSettings(
                whitelistedTokens[i]
            );
            console.log("-------------------------------");
            console.log("Asset Settings for: ", whitelistedTokens[i]);
            console.log("-------------------------------");
            console.log("selector: ");
            console.logBytes4(assetSettings.selector);
            console.log("encodeType: ");
            console.logBytes1(assetSettings.encodeType);
            console.log("stalkEarnedPerSeason: ", assetSettings.stalkEarnedPerSeason);
            console.log("stalkIssuedPerBdv: ", assetSettings.stalkIssuedPerBdv);
            console.log("milestoneSeason: ", assetSettings.milestoneSeason);
            console.log("milestoneStem: ", assetSettings.milestoneStem);
            console.log("deltaStalkEarnedPerSeason: ", assetSettings.deltaStalkEarnedPerSeason);
            console.log("gaugePoints: ", assetSettings.gaugePoints);
            console.log("optimalPercentDepositedBdv: ", assetSettings.optimalPercentDepositedBdv);
            console.log("-------------------------------");
            // pinto
            if (i == 0) {
                assertEq(assetSettings.selector, IMockFBeanstalk.beanToBDV.selector);
                assertEq(assetSettings.encodeType, bytes1(0));
                assertEq(
                    assetSettings.optimalPercentDepositedBdv,
                    defaultOptimalPercentDepositedBdv
                );
                assertEq(assetSettings.gaugePoints, 0); //0 gauge points for pinto
                assertEq(assetSettings.stalkEarnedPerSeason, 2000000);
            } else {
                // other tokens
                assertEq(assetSettings.selector, IMockFBeanstalk.wellBdv.selector);
                assertEq(assetSettings.encodeType, bytes1(0x01));
                assertEq(assetSettings.stalkEarnedPerSeason, 3000000);
                // get optimal percent deposited bdv
                assertEq(
                    assetSettings.optimalPercentDepositedBdv,
                    optimalPercentDepositedBdvs[whitelistedTokens[i]]
                );
            }

            assertEq(assetSettings.stalkIssuedPerBdv, defaultStalkIssuedPerBdv);
            assertEq(assetSettings.milestoneSeason, defaultMilestoneSeason);
            assertEq(assetSettings.milestoneStem, defaultMilestoneStem);
            assertEq(assetSettings.deltaStalkEarnedPerSeason, defaultDeltaStalkEarnedPerSeason);
            // get optimal percent deposited bdv
            assertEq(
                assetSettings.optimalPercentDepositedBdv,
                optimalPercentDepositedBdvs[whitelistedTokens[i]]
            );
        }
    }

    function test_tokenImplementations() public view {
        IMockFBeanstalk.Implementation memory defaultGaugePointImpl = IMockFBeanstalk
            .Implementation({
                target: address(0),
                selector: bytes4(0),
                encodeType: bytes1(0),
                data: ""
            });

        IMockFBeanstalk.Implementation memory defaultLiquidityWeightImpl = IMockFBeanstalk
            .Implementation({
                target: address(0),
                selector: ILiquidityWeightFacet.maxWeight.selector,
                encodeType: bytes1(0),
                data: ""
            });

        // get token implementations
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            //////////////////// Gauge Point ////////////////////
            IMockFBeanstalk.Implementation memory gaugePointImplementation = pinto
                .getGaugePointImplementationForToken(whitelistedTokens[i]);
            // log the gauge point implementation
            console.log("-------------------------------");
            console.log("Token: ", whitelistedTokens[i]);
            console.log("-------------------------------");
            console.log("Gauge Point Implementation");
            console.log("-------------------------------");
            console.log("target: ", gaugePointImplementation.target);
            console.log("selector: ");
            console.logBytes4(gaugePointImplementation.selector);
            console.log("encodeType: ");
            console.logBytes1(gaugePointImplementation.encodeType);
            console.log("data: ");
            console.logBytes(gaugePointImplementation.data);
            console.log("-------------------------------");
            // same gauge point implementation for all tokens
            assertEq(gaugePointImplementation.target, defaultGaugePointImpl.target);
            assertEq(gaugePointImplementation.selector, defaultGaugePointImpl.selector);
            assertEq(gaugePointImplementation.encodeType, defaultGaugePointImpl.encodeType);
            assertEq(gaugePointImplementation.data, defaultGaugePointImpl.data);

            //////////////////// Liquidity Weight ////////////////////
            IMockFBeanstalk.Implementation memory liquidityWeightImplementation = pinto
                .getLiquidityWeightImplementationForToken(whitelistedTokens[i]);
            console.log("-------------------------------");
            console.log("Liquidity Weight Implementation");
            console.log("-------------------------------");
            console.log("target: ", liquidityWeightImplementation.target);
            console.log("selector: ");
            console.logBytes4(liquidityWeightImplementation.selector);
            console.log("encodeType: ");
            console.logBytes1(liquidityWeightImplementation.encodeType);
            console.log("data: ");
            console.logBytes(liquidityWeightImplementation.data);
            console.log("-------------------------------");
            // same liquidity weight implementation for all tokens
            assertEq(liquidityWeightImplementation.target, defaultLiquidityWeightImpl.target);
            assertEq(liquidityWeightImplementation.selector, defaultLiquidityWeightImpl.selector);
            assertEq(
                liquidityWeightImplementation.encodeType,
                defaultLiquidityWeightImpl.encodeType
            );
            assertEq(liquidityWeightImplementation.data, defaultLiquidityWeightImpl.data);
        }
    }

    function test_nonbeantokenOracleImpl() public view {
        for (uint256 i = 0; i < pintoAndNonBeanTokens.length; i++) {
            //////////////////// Oracle ////////////////////
            IMockFBeanstalk.Implementation memory oralceImplementation = pinto
                .getOracleImplementationForToken(pintoAndNonBeanTokens[i]);
            console.log("-------------------------------");
            console.log("Non pinto Token: ", pintoAndNonBeanTokens[i]);
            console.log("-------------------------------");
            console.log("Oracle Implementation");
            console.log("-------------------------------");
            console.log("target: ", oralceImplementation.target);
            console.log("selector: ");
            console.logBytes4(oralceImplementation.selector);
            console.log("encodeType: ");
            console.logBytes1(oralceImplementation.encodeType);
            console.log("data: ");
            console.logBytes(oralceImplementation.data);
            console.log("-------------------------------");

            // pinto
            if (i == 0) {
                assertEq(oralceImplementation.target, address(0));
                assertEq(oralceImplementation.selector, bytes4(0));
                assertEq(oralceImplementation.encodeType, bytes1(0));
                assertEq(oralceImplementation.data, "");
            } else if (i == 1) {
                // WETH
                // weth oracle base
                assertEq(
                    oralceImplementation.target,
                    address(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70)
                );
                assertEq(oralceImplementation.selector, bytes4(0));
                assertEq(oralceImplementation.encodeType, bytes1(0x01));
                uint256 wethTimeoutIncreased = 1800;
                assertEq(oralceImplementation.data, abi.encode(wethTimeoutIncreased));
            } else if (i == 2) {
                // cbETH
                // cbETH oracle base
                assertEq(
                    oralceImplementation.target,
                    address(0xd7818272B9e248357d13057AAb0B417aF31E817d)
                );
                assertEq(oralceImplementation.selector, bytes4(0));
                assertEq(oralceImplementation.encodeType, bytes1(0x01));
                uint256 cbEthTimeoutIncreased = 1800;
                assertEq(oralceImplementation.data, abi.encode(cbEthTimeoutIncreased));
            } else if (i == 3) {
                // cbBTC
                // cbBTC oracle base
                assertEq(
                    oralceImplementation.target,
                    address(0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D)
                );
                assertEq(oralceImplementation.selector, bytes4(0));
                assertEq(oralceImplementation.encodeType, bytes1(0x01));
                uint256 cbBtcTimeoutIncreased = 129600;
                assertEq(oralceImplementation.data, abi.encode(cbBtcTimeoutIncreased));
            } else if (i == 4) {
                // USDC
                // USDC oracle base
                assertEq(
                    oralceImplementation.target,
                    address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B)
                );
                assertEq(oralceImplementation.selector, bytes4(0));
                assertEq(oralceImplementation.encodeType, bytes1(0x01));
                uint256 usdcTimeoutIncreased = 129600;
                assertEq(oralceImplementation.data, abi.encode(usdcTimeoutIncreased));
            } else if (i == 5) {
                // WSOL
                // WSOL oracle base
                assertEq(
                    oralceImplementation.target,
                    address(0x975043adBb80fc32276CbF9Bbcfd4A601a12462D)
                );
                assertEq(oralceImplementation.selector, bytes4(0));
                assertEq(oralceImplementation.encodeType, bytes1(0x01));
                uint256 wsolTimeoutIncreased = 129600;
                assertEq(oralceImplementation.data, abi.encode(wsolTimeoutIncreased));
            }
        }
    }

    function test_whiteListedTokens() public view {
        // all whitelisted tokens
        address[] memory tokens = pinto.getWhitelistedTokens();
        console.log("-------------------------------");
        console.log("Whitelisted Tokens");
        console.log("-------------------------------");
        for (uint256 i = 0; i < tokens.length; i++) {
            console.log("Whitelisted Token: ", tokens[i]);
            assertEq(tokens[i], whitelistedTokens[i]);
        }
        console.log("-------------------------------");
        // all whitelisted lp tokens
        address[] memory whitelistedLpTokens = pinto.getWhitelistedLpTokens();
        console.log("-------------------------------");
        console.log("Whitelisted LP Tokens");
        console.log("-------------------------------");
        for (uint256 i = 0; i < whitelistedLpTokens.length; i++) {
            console.log("Whitelisted LP Token: ", whitelistedLpTokens[i]);
            assertEq(whitelistedLpTokens[i], whiteListedWellTokens[i]);
        }
        // all whitelisted well lp tokens (should be the same)
        console.log("-------------------------------");
        console.log("Whitelisted Well LP Tokens");
        console.log("-------------------------------");
        address[] memory whitelistedWellLpTokens = pinto.getWhitelistedWellLpTokens();
        for (uint256 i = 0; i < whitelistedWellLpTokens.length; i++) {
            console.log("Whitelisted Well LP Token: ", whitelistedWellLpTokens[i]);
            assertEq(whitelistedWellLpTokens[i], whiteListedWellTokens[i]);
        }
        console.log("-------------------------------");
    }

    function test_shipmentRoutes() public view {
        address shipmentPlanner = address(0x73924B07D9E087b5Cb331c305A65882101bC2fa2);
        // get shipment routes
        IMockFBeanstalk.ShipmentRoute[] memory routes = pinto.getShipmentRoutes();
        console.log("-------------------------------");
        console.log("Receipient list");
        console.log("-------------------------------");
        console.log("NULL: ", uint8(ShipmentRecipient.NULL));
        console.log("SILO: ", uint8(ShipmentRecipient.SILO));
        console.log("FIELD: ", uint8(ShipmentRecipient.FIELD));
        console.log("INTERNAL_BALANCE: ", uint8(ShipmentRecipient.INTERNAL_BALANCE));
        console.log("EXTERNAL_BALANCE: ", uint8(ShipmentRecipient.EXTERNAL_BALANCE));
        console.log("-------------------------------");
        console.log("-------------------------------");
        console.log("Shipment Routes");
        console.log("-------------------------------");
        for (uint256 i = 0; i < routes.length; i++) {
            assertEq(routes[i].planContract, shipmentPlanner);
            console.log("-------------------------------");
            console.log("Shipment Route: ", i);
            console.log("-------------------------------");
            console.log("Plan Contract: ", routes[i].planContract);
            console.log("Plan Selector: ");
            console.logBytes4(routes[i].planSelector);
            console.log("Recipient: ", uint8(routes[i].recipient));
            console.log("Data: ");
            console.logBytes(routes[i].data);
            console.log("-------------------------------");
        }
        // silo (0x01)
        assertEq(routes[0].planSelector, ShipmentPlanner.getSiloPlan.selector);
        assertEq(uint8(routes[0].recipient), uint8(ShipmentRecipient.SILO));
        assertEq(routes[0].data, new bytes(32));
        // field (0x02)
        assertEq(routes[1].planSelector, ShipmentPlanner.getFieldPlan.selector);
        assertEq(uint8(routes[1].recipient), uint8(ShipmentRecipient.FIELD));
        assertEq(routes[1].data, abi.encodePacked(uint256(0)));
        // budget (0x03)
        assertEq(routes[2].planSelector, ShipmentPlanner.getBudgetPlan.selector);
        assertEq(uint8(routes[2].recipient), uint8(ShipmentRecipient.INTERNAL_BALANCE));
        assertEq(routes[2].data, abi.encode(DEV_BUDGET));
        // payback field (0x02)
        assertEq(routes[3].planSelector, ShipmentPlanner.getPaybackFieldPlan.selector);
        assertEq(uint8(routes[3].recipient), uint8(ShipmentRecipient.FIELD));
        assertEq(routes[3].data, abi.encode(PAYBACK_FIELD_ID, PCM));
        // payback contract (0x04)
        assertEq(routes[4].planSelector, ShipmentPlanner.getPaybackPlan.selector);
        assertEq(uint8(routes[4].recipient), uint8(ShipmentRecipient.EXTERNAL_BALANCE));
        assertEq(routes[4].data, abi.encode(PCM));
    }

    function test_pintoProperties() public {
        uint256 totalSupply = IBeanstalkERC20(L2_PINTO).totalSupply();
        uint256 totalSupplyFromGlobal = getGlobalPropertyUint("token.initSupply");
        assertEq(totalSupply, totalSupplyFromGlobal);
        console.log("-------------------------------");
        console.log("Pinto Properties");
        console.log("-------------------------------");
        console.log("Total Supply: ", totalSupply);

        string memory name = IBeanstalkERC20(L2_PINTO).name();
        console.log("Name: ", name);
        assertEq(name, "Pinto");

        string memory symbol = IBeanstalkERC20(L2_PINTO).symbol();
        console.log("Symbol: ", symbol);
        assertEq(symbol, "PINTO");
        console.log("-------------------------------");
    }

    function test_ownership() public view {
        console.log("-------------------------------");
        console.log("Ownership");
        console.log("-------------------------------");
        address owner = pinto.owner();
        console.log("Owner: ", owner);
        address ownerCandidate = pinto.ownerCandidate();
        console.log("Owner Candidate: ", ownerCandidate);
        console.log("-------------------------------");
        assertEq(owner, PINTO_DEPLOYER);
        assertEq(ownerCandidate, PCM);
    }

    function test_initialDeposit() public view {
        // test that deposit went to dev budget //pinto/weth
        address depositedToken = address(0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3);
        IMockFBeanstalk.TokenDepositId[] memory deposits = pinto.getDepositsForAccount(
            FIVE_PERCENT_RESERVES
        );
        console.log("-------------------------------");
        console.log("Initial Deposits for address: ", FIVE_PERCENT_RESERVES);
        console.log("-------------------------------");
        for (uint256 i = 0; i < deposits.length; i++) {
            console.log("Token: ", deposits[i].token);
            for (uint256 j = 0; j < deposits[i].tokenDeposits.length; j++) {
                console.log("Amount: ", deposits[i].tokenDeposits[j].amount);
                assertGt(deposits[i].tokenDeposits[j].amount, 0);
            }
        }
        console.log("-------------------------------");
    }

    //////////////////// Helper Functions ////////////////////

    function getGlobalPropertyUint(string memory property) public returns (uint256) {
        bytes memory globalPropertyJson = searchGlobalPropertyData(property);
        return vm.parseUint(vm.toString(globalPropertyJson));
    }

    function searchGlobalPropertyData(string memory property) public returns (bytes memory) {
        string[] memory inputs = new string[](4);
        inputs[0] = "node";
        inputs[1] = "./scripts/deployment/parameters/finders/finder.js"; // script
        inputs[2] = "./scripts/deployment/parameters/input/deploymentParams.json"; // json file
        inputs[3] = property;
        bytes memory propertyValue = vm.ffi(inputs);
        return propertyValue;
    }
}

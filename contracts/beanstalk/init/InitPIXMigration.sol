/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import {LibInitGauges} from "contracts/libraries/Gauge/LibInitGauges.sol";
import {InitWells} from "contracts/beanstalk/init/deployment/InitWells.sol";
import {LibAppStorage, AppStorage} from "contracts/libraries/LibAppStorage.sol";
import {AssetSettings, Implementation} from "contracts/beanstalk/storage/System.sol";
import {BDVFacet} from "contracts/beanstalk/facets/silo/BDVFacet.sol";
import {Call, IERC20} from "contracts/interfaces/basin/IWell.sol";
import {console} from "forge-std/console.sol";
import {LSDChainlinkOracle} from "contracts/ecosystem/oracles/LSDChainlinkOracle.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {InitPodReferral} from "contracts/beanstalk/init/InitPodReferral.sol";


/**
 * @title InitPIXMigration
 * @author Frijo, pocikerim
 * @dev This PI performs the following upgrades:
 * 1. Deploys a new pinto-wsteth well.
 * 2. Whitelists the new asset.
 * 3. Initializes the LP distribution gauge to distribute the LP over the new asset.
 * 4. Initializes the referral system.
 * 5. Updates the tractor version.
 **/
contract InitPIXMigration is InitWells, InitPodReferral {

    // Well parameters.
    address internal constant PINTO_CBETH_WELL = 0x3e111115A82dF6190e36ADf0d552880663A4dBF1;
    address internal constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address internal constant WELL_IMPLEMENTATION = 0xBA510990a720725Ab1F9a0D231F045fc906909f4;
    address internal constant AQUIFER = 0xBA51AA60B3b8d9A36cc748a62Aa56801060183f8;
    bytes32 internal constant WELL_SALT =
        0xa1403b59e21fd5e877f0c926cc94485d8e048272197f6b1e94bad0186e6c53a7;
    bytes32 internal constant PROXY_SALT =
        0x00ee4d9e32976f40b38d99d1c3eee5ca2e3ae06d24630a6df69a9a8b7c8b4500;

    // Gauge parameters.
    int64 internal constant DELTA = 1111111;
    uint64 internal constant TARGET = 33333333;

    // Asset parameters.
    uint48 internal constant STALK_PER_BDV = 1e10;
    address internal constant ETH_USD_CHAINLINK_ORACLE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant WSTETH_ETH_CHAINLINK_ORACLE =
        0x43a5C292A453A3bF3606fa856197f09D7B74251a;

    function init(address[] memory allowedReferrers) external {
        // Deploy the new well.
        (address wellImplementation, address wstethWell) = deployUpgradableWell(
            getWstethWellData()
        );

        // Whitelist new asset.
        whitelistBeanAsset(getWhitelistData(wstethWell, address(new LSDChainlinkOracle())));

        // Initialize the LP distribution gauge.
        LibInitGauges.initLpDistributionGauge(PINTO_CBETH_WELL, wstethWell, DELTA, TARGET);
        console.log("wsteth well deployed to:", wstethWell);
        console.log("wsteth well implementation deployed to:", wellImplementation);

        // Initialize the referral system.
        initPodReferral(allowedReferrers);

        // update tractor version. 
        // Tractor now supports dynamic calldata for contracts,
        // and is backwards compatible with the old version.
        LibTractor._setVersion("1.1.0");
    }

    function getWstethWellData() internal view returns (WellData memory wstethWellData) {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(s.sys.bean);
        tokens[1] = IERC20(WSTETH);
        Call[] memory pumps = new Call[](1);
        pumps[0] = getMultiFlowPumpCall();
        wstethWellData = WellData({
            tokens: tokens,
            wellImplementation: WELL_IMPLEMENTATION,
            wellFunction: getConstantProduct2Call(),
            aquifer: AQUIFER,
            pumps: pumps,
            wellSalt: WELL_SALT,
            proxySalt: PROXY_SALT,
            name: "PINTO:WSTETH Constant Product 2 Upgradeable Well",
            symbol: "U-PINTOWSTETHCP2w"
        });
    }

    function getWhitelistData(
        address well,
        address oracleAddress
    ) internal view returns (WhitelistData memory whitelistData) {
        AssetSettings memory assetSettings = AssetSettings({
            selector: BDVFacet.wellBdv.selector,
            stalkEarnedPerSeason: 1,
            stalkIssuedPerBdv: STALK_PER_BDV,
            milestoneSeason: uint32(s.sys.season.current),
            milestoneStem: 0,
            encodeType: bytes1(0x01),
            deltaStalkEarnedPerSeason: 0,
            gaugePoints: 0,
            optimalPercentDepositedBdv: 0,
            gaugePointImplementation: getDefaultGaugePointImplementation(),
            liquidityWeightImplementation: getDefaultLiquidityWeightImplementation()
        });
        Implementation memory oracle = Implementation({
            target: oracleAddress,
            selector: bytes4(0xb0dd7409),
            encodeType: bytes1(0x00),
            data: abi.encode(
                ETH_USD_CHAINLINK_ORACLE,
                type(uint256).max,
                WSTETH_ETH_CHAINLINK_ORACLE,
                type(uint256).max
            )
        });
        whitelistData = WhitelistData({
            token: well,
            nonBeanToken: WSTETH,
            asset: assetSettings,
            oracle: oracle
        });
        return whitelistData;
    }
}

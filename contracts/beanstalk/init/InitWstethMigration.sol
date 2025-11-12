/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
import {LibInitGauges} from "contracts/libraries/Gauge/LibInitGauges.sol";
import {InitWells} from "contracts/beanstalk/init/deployment/InitWells.sol";
import {LibAppStorage, AppStorage} from "contracts/libraries/LibAppStorage.sol";
import {AssetSettings, Implementation} from "contracts/beanstalk/storage/System.sol";
import {BDVFacet} from "contracts/beanstalk/facets/silo/BDVFacet.sol";
import {Call} from "contracts/interfaces/basin/IWell.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/**
 * @title InitWstethMigration
 * @dev performs the wsteth migration.
 * This PI performs the following steps:
 * 1. Deploys a new pinto-wsteth well.
 * 2. Whitelists the new asset.
 * 3. Initializes the LP distribution gauge to distribute the LP over the new asset.
 **/
contract InitWstethMigration is InitWells {

    int64 internal constant DELTA = 1e6;
    uint256 internal constant NUM_SEASONS = 33;
    address internal constant PINTO_CBETH_WELL = 0x3e111115A82dF6190e36ADf0d552880663A4dBF1;
    
    // Well parameters.
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WELL_IMPLEMENTATION = 0x0000000000000000000000000000000000000000;
    address internal constant AQUIFER = 0x0000000000000000000000000000000000000000;
    bytes32 internal constant WELL_SALT = 0x0000000000000000000000000000000000000000000000000000000000000002;
    bytes32 internal constant PROXY_SALT = 0x0000000000000000000000000000000000000000000000000000000000000000;

    // Asset parameters.
    uint48 internal constant STALK_PER_BDV = 1e10;

    function init() external {
        // Deploy the new well.
        (, address wstethWell) = deployUpgradableWell(getWstethWellData());
        // Whitelist new asset.
        whitelistBeanAsset(getWhitelistData(wstethWell));

        // Initialize the LP distribution gauge.
        LibInitGauges.initLpDistributionGauge(NUM_SEASONS, PINTO_CBETH_WELL, wstethWell, DELTA);
    }

    function getWstethWellData() internal pure returns (WellData memory wstethWellData) {
        IERC20[] memory tokens;
        Call[] memory pumps;
        wstethWellData = WellData({
            tokens: tokens,
            wellImplementation: WELL_IMPLEMENTATION,
            wellFunction: getConstantProduct2Call(),
            aquifer: AQUIFER,
            pumps: pumps,
            wellSalt: WELL_SALT,
            proxySalt: PROXY_SALT,
            name: "WSTETH",
            symbol: "WSTETH"
        });
    }

    function getWhitelistData(address well) internal view returns (WhitelistData memory whitelistData) {
        AssetSettings memory assetSettings = AssetSettings({
            selector: BDVFacet.beanToBDV.selector,
            stalkEarnedPerSeason: 0,
            stalkIssuedPerBdv: STALK_PER_BDV,
            milestoneSeason: 0,
            milestoneStem: 0,
            encodeType: bytes1(0x01),
            deltaStalkEarnedPerSeason: 0,
            gaugePoints: 0,
            optimalPercentDepositedBdv: 0,
            gaugePointImplementation: getDefaultGaugePointImplementation(),
            liquidityWeightImplementation: getDefaultLiquidityWeightImplementation()
        });
        Implementation memory oracle = Implementation({
            target: 0x0000000000000000000000000000000000000000,
            selector: 0x00000000,
            encodeType: bytes1(0x00),
            data: bytes("")
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

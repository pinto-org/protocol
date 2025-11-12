/*
 SPDX-License-Identifier: MIT
*/
pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LibWellDeployer} from "contracts/libraries/Basin/LibWellDeployer.sol";
import {IWellUpgradeable} from "contracts/interfaces/basin/IWellUpgradeable.sol";
import {IAquifer} from "contracts/interfaces/basin/IAquifer.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Implementation, WhitelistStatus, AssetSettings} from "contracts/beanstalk/storage/System.sol";
import {LibWhitelist} from "contracts/libraries/Silo/LibWhitelist.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {Call} from "contracts/interfaces/basin/IWell.sol";
import {IGaugeFacet} from "contracts/beanstalk/facets/sun/GaugeFacet.sol";
import {ILiquidityWeightFacet} from "contracts/beanstalk/facets/sun/LiquidityWeightFacet.sol";
/**
 * @title InitWells
 * Deploys the initial wells for the protocol and whitelists all assets.
 */
contract InitWells {
    AppStorage internal s;
    address internal constant CONSTANT_PRODUCT_2 = 0xBA510C289fD067EBbA41335afa11F0591940d6fe;
    address internal constant MULTI_FLOW_PUMP = 0xBA51AAaA66DaB6c236B356ad713f759c206DcB93;

    /**
     * @notice contains parameters for the wells to be deployed on basin. Assumes Pinto is the first token in the well.
     */
    struct WellData {
        IERC20[] tokens;
        address wellImplementation;
        Call wellFunction;
        address aquifer;
        Call[] pumps;
        bytes32 wellSalt;
        bytes32 proxySalt;
        string name;
        string symbol;
    }

    /**
     * @notice contains the initial whitelist data for bean assets.
     */
    struct WhitelistData {
        address token;
        address nonBeanToken;
        AssetSettings asset;
        Implementation oracle;
    }

    /**
     * @notice Initializes the Bean protocol deployment.
     */
    function initWells(WellData[] calldata wells, WhitelistData[] calldata whitelist) external {
        // Deploy the initial wells
        deployUpgradableWells(s.sys.bean, wells);
        // Whitelist bean assets
        whitelistBeanAssets(whitelist);
    }

    /**
     * @notice Deploys a minimal proxy well with the upgradeable well implementation and a
     * ERC1967Proxy in front of it to allow for future upgrades.
     */
    function deployUpgradableWell(
        WellData memory wellData
    ) internal returns (address well, address proxy) {
        // Encode well data
        (bytes memory immutableData, bytes memory initData) = LibWellDeployer
            .encodeUpgradeableWellDeploymentData(
                wellData.aquifer,
                wellData.tokens,
                wellData.wellFunction,
                wellData.pumps
            );

        well = IAquifer(wellData.aquifer).boreWell(
            wellData.wellImplementation,
            immutableData,
            initData,
            wellData.wellSalt
        );

        // Deploy proxy
        initData = abi.encodeCall(IWellUpgradeable.init, (wellData.name, wellData.symbol));
        // log initData
        bytes memory creationCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(well, initData)
        );
        proxy = address(new ERC1967Proxy{salt: wellData.proxySalt}(well, initData));
    }

    /**
     * @notice Deploys bean basin wells with the upgradeable well implementation.
     * Configures the well's components and pumps.
     */
    function deployUpgradableWells(address bean, WellData[] memory wells) internal {
        // Deployment
        for (uint256 i; i < wells.length; i++) {
            wells[i].tokens[0] = IERC20(bean);
            deployUpgradableWell(wells[i]);
        }
    }

    /**
     * @notice Whitelists bean and Well LP tokens in the Silo. Initializes oracle settings and whitelist statuses.
     * Note: Addresses for bean LP tokens are already determined since they are deployed
     * using create2, thus, we don't need to pass them in from the previous step.
     * Note: When whitelisting, we assume all non-bean whitelist tokens are well LP tokens.
     */
    function whitelistBeanAssets(WhitelistData[] calldata whitelistData) internal {
        for (uint256 i; i < whitelistData.length; i++) {
            whitelistBeanAsset(whitelistData[i]);
        }
    }

    function whitelistBeanAsset(WhitelistData memory wd) internal {
        // If an LP token, initialize oracle storage variables.
        if (wd.token != address(s.sys.bean)) {
            s.sys.usdTokenPrice[wd.token] = 1;
            s.sys.twaReserves[wd.token].reserve0 = 1;
            s.sys.twaReserves[wd.token].reserve1 = 1;
            // LP tokens will require an Oracle Implementation for the non Bean Asset.
            s.sys.oracleImplementation[wd.nonBeanToken] = wd.oracle;
            emit LibWhitelist.UpdatedOracleImplementationForToken(wd.token, wd.oracle);
        }
        // add asset settings for the underlying lp token
        s.sys.silo.assetSettings[wd.token] = wd.asset;
        // Whitelist status contains all true values except for the bean token.
        WhitelistStatus memory ws = WhitelistStatus(
            wd.token,
            true,
            wd.token != address(s.sys.bean),
            wd.token != address(s.sys.bean),
            wd.token != address(s.sys.bean)
        );
        uint256 index = s.sys.silo.whitelistStatuses.length;
        s.sys.silo.whitelistStatuses.push(ws);

        emitWhitelistEvents(wd, ws, index);
    }

    function emitWhitelistEvents(
        WhitelistData memory wd,
        WhitelistStatus memory ws,
        uint256 index
    ) internal {
        emit LibWhitelistedTokens.UpdateWhitelistStatus(
            ws.token,
            index,
            ws.isWhitelisted,
            ws.isWhitelistedLp,
            ws.isWhitelistedWell,
            ws.isSoppable
        );

        emit LibWhitelist.WhitelistToken(
            ws.token,
            wd.asset.selector,
            wd.asset.stalkEarnedPerSeason,
            wd.asset.stalkIssuedPerBdv,
            wd.asset.gaugePoints,
            wd.asset.optimalPercentDepositedBdv
        );

        emit LibWhitelist.UpdatedGaugePointImplementationForToken(
            ws.token,
            wd.asset.gaugePointImplementation
        );
        emit LibWhitelist.UpdatedLiquidityWeightImplementationForToken(
            ws.token,
            wd.asset.liquidityWeightImplementation
        );
    }

    function getDefaultGaugePointImplementation()
        internal
        view
        returns (Implementation memory gaugePointImplementation)
    {
        gaugePointImplementation = Implementation({
            target: address(this),
            selector: IGaugeFacet.defaultGaugePoints.selector,
            encodeType: 0x00,
            data: bytes("")
        });
    }

    function getDefaultLiquidityWeightImplementation()
        internal
        view
        returns (Implementation memory liquidityWeightImplementation)
    {
        liquidityWeightImplementation = Implementation({
            target: address(this),
            selector: ILiquidityWeightFacet.maxWeight.selector,
            encodeType: 0x00,
            data: bytes("")
        });
    }

    function getConstantProduct2Call() internal pure returns (Call memory wellFunction) {
        wellFunction = Call({target: CONSTANT_PRODUCT_2, data: bytes("")});
    }

    function getMultiFlowPumpCall() internal pure returns (Call memory pump) {
        pump = Call({
            target: MULTI_FLOW_PUMP,
            data: hex"3ffefd29d6deab9ccdef2300d0c1c903000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000603ffd0000000000000000000000000000000000000000000000000000000000003ffd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003ffd00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000023ffd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        });
    }
}

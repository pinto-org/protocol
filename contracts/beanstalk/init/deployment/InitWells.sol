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

/**
 * @title InitWells
 * Deploys the initial wells for the protocol and whitelists all assets.
 */
contract InitWells {
    AppStorage internal s;

    // A default well salt is used to prevent front-running attacks
    // as the aquifer also uses msg.sender when boring with non-zero salt.
    bytes32 internal constant DEFAULT_WELL_SALT =
        0x0000000000000000000000000000000000000000000000000000000000000001;

    /**
     * @notice contains parameters for the wells to be deployed on basin.
     */
    struct WellData {
        IERC20 nonBeanToken;
        address wellImplementation;
        address wellFunctionTarget;
        bytes wellFunctionData;
        address aquifer;
        address pump;
        bytes pumpData;
        bytes32 salt;
        string name;
        string symbol;
    }

    /**
     * @notice contains the initial whitelist data for bean assets.
     */
    struct WhitelistData {
        address[] tokens;
        address[] nonBeanTokens;
        AssetSettings[] assets;
        Implementation[] oracle;
    }

    /**
     * @notice Initializes the Bean protocol deployment.
     */
    function init(WellData[] calldata wells, WhitelistData calldata whitelist) external {
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
        IERC20[] memory tokens,
        Call memory wellFunction,
        Call[] memory pumps,
        address aquifer,
        address wellImplementation,
        bytes32 salt,
        string memory name,
        string memory symbol
    ) internal {
        // Encode well data
        (bytes memory immutableData, bytes memory initData) = LibWellDeployer
            .encodeUpgradeableWellDeploymentData(aquifer, tokens, wellFunction, pumps);

        // Bore upgradeable well with the same salt for reproducibility.
        // The address of this is irrelevant, we just need it to be constant, this is why no salt is used.
        address _well = IAquifer(aquifer).boreWell(
            wellImplementation,
            immutableData,
            initData,
            DEFAULT_WELL_SALT
        );

        // console.log("_well for %s: %s", name, _well);

        // Deploy proxy
        address wellProxy = address(
            new ERC1967Proxy{salt: salt}(
                _well,
                abi.encodeCall(IWellUpgradeable.init, (name, symbol))
            )
        );
    }

    /**
     * @notice Deploys bean basin wells with the upgradeable well implementation.
     * Congigures the well's components and pumps.
     */
    function deployUpgradableWells(address bean, WellData[] calldata wells) internal {
        // tokens
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(bean);

        // Deployment
        for (uint256 i; i < wells.length; i++) {
            WellData calldata wellData = wells[i];
            // tokens
            tokens[1] = wellData.nonBeanToken;
            // well function
            Call memory wellFunction = Call(wellData.wellFunctionTarget, wellData.wellFunctionData);
            // pumps
            Call[] memory pumps = new Call[](1);
            pumps[0] = Call(wellData.pump, wellData.pumpData);
            // deploy well
            deployUpgradableWell(
                tokens, // tokens (IERC20[])
                wellFunction, // well function (Call)
                pumps, // pumps (Call[])
                wellData.aquifer, // aquifer (address)
                wellData.wellImplementation, // well implementation (address)
                wellData.salt,
                wellData.name,
                wellData.symbol
            );
        }
    }

    /**
     * @notice Whitelists bean and Well LP tokens in the Silo. Initializes oracle settings and whitelist statuses.
     * Note: Addresses for bean LP tokens are already determined since they are deployed
     * using create2, thus, we don't need to pass them in from the previous step.
     * Note: When whitelisting, we assume all non-bean whitelist tokens are well LP tokens.
     */
    function whitelistBeanAssets(WhitelistData calldata whitelistData) internal {
        for (uint256 i; i < whitelistData.tokens.length; i++) {
            address token = whitelistData.tokens[i];
            address nonBeanToken = whitelistData.nonBeanTokens[i];
            AssetSettings memory assetSettings = whitelistData.assets[i];
            // If an LP token, initialize oracle storage variables.
            if (token != address(s.sys.bean)) {
                s.sys.usdTokenPrice[token] = 1;
                s.sys.twaReserves[token].reserve0 = 1;
                s.sys.twaReserves[token].reserve1 = 1;
                // LP tokens will require an Oracle Implementation for the non Bean Asset.
                s.sys.oracleImplementation[nonBeanToken] = whitelistData.oracle[i];
                emit LibWhitelist.UpdatedOracleImplementationForToken(
                    token,
                    whitelistData.oracle[i]
                );
            }
            // add asset settings for the underlying lp token
            s.sys.silo.assetSettings[token] = assetSettings;
            // Whitelist status contains all true values exept for the bean token.
            WhitelistStatus memory whitelistStatus = WhitelistStatus(
                token,
                true,
                token != address(s.sys.bean),
                token != address(s.sys.bean),
                token != address(s.sys.bean)
            );
            s.sys.silo.whitelistStatuses.push(whitelistStatus);

            emit LibWhitelistedTokens.UpdateWhitelistStatus(
                token,
                i,
                true,
                token != address(s.sys.bean),
                token != address(s.sys.bean),
                token != address(s.sys.bean)
            );

            emit LibWhitelist.WhitelistToken(
                token,
                assetSettings.selector,
                assetSettings.stalkEarnedPerSeason,
                assetSettings.stalkIssuedPerBdv,
                assetSettings.gaugePoints,
                assetSettings.optimalPercentDepositedBdv
            );

            emit LibWhitelist.UpdatedGaugePointImplementationForToken(
                token,
                assetSettings.gaugePointImplementation
            );
            emit LibWhitelist.UpdatedLiquidityWeightImplementationForToken(
                token,
                assetSettings.liquidityWeightImplementation
            );
        }
    }
}

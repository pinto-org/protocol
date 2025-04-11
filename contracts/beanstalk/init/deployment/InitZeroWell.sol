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
import {IWell, Call} from "contracts/interfaces/basin/IWell.sol";

/**
 * @title InitWells
 * Deploys the initial wells for the protocol and whitelists all assets.
 */
contract InitZeroWell {
    AppStorage internal s;

    // A default well salt is used to prevent front-running attacks
    // as the aquifer also uses msg.sender when boring with non-zero salt.
    bytes32 internal constant DEFAULT_WELL_SALT =
        0x0000000000000000000000000000000000000000000000000000000000000002;

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
     * @notice Emitted when a Well Minting Oracle is captured.
     * @param season The season that the Well was captured.
     * @param well The Well that was captured.
     * @param deltaB The time weighted average delta B computed during the Oracle capture.
     * @param cumulativeReserves The encoded cumulative reserves that were snapshotted most by the Oracle capture.
     */
    event WellOracle(uint32 indexed season, address well, int256 deltaB, bytes cumulativeReserves);

    /**
     * @notice Initializes the Bean protocol deployment.
     */
    function init(WellData[] calldata wells) external {
        // deploy new upgradeable well, upgrade the wells,
        // and delete the wellOracleSnapshots.
        deployUpgradableWells(s.sys.bean, wells);
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
        bytes32,
        string memory,
        string memory,
        address wellToUpgrade
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

        // delete the wellOracleSnapshot.
        delete s.sys.wellOracleSnapshots[wellToUpgrade];
        emit WellOracle(s.sys.season.current, wellToUpgrade, 0, new bytes(0));
        // Upgrade the well to the new implementation
        IWellUpgradeable(payable(wellToUpgrade)).upgradeTo(_well);
        IWell(wellToUpgrade).sync(address(this), 0);
        IWell(wellToUpgrade).sync(address(this), 0);
    }

    /**
     * @notice Deploys bean basin wells with the upgradeable well implementation.
     * Configures the well's components and pumps.
     */
    function deployUpgradableWells(address bean, WellData[] calldata wells) internal {
        // tokens
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(bean);
        address[] memory whitelistedTokens = LibWhitelistedTokens.getWhitelistedWellLpTokens();
        // Deployment
        for (uint256 i; i < whitelistedTokens.length; i++) {
            WellData calldata wellData = wells[i];
            address wellToUpgrade = whitelistedTokens[i];
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
                wellData.symbol,
                wellToUpgrade
            );
        }
    }
}

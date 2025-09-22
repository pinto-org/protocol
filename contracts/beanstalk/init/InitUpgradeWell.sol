/*
 SPDX-License-Identifier: MIT
*/
pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LibWellDeployer} from "contracts/libraries/Basin/LibWellDeployer.sol";
import {IWellUpgradeable} from "contracts/interfaces/basin/IWellUpgradeable.sol";
import {IAquifer} from "contracts/interfaces/basin/IAquifer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWell, Call} from "contracts/interfaces/basin/IWell.sol";

/**
 * @title InitUpgradeWell
 * Upgrades a set of upgradeable wells to use new arbitrary components.
 * Intended for when fixes or updates to a well's components but keeping the same data.
 */
contract InitUpgradeWell {
    // A default well salt is used to prevent front-running attacks as boring wells also uses msg.sender with non-zero salt.
    bytes32 internal constant DEFAULT_WELL_SALT =
        0x0000000000000000000000000000000000000000000000000000000000000010;

    /**
     * @notice Upgrades a set of upgradeable wells to use new arbitrary components.
     * @param wellsToUpgrade The addresses of the wells to upgrade.
     * For now only the Upgradeable well implementation is supported.
     * @param newWellFunctionTarget The new well function target to use or address(0) for no change.
     * @param newPumpTarget The new pump target to use or address(0) for no change.
     */
    function init(
        address[] memory wellsToUpgrade,
        address newWellFunctionTarget,
        address newPumpTarget
    ) external {
        for (uint256 i; i < wellsToUpgrade.length; i++) {
            address wellToUpgrade = wellsToUpgrade[i];

            // get well components
            (
                IERC20[] memory tokens,
                Call memory wellFunction,
                Call[] memory pumps, // well data
                ,
                address aquifer
            ) = IWell(wellToUpgrade).well();

            // get the upgradeable well implementation component address
            address wellImplementation = getWellUpgradeableImplementation(wellToUpgrade, aquifer);

            // if specified, create new well function with updated target but same data
            wellFunction = newWellFunctionTarget != address(0)
                ? Call(newWellFunctionTarget, wellFunction.data)
                : wellFunction;

            // if specified, update the well's first pump with updated target but same data
            pumps[0] = newPumpTarget != address(0) ? Call(newPumpTarget, pumps[0].data) : pumps[0];

            deployAndUpgradeWell(
                tokens,
                wellFunction,
                pumps,
                aquifer,
                wellImplementation,
                wellToUpgrade
            );
        }
    }

    /**
     * @notice Deploys a minimal proxy well with the upgradeable well implementation and a
     * ERC1967Proxy in front of it to allow for future upgrades.
     * Upgrades the existing well to the new implementation.
     */
    function deployAndUpgradeWell(
        IERC20[] memory tokens,
        Call memory wellFunction,
        Call[] memory pumps,
        address aquifer,
        address wellImplementation,
        address wellToUpgrade
    ) internal {
        // Encode well data
        (bytes memory immutableData, bytes memory initData) = LibWellDeployer
            .encodeUpgradeableWellDeploymentData(aquifer, tokens, wellFunction, pumps);

        // Bore upgradeable well with the same salt for reproducibility.
        address _well = IAquifer(aquifer).boreWell(
            wellImplementation,
            immutableData,
            initData,
            DEFAULT_WELL_SALT
        );

        // Upgrade the well to the new implementation
        IWellUpgradeable(payable(wellToUpgrade)).upgradeTo(_well);
    }

    /**
     * @notice Returns the WellUpgradeable standalone component address of an upgradeable Well.
     * by traversing through the ERC1967Proxy and the minimal proxy chain and finally fetching the Aquifer registry.
     */
    function getWellUpgradeableImplementation(
        address wellToUpgrade,
        address aquifer
    ) internal view returns (address) {
        address minimalProxy = IWellUpgradeable(wellToUpgrade).getImplementation();
        return IAquifer(aquifer).wellImplementation(minimalProxy);
    }
}

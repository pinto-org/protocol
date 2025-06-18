/**
 * SPDX-License-Identifier: MIT
 **/
pragma solidity ^0.8.20;

import "./interfaces/IBean.sol";
import "./interfaces/IProxyAdmin.sol";
import "./libraries/Decimal.sol";
import "./interfaces/IPipeline.sol";

/**
 * @title C
 * @notice Contains constants used throughout Beanstalk.
 */
library C {
    using Decimal for Decimal.D256;

    //////////////////// Globals ////////////////////

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant PRECISION_6 = 1e6;
    /// @dev The absolute maximum amount of Beans or Soil that can be issued from the system.
    uint256 internal constant GLOBAL_ABSOLUTE_MAX = 800_000e6;
    /// @dev The maximum percentage of Beans or Soil that can be issued from the system.
    /// @dev Relative to the total supply.
    uint256 internal constant GLOBAL_RATIO_MAX = 0.04e18;

    //////////////////// Reentrancy ////////////////////
    uint256 internal constant NOT_ENTERED = 1;
    uint256 internal constant ENTERED = 2;

    //////////////////// Season ////////////////////

    /// @dev The length of a Season meaured in seconds.
    uint256 internal constant CURRENT_SEASON_PERIOD = 3600; // 1 hour
    uint256 internal constant SOP_PRECISION = 1e30;

    //////////////////// Silo ////////////////////
    uint256 internal constant STALK_PER_BEAN = 1e10;
    uint256 private constant ROOTS_BASE = 1e12;

    //////////////////// Contracts ////////////////////
    address internal constant PIPELINE = 0xb1bE0001f5a373b69b1E132b420e6D9687155e80;

    //////////////////// Well ////////////////////

    /// @dev The minimum balance required to calculate the BDV of a Well Token.
    uint256 internal constant WELL_MINIMUM_BEAN_BALANCE = 10e6;
    /// @dev The absolute maximum amount of Beans or Soil that can be issued from a single Well.
    uint256 internal constant WELL_ABSOLUTE_MAX = 200_000e6;
    /// @dev The maximum percentage of Beans or Soil that can be issued from a single Well.
    /// @dev Relative to the total supply.
    uint256 internal constant WELL_RATIO_MAX = 0.02e18;

    //////////////////// Tractor ////////////////////

    uint80 internal constant SLOT_SIZE = 32;
    // Special index to indicate the data to copy is the publisher address.
    uint80 internal constant PUBLISHER_COPY_INDEX = type(uint80).max;
    // Special index to indicate the data to copy is the operator address.
    uint80 internal constant OPERATOR_COPY_INDEX = type(uint80).max - 1;

    function getRootsBase() internal pure returns (uint256) {
        return ROOTS_BASE;
    }

    function precision() internal pure returns (uint256) {
        return PRECISION;
    }

    function pipeline() internal pure returns (IPipeline) {
        return IPipeline(PIPELINE);
    }
}

/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import "contracts/libraries/Math/LibRedundantMath256.sol";
import "contracts/libraries/Math/LibRedundantMath128.sol";
import "contracts/beanstalk/facets/silo/SiloFacet.sol";
import "contracts/libraries/Silo/LibWhitelist.sol";
import "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import "contracts/libraries/LibTractor.sol";

/**
 * @title Mock Silo Facet
 *
 */
contract MockSiloFacet is SiloFacet {
    uint256 private constant AMOUNT_TO_BDV_BEAN_ETH = 119894802186829;
    uint256 private constant AMOUNT_TO_BDV_BEAN_3CRV = 992035;
    uint256 private constant AMOUNT_TO_BDV_BEAN_LUSD = 983108;

    using SafeCast for uint256;
    using LibRedundantMath128 for uint128;
    using LibRedundantMath256 for uint256;

    function mockBDV(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function mockBDVIncrease(uint256 amount) external pure returns (uint256) {
        return amount.mul(3).div(2);
    }

    /// @dev Mocks a BDV decrease of 10
    function mockBDVDecrease(uint256 amount) external pure returns (uint256) {
        return amount - 10;
    }

    /// @dev Mocks a constant BDV of 1e6
    function newMockBDV() external pure returns (uint256) {
        return 1e6;
    }

    /// @dev Mocks a decrease in constant BDV
    function newMockBDVDecrease() external pure returns (uint256) {
        return 0.9e6;
    }

    /// @dev Mocks an increase in constant BDV
    function newMockBDVIncrease() external pure returns (uint256) {
        return 1.1e6;
    }

    /// @dev changes bdv selector of token
    function mockChangeBDVSelector(address token, bytes4 selector) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.silo.assetSettings[token].selector = selector;
    }

    //////////////////////// ADD DEPOSIT ////////////////////////

    // function balanceOfSeeds(address account) public view returns (uint256) {
    //     return s.accts[account].silo.seeds;
    // }

    /**
     * @notice Whitelists a token for testing purposes.
     * @dev no gauge. no error checking.
     */
    function mockWhitelistToken(
        address token,
        bytes4 selector,
        uint48 stalkIssuedPerBdv,
        uint40 stalkEarnedPerSeason
    ) external {
        s.sys.silo.assetSettings[token].selector = selector;
        s.sys.silo.assetSettings[token].stalkIssuedPerBdv = stalkIssuedPerBdv; //previously just called "stalk"
        s.sys.silo.assetSettings[token].stalkEarnedPerSeason = stalkEarnedPerSeason; //previously called "seeds"

        s.sys.silo.assetSettings[token].milestoneSeason = uint24(s.sys.season.current);
        LibWhitelistedTokens.addWhitelistStatus(
            token,
            true,
            true,
            selector == LibWell.WELL_BDV_SELECTOR,
            false // is soppable
        );

        // emit WhitelistToken(token, selector, stalkEarnedPerSeason, stalkIssuedPerBdv);
    }

    /**
     * @dev Whitelists a token for testing purposes.
     * @dev no error checking.
     */
    function mockWhitelistTokenWithGauge(
        address token,
        bytes4 selector,
        uint16 stalkIssuedPerBdv,
        uint24 stalkEarnedPerSeason,
        bytes1 encodeType,
        bytes4 gaugePointSelector,
        bytes4 liquidityWeightSelector,
        uint128 gaugePoints,
        uint64 optimalPercentDepositedBdv
    ) external {
        if (stalkEarnedPerSeason == 0) stalkEarnedPerSeason = 1;
        s.sys.silo.assetSettings[token].selector = selector;
        s.sys.silo.assetSettings[token].stalkEarnedPerSeason = stalkEarnedPerSeason;
        s.sys.silo.assetSettings[token].stalkIssuedPerBdv = stalkIssuedPerBdv;
        s.sys.silo.assetSettings[token].milestoneSeason = uint32(s.sys.season.current);
        s.sys.silo.assetSettings[token].encodeType = encodeType;
        s.sys.silo.assetSettings[token].gaugePointImplementation.selector = gaugePointSelector;
        s
            .sys
            .silo
            .assetSettings[token]
            .liquidityWeightImplementation
            .selector = liquidityWeightSelector;
        s.sys.silo.assetSettings[token].gaugePoints = gaugePoints;
        s.sys.silo.assetSettings[token].optimalPercentDepositedBdv = optimalPercentDepositedBdv;

        LibWhitelistedTokens.addWhitelistStatus(
            token,
            true,
            true,
            selector == LibWell.WELL_BDV_SELECTOR,
            true
        );
    }

    function addWhitelistSelector(address token, bytes4 selector) external {
        s.sys.silo.assetSettings[token].selector = selector;
    }

    function removeWhitelistSelector(address token) external {
        s.sys.silo.assetSettings[token].selector = 0x00000000;
    }

    function mockLiquidityWeight() external pure returns (uint256) {
        return 0.5e18;
    }

    function mockUpdateLiquidityWeight(
        address token,
        address newLiquidityWeightImplementation,
        bytes1 encodeType,
        bytes4 selector,
        bytes memory data
    ) external {
        s.sys.silo.assetSettings[token].liquidityWeightImplementation = Implementation(
            newLiquidityWeightImplementation,
            selector,
            encodeType,
            data
        );
    }

    function incrementTotalDepositedAmount(address token, uint256 amount) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.silo.balances[token].deposited = s.sys.silo.balances[token].deposited.add(
            amount.toUint128()
        );
    }

    function setStalkAndRoots(address account, uint128 stalk, uint256 roots) external {
        s.sys.silo.stalk = stalk;
        s.sys.silo.roots = stalk;
        s.accts[account].stalk = stalk;
        s.accts[account].roots = roots;
    }

    function reduceAccountRainRoots(address account, uint256 rainRoots) external {
        // reduce user rain roots
        s.accts[account].sop.rainRoots = s.accts[account].sop.rainRoots.sub(rainRoots);
        // reduce global rain roots
        s.sys.rain.roots = s.sys.rain.roots.sub(rainRoots);
    }
}

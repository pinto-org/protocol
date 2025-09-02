/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {AssetSettings} from "contracts/beanstalk/storage/System.sol";
import "contracts/beanstalk/init/InitializeDiamond.sol";
import {LibWhitelistedTokens} from "contracts/libraries/Silo/LibWhitelistedTokens.sol";
import {LibWhitelist} from "contracts/libraries/Silo/LibWhitelist.sol";
import {BDVFacet} from "contracts/beanstalk/facets/silo/BDVFacet.sol";

/**
 * @title MockInitDiamond
 * @notice MockInitDiamond initializes the Beanstalk Diamond.
 * @dev MockInitDiamond additionally:
 * - Whitelists the bean:wsteth well.
 **/
contract MockInitDiamond is InitializeDiamond {
    // min 1micro stalk earned per season due to germination.
    uint32 internal constant INIT_BEAN_WSTETH_WELL_STALK_EARNED_PER_SEASON = 4e6;
    uint128 internal constant INIT_TOKEN_POINTS = 100e18;
    uint32 internal constant INIT_BEAN_PERCENT_TARGET = 50e6;

    // Tokens
    address internal constant BEAN = address(0xBEA0000029AD1c77D3d5D23Ba2D8893dB9d1Efab);
    address internal constant BEAN_ETH_WELL = address(0xBEA0e11282e2bB5893bEcE110cF199501e872bAd);
    address internal constant BEAN_WSTETH_WELL =
        address(0xBeA0000113B0d182f4064C86B71c315389E4715D);

    function init() external {
        // initalize the default state of the diamond.
        // {see. InitializeDiamond.initializeDiamond()}
        initializeDiamond(BEAN, BEAN_ETH_WELL);

        // Whitelist the LP well.
        whitelistLPWell(BEAN_WSTETH_WELL);
    }

    /**
     * @notice Whitelist a well LP token.
     */
    function whitelistLPWell(address well) internal {
        // note: no error checking:
        s.sys.silo.assetSettings[well] = AssetSettings({
            selector: BDVFacet.wellBdv.selector,
            stalkEarnedPerSeason: INIT_BEAN_WSTETH_WELL_STALK_EARNED_PER_SEASON,
            stalkIssuedPerBdv: INIT_STALK_ISSUED_PER_BDV,
            milestoneSeason: s.sys.season.current,
            milestoneStem: 0,
            encodeType: 0x01,
            deltaStalkEarnedPerSeason: 0,
            gaugePoints: INIT_TOKEN_POINTS,
            optimalPercentDepositedBdv: INIT_BEAN_PERCENT_TARGET,
            gaugePointImplementation: Implementation(
                address(0),
                IGaugeFacet.defaultGaugePoints.selector,
                bytes1(0),
                new bytes(0)
            ),
            liquidityWeightImplementation: Implementation(
                address(0),
                ILiquidityWeightFacet.maxWeight.selector,
                bytes1(0),
                new bytes(0)
            )
        });

        // updates the optimal percent deposited for bean:eth.
        LibWhitelist.updateOptimalPercentDepositedBdvForToken(
            BEAN_ETH_WELL,
            INIT_BEAN_TOKEN_WELL_PERCENT_TARGET - INIT_BEAN_PERCENT_TARGET
        );

        // update whitelist status.
        LibWhitelistedTokens.addWhitelistStatus(
            well,
            true, // is whitelisted,
            true, // is LP
            true, // is well
            true // is soppable
        );

        s.sys.usdTokenPrice[well] = 1;
        s.sys.twaReserves[well].reserve0 = 1;
        s.sys.twaReserves[well].reserve1 = 1;
    }
}

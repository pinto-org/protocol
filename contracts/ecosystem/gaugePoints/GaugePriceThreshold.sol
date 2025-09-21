/*
 * SPDX-License-Identifier: MIT
 */

pragma solidity ^0.8.20;

import {GaugeDefault} from "contracts/beanstalk/facets/sun/abstract/GaugeDefault.sol";

/**
 * @title GaugePriceThreshold
 * @notice GaugePriceThreshold implements priceThresholdGaugePoints.
 * Falls back to GaugeDefault.defaultGaugePoints.
 * @dev Intended to be deployed externally with one contract per token.
 */
interface IBeanstalk {
    function getTokenUsdPrice(address) external view returns (uint256);
}

/**
 * @notice GaugePriceThreshold is an external contract for use with high risk assets.
 * @dev When the price of the asset is below a certain threshold, the gauge points
 * are set to a specified value. Can be used to set gauge points to 0 automatically
 * if price goes trends to 0, which prevents extreme point accumulation by users.
 */
contract GaugePriceThreshold is GaugeDefault {
    address immutable beanstalk;
    address immutable token;
    uint256 immutable priceThreshold;
    uint256 immutable gaugePointsPrice;

    /**
     * @param _beanstalk The address of the Beanstalk contract.
     * @param _token The address of the token to check the price of.
     * @param _priceThreshold The price threshold to check against.
     * @param _gaugePointsPrice The gauge points price to return when the price is below the threshold.
     * @dev `priceThreshold` should have 6 decimal precision, regardless of token decimals.
     */
    constructor(
        address _beanstalk,
        address _token,
        uint256 _priceThreshold,
        uint256 _gaugePointsPrice
    ) {
        beanstalk = _beanstalk;
        token = _token;
        priceThreshold = _priceThreshold;
        gaugePointsPrice = _gaugePointsPrice;
    }

    /**
     * @notice priceThresholdGaugePoints
     * checks that the price of `token` is above `priceThreshold`.
     * When below the priceThreshold, the function returns the minimum of
     * `currentGaugepoints` and `gaugePointsPrice`.
     * Else, use the defaultGaugePoints implmentation defined in `GaugeDefault`.
     *
     * @dev `Price` is fetched from Beanstalk via {OracleFacet.getUsdPrice}. An instanteous Lookback
     * is used to get the most recent price from the Oracle.
     */
    function priceThresholdGaugePoints(
        uint256 currentGaugePoints,
        uint256 optimalPercentDepositedBdv,
        uint256 percentOfDepositedBdv,
        bytes memory data
    ) public view returns (uint256 newGaugePoints) {
        try IBeanstalk(beanstalk).getTokenUsdPrice(token) returns (uint256 price) {
            if (priceThreshold >= price) {
                return
                    currentGaugePoints > gaugePointsPrice ? gaugePointsPrice : currentGaugePoints;
            } else {
                return
                    defaultGaugePoints(
                        currentGaugePoints,
                        optimalPercentDepositedBdv,
                        percentOfDepositedBdv,
                        data
                    );
            }
        } catch {
            // If the price cannot be fetched, assume price manipulation.
            return currentGaugePoints > gaugePointsPrice ? gaugePointsPrice : currentGaugePoints;
        }
    }

    function getBeanstalk() external view returns (address) {
        return beanstalk;
    }

    function getToken() external view returns (address) {
        return token;
    }

    function getPriceThreshold() external view returns (uint256) {
        return priceThreshold;
    }

    function getGaugePointsPrice() external view returns (uint256) {
        return gaugePointsPrice;
    }
}

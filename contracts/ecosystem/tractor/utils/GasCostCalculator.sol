// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LibChainlinkOracle} from "contracts/libraries/Oracle/LibChainlinkOracle.sol";
import {LibUsdOracle} from "contracts/libraries/Oracle/LibUsdOracle.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";

/**
 * @title GasCostCalculator
 * @author pocikerim
 * @notice Calculates gas-based fees in Pinto tokens for blueprint executions.
 * @dev Uses ETH/USD Chainlink oracle and LibUsdOracle for Pinto price to convert gas cost to Pinto fee.
 *      Reverts on oracle failure (assumes manipulation if oracle fails).
 */
contract GasCostCalculator is Ownable {
    /// @notice ETH/USD Chainlink oracle on Base.
    address public constant ETH_USD_ORACLE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    /// @notice Chainlink timeout (4 hours).
    uint256 public constant ORACLE_TIMEOUT = 14400;

    /// @notice Precision for internal calculations (1e18).
    uint256 private constant PRECISION = 1e18;

    /// @notice Pinto token decimals.
    uint256 private constant PINTO_DECIMALS = 1e6;

    /// @notice Beanstalk contract for getting Pinto token address.
    IBeanstalk public immutable beanstalk;

    /// @notice Base gas overhead for Tractor infrastructure (signature verification, etc.).
    uint256 public baseGasOverhead;

    /// @notice Emitted when base gas overhead is updated
    event BaseGasOverheadUpdated(uint256 oldOverhead, uint256 newOverhead);

    /**
     * @notice Creates a new GasCostCalculator.
     * @param _beanstalk Address of the Beanstalk diamond
     * @param _owner Address of the contract owner
     * @param _baseGasOverhead Initial base gas overhead (default: 50000)
     */
    constructor(
        address _beanstalk,
        address _owner,
        uint256 _baseGasOverhead
    ) Ownable(_owner) {
        require(_beanstalk != address(0), "GasCostCalculator: zero beanstalk");

        beanstalk = IBeanstalk(_beanstalk);
        baseGasOverhead = _baseGasOverhead;
    }

    /**
     * @notice Calculate fee in Pinto tokens for gas consumed using current tx.gasprice.
     * @param gasUsed Gas consumed by the operation (excluding overhead)
     * @param marginBps Additional margin in basis points (100 = 1%, 1000 = 10%)
     * @return fee Fee amount in Pinto tokens (6 decimals)
     */
    function calculateFeeInPinto(
        uint256 gasUsed,
        uint256 marginBps
    ) external view returns (uint256 fee) {
        return calculateFeeInPintoWithGasPrice(gasUsed, tx.gasprice, marginBps);
    }

    /**
     * @notice Calculate fee in Pinto tokens for gas consumed using custom gas price.
     * @param gasUsed Gas consumed by the operation (excluding overhead)
     * @param gasPriceWei Gas price in wei
     * @param marginBps Additional margin in basis points (100 = 1%, 1000 = 10%)
     * @return fee Fee amount in Pinto tokens (6 decimals)
     */
    function calculateFeeInPintoWithGasPrice(
        uint256 gasUsed,
        uint256 gasPriceWei,
        uint256 marginBps
    ) public view returns (uint256 fee) {
        // Add base overhead to gas used
        uint256 totalGas = gasUsed + baseGasOverhead;

        // Calculate ETH cost in wei
        uint256 ethCostWei = totalGas * gasPriceWei;

        // Get ETH/Pinto rate (Pinto per ETH, 6 decimals) - reverts on oracle failure
        uint256 ethPintoRate = _getEthPintoRate();

        // Convert ETH cost to Pinto
        // ethCostWei is in wei (1e18 = 1 ETH)
        // ethPintoRate is Pinto per 1 ETH (6 decimals)
        // fee = ethCostWei * ethPintoRate / 1e18
        fee = (ethCostWei * ethPintoRate) / PRECISION;

        // Apply margin: fee * (10000 + marginBps) / 10000
        if (marginBps > 0) {
            fee = (fee * (10000 + marginBps)) / 10000;
        }
    }

    /**
     * @notice Get estimated fee for a given gas amount (convenience function).
     * @param gasUsed Estimated gas usage
     * @param marginBps Margin in basis points
     * @return fee Estimated fee in Pinto (6 decimals)
     * @return ethPintoRate Current ETH/Pinto rate used
     */
    function estimateFee(
        uint256 gasUsed,
        uint256 marginBps
    ) external view returns (uint256 fee, uint256 ethPintoRate) {
        ethPintoRate = _getEthPintoRate();
        fee = this.calculateFeeInPinto(gasUsed, marginBps);
    }

    /**
     * @notice Get current ETH/Pinto rate.
     * @return rate Pinto per 1 ETH (6 decimals)
     */
    function getEthPintoRate() external view returns (uint256) {
        return _getEthPintoRate();
    }

    // ==================== Admin Functions ====================

    /**
     * @notice Update base gas overhead.
     * @param _baseGasOverhead New overhead value
     */
    function setBaseGasOverhead(uint256 _baseGasOverhead) external onlyOwner {
        uint256 oldOverhead = baseGasOverhead;
        baseGasOverhead = _baseGasOverhead;
        emit BaseGasOverheadUpdated(oldOverhead, _baseGasOverhead);
    }

    // ==================== Internal Functions ====================

    /**
     * @dev Get ETH/Pinto rate from oracles. Reverts on oracle failure.
     * @return rate Pinto per 1 ETH (6 decimals)
     */
    function _getEthPintoRate() internal view returns (uint256 rate) {
        // Get ETH/USD price - reverts if oracle fails
        uint256 ethUsd = _safeGetEthUsdPrice();
        require(ethUsd > 0, "GasCostCalculator: ETH/USD oracle failed");

        // Get Pinto/USD price - reverts if oracle fails
        uint256 pintoUsd = _safeGetPintoUsdPrice();
        require(pintoUsd > 0, "GasCostCalculator: Pinto/USD oracle failed");

        // Calculate ETH/Pinto = (ETH/USD) / (Pinto/USD)
        // Both have 6 decimal precision
        // Result: Pinto per 1 ETH with 6 decimals
        rate = (ethUsd * PINTO_DECIMALS) / pintoUsd;
    }

    /**
     * @dev Safely get ETH/USD price
     * @return 0 if oracle has no code or returns invalid data
     */
    function _safeGetEthUsdPrice() internal view returns (uint256) {
        // Check if oracle has code
        if (ETH_USD_ORACLE.code.length == 0) {
            return 0;
        }

        // LibChainlinkOracle.getPrice uses try-catch internally and returns 0 on failure
        return LibChainlinkOracle.getPrice(
            ETH_USD_ORACLE,
            ORACLE_TIMEOUT,
            0, // tokenDecimals = 0 for TOKEN1/TOKEN2 price
            false // not million
        );
    }

    /**
     * @dev Safely get Pinto/USD price
     * @return 0 if oracle returns invalid data
     */
    function _safeGetPintoUsdPrice() internal view returns (uint256) {
        address pintoToken = beanstalk.getBeanToken();

        // LibUsdOracle.getTokenPrice handles failures internally and returns 0
        return LibUsdOracle.getTokenPrice(pintoToken, 0);
    }
}

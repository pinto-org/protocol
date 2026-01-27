// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LibChainlinkOracle} from "contracts/libraries/Oracle/LibChainlinkOracle.sol";
import {BeanstalkPrice, ReservesType} from "contracts/ecosystem/price/BeanstalkPrice.sol";

/**
 * @title GasCostCalculator
 * @author exTypen
 * @notice Calculates gas-based fees in Bean tokens for blueprint executions.
 * @dev Uses ETH/USD Chainlink oracle and BeanstalkPrice to convert gas cost to Bean fee.
 *      Reverts on oracle failure.
 */
contract GasCostCalculator is Ownable {
    /// @notice ETH/USD Chainlink oracle on Base.
    address public constant ETH_USD_ORACLE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    /// @notice Chainlink timeout (1 hour, consistent with ETH/USD oracle heartbeat).
    uint256 public constant ORACLE_TIMEOUT = 3600;

    /// @notice Precision for internal calculations (1e18).
    uint256 private constant PRECISION = 1e18;

    /// @notice Bean token decimals.
    uint256 private constant BEAN_DECIMALS = 1e6;

    /// @notice Maximum margin in basis points (100% = 10000 bps).
    uint256 public constant MAX_MARGIN_BPS = 10000;

    /// @notice BeanstalkPrice contract for getting manipulation-resistant Bean price.
    BeanstalkPrice public immutable beanstalkPrice;

    /// @notice Base gas overhead for Tractor infrastructure (signature verification, etc.).
    uint256 public baseGasOverhead;

    /// @notice Emitted when base gas overhead is updated
    event BaseGasOverheadUpdated(uint256 oldOverhead, uint256 newOverhead);

    /**
     * @notice Creates a new GasCostCalculator.
     * @param _beanstalkPrice Address of the BeanstalkPrice contract
     * @param _owner Address of the contract owner
     * @param _baseGasOverhead Initial base gas overhead (default: 50000)
     */
    constructor(address _beanstalkPrice, address _owner, uint256 _baseGasOverhead) Ownable(_owner) {
        require(_beanstalkPrice != address(0), "GasCostCalculator: zero beanstalkPrice");

        beanstalkPrice = BeanstalkPrice(_beanstalkPrice);
        baseGasOverhead = _baseGasOverhead;
    }

    /**
     * @notice Calculate fee in Bean tokens for gas consumed using current tx.gasprice.
     * @param gasUsed Gas consumed by the operation (excluding overhead)
     * @param marginBps Additional margin in basis points (100 = 1%, 1000 = 10%)
     * @return fee Fee amount in Bean tokens (6 decimals)
     */
    function calculateFeeInBean(
        uint256 gasUsed,
        uint256 marginBps
    ) external view returns (uint256 fee) {
        return calculateFeeInBeanWithGasPrice(gasUsed, tx.gasprice, marginBps);
    }

    /**
     * @notice Calculate fee in Bean tokens for gas consumed using custom gas price.
     * @param gasUsed Gas consumed by the operation (excluding overhead)
     * @param gasPriceWei Gas price in wei
     * @param marginBps Additional margin in basis points (100 = 1%, 1000 = 10%, max 10000 = 100%)
     * @return fee Fee amount in Bean tokens (6 decimals)
     */
    function calculateFeeInBeanWithGasPrice(
        uint256 gasUsed,
        uint256 gasPriceWei,
        uint256 marginBps
    ) public view returns (uint256 fee) {
        require(marginBps <= MAX_MARGIN_BPS, "GasCostCalculator: margin exceeds max");

        // Add base overhead to gas used
        uint256 totalGas = gasUsed + baseGasOverhead;

        // Calculate ETH cost in wei
        uint256 ethCostWei = totalGas * gasPriceWei;

        // Get ETH/Bean rate (Bean per ETH, 6 decimals) - reverts on oracle failure
        uint256 ethBeanRate = _getEthBeanRate();

        // Convert ETH cost to Bean
        // ethCostWei is in wei (1e18 = 1 ETH)
        // ethBeanRate is Bean per 1 ETH (6 decimals)
        // fee = ethCostWei * ethBeanRate / 1e18
        fee = (ethCostWei * ethBeanRate) / PRECISION;

        // Apply margin: fee * (10000 + marginBps) / 10000
        if (marginBps > 0) {
            fee = (fee * (10000 + marginBps)) / 10000;
        }
    }

    /**
     * @notice Get estimated fee for a given gas amount (convenience function).
     * @param gasUsed Estimated gas usage
     * @param marginBps Margin in basis points
     * @return fee Estimated fee in Bean (6 decimals)
     * @return ethBeanRate Current ETH/Bean rate used
     */
    function estimateFee(
        uint256 gasUsed,
        uint256 marginBps
    ) external view returns (uint256 fee, uint256 ethBeanRate) {
        ethBeanRate = _getEthBeanRate();
        fee = this.calculateFeeInBean(gasUsed, marginBps);
    }

    /**
     * @notice Get current ETH/Bean rate.
     * @return rate Bean per 1 ETH (6 decimals)
     */
    function getEthBeanRate() external view returns (uint256) {
        return _getEthBeanRate();
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
     * @dev Get ETH/Bean rate from oracles. Reverts on oracle failure.
     * @return rate Bean per 1 ETH (6 decimals)
     */
    function _getEthBeanRate() internal view virtual returns (uint256 rate) {
        // Get ETH/USD price - reverts if oracle fails
        uint256 ethUsd = _safeGetEthUsdPrice();
        require(ethUsd > 0, "GasCostCalculator: ETH/USD oracle failed");

        // Get Bean/USD price - reverts if oracle fails
        uint256 beanUsd = _safeGetBeanUsdPrice();
        require(beanUsd > 0, "GasCostCalculator: Bean/USD oracle failed");

        // Calculate ETH/Bean = (ETH/USD) / (Bean/USD)
        // Both have 6 decimal precision
        // Result: Bean per 1 ETH with 6 decimals
        rate = (ethUsd * BEAN_DECIMALS) / beanUsd;
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
        return
            LibChainlinkOracle.getPrice(
                ETH_USD_ORACLE,
                ORACLE_TIMEOUT,
                0, // tokenDecimals = 0 for TOKEN1/TOKEN2 price
                false // not million
            );
    }

    /**
     * @dev Get Bean/USD price using BeanstalkPrice with INSTANTANEOUS_RESERVES.
     * @return Bean price in USD (6 decimals)
     */
    function _safeGetBeanUsdPrice() internal view returns (uint256) {
        return beanstalkPrice.price(ReservesType.INSTANTANEOUS_RESERVES).price;
    }
}

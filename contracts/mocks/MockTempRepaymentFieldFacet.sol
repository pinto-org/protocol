// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockTempRepaymentFieldFacet
 * @notice Mirrors TempRepaymentFieldFacet for gas estimation in batch simulations
 * @dev Includes ReentrancyGuard and require check to match real contract gas usage
 */
contract MockTempRepaymentFieldFacet {
    // ReentrancyGuard state (mirrors Beanstalk ReentrancyGuard)
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrantStatus = _NOT_ENTERED;

    // Mirror of Account.sol Field struct
    struct Field {
        mapping(uint256 => uint256) plots;
        mapping(address => uint256) podAllowances;
        uint256[] plotIndexes;
        mapping(uint256 => uint256) piIndex;
    }

    struct Plot {
        uint256 podIndex;
        uint256 podAmounts;
    }

    struct RepaymentPlotData {
        address account;
        Plot[] plots;
    }

    // Storage - mirrors s.accts[account].fields[fieldId]
    mapping(address => Field) internal accountFields;

    // Authorized populator (matches real contract)
    address public populator;

    event RepaymentPlotAdded(address indexed account, uint256 indexed plotIndex, uint256 pods);

    constructor() {
        populator = msg.sender;
    }

    modifier nonReentrant() {
        require(_reentrantStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        _reentrantStatus = _ENTERED;
        _;
        _reentrantStatus = _NOT_ENTERED;
    }

    /**
     * @notice Mirrors TempRepaymentFieldFacet.initializeRepaymentPlots exactly
     * @dev Includes ReentrancyGuard + require check for accurate gas measurement
     */
    function initializeRepaymentPlots(RepaymentPlotData[] calldata accountPlots) external nonReentrant {
        require(msg.sender == populator, "Only the repayment field populator can call this function");

        for (uint256 i; i < accountPlots.length; i++) {
            address account = accountPlots[i].account;
            for (uint256 j; j < accountPlots[i].plots.length; j++) {
                uint256 podIndex = accountPlots[i].plots[j].podIndex;
                uint256 podAmount = accountPlots[i].plots[j].podAmounts;

                accountFields[account].plots[podIndex] = podAmount;
                accountFields[account].plotIndexes.push(podIndex);
                accountFields[account].piIndex[podIndex] = accountFields[account].plotIndexes.length - 1;

                emit RepaymentPlotAdded(account, podIndex, podAmount);
            }
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface IMultiFlowPump {
    /**
     * @dev Reads the capped reserves from the Pump updated to the current block using the current reserves of `well`.
     */
    function readCappedReserves(
        address well,
        bytes memory data
    ) external view returns (uint256[] memory cappedReserves);

    /**
     * @notice Reads instantaneous reserves from the Pump
     * @param well The address of the Well
     * @return reserves The instantaneous balanecs tracked by the Pump
     */
    function readInstantaneousReserves(
        address well,
        bytes memory data
    ) external view returns (uint256[] memory reserves);
}

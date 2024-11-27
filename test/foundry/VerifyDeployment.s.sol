// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
contract TraceTransaction is Script {
    function run() external {
        // Prepare the transaction data
        address sender = 0x0000000000000000000000000000000000000000;
        address receiver = 0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f;
        // note if you get "Expected even number of hex-nibbles." then you need to remove the 0x at the front of the hex string
        bytes memory rawInput = hex"fc06d2a6";

        // Trace the transaction
        vm.prank(sender);
        (bool success, ) = receiver.call(rawInput);
    }
}

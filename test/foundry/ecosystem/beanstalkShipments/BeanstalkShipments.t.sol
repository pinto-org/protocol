// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {OperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console} from "forge-std/console.sol";
import {IBarnPayback} from "contracts/interfaces/IBarnPayback.sol";
import {ISiloPayback} from "contracts/interfaces/ISiloPayback.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";

/**
 * @notice Tests that the whole shipments initialization and logic works correctly.
 * This tests should be ran against a local node after the deployment and initialization task is complete.
 * 1. Create a local anvil node
 * 2. Run the hardhat task: `npx hardhat compile && npx hardhat beanstalkShipments --network localhost`
 * 3. Run the test: `forge test --match-test test_shipments --fork-url http://localhost:8545`
 */
contract BeanstalkShipmentsTest is TestHelper {

    // Contracts
    address constant SHIPMENT_PLANNER = address(0x1152691C30aAd82eB9baE7e32d662B19391e34Db);
    address constant SILO_PAYBACK = address(0x9E449a18155D4B03C2E08A4E28b2BcAE580efC4E);
    address constant BARN_PAYBACK = address(0x71ad4dCd54B1ee0FA450D7F389bEaFF1C8602f9b);

    // Owners
    address constant PCM = address(0x2cf82605402912C6a79078a9BBfcCf061CbfD507);

    // Users
    address farmer1 = makeAddr("farmer1");
    address farmer2 = makeAddr("farmer2");
    address farmer3 = makeAddr("farmer3");

    // Contracts
    ISiloPayback siloPayback = ISiloPayback(SILO_PAYBACK);
    IBarnPayback barnPayback = IBarnPayback(BARN_PAYBACK);
    IMockFBeanstalk pinto = IMockFBeanstalk(L2_PINTO);

    // we need to:
    // - Verify that all state matches the one in the json files for shipments, silo and barn payback
    // - get to a supply where the beanstalk shipments kick in
    // - make the system print, check distribution in each contract
    // - for each component, make sure everything is distributed correctly
    // - make sure that at any point all users can claim their rewards pro rata
    function setUp() public {
        // mint 1bil pinto
        // deal(PINTO, farmer1, 1_000_000_000e6);
    }

    //////////////////////// STATE VERIFICATION ////////////////////////
    // note: get properties from json, see l2migration 

    function test_shipment_state() public {
        console.log("Bs Field data:");
        console.logBytes(abi.encode(1));

        console.log("Silo payback:");
        console.logBytes(abi.encode(SILO_PAYBACK));
        console.log("Barn payback:");
        console.logBytes(abi.encode(BARN_PAYBACK));
    }

    function test_repayment_field_state() public {}

    function test_silo_payback_state() public {}

    function test_barn_payback_state() public {}
    

    //////////////////////// SHIPMENT DISTRIBUTION ////////////////////////
    // note: test distribution at the edge, 
    // note: test when a payback is done
    // note: test that all users can claim their rewards at any point
}

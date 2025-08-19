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
import {ShipmentPlanner} from "contracts/ecosystem/ShipmentPlanner.sol";

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
    address constant DEV_BUDGET = address(0xb0cdb715D8122bd976a30996866Ebe5e51bb18b0);

    // Owners
    address constant PCM = address(0x2cf82605402912C6a79078a9BBfcCf061CbfD507);

    // Shipment Recipient enum
    enum ShipmentRecipient {
        NULL,
        SILO,
        FIELD,
        INTERNAL_BALANCE,
        EXTERNAL_BALANCE,
        SILO_PAYBACK,
        BARN_PAYBACK
    }

    struct ShipmentRoute {
        address planContract;
        bytes4 planSelector;
        ShipmentRecipient recipient;
        bytes data;
    }

    // Constants
    uint256 constant PAYBACK_FIELD_ID = 1;

    // Users
    address farmer1 = makeAddr("farmer1");
    address farmer2 = makeAddr("farmer2");
    address farmer3 = makeAddr("farmer3");

    // Contracts
    ISiloPayback siloPayback = ISiloPayback(SILO_PAYBACK);
    IBarnPayback barnPayback = IBarnPayback(BARN_PAYBACK);
    IMockFBeanstalk pinto = IMockFBeanstalk(PINTO);

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

    function test_shipment_routes() public {
        // get shipment routes
        IMockFBeanstalk.ShipmentRoute[] memory routes = pinto.getShipmentRoutes();
        // silo (0x01)
        assertEq(routes[0].planSelector, ShipmentPlanner.getSiloPlan.selector);
        assertEq(uint8(routes[0].recipient), uint8(IShipmentRecipient.SILO));
        assertEq(routes[0].data, new bytes(32));
        // field (0x02)
        assertEq(routes[1].planSelector, ShipmentPlanner.getFieldPlan.selector);
        assertEq(uint8(routes[1].recipient), uint8(ShipmentRecipient.FIELD));
        assertEq(routes[1].data, abi.encodePacked(uint256(0)));
        // budget (0x03)
        assertEq(routes[2].planSelector, ShipmentPlanner.getBudgetPlan.selector);
        assertEq(uint8(routes[2].recipient), uint8(ShipmentRecipient.INTERNAL_BALANCE));
        assertEq(routes[2].data, abi.encode(DEV_BUDGET));
        // payback field (0x02)
        assertEq(routes[3].planSelector, ShipmentPlanner.getPaybackFieldPlan.selector);
        assertEq(uint8(routes[3].recipient), uint8(ShipmentRecipient.FIELD));
        assertEq(routes[3].data, abi.encode(PAYBACK_FIELD_ID, PCM));
        // payback silo (0x05)
        assertEq(routes[4].planSelector, ShipmentPlanner.getPaybackSiloPlan.selector);
        assertEq(uint8(routes[4].recipient), uint8(ShipmentRecipient.SILO_PAYBACK));
        assertEq(routes[4].data, abi.encode(SILO_PAYBACK));
        // payback barn (0x06)
        assertEq(routes[5].planSelector, ShipmentPlanner.getPaybackBarnPlan.selector);
        assertEq(uint8(routes[5].recipient), uint8(ShipmentRecipient.BARN_PAYBACK));
        assertEq(routes[5].data, abi.encode(BARN_PAYBACK));
    }

    function test_repayment_field_state() public {}

    function test_silo_payback_state() public {}

    function test_barn_payback_state() public {}

    //////////////////////// SHIPMENT DISTRIBUTION ////////////////////////
    // note: test distribution at the edge,
    // note: test when a payback is done
    // note: test that all users can claim their rewards at any point
}

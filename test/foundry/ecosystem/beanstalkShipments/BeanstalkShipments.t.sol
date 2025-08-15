// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {OperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice Tests that the whole shipments initialization and logic works correctly.
 * This tests should be ran against a local node after the deployment and initialization task is complete.
 * 1. Create a local anvil node
 * 2. Run the hardhat task: `npx hardhat compile && npx hardhat beanstalkShipments --network localhost`
 * 3. Run the test: `forge test --match-test test_shipments --fork-url http://localhost:8545`
 */
contract BeanstalkShipmentsTest is TestHelper {

    // we need to:
    // - 1. recreate a mock beanstalk repayment field with a mock podline
    // - 2. deploy the silo payback proxy
    // - 3. deploy the barn payback proxy
    // - 4. create a function and make sure shipments are set correctly in the initialization in ShipmentDeployer.sol
    // - 5. get to a supply where the beanstalk shipments kick in
    // - 6. make the system print, check distribution in each contract
    // - 6. for each component, make sure everything is set correctly, 
    // all tokens are distributed correctly and users can claim their rewards
    function setUp() public {
        
    }
}

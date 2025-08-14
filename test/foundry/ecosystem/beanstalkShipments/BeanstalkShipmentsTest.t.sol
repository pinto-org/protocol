// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {OperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract BeanstalkShipmentsTest is TestHelper {

    // we need to:
    // - 1. recreate a mock beanstalk repayment field with a mock podline
    // - 2. deploy the unripe distributor (make a mock that is non upgradable for ease of testing)
    // - 3. make sure shipments are set correctly in the initialization in ShipmentDeployer.sol
    // - 4. get to a supply where the beanstalk shipments kick in
    // - 5. make the system print, check distribution in each contract
    // - 6. for each component, make sure everything is set correctly
    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // add new field, init some plots (see sun.t.sol)

        // deploy unripe distributor
        // siloPayback = new SiloPayback(PINTO, BEANSTALK);

        // upddate routes here
        setRoutes_all();
    }
}

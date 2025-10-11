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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShipmentRecipient, ShipmentRoute} from "contracts/beanstalk/storage/System.sol";

/**
 * @notice Tests state verification for the beanstalk shipments system.
 * This tests should be ran against a local node after the deployment and initialization task is complete.
 * 1. Create a local anvil node at block 33349326, right before Season 5952 where the deltab was +19,281 TWAΔP
 * 2. Run the hardhat tasks to initialize the shipments.`
 * 3. Run the test: `forge test --match-contract BeanstalkShipmentsStateTest --fork-url http://localhost:8545`
 * Alternatively, the tests need to be ran using a fork after the deployment is done.
 */
contract Skip_BeanstalkShipmentsStateTest is TestHelper {
    // Contracts
    address constant SHIPMENT_PLANNER = address(0x1152691C30aAd82eB9baE7e32d662B19391e34Db);
    address constant SILO_PAYBACK = address(0x9E449a18155D4B03C2E08A4E28b2BcAE580efC4E);
    address constant BARN_PAYBACK = address(0x71ad4dCd54B1ee0FA450D7F389bEaFF1C8602f9b);
    address constant DEV_BUDGET = address(0xb0cdb715D8122bd976a30996866Ebe5e51bb18b0);

    uint256 constant REPAYMENT_FIELD_PODS = 919768387056514;

    // Paths
    // Field
    string constant FIELD_ADDRESSES_PATH =
        "./scripts/beanstalkShipments/data/exports/accounts/field_addresses.txt";
    string constant FIELD_JSON_PATH =
        "./scripts/beanstalkShipments/data/exports/beanstalk_field.json";
    // Silo
    string constant SILO_ADDRESSES_PATH =
        "./scripts/beanstalkShipments/data/exports/accounts/silo_addresses.txt";
    string constant SILO_JSON_PATH =
        "./scripts/beanstalkShipments/data/exports/beanstalk_silo.json";
    // Barn
    string constant BARN_ADDRESSES_PATH =
        "./scripts/beanstalkShipments/data/exports/accounts/barn_addresses.txt";
    string constant BARN_JSON_PATH =
        "./scripts/beanstalkShipments/data/exports/beanstalk_barn.json";

    // Owners
    address constant PCM = address(0x2cf82605402912C6a79078a9BBfcCf061CbfD507);

    address[] public fertilizedContractAccounts;

    ////////// State Structs //////////

    struct SystemFertilizerStruct {
        uint256 activeFertilizer;
        uint256 fertilizedIndex;
        uint256 unfertilizedIndex;
        uint256 fertilizedPaidIndex;
        uint128 fertFirst;
        uint128 fertLast;
        uint128 bpf;
        uint256 leftoverBeans;
    }

    struct FertDepositData {
        uint256 fertId;
        uint256 amount;
        uint256 lastBpf;
    }

    // Constants
    uint256 constant ACTIVE_FIELD_ID = 0;
    uint256 constant PAYBACK_FIELD_ID = 1;
    uint256 constant SUPPLY_THRESHOLD = 1_000_000_000e6;

    // Contracts
    ISiloPayback siloPayback = ISiloPayback(SILO_PAYBACK);
    IBarnPayback barnPayback = IBarnPayback(BARN_PAYBACK);
    IMockFBeanstalk pinto = IMockFBeanstalk(PINTO);

    function setUp() public {
        // after deployment, uncomment this, set forkBlock at a later block
        // uint256 forkBlock = 33349326;
        // vm.createSelectFork("base", forkBlock);
    }

    //////////////////////// STATE VERIFICATION ////////////////////////

    function test_beanstalkShipmentRoutes() public {
        // get shipment routes
        IMockFBeanstalk.ShipmentRoute[] memory routes = pinto.getShipmentRoutes();

        // assert length is 6
        assertEq(routes.length, 6, "Shipment routes length mismatch");

        // silo (0x01)
        assertEq(
            routes[0].planSelector,
            IMockFBeanstalk.getSiloPlan.selector,
            "Silo plan selector mismatch"
        );
        assertEq(
            uint8(routes[0].recipient),
            uint8(ShipmentRecipient.SILO),
            "Silo recipient mismatch"
        );
        assertEq(routes[0].data, new bytes(32), "Silo data mismatch");
        // field (0x02)
        assertEq(
            routes[1].planSelector,
            IMockFBeanstalk.getFieldPlan.selector,
            "Field plan selector mismatch"
        );
        assertEq(
            uint8(routes[1].recipient),
            uint8(ShipmentRecipient.FIELD),
            "Field recipient mismatch"
        );
        assertEq(routes[1].data, abi.encodePacked(uint256(0)), "Field data mismatch");
        // budget (0x03)
        assertEq(
            routes[2].planSelector,
            IMockFBeanstalk.getBudgetPlan.selector,
            "Budget plan selector mismatch"
        );
        assertEq(
            uint8(routes[2].recipient),
            uint8(ShipmentRecipient.INTERNAL_BALANCE),
            "Budget recipient mismatch"
        );
        assertEq(routes[2].data, abi.encode(DEV_BUDGET), "Budget data mismatch");
        // payback field (0x02)
        assertEq(
            routes[3].planSelector,
            IMockFBeanstalk.getPaybackFieldPlan.selector,
            "Payback field plan selector mismatch"
        );
        assertEq(
            uint8(routes[3].recipient),
            uint8(ShipmentRecipient.FIELD),
            "Payback field recipient mismatch"
        );
        assertEq(
            routes[3].data,
            abi.encode(SILO_PAYBACK, BARN_PAYBACK, PAYBACK_FIELD_ID),
            "Payback field data mismatch"
        );
        // payback silo (0x05)
        assertEq(
            routes[4].planSelector,
            IMockFBeanstalk.getPaybackSiloPlan.selector,
            "Payback silo plan selector mismatch"
        );
        assertEq(
            uint8(routes[4].recipient),
            uint8(ShipmentRecipient.SILO_PAYBACK),
            "Payback silo recipient mismatch"
        );
        assertEq(
            routes[4].data,
            abi.encode(SILO_PAYBACK, BARN_PAYBACK),
            "Payback silo data mismatch"
        );
        // payback barn (0x06)
        assertEq(
            routes[5].planSelector,
            IMockFBeanstalk.getPaybackBarnPlan.selector,
            "Payback barn plan selector mismatch"
        );
        assertEq(
            uint8(routes[5].recipient),
            uint8(ShipmentRecipient.BARN_PAYBACK),
            "Payback barn recipient mismatch"
        );
        assertEq(
            routes[5].data,
            abi.encode(BARN_PAYBACK, SILO_PAYBACK),
            "Payback barn data mismatch"
        );
    }

    //////////////////// Field State Verification ////////////////////

    function test_beanstalkRepaymentFieldState() public {
        uint256 accountNumber = getAccountNumber(FIELD_ADDRESSES_PATH);
        console.log("Testing repayment field state for", accountNumber, "accounts");

        // get active field, assert its the same
        uint256 activeField = pinto.activeField();
        assertEq(activeField, 0);

        // get the field count, assert a new field has been added
        uint256 fieldCount = pinto.fieldCount();
        assertEq(fieldCount, 2);

        // get the total pods in the field
        uint256 totalPods = pinto.totalPods(PAYBACK_FIELD_ID);
        assertEq(totalPods, REPAYMENT_FIELD_PODS);

        // get the harvestable index, assert it is 0
        uint256 harvestableIndex = pinto.harvestableIndex(PAYBACK_FIELD_ID);
        assertEq(harvestableIndex, 0, "Harvestable index mismatch");

        string memory account;
        // For every account
        for (uint256 i = 0; i < accountNumber; i++) {
            account = vm.readLine(FIELD_ADDRESSES_PATH);
            // get the plots in storage
            IMockFBeanstalk.Plot[] memory plots = pinto.getPlotsFromAccount(
                vm.parseAddress(account),
                PAYBACK_FIELD_ID
            );
            // compare against the plots in the json
            for (uint256 j = 0; j < plots.length; j++) {
                // Get the expected pod amount for this plot index from JSON
                string memory plotIndexKey = vm.toString(plots[j].index);
                // arbEOAs.account.plotIndex
                string memory plotAmountPath = string.concat(
                    "arbEOAs.",
                    account,
                    ".",
                    plotIndexKey
                );

                bytes memory plotAmountJson = searchPropertyData(plotAmountPath, FIELD_JSON_PATH);
                // Decode the plot amount from JSON
                uint256 expectedPodAmount = vm.parseUint(vm.toString(plotAmountJson));
                // Compare the plot amount and index
                assertEq(expectedPodAmount, plots[j].pods, "Invalid pod amount for account");
            }
        }
    }

    //////////////////// Silo State Verification ////////////////////

    function test_siloPaybackState() public {
        uint256 accountNumber = getAccountNumber(SILO_ADDRESSES_PATH);

        console.log("Testing silo payback state for", accountNumber, "accounts");

        assertEq(
            siloPayback.totalDistributed(),
            siloPayback.totalSupply(),
            "Total distributed should be equal to total supply"
        );
        assertEq(siloPayback.totalReceived(), 0, "Total shipments received should be 0");

        string memory account;

        // For every account
        for (uint256 i = 0; i < accountNumber; i++) {
            account = vm.readLine(SILO_ADDRESSES_PATH);
            address accountAddr = vm.parseAddress(account);

            // Get the silo payback ERC20 token balance for this account
            uint256 siloPaybackBalance = siloPayback.balanceOf(accountAddr);

            // Get the expected total BDV at recapitalization from JSON
            string memory totalBdvPath = string.concat(
                "arbEOAs.",
                account,
                ".bdvAtRecapitalization.total"
            );
            bytes memory expectedTotalBdvJson = searchPropertyData(totalBdvPath, SILO_JSON_PATH);

            // Decode the expected total BDV from JSON
            uint256 expectedTotalBdv = vm.parseUint(vm.toString(expectedTotalBdvJson));

            // Compare the silo payback balance against total BDV at recapitalization
            assertEq(
                siloPaybackBalance,
                expectedTotalBdv,
                string.concat("Silo payback balance mismatch for account ", account)
            );
        }
    }

    //////////////////// Barn State Verification ////////////////////

    function test_barnPaybackStateGlobal() public {
        SystemFertilizerStruct memory systemFertilizer = _getSystemFertilizer();
        // get each property and compare against the json
        // get the activeFertilizer
        uint256 activeFertilizer = vm.parseUint(
            vm.toString(searchPropertyData("storage.activeFertilizer", BARN_JSON_PATH))
        );
        assertEq(activeFertilizer, systemFertilizer.activeFertilizer, "activeFertilizer mismatch");

        // get the fertilizedIndex
        uint256 fertilizedIndex = vm.parseUint(
            vm.toString(searchPropertyData("storage.fertilizedIndex", BARN_JSON_PATH))
        );
        assertEq(fertilizedIndex, systemFertilizer.fertilizedIndex, "fertilizedIndex mismatch");

        // get the unfertilizedIndex
        uint256 unfertilizedIndex = vm.parseUint(
            vm.toString(searchPropertyData("storage.unfertilizedIndex", BARN_JSON_PATH))
        );
        assertEq(
            unfertilizedIndex,
            systemFertilizer.unfertilizedIndex,
            "unfertilizedIndex mismatch"
        );

        // get the fertilizedPaidIndex
        uint256 fertilizedPaidIndex = vm.parseUint(
            vm.toString(searchPropertyData("storage.fertilizedPaidIndex", BARN_JSON_PATH))
        );
        assertEq(
            fertilizedPaidIndex,
            systemFertilizer.fertilizedPaidIndex,
            "fertilizedPaidIndex mismatch"
        );

        // get the fertFirst
        uint256 fertFirst = vm.parseUint(
            vm.toString(searchPropertyData("storage.fertFirst", BARN_JSON_PATH))
        );
        assertEq(fertFirst, systemFertilizer.fertFirst, "fertFirst mismatch");

        // get the fertLast
        uint256 fertLast = vm.parseUint(
            vm.toString(searchPropertyData("storage.fertLast", BARN_JSON_PATH))
        );
        assertEq(fertLast, systemFertilizer.fertLast, "fertLast mismatch");

        // get the bpf
        uint128 bpf = uint128(
            vm.parseUint(vm.toString(searchPropertyData("storage.bpf", BARN_JSON_PATH)))
        );
        assertEq(bpf, systemFertilizer.bpf, "bpf mismatch");

        // get the leftoverBeans
        uint256 leftoverBeans = vm.parseUint(
            vm.toString(searchPropertyData("storage.leftoverBeans", BARN_JSON_PATH))
        );
        assertEq(leftoverBeans, systemFertilizer.leftoverBeans, "leftoverBeans mismatch");
    }

    function test_barnPaybackStateAccount() public {
        uint256 accountNumber = getAccountNumber(BARN_ADDRESSES_PATH);
        console.log("Testing barn payback state for", accountNumber, "accounts");

        string memory account;
        uint256 totalContractAccounts = 0;

        // For every account
        for (uint256 i = 0; i < accountNumber; i++) {
            account = vm.readLine(BARN_ADDRESSES_PATH);
            address accountAddr = vm.parseAddress(account);

            // skip contract accounts
            if (isContract(accountAddr)) {
                totalContractAccounts++;
                fertilizedContractAccounts.push(accountAddr);
                continue;
            }

            // Get fertilizer data for this account using the fertilizer finder
            bytes memory accountFertilizerData = searchAccountFertilizer(accountAddr);
            FertDepositData[] memory expectedFertilizers = abi.decode(
                accountFertilizerData,
                (FertDepositData[])
            );

            // For each expected fertilizer, verify the balance matches
            for (uint256 j = 0; j < expectedFertilizers.length; j++) {
                FertDepositData memory expectedFert = expectedFertilizers[j];

                // Get actual balance from barn payback contract
                uint256 actualBalance = barnPayback.balanceOf(accountAddr, expectedFert.fertId);

                // Compare the balances
                assertEq(
                    actualBalance,
                    expectedFert.amount,
                    string.concat(
                        "Fertilizer balance mismatch for account ",
                        account,
                        " fertilizer ID ",
                        vm.toString(expectedFert.fertId)
                    )
                );
            }
        }
        console.log("Total contract accounts", totalContractAccounts);
        // log the contract accounts
        for (uint256 i = 0; i < fertilizedContractAccounts.length; i++) {
            console.log("fertilizedContractAccounts index", i, fertilizedContractAccounts[i]);
        }
    }

    /**
     * @notice Tests that the silo payback hook is whitelisted and has the correct parameters.
     */
    function test_siloPaybackHook() public {
        assertEq(pinto.hasTokenHook(SILO_PAYBACK), true, "Silo payback hook not whitelisted");
        assertEq(
            pinto.getTokenHook(SILO_PAYBACK).target,
            SILO_PAYBACK,
            "Silo payback hook target mismatch"
        );
        assertEq(
            pinto.getTokenHook(SILO_PAYBACK).selector,
            ISiloPayback.protocolUpdate.selector,
            "Silo payback hook selector mismatch"
        );
        assertEq(
            pinto.getTokenHook(SILO_PAYBACK).encodeType,
            0x00,
            "Silo payback hook encode type mismatch"
        );
    }

    //////////////////// Helper Functions ////////////////////

    function searchPropertyData(
        string memory property,
        string memory jsonFilePath
    ) public returns (bytes memory) {
        string[] memory inputs = new string[](4);
        inputs[0] = "node";
        inputs[1] = "./scripts/deployment/parameters/finders/finder.js";
        inputs[2] = jsonFilePath;
        inputs[3] = property;
        bytes memory propertyValue = vm.ffi(inputs);
        return propertyValue;
    }

    function searchAccountFertilizer(address account) public returns (bytes memory) {
        string[] memory inputs = new string[](4);
        inputs[0] = "node";
        inputs[1] = "./scripts/beanstalkShipments/utils/fertilizerFinder.js";
        inputs[2] = BARN_JSON_PATH;
        inputs[3] = vm.toString(account);
        bytes memory accountFertilizer = vm.ffi(inputs);
        return accountFertilizer;
    }

    /// @dev returns the number of accounts in the txt account file
    function getAccountNumber(string memory addressesFilePath) public returns (uint256) {
        string memory content = vm.readFile(addressesFilePath);
        string[] memory lines = vm.split(content, "\n");

        uint256 count = 0;
        for (uint256 i = 0; i < lines.length; i++) {
            if (bytes(lines[i]).length > 0) {
                count++;
            }
        }
        return count;
    }

    function _getSystemFertilizer() internal view returns (SystemFertilizerStruct memory) {
        (
            uint256 activeFertilizer,
            uint256 fertilizedIndex,
            uint256 unfertilizedIndex,
            uint256 fertilizedPaidIndex,
            uint128 fertFirst,
            uint128 fertLast,
            uint128 bpf,
            uint256 leftoverBeans
        ) = barnPayback.fert();
        return
            SystemFertilizerStruct({
                activeFertilizer: uint256(activeFertilizer),
                fertilizedIndex: fertilizedIndex,
                unfertilizedIndex: unfertilizedIndex,
                fertilizedPaidIndex: fertilizedPaidIndex,
                fertFirst: fertFirst,
                fertLast: fertLast,
                bpf: bpf,
                leftoverBeans: leftoverBeans
            });
    }

    /**
     * @notice Checks if an account is a contract.
     */
    function isContract(address account) internal view returns (bool) {
        uint size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}

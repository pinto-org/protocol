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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShipmentRecipient, ShipmentRoute} from "contracts/beanstalk/storage/System.sol";

/**
 * @notice Tests shipment distribution and claiming functionality for the beanstalk shipments system.
 * This tests should be ran against a local node after the deployment and initialization task is complete.
 * 1. Create a local anvil node at block 33349326, right before Season 5952 where the deltab was +19,281 TWAΔP
 * 2. Run the hardhat task: `npx hardhat compile && npx hardhat beanstalkShipments --network localhost`
 * 3. Run the test: `forge test --match-contract BeanstalkShipmentsTest --fork-url http://localhost:8545`
 */
contract BeanstalkShipmentsTest is TestHelper {
    // Contracts
    address constant SHIPMENT_PLANNER = address(0x1152691C30aAd82eB9baE7e32d662B19391e34Db);
    address constant SILO_PAYBACK = address(0x9E449a18155D4B03C2E08A4E28b2BcAE580efC4E);
    address constant BARN_PAYBACK = address(0x71ad4dCd54B1ee0FA450D7F389bEaFF1C8602f9b);
    address constant DEV_BUDGET = address(0xb0cdb715D8122bd976a30996866Ebe5e51bb18b0);

    // Owners
    address constant PCM = address(0x2cf82605402912C6a79078a9BBfcCf061CbfD507);

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

    // Constants
    uint256 constant ACTIVE_FIELD_ID = 0;
    uint256 constant PAYBACK_FIELD_ID = 1;
    uint256 constant SUPPLY_THRESHOLD = 1_000_000_000e6;

    // Users
    address farmer1 = makeAddr("farmer1");

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
    function setUp() public {}

    //////////////////////// SHIPMENT DISTRIBUTION ////////////////////////

    /**
     * @notice Test distribution amount for normal case, well above 1billion supply
     */
    function test_shipmentDistributionKicksInAtCorrectSupply() public {
        // get the total delta b before sunrise aka the expected pinto mints
        int256 totalDeltaBBefore = pinto.totalDeltaB();
        // 1% of the total delta b shiped to each payback contract, totalDeltaBBefore here is positive
        uint256 expectedPintoMints = (uint256(totalDeltaBBefore) * 0.01e18) / 1e18;

        // get fertilized index before
        uint256 fertilizedIndexBefore = _getSystemFertilizer().fertilizedIndex;
        // get fert remaining before
        uint256 fertRemainingBefore = barnPayback.barnRemaining();

        // supply is 1,010bil, sunrise is called and new pintos are distributed
        increaseSupplyAndDistribute();

        /////////// PAYBACK FIELD ///////////

        // assert that: 1 % of mints went to the payback field so harvestable index must have increased
        // by the expected pinto mints with a 0.1% tolerance
        assertApproxEqRel(pinto.harvestableIndex(PAYBACK_FIELD_ID), expectedPintoMints, 0.001e18);

        /////////// SILO PAYBACK ///////////

        // assert that: 1 % of mints went to the silo so silo payback balance of pinto must have increased
        assertApproxEqRel(IERC20(L2_PINTO).balanceOf(SILO_PAYBACK), expectedPintoMints, 0.001e18);
        // assert the silo payback balance is within 0.1% of the expected pinto mints shipped to the silo
        assertApproxEqRel(
            siloPayback.totalReceived(),
            expectedPintoMints,
            0.001e18,
            "Silo payback total distributed mismatch"
        );
        // assert that remaining is correct
        uint256 siloPaybackTotalSupply = siloPayback.totalSupply();
        assertApproxEqRel(
            siloPayback.siloRemaining(),
            siloPaybackTotalSupply - expectedPintoMints,
            0.001e18,
            "Silo payback silo remaining mismatch"
        );

        /////////// BARN PAYBACK ///////////

        // assert that: 1 % of mints went to the barn so barn payback balance of pinto must have increased
        assertApproxEqRel(IERC20(L2_PINTO).balanceOf(BARN_PAYBACK), expectedPintoMints, 0.001e18);
        // assert that the fertilized index has increased
        assertGt(_getSystemFertilizer().fertilizedIndex, fertilizedIndexBefore);
        // assert that the fert remaining has decreased
        assertLt(barnPayback.barnRemaining(), fertRemainingBefore);
    }

    /**
     * @notice Test distribution at the edge, ~1bil supply, asserts the scaling is correct
     */
    function test_shipmentDistributionScaledAtSupplyEdge() public {}

    /**
     * @notice Test that the shipment distribution finishes when no remaining payback
     * uses vm.mockCall to mock the silo and barn payback to return 0
     * Checks that no pintos were allocated to the silo, barn or payback field
     */
    function test_shipmentDistributionFinishesWhenNoRemainingPayback() public {
        _mockFinishPayback(true, true, true);
        // increase supply and distribute
        increaseSupplyAndDistribute();

        // assert that the silo payback is done
        assertEq(siloPayback.siloRemaining(), 0);
        // assert that the barn payback is done
        assertEq(barnPayback.barnRemaining(), 0);

        // assert no pintos were sent to the silo
        assertEq(IERC20(L2_PINTO).balanceOf(SILO_PAYBACK), 0);
        // assert no pintos were sent to the barn
        assertEq(IERC20(L2_PINTO).balanceOf(BARN_PAYBACK), 0);
        // assert the unharvestable index for the payback field is 0
        assertEq(pinto.totalUnharvestable(PAYBACK_FIELD_ID), 0);
        // assert the harvestable index for the payback field is 0 (no pintos were made harvestable)
        assertEq(pinto.harvestableIndex(PAYBACK_FIELD_ID), 0);
    }

    /**
     * @notice Test when the barn payback is done, the mints should be split 1.5% to silo and 1.5% to payback field
     */
    function test_shipmentDistributionWhenNoRemainingBarnPayback() public {
        // silo payback is not done, barn payback is done, payback field is not done
        _mockFinishPayback(false, true, false);

        // get the total delta b before sunrise aka the expected pinto mints
        int256 totalDeltaBBefore = pinto.totalDeltaB();
        // 1.5% of the total delta b shiped to each payback contract, totalDeltaBBefore here is positive
        uint256 expectedPintoMints = (uint256(totalDeltaBBefore) * 0.015e18) / 1e18;

        // increase supply and distribute
        increaseSupplyAndDistribute();

        /////////// BARN PAYBACK ///////////
        // assert that the barn payback is done
        assertEq(barnPayback.barnRemaining(), 0);

        /////////// SILO PAYBACK ///////////
        // assert that the silo payback balance of pinto must have received 1.5% of the mints
        assertApproxEqRel(IERC20(L2_PINTO).balanceOf(SILO_PAYBACK), expectedPintoMints, 0.001e18);
        // assert the silo payback balance is within 0.1% of the expected pinto mints shipped to the silo
        assertApproxEqRel(
            siloPayback.totalReceived(),
            expectedPintoMints,
            0.001e18,
            "Silo payback total distributed mismatch"
        );

        /////////// PAYBACK FIELD ///////////
        // assert that the payback field harvestable index must have increased by the expected pinto mints
        assertApproxEqRel(pinto.harvestableIndex(PAYBACK_FIELD_ID), expectedPintoMints, 0.001e18);
    }

    /**
     * @notice Test when the silo payback is done and the barn payback is done, 
     * all 3% of mints should go to the payback field
     */
    function test_shipmentDistributionWhenNoRemainingSiloPayback() public {
        // silo payback is done, barn payback is done, payback field is not done
        _mockFinishPayback(true, true, false);

        // get the total delta b before sunrise aka the expected pinto mints
        int256 totalDeltaBBefore = pinto.totalDeltaB();
        // 3% of the total delta b shiped to the payback field, totalDeltaBBefore here is positive
        uint256 expectedPintoMints = (uint256(totalDeltaBBefore) * 0.03e18) / 1e18;

        // increase supply and distribute
        increaseSupplyAndDistribute();

        /////////// PAYBACK FIELD ///////////
        // assert that the payback field harvestable index must have increased by the expected pinto mints
        assertApproxEqRel(pinto.harvestableIndex(PAYBACK_FIELD_ID), expectedPintoMints, 0.001e18, "Payback field harvestable index mismatch");

        /////////// SILO PAYBACK ///////////
        // assert remaining is 0
        assertEq(siloPayback.siloRemaining(), 0);

        /////////// BARN PAYBACK ///////////
        // assert remaining is 0
        assertEq(barnPayback.barnRemaining(), 0);
    }

    //////////////////////// CLAIMING ////////////////////////

    // note: test that all users can claim their rewards at any point
    // iterate through the accounts array of silo and fert payback and claim the rewards for each
    // silo
    function test_siloPaybackClaimShipmentDistribution() public {}
    // barn
    function test_barnPaybackClaimShipmentDistribution() public {}
    // payback field
    function test_paybackFieldClaimShipmentDistribution() public {}

    // check that all contract accounts can claim their rewards directly
    function test_contractAccountsCanClaimShipmentDistribution() public {}

    // check that 0xBc7c5f21C632c5C7CA1Bfde7CBFf96254847d997 can claim their rewards
    // check gas usage
    function test_plotContractCanClaimShipmentDistribution() public {}

    //////////////////// Helper Functions ////////////////////

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

    function _skipAndCallSunrise() internal {
        // skip 2 blocks and call sunrise
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 30 seconds);
        pinto.sunrise();
    }

    function increaseSupplyAndDistribute() internal {
        // get the total supply before minting
        uint256 totalSupplyBefore = IERC20(L2_PINTO).totalSupply();
        assertLt(totalSupplyBefore, SUPPLY_THRESHOLD, "Total supply is not below the threshold");

        // mint 1bil supply to get well above the threshold
        deal(L2_PINTO, address(this), SUPPLY_THRESHOLD, true);

        // get the total supply of pinto
        uint256 totalSupplyAfter = IERC20(L2_PINTO).totalSupply();
        console.log("Total supply after minting", totalSupplyAfter);
        // assert the total supply is above the threshold
        assertGt(totalSupplyAfter, SUPPLY_THRESHOLD, "Total supply is not above the threshold");
        assertGt(pinto.totalDeltaB(), 0, "System should be above the value target");
        // skip 2 blocks and call sunrise
        _skipAndCallSunrise();
    }

    function _mockFinishPayback(bool silo, bool barn, bool field) internal {
        if (silo) {
            vm.mockCall(
                address(siloPayback),
                abi.encodeWithSelector(siloPayback.siloRemaining.selector),
                abi.encode(0)
            );
        }
        if (barn) {
            vm.mockCall(
                address(barnPayback),
                abi.encodeWithSelector(barnPayback.barnRemaining.selector),
                abi.encode(0)
            );
        }
        if (field) {
            vm.mockCall(
                address(pinto),
                abi.encodeWithSelector(pinto.totalUnharvestable.selector, PAYBACK_FIELD_ID),
                abi.encode(0)
            );
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {OperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console} from "forge-std/console.sol";
import {IBarnPayback, LibTransfer as BarnLibTransfer, BeanstalkFertilizer} from "contracts/interfaces/IBarnPayback.sol";
import {ISiloPayback, LibTransfer as SiloLibTransfer} from "contracts/interfaces/ISiloPayback.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {ShipmentPlanner} from "contracts/ecosystem/ShipmentPlanner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShipmentRecipient, ShipmentRoute} from "contracts/beanstalk/storage/System.sol";
import {LibReceiving} from "contracts/libraries/LibReceiving.sol";
import {ContractPaybackDistributor} from "contracts/ecosystem/beanstalkShipments/contractDistribution/ContractPaybackDistributor.sol";

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
    address constant CONTRACT_PAYBACK_DISTRIBUTOR =
        address(0x5dC8F2e4F47F36F5d20B6456F7993b65A7994000);
    // Owners
    address constant PCM = address(0x2cf82605402912C6a79078a9BBfcCf061CbfD507);

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
    ContractPaybackDistributor contractDistributor =
        ContractPaybackDistributor(CONTRACT_PAYBACK_DISTRIBUTOR);

    // Contract accounts loaded from JSON file
    address[] contractAccounts;

    // we need to:
    // - Verify that all state matches the one in the json files for shipments, silo and barn payback
    // - get to a supply where the beanstalk shipments kick in
    // - make the system print, check distribution in each contract
    // - for each component, make sure everything is distributed correctly
    // - make sure that at any point all users can claim their rewards pro rata
    function setUp() public {
        _loadContractAccountsFromJson();
    }

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
     * @notice Test distribution at the edge, ~1bil supply, checks that the scaling is correct
     * checks that all paybacks and budget receive pintos
     */
    function test_shipmentDistributionScaledAtSupplyEdge() public {
        // increase supply at the edge, get the new supply to calculate the ratio
        increaseSupplyAtEdge();

        // get the total delta b before sunrise aka the expected pinto mints
        uint256 totalDeltaBBefore = uint256(pinto.totalDeltaB());
        // get total supply before sunrise
        uint256 beanSupplyBefore = IERC20(L2_PINTO).totalSupply();

        // skip 2 blocks and call sunrise, distribute the pintos, expect all shipment receipts to be emitted
        vm.expectEmit(true, false, true, false);
        emit LibReceiving.Receipt(ShipmentRecipient.SILO, 0, abi.encode(0)); // SILO
        emit LibReceiving.Receipt(ShipmentRecipient.FIELD, 0, abi.encode(0)); // FIELD
        emit LibReceiving.Receipt(ShipmentRecipient.INTERNAL_BALANCE, 0, abi.encode(DEV_BUDGET)); // BUDGET
        emit LibReceiving.Receipt(
            ShipmentRecipient.FIELD,
            0,
            abi.encode(PAYBACK_FIELD_ID, SILO_PAYBACK, BARN_PAYBACK)
        ); // PAYBACK FIELD
        emit LibReceiving.Receipt(
            ShipmentRecipient.SILO_PAYBACK,
            0,
            abi.encode(SILO_PAYBACK, BARN_PAYBACK)
        ); // SILO PAYBACK
        emit LibReceiving.Receipt(
            ShipmentRecipient.BARN_PAYBACK,
            0,
            abi.encode(SILO_PAYBACK, BARN_PAYBACK)
        ); // BARN PAYBACK
        _skipAndCallSunrise();

        // total delta b before sunrise was 18224884688
        // bean supply before sunrise was 999990000000000
        // uint256 remainingBudget = SUPPLY_BUDGET_FLIP - (beanSupply - seasonalMints)
        // 1_000_000_000e6 - (999990000000000 - 18224884688) = ~28_224e6

        // ratio = (remainingBudget * PRECISION) / seasonalMints
        // ratio = (28224000000 * 1e18) / 18224884688 = ~1,5486e18 aka 1,005486%

        // all paybacks are active so all points are 1%
        // and scaled by the ratio (points = (points * paybackRatio) / PRECISION;)
        // so the expected pinto mints should be slighly less than the 1% of the total delta b
        // since a portion still goes to the budget so around ~181e6 pintos

        // get the scaled ratio
        uint256 remainingBudget = SUPPLY_THRESHOLD - (beanSupplyBefore - totalDeltaBBefore);
        uint256 scaledRatio = (remainingBudget * 1e18) / totalDeltaBBefore;
        // 1,0054870032 => 1,005487% of the total delta b

        // get the expected pinto mints. first get the 1%
        uint256 expectedPintoMints = (totalDeltaBBefore * 0.01e18) / 1e18;
        // then scale it by the ratio
        expectedPintoMints = (expectedPintoMints * scaledRatio) / 1e18;

        /////////// PAYBACK FIELD ///////////
        // assert that the expected pinto mints are equal to the actual pinto mints with a 1.5% tolerance
        assertApproxEqRel(pinto.harvestableIndex(PAYBACK_FIELD_ID), expectedPintoMints, 0.015e18);

        /////////// SILO PAYBACK ///////////
        // assert that the silo payback balance of pinto must have increased
        assertApproxEqRel(IERC20(L2_PINTO).balanceOf(SILO_PAYBACK), expectedPintoMints, 0.015e18);

        /////////// BARN PAYBACK ///////////
        // assert that the barn payback balance of pinto must have increased
        assertApproxEqRel(IERC20(L2_PINTO).balanceOf(BARN_PAYBACK), expectedPintoMints, 0.015e18);
    }

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
        assertApproxEqRel(
            pinto.harvestableIndex(PAYBACK_FIELD_ID),
            expectedPintoMints,
            0.001e18,
            "Payback field harvestable index mismatch"
        );

        /////////// SILO PAYBACK ///////////
        // assert remaining is 0
        assertEq(siloPayback.siloRemaining(), 0);

        /////////// BARN PAYBACK ///////////
        // assert remaining is 0
        assertEq(barnPayback.barnRemaining(), 0);
    }

    //////////////////////// REGULAR ACCOUNT CLAIMING ////////////////////////

    /**
     * @notice Test that all silo payback holders are able to claim their rewards
     * after a distribution has occured.
     */
    function test_siloPaybackClaimShipmentDistribution() public {
        // assert no rewards before distribution
        assertEq(siloPayback.rewardPerTokenStored(), 0);

        // distribute 3 times to get rewards per token stored
        increaseSupplyAndDistribute();
        _skipSeasonAndCallSunrise();
        _skipSeasonAndCallSunrise();
        uint256 rewardsPerTokenStored = siloPayback.rewardPerTokenStored();

        // claim for the first 50 accounts
        uint256 accountNumber = 50;
        string memory account;
        for (uint256 i = 0; i < accountNumber; i++) {
            account = vm.readLine(SILO_ADDRESSES_PATH);
            address accountAddr = vm.parseAddress(account);
            // assert the user has claimable rewards
            // if the account has less than 1e6 silo payback, skip it since it may cause rounding errors in earned()
            if (siloPayback.balanceOf(accountAddr) < 1e6) continue;
            assertGt(siloPayback.earned(accountAddr), 0, "Account should have rewards");
            assertEq(
                siloPayback.userRewardPerTokenPaid(accountAddr),
                0,
                "User should have no rewards paid yet"
            );

            // claim the pinto rewards
            vm.prank(accountAddr); // prank as the account
            siloPayback.claim(accountAddr, SiloLibTransfer.To.EXTERNAL); // claim the rewards

            // check that the user and global indexes are synced
            assertEq(siloPayback.userRewardPerTokenPaid(accountAddr), rewardsPerTokenStored);
            // check that the balance of pinto of the account is greater than 0
            assertGt(IERC20(L2_PINTO).balanceOf(accountAddr), 0);
        }
    }

    /**
     * @notice Test the payback field holder with the plot at the front of the line can harvest
     * their plot for pinto after a distribution has occured.
     */
    function test_paybackFieldHarvestFromShipmentDistribution() public {
        // distribute and increment harvestable index
        increaseSupplyAndDistribute();
        address firstHarvester = address(0xe3cd19FAbC17bA4b3D11341Aa06b6f245DE3f9A6);
        assertGt(
            pinto.harvestableIndex(PAYBACK_FIELD_ID),
            0,
            "Harvestable index of payback field should have increased"
        );
        // 164866037 harvestable index ( around 1% of total delta b)

        uint256 plotId = 0; // first plot
        uint256[] memory plots = new uint256[](1);
        plots[0] = plotId;

        // prank and call harvest
        vm.prank(firstHarvester);
        pinto.harvest(PAYBACK_FIELD_ID, plots, uint8(BarnLibTransfer.To.EXTERNAL));

        // assert the balance of pinto of the first harvester is greater than 0
        assertGt(IERC20(L2_PINTO).balanceOf(firstHarvester), 0);
    }

    /**
     * @notice Test that all active fertilizer holders are able to claim their * rinsable sprouts after a distribution has occured.
     */
    function test_barnPaybackClaimShipmentDistribution() public {
        // Capture initial barn payback state before distribution
        SystemFertilizerStruct memory initialFertState = _getSystemFertilizer();

        // Ensure shipments have been distributed to advance BPF
        increaseSupplyAndDistribute();

        // Calculate expected BPF and fertilizedIndex increases based on shipment amount
        // From BarnPayback.barnPaybackReceive(): remainingBpf = amountToFertilize / fert.activeFertilizer
        uint256 shipmentAmount = 164866037; // 1% of total deltaB
        uint256 amountToFertilize = shipmentAmount + initialFertState.leftoverBeans;
        uint256 expectedBpfIncrease = amountToFertilize / initialFertState.activeFertilizer;
        uint256 expectedFertilizedIndexIncrease = expectedBpfIncrease *
            initialFertState.activeFertilizer;

        // Verify distribution state changes
        SystemFertilizerStruct memory postDistributionState = _getSystemFertilizer();

        assertEq(
            postDistributionState.bpf,
            initialFertState.bpf + expectedBpfIncrease,
            "BPF should increase by shipment amount divided by active fertilizer"
        );
        assertEq(
            postDistributionState.fertilizedIndex,
            initialFertState.fertilizedIndex + expectedFertilizedIndexIncrease,
            "FertilizedIndex should increase by BPF increase times active fertilizer"
        );

        // Load fertilizer data and get first 10 active fertilizer IDs
        (
            uint256[] memory fertilizerIds,
            address[] memory claimAccounts
        ) = _getFirst10FertilizerClaims();

        uint256 totalClaimedAmount = 0;

        for (uint256 i = 0; i < fertilizerIds.length && i < 10; i++) {
            uint256[] memory singleId = new uint256[](1);
            singleId[0] = fertilizerIds[i];

            uint256 claimableAmount = barnPayback.balanceOfFertilized(claimAccounts[i], singleId);

            if (claimableAmount > 0) {
                uint256 userBalanceBefore = IERC20(L2_PINTO).balanceOf(claimAccounts[i]);
                uint256 paidIndexBefore = _getSystemFertilizer().fertilizedPaidIndex;

                vm.prank(claimAccounts[i]);
                barnPayback.claimFertilized(singleId, BarnLibTransfer.To.EXTERNAL);

                // User should receive exactly the claimed pinto amount
                assertEq(
                    IERC20(L2_PINTO).balanceOf(claimAccounts[i]),
                    userBalanceBefore + claimableAmount,
                    "User should receive exactly claimed pinto amount"
                );

                assertEq(
                    _getSystemFertilizer().fertilizedPaidIndex,
                    paidIndexBefore + claimableAmount,
                    "FertilizedPaidIndex should increase by exactly claimed amount"
                );

                assertEq(
                    barnPayback.balanceOfFertilized(claimAccounts[i], singleId),
                    0,
                    "User should have exactly zero claimable beans after claim"
                );

                assertEq(
                    barnPayback.lastBalanceOf(claimAccounts[i], fertilizerIds[i]).lastBpf,
                    postDistributionState.bpf < fertilizerIds[i]
                        ? postDistributionState.bpf
                        : fertilizerIds[i],
                    "User's lastBpf should be updated to min(currentBpf, fertilizerId)"
                );

                totalClaimedAmount += claimableAmount;
            }
        }

        // final state
        SystemFertilizerStruct memory finalState = _getSystemFertilizer();

        assertEq(
            finalState.fertilizedPaidIndex,
            postDistributionState.fertilizedPaidIndex + totalClaimedAmount,
            "FertilizedPaidIndex should increase by exactly total claimed amount"
        );
    }

    //////////////////////// CONTRACT ACCOUNT CLAIMING ////////////////////////

    /**
     * @notice Check that all contract accounts can claim their rewards directly
     * By measuring the gas usage for each claim, we also get the necessary gas limit for the L1 contract messenger
     * See L1ContractMessenger.{claimL2BeanstalkAssets} for details on the gas limit
     */
    function test_contractAccountsCanClaimShipmentDistribution() public {
        uint256 maxGasUsed;

        for (uint256 i = 0; i < contractAccounts.length; i++) {
            vm.startSnapshotGas("contractClaimWithPlots");

            // Prank as the contract account to call claimDirect
            vm.prank(contractAccounts[i]);
            contractDistributor.claimDirect(farmer1);

            uint256 gasUsed = vm.stopSnapshotGas();
            if (gasUsed > maxGasUsed) {
                maxGasUsed = gasUsed;
            }
        }
        console.log("Max gas used for claims from all contracts", maxGasUsed);
    }

    /**
     * @notice Check that 0xBc7c5f21C632c5C7CA1Bfde7CBFf96254847d997 can claim their rewards
     * check gas usage
     */
    function test_plotContractCanClaimShipmentDistribution() public {
        address plotContract = address(0xBc7c5f21C632c5C7CA1Bfde7CBFf96254847d997);
        vm.startSnapshotGas("contractClaimWithPlots");
        // prank and call claimDirect
        vm.prank(plotContract);
        contractDistributor.claimDirect(farmer1);
        uint256 gasUsed = vm.stopSnapshotGas();
        console.log("Gas used by contract claim with plots", gasUsed);
    }

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

    function _skipSeasonAndCallSunrise() internal {
        // skip 2 blocks and call sunrise
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 2 hours);
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
        // assert the total supply is above the threshold
        assertGt(totalSupplyAfter, SUPPLY_THRESHOLD, "Total supply is not above the threshold");
        assertGt(pinto.totalDeltaB(), 0, "System should be above the value target");
        // skip 2 blocks and call sunrise
        expectPaybackShipmentReceipts();
        _skipAndCallSunrise();
    }

    function expectPaybackShipmentReceipts() internal {
        vm.expectEmit(true, false, true, false);
        emit LibReceiving.Receipt(
            ShipmentRecipient.FIELD,
            0,
            abi.encode(PAYBACK_FIELD_ID, SILO_PAYBACK, BARN_PAYBACK)
        ); // PAYBACK FIELD
        emit LibReceiving.Receipt(
            ShipmentRecipient.SILO_PAYBACK,
            0,
            abi.encode(SILO_PAYBACK, BARN_PAYBACK)
        ); // SILO PAYBACK
        emit LibReceiving.Receipt(
            ShipmentRecipient.BARN_PAYBACK,
            0,
            abi.encode(SILO_PAYBACK, BARN_PAYBACK)
        ); // BARN PAYBACK
    }

    function increaseSupplyAtEdge() internal {
        // get the total supply before minting
        uint256 totalSupplyBefore = IERC20(L2_PINTO).totalSupply();
        assertLt(totalSupplyBefore, SUPPLY_THRESHOLD, "Total supply is not below the threshold");

        // mint ~990mil so that some mints should go to budget and some to payback contracts
        // 10_000_000 + 1_000_000_000 - 10_000_000 - 100 = 999_999_000 pintos before sunrise
        // 18_000 * 0,03 = 540 pintos should go to the budget if there were no paybacks
        // now that there are paybacks, the should get 540 - 100 = 440 pintos split between silo, barn and payback field
        deal(L2_PINTO, address(this), SUPPLY_THRESHOLD - totalSupplyBefore - 100e6, true);

        // assert that the minting did not exceed the payback threshold
        uint256 totalSupplyAfterMinting = IERC20(L2_PINTO).totalSupply();
        assertLt(
            totalSupplyAfterMinting,
            SUPPLY_THRESHOLD,
            "Total supply is not below the threshold"
        );
        // assert that the sum of the 2 exceeeds the threshold
        assertGt(
            IERC20(L2_PINTO).totalSupply() + uint256(pinto.totalDeltaB()),
            SUPPLY_THRESHOLD,
            "Total supply and delta b before sunrise does not exceed the threshold"
        );
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

    /**
     * @notice Load contract accounts from JSON file
     */
    function _loadContractAccountsFromJson() internal {
        string memory jsonPath = "scripts/beanstalkShipments/data/ethContractAccounts.json";
        string memory json = vm.readFile(jsonPath);
        contractAccounts = vm.parseJsonAddressArray(json, "");
    }

    /**
     * @notice Get the first 10 active fertilizer IDs and corresponding account holders
     * @return fertilizerIds Array of the first 10 fertilizer IDs
     * @return claimAccounts Array of accounts that hold each fertilizer ID
     */
    function _getFirst10FertilizerClaims()
        internal
        view
        returns (uint256[] memory fertilizerIds, address[] memory claimAccounts)
    {
        // Based on the JSON data, the first 10 fertilizer IDs are the earliest ones
        // From beanstalkAccountFertilizer.json, the first entries have the lowest IDs
        fertilizerIds = new uint256[](10);
        claimAccounts = new address[](10);

        // First 10 fertilizer IDs from the data (sorted chronologically)
        fertilizerIds[0] = 1334303; // First fertilizer ID
        fertilizerIds[1] = 1334880;
        fertilizerIds[2] = 1334901;
        fertilizerIds[3] = 1334925;
        fertilizerIds[4] = 1335008;
        fertilizerIds[5] = 1335068;
        fertilizerIds[6] = 1335304;
        fertilizerIds[7] = 1336323;
        fertilizerIds[8] = 1337953;
        fertilizerIds[9] = 1338731;

        // Corresponding account holders for each fertilizer ID (first holder from each ID)
        claimAccounts[0] = 0xBd120e919eb05343DbA68863f2f8468bd7010163; // Holds fertilizer ID 1334303
        claimAccounts[1] = 0x97b60488997482C29748d6f4EdC8665AF4A131B5; // Holds fertilizer ID 1334880
        claimAccounts[2] = 0xf662972FF1a9D77DcdfBa640c1D01Fa9d6E4Fb73; // Holds fertilizer ID 1334901
        claimAccounts[3] = 0x5f5ad340348Cd7B1d8FABE62c7afE2E32d2dE359; // Holds fertilizer ID 1334925
        claimAccounts[4] = 0xa5D0084A766203b463b3164DFc49D91509C12daB; // Holds fertilizer ID 1335008
        claimAccounts[5] = 0x7003d82D2A6F07F07Fc0D140e39ebb464024C91B; // Holds fertilizer ID 1335068
        claimAccounts[6] = 0x82Ff15f5de70250a96FC07a0E831D3e391e47c48; // Holds fertilizer ID 1335304
        claimAccounts[7] = 0x710B5BB4552f20524232ae3e2467a6dC74b21982; // Holds fertilizer ID 1336323
        claimAccounts[8] = 0x18C6A47AcA1c6a237e53eD2fc3a8fB392c97169b; // Holds fertilizer ID 1337953
        claimAccounts[9] = 0xCF0dCc80F6e15604E258138cca455A040ecb4605; // Holds fertilizer ID 1338731
    }
}

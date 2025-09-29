// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
pragma abicoder v2;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BeanstalkFertilizer} from "contracts/ecosystem/beanstalkShipments/barn/BeanstalkFertilizer.sol";
import {BarnPayback} from "contracts/ecosystem/beanstalkShipments/barn/BarnPayback.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TestHelper} from "test/foundry/utils/TestHelper.sol";

/**
 * @title BarnPaybackTest
 * @author Generated Test
 * @notice Comprehensive tests for BarnPayback fertilizer functionality
 * @dev Tests focus on pinto distribution and payback mechanics for fertilizer holders
 */
contract BarnPaybackTest is TestHelper {
    // Events
    event ClaimFertilizer(uint256[] ids, uint256 beans);
    event BarnPaybackRewardsReceived(uint256 amount);

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

    // Initial state of the system after arbitrum migration for reference
    //     "activeFertilizer": "17216958", // Total amount of active fertilizer tokens
    //     "fertilizedIndex": "5654645373178", // Total amount of fertilized beans paid out
    //     "unfertilizedIndex": "95821405245000", // Total amount of unfertilized beans ever (total debt)
    //     "fertilizedPaidIndex": "5654645373178", // Total amount of fertilized beans paid out
    //     "fertFirst": "1334303", // First active fertilizer id
    //     "fertLast": "6000000", // Last active fertilizer id
    //     "bpf": "340802", // current Beans per fertilizer, determines if an id is active or not
    //     "leftoverBeans": "0x0" // Amount of beans that have shipped to Fert but not yet reflected in bpf
    //   },
    // BPF is the amount at which the fert STOPS earning rewards

    // Contracts
    BarnPayback public barnPayback;
    TransparentUpgradeableProxy public proxy;

    // Test users
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("farmer1");
    address public user2 = makeAddr("farmer2");
    address public user3 = makeAddr("farmer3");

    // Test constants
    uint128 constant INITIAL_BPF = 45e6; // Close to the first fert id
    uint128 constant FERT_ID_1 = 50e6; // 50 beans per fertilizer
    uint128 constant FERT_ID_2 = 100e6; // 100 beans per fertilizer
    uint128 constant FERT_ID_3 = 150e6; // 150 beans per fertilizer

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // Deploy implementation contract
        BarnPayback implementation = new BarnPayback();

        // Prepare system fertilizer state
        BeanstalkFertilizer.InitSystemFertilizer
            memory initSystemFert = _createInitSystemFertilizerData();

        // Encode initialization data
        vm.startPrank(owner);
        bytes memory data = abi.encodeWithSelector(
            BarnPayback.initialize.selector,
            address(BEAN),
            address(BEANSTALK),
            address(0), // contract distributor
            initSystemFert
        );

        // Deploy proxy contract
        proxy = new TransparentUpgradeableProxy(
            address(implementation), // implementation
            owner, // initial owner
            data // initialization data
        );

        vm.stopPrank();

        // Set the barn payback proxy
        barnPayback = BarnPayback(address(proxy));

        // Mint fertilizers to accounts
        vm.startPrank(owner);
        // Mint fertilizers to accounts
        // user1: 60 of FERT_ID_1 (50 beans per fertilizer)
        // user2: 40 of FERT_ID_1, 30 of FERT_ID_2 (100 beans per fertilizer)
        // user3: 25 of FERT_ID_3 (150 beans per fertilizer)
        BarnPayback.Fertilizers[] memory fertilizerData = _createFertilizerAccountData();
        barnPayback.mintFertilizers(fertilizerData);
        vm.stopPrank();

        // label the users
        vm.label(user1, "farmer1");
        vm.label(user2, "farmer2");
        vm.label(user3, "farmer3");
    }

    ////////////// Shipment receiving //////////////

    /**
     * @notice Test that the barn payback receive function updates the state correctly,
     * reducing the unfertilized beans and increasing the bpf.
     */
    function test_barnPaybackReceive() public {
        uint256 initialUnfertilized = barnPayback.totalUnfertilizedBeans();
        uint256 shipmentAmount = 100e6; // 100 pinto

        // Only pinto protocol can call barnPaybackReceive
        vm.expectRevert("BarnPayback: only pinto protocol");
        vm.prank(user1);
        barnPayback.barnPaybackReceive(shipmentAmount);

        // Pinto protocol sends rewards
        vm.expectEmit(true, true, true, true);
        emit BarnPaybackRewardsReceived(shipmentAmount);

        vm.prank(address(BEANSTALK));
        barnPayback.barnPaybackReceive(shipmentAmount);

        // Should reduce unfertilized beans
        uint256 finalUnfertilized = barnPayback.totalUnfertilizedBeans();
        assertLt(finalUnfertilized, initialUnfertilized, "Should reduce unfertilized beans");

        // Should increase bpf
        SystemFertilizerStruct memory fert = _getSystemFertilizer();
        assertGt(fert.bpf, INITIAL_BPF, "Should increase bpf");

        // Should not change fertFirst since the id did not get popped from the queue
        assertEq(fert.fertFirst, FERT_ID_1, "Should not change fertFirst");

        // paid index should be 0 since noone claimed yet
        assertEq(fert.fertilizedPaidIndex, 0, "Should have 0 fertilized paid index");

        // Should not change activeFertilizer since no fert token ids ran out
        assertEq(fert.activeFertilizer, 175, "Should not change activeFertilizer");

        // Barn remaining should be updated
        assertEq(
            barnPayback.barnRemaining(),
            finalUnfertilized,
            "Barn remaining should match unfertilized"
        );
    }

    /////////////// Earned calculation ///////////////

    /**
     * @notice Test that the fertilized amount is calculated correctly for multiple users with active fertilizers
     * When the bpf exceeds the first id, the first id is popped from the queue and the activeFertilizer is reduced
     */
    function test_barnPaybackFertilizedMultipleUsersWithPop() public {
        // Send rewards to advance BPF
        // first, get it to match the first id and then advance to pop the id from the queue
        uint256 rewardAmount = 1000e6;
        _sendRewardsToContract(rewardAmount);

        // get the system fertilizer state
        SystemFertilizerStruct memory fert = _getSystemFertilizer();

        // user1 has 60 of FERT_ID_1
        uint256[] memory user1Ids = new uint256[](1);
        user1Ids[0] = FERT_ID_1;

        // user2 has 40 of FERT_ID_1 and 30 of FERT_ID_2
        uint256[] memory user2Ids = new uint256[](2);
        user2Ids[0] = FERT_ID_1;
        user2Ids[1] = FERT_ID_2;

        uint256 user1Fertilized = barnPayback.balanceOfFertilized(user1, user1Ids);
        uint256 user2Fertilized = barnPayback.balanceOfFertilized(user2, user2Ids);

        assertGt(user1Fertilized, 0, "user1 should have fertilized beans");
        assertGt(user2Fertilized, 0, "user2 should have fertilized beans");

        // assert that new bpf exceeds the first id, meaning the first id is no longer active
        assertGt(fert.bpf, FERT_ID_1);

        // assert the number of active fertilizers is 75 (175 initial - 100 popped from first id)
        assertEq(fert.activeFertilizer, 75);

        // assert that fertFirst variable is updated to the next id in the queue
        assertEq(fert.fertFirst, FERT_ID_2);
    }

    ////////////////// Claiming //////////////////

    /**
     * @dev test that two users can claim their fertilizer rewards pro rata to their balance
     */
    function test_barnPaybackClaimOneFertOneUser() public {
        // First distribution: advance BPF but dont cross over the first fert id
        uint256 rewardAmount = 100e6;
        _sendRewardsToContract(rewardAmount);

        uint256[] memory user1Ids = new uint256[](1);
        user1Ids[0] = FERT_ID_1;

        // Check initial fertilized amounts
        uint256 user1Fertilized1 = barnPayback.balanceOfFertilized(user1, user1Ids);
        assertGt(user1Fertilized1, 0, "user1 should have fertilized beans");

        // user1 claims immediately after first distribution
        uint256 user1BalanceBefore = IERC20(BEAN).balanceOf(user1);
        vm.expectEmit(true, true, true, true);
        emit ClaimFertilizer(user1Ids, user1Fertilized1);
        vm.prank(user1);
        barnPayback.claimFertilized(user1Ids, LibTransfer.To.EXTERNAL);

        // Verify user1 received rewards
        assertEq(IERC20(BEAN).balanceOf(user1), user1BalanceBefore + user1Fertilized1);
        // user1 should have no more fertilized beans for these IDs
        assertEq(barnPayback.balanceOfFertilized(user1, user1Ids), 0);

        // verify that the bpf increased but did not cross over the first fert id
        SystemFertilizerStruct memory fert = _getSystemFertilizer();
        assertGt(fert.bpf, INITIAL_BPF);
        assertLt(fert.bpf, FERT_ID_1);

        // verify that the fertilized index increased by the amount sent as rewards minus the leftover beans
        assertEq(fert.fertilizedIndex, rewardAmount - fert.leftoverBeans);
    }

    /**
     * @notice Test attempting to send more payments after all fertilizers are inactive
     */
    function test_paymentAfterAllFertilizersInactive() public {
        // First, make all fertilizers inactive
        SystemFertilizerStruct memory initialFert = _getSystemFertilizer();
        uint256 completeRepayment = (FERT_ID_3 - initialFert.bpf + 10e6) *
            initialFert.activeFertilizer;

        _sendRewardsToContract(completeRepayment);

        // Verify all fertilizers are inactive
        SystemFertilizerStruct memory postPaymentFert = _getSystemFertilizer();
        assertEq(postPaymentFert.activeFertilizer, 0, "All fertilizers should be inactive");

        // try to send another payment, expect revert
        uint256 additionalPayment = 1000e6;

        deal(address(BEAN), address(deployer), additionalPayment);
        vm.prank(deployer);
        IERC20(BEAN).transfer(address(barnPayback), additionalPayment);
        vm.prank(address(BEANSTALK));
        vm.expectRevert();
        barnPayback.barnPaybackReceive(additionalPayment);
    }

    /**
     * @notice Test that rewards are claimed to sender's internal balance on fertilizer transfer
     */
    function test_rewardsClaimedOnTransfer() public {
        // Send rewards to create claimable beans for FERT_ID_1
        uint256 paymentAmount = 500e6;
        _sendRewardsToContract(paymentAmount);

        // Check user1 has rewards available
        uint256[] memory user1Ids = new uint256[](1);
        user1Ids[0] = FERT_ID_1;
        uint256 pendingRewards = barnPayback.balanceOfFertilized(user1, user1Ids);
        assertGt(pendingRewards, 0, "User1 should have pending rewards");

        // Get user1's initial internal bean balance
        uint256 initialBalance = IERC20(BEAN).balanceOf(user1);

        // Transfer fertilizer to another address
        address recipient = makeAddr("recipient");
        vm.prank(user1);
        barnPayback.safeTransferFrom(user1, recipient, FERT_ID_1, 10, "");

        // Check that beans were transferred to user1's internal balance
        uint256 finalBalance = IERC20(BEAN).balanceOf(user1);
        assertEq(finalBalance, initialBalance, "Beans should be transferred to external balance");
        // user should have no more fertilized beans for these IDs
        assertEq(barnPayback.balanceOfFertilized(user1, user1Ids), 0);
        // user should have the pending rewards in their internal balance
        assertEq(bs.getInternalBalance(user1, BEAN), pendingRewards);
    }

    ///////////////////// Helper functions /////////////////////

    /**
     * @notice Helper function to send reward pinto to the fertilizer contract via barn payback receive
     * @param amount Amount of pinto to distribute
     */
    function _sendRewardsToContract(uint256 amount) internal {
        deal(address(BEAN), address(deployer), amount);
        vm.prank(deployer);
        IERC20(BEAN).transfer(address(barnPayback), amount);

        vm.prank(address(BEANSTALK));
        barnPayback.barnPaybackReceive(amount);
    }

    /**
     * @notice Creates mock system fertilizer data for testing
     */
    function _createInitSystemFertilizerData()
        internal
        pure
        returns (BeanstalkFertilizer.InitSystemFertilizer memory)
    {
        uint128[] memory fertilizerIds = new uint128[](3);
        fertilizerIds[0] = FERT_ID_1;
        fertilizerIds[1] = FERT_ID_2;
        fertilizerIds[2] = FERT_ID_3;

        uint256[] memory fertilizerAmounts = new uint256[](3);
        fertilizerAmounts[0] = 100; // 100 units of FERT_ID_1
        fertilizerAmounts[1] = 50; // 50 units of FERT_ID_2
        fertilizerAmounts[2] = 25; // 25 units of FERT_ID_3

        // Calculate total fertilizer for activeFertilizer and unfertilized index
        uint256 totalFertilizer = (FERT_ID_1 * 100) + (FERT_ID_2 * 50) + (FERT_ID_3 * 25);

        return
            BeanstalkFertilizer.InitSystemFertilizer({
                fertilizerIds: fertilizerIds,
                fertilizerAmounts: fertilizerAmounts,
                activeFertilizer: 175, // 100 + 50 + 25
                fertilizedIndex: 0,
                unfertilizedIndex: totalFertilizer,
                fertilizedPaidIndex: 0,
                fertFirst: FERT_ID_1, // Start of linked list
                fertLast: FERT_ID_3, // End of linked list
                bpf: INITIAL_BPF,
                leftoverBeans: 0
            });
    }

    /**
     * @notice Creates mock fertilizer account data for testing
     */
    function _createFertilizerAccountData()
        internal
        view
        returns (BarnPayback.Fertilizers[] memory)
    {
        BarnPayback.Fertilizers[] memory fertilizerData = new BarnPayback.Fertilizers[](3);

        // FERT_ID_1 holders
        BarnPayback.AccountFertilizerData[]
            memory accounts1 = new BarnPayback.AccountFertilizerData[](2);
        accounts1[0] = BarnPayback.AccountFertilizerData({
            account: user1,
            amount: 60,
            lastBpf: INITIAL_BPF
        });
        accounts1[1] = BarnPayback.AccountFertilizerData({
            account: user2,
            amount: 40,
            lastBpf: INITIAL_BPF
        });

        fertilizerData[0] = BarnPayback.Fertilizers({
            fertilizerId: FERT_ID_1,
            accountData: accounts1
        });

        // FERT_ID_2 holders
        BarnPayback.AccountFertilizerData[]
            memory accounts2 = new BarnPayback.AccountFertilizerData[](2);
        accounts2[0] = BarnPayback.AccountFertilizerData({
            account: user2,
            amount: 30,
            lastBpf: INITIAL_BPF
        });
        accounts2[1] = BarnPayback.AccountFertilizerData({
            account: user3,
            amount: 20,
            lastBpf: INITIAL_BPF
        });

        fertilizerData[1] = BarnPayback.Fertilizers({
            fertilizerId: FERT_ID_2,
            accountData: accounts2
        });

        // FERT_ID_3 holders
        BarnPayback.AccountFertilizerData[]
            memory accounts3 = new BarnPayback.AccountFertilizerData[](1);
        accounts3[0] = BarnPayback.AccountFertilizerData({
            account: user3,
            amount: 25,
            lastBpf: INITIAL_BPF
        });

        fertilizerData[2] = BarnPayback.Fertilizers({
            fertilizerId: FERT_ID_3,
            accountData: accounts3
        });

        return fertilizerData;
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
}

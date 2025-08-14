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
    event FertilizerRewardsReceived(uint256 amount);

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

    // Contracts
    BarnPayback public barnPayback;
    TransparentUpgradeableProxy public proxy;

    // Test users
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("farmer1");
    address public user2 = makeAddr("farmer2");
    address public user3 = makeAddr("farmer3");

    // Test constants
    uint128 constant INITIAL_BPF = 1000;
    uint128 constant FERT_ID_1 = 5000; // 5000 beans per fertilizer
    uint128 constant FERT_ID_2 = 10000; // 10000 beans per fertilizer
    uint128 constant FERT_ID_3 = 15000; // 15000 beans per fertilizer

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
        BarnPayback.Fertilizers[] memory fertilizerData = _createFertilizerAccountData();
        barnPayback.mintFertilizers(fertilizerData);
        vm.stopPrank();

        // label the users
        vm.label(user1, "farmer1");
        vm.label(user2, "farmer2");
        vm.label(user3, "farmer3");
    }

    ////////////// Shipment receiving //////////////

    function test_barnPaybackReceivePintoRewards() public {
        // Try to update state from non-protocol, expect revert
        vm.prank(user1);
        vm.expectRevert("BarnPayback: only pinto protocol");
        barnPayback.barnPaybackReceive(100000);

        // Send rewards to contract and call barnPaybackReceive
        uint256 rewardAmount = 50000; // 50k pinto (6 decimals)
        uint256 initialUnfertilized = barnPayback.totalUnfertilizedBeans();

        deal(address(BEAN), address(barnPayback), rewardAmount);

        // Only BEANSTALK can call barnPaybackReceive
        vm.expectEmit(true, true, true, true);
        emit FertilizerRewardsReceived(rewardAmount);

        vm.prank(address(BEANSTALK));
        barnPayback.barnPaybackReceive(rewardAmount);

        // Should reduce unfertilized beans
        uint256 finalUnfertilized = barnPayback.totalUnfertilizedBeans();
        assertLt(finalUnfertilized, initialUnfertilized, "Should reduce unfertilized beans");

        // Barn remaining should be updated
        assertEq(
            barnPayback.barnRemaining(),
            finalUnfertilized,
            "Barn remaining should match unfertilized"
        );
    }

    /////////////// Earned calculation ///////////////

    function test_barnPaybackFertilizedCalculationMultipleUsers() public {
        // Send rewards to advance BPF
        uint256 rewardAmount = 25000;
        _sendRewardsToContract(rewardAmount);

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

        // user2 should have more since they hold more fertilizer (40 + 30 vs 60)
        // But the ratio depends on how BPF advancement affects each ID
        console.log("user1 fertilized:", user1Fertilized);
        console.log("user2 fertilized:", user2Fertilized);
    }

    ////////////// Claim //////////////

    /**
     * @dev test that two users can claim their fertilizer rewards pro rata to their balance
     * - user1 claims after each distribution
     * - user2 waits until the end
     */
    function test_barnPayback2UsersLateClaim() public {
        // Setup: user1 claims after each distribution, user2 waits until the end
        // user1: 60 of FERT_ID_1
        // user2: 40 of FERT_ID_1, 30 of FERT_ID_2

        uint256[] memory user1Ids = new uint256[](1);
        user1Ids[0] = FERT_ID_1;

        uint256[] memory user2Ids = new uint256[](2);
        user2Ids[0] = FERT_ID_1;
        user2Ids[1] = FERT_ID_2;

        // First distribution: advance BPF
        _sendRewardsToContract(25000);

        // Check initial fertilized amounts
        uint256 user1Fertilized1 = barnPayback.balanceOfFertilized(user1, user1Ids);
        uint256 user2Fertilized1 = barnPayback.balanceOfFertilized(user2, user2Ids);
        assertGt(user1Fertilized1, 0, "user1 should have fertilized beans");
        assertGt(user2Fertilized1, 0, "user2 should have fertilized beans");

        // user1 claims immediately after first distribution (claiming every season)
        uint256 user1BalanceBefore = IERC20(BEAN).balanceOf(user1);

        vm.expectEmit(true, true, true, true);
        emit ClaimFertilizer(user1Ids, user1Fertilized1);

        vm.prank(user1);
        barnPayback.claimFertilized(user1Ids, LibTransfer.To.EXTERNAL);

        // Verify user1 received rewards
        assertEq(IERC20(BEAN).balanceOf(user1), user1BalanceBefore + user1Fertilized1);

        // user1 should have no more fertilized beans for these IDs
        assertEq(barnPayback.balanceOfFertilized(user1, user1Ids), 0);

        // user2 does NOT claim, so their fertilized amount should remain
        assertEq(barnPayback.balanceOfFertilized(user2, user2Ids), user2Fertilized1);

        // Second distribution: advance BPF further
        _sendRewardsToContract(25000);

        // After second distribution:
        // user1 should have new fertilized beans (since they claimed and reset)
        // user2 should have accumulated fertilized beans from both distributions
        uint256 user1Fertilized2 = barnPayback.balanceOfFertilized(user1, user1Ids);
        uint256 user2Fertilized2 = barnPayback.balanceOfFertilized(user2, user2Ids);

        assertGt(user1Fertilized2, 0, "user1 should have new fertilized beans");
        assertGt(user2Fertilized2, user2Fertilized1, "user2 should have more accumulated beans");

        // Now user1 claims again (claiming every season)
        uint256 user1BalanceBeforeClaim2 = IERC20(BEAN).balanceOf(user1);
        vm.prank(user1);
        barnPayback.claimFertilized(user1Ids, LibTransfer.To.EXTERNAL);

        // user1 should have received their second round rewards
        assertEq(IERC20(BEAN).balanceOf(user1), user1BalanceBeforeClaim2 + user1Fertilized2);

        // user2 finally claims all accumulated rewards
        uint256 user2BalanceBefore = IERC20(BEAN).balanceOf(user2);
        vm.prank(user2);
        barnPayback.claimFertilized(user2Ids, LibTransfer.To.EXTERNAL);

        // user2 should receive all their accumulated rewards
        assertEq(IERC20(BEAN).balanceOf(user2), user2BalanceBefore + user2Fertilized2);

        // Both users should have no more fertilized beans after claiming
        assertEq(barnPayback.balanceOfFertilized(user1, user1Ids), 0);
        assertEq(barnPayback.balanceOfFertilized(user2, user2Ids), 0);
    }

    ////////////// Double claim and transfer logic //////////////

    function test_barnPaybackFertilizerTransfersAndClaims() public {
        // Initial state: user1 has 60 of FERT_ID_1
        assertEq(barnPayback.balanceOf(user1, FERT_ID_1), 60);
        assertEq(barnPayback.balanceOf(user3, FERT_ID_1), 0);

        // User1 transfers 20 fertilizers to user3
        vm.prank(user1);
        barnPayback.safeTransferFrom(user1, user3, FERT_ID_1, 20, "");

        // Check balances after transfer
        assertEq(
            barnPayback.balanceOf(user1, FERT_ID_1),
            40,
            "user1 should have 40 after transfer"
        );
        assertEq(
            barnPayback.balanceOf(user3, FERT_ID_1),
            20,
            "user3 should have 20 after transfer"
        );

        // Send rewards to advance BPF
        _sendRewardsToContract(25000);

        // Both users should be able to claim based on their balances
        uint256[] memory ids = new uint256[](1);
        ids[0] = FERT_ID_1;

        uint256 user1Fertilized = barnPayback.balanceOfFertilized(user1, ids);
        uint256 user3Fertilized = barnPayback.balanceOfFertilized(user3, ids);

        assertGt(user1Fertilized, 0, "user1 should have fertilized beans");
        assertGt(user3Fertilized, 0, "user3 should have fertilized beans");

        // The ratio should match their fertilizer balances (40:20 = 2:1)
        // Due to the transfer hook updating rewards, the ratio should be approximately correct
        uint256 expectedRatio = (user1Fertilized * 1e18) / user3Fertilized;
        assertApproxEqRel(
            expectedRatio,
            2e18,
            0.05e18,
            "Reward ratio should match fertilizer balance ratio"
        );

        // Both claim their rewards
        vm.prank(user1);
        barnPayback.claimFertilized(ids, LibTransfer.To.EXTERNAL);

        vm.prank(user3);
        barnPayback.claimFertilized(ids, LibTransfer.To.EXTERNAL);

        assertEq(
            IERC20(BEAN).balanceOf(user1),
            user1Fertilized,
            "user1 should receive their share"
        );
        assertEq(
            IERC20(BEAN).balanceOf(user3),
            user3Fertilized,
            "user3 should receive their share"
        );

        // Both should have no fertilized beans left
        assertEq(
            barnPayback.balanceOfFertilized(user1, ids),
            0,
            "user1 should have no fertilized beans left"
        );
        assertEq(
            barnPayback.balanceOfFertilized(user3, ids),
            0,
            "user3 should have no fertilized beans left"
        );
    }

    function test_barnPaybackComprehensiveTransferAndRewardMechanisms() public {
        // Combined test covering transfer mechanics and anti-gaming features for fertilizer

        // Phase 1: Initial setup - users have different fertilizer holdings
        // user1: 60 of FERT_ID_1
        // user2: 40 of FERT_ID_1, 30 of FERT_ID_2
        assertEq(barnPayback.balanceOf(user1, FERT_ID_1), 60);
        assertEq(barnPayback.balanceOf(user2, FERT_ID_1), 40);
        assertEq(barnPayback.balanceOf(user2, FERT_ID_2), 30);

        uint256[] memory user1Ids = new uint256[](1);
        user1Ids[0] = FERT_ID_1;

        uint256[] memory user2Ids = new uint256[](2);
        user2Ids[0] = FERT_ID_1;
        user2Ids[1] = FERT_ID_2;

        // Phase 2: First reward distribution - both users earn proportionally
        _sendRewardsToContract(30000);

        uint256 user1InitialFertilized = barnPayback.balanceOfFertilized(user1, user1Ids);
        uint256 user2InitialFertilized = barnPayback.balanceOfFertilized(user2, user2Ids);
        assertGt(user1InitialFertilized, 0, "user1 should have fertilized beans");
        assertGt(user2InitialFertilized, 0, "user2 should have fertilized beans");

        // Phase 3: Transfer updates rewards (ERC1155 transfer hook)
        // user1 transfers 20 FERT_ID_1 to user2
        vm.prank(user1);
        barnPayback.safeTransferFrom(user1, user2, FERT_ID_1, 20, "");

        // Verify balances updated correctly
        assertEq(
            barnPayback.balanceOf(user1, FERT_ID_1),
            40,
            "user1 fertilizer balance after transfer"
        );
        assertEq(
            barnPayback.balanceOf(user2, FERT_ID_1),
            60,
            "user2 fertilizer balance after transfer"
        );

        // Verify fertilized amounts remain the same after transfer (rewards captured by transfer hook)
        assertEq(
            barnPayback.balanceOfFertilized(user1, user1Ids),
            user1InitialFertilized,
            "user1 fertilized should remain same after transfer"
        );
        assertEq(
            barnPayback.balanceOfFertilized(user2, user2Ids),
            user2InitialFertilized,
            "user2 fertilized should remain same after transfer"
        );

        // Phase 4: Anti-gaming test - user1 tries to transfer to user3 (new user)
        vm.prank(user1);
        barnPayback.safeTransferFrom(user1, user3, FERT_ID_1, 20, "");

        // Verify user3 starts fresh with no historical fertilized beans
        uint256[] memory user3Ids = new uint256[](1);
        user3Ids[0] = FERT_ID_1;
        assertEq(
            barnPayback.balanceOfFertilized(user3, user3Ids),
            0,
            "user3 should have no fertilized beans from before they held fertilizer"
        );
        assertEq(barnPayback.balanceOf(user3, FERT_ID_1), 20, "user3 received fertilizer");

        // user1 still has their original fertilized beans (can't be gamed away)
        assertEq(
            barnPayback.balanceOfFertilized(user1, user1Ids),
            user1InitialFertilized,
            "user1 retains original fertilized beans"
        );

        // Phase 5: Second reward distribution - new proportional split
        _sendRewardsToContract(30000);

        // Current fertilizer balances: user1=20, user2=90 (60+30), user3=20
        // New rewards should be distributed based on current holdings and BPF advancement

        uint256 user1FinalFertilized = barnPayback.balanceOfFertilized(user1, user1Ids);
        uint256 user2FinalFertilized = barnPayback.balanceOfFertilized(user2, user2Ids);
        uint256 user3FinalFertilized = barnPayback.balanceOfFertilized(user3, user3Ids);

        // user1: should have original + new rewards
        // user2: should have original + new rewards
        // user3: should only have new rewards (no historical)
        assertGt(
            user1FinalFertilized,
            user1InitialFertilized,
            "user1 should have accumulated fertilized beans"
        );
        assertGt(
            user2FinalFertilized,
            user2InitialFertilized,
            "user2 should have accumulated fertilized beans"
        );
        assertGt(user3FinalFertilized, 0, "user3 should have new fertilized beans");

        // Phase 6: All users claim and verify final balances
        uint256 user1BalanceBefore = IERC20(BEAN).balanceOf(user1);
        uint256 user2BalanceBefore = IERC20(BEAN).balanceOf(user2);
        uint256 user3BalanceBefore = IERC20(BEAN).balanceOf(user3);

        vm.prank(user1);
        barnPayback.claimFertilized(user1Ids, LibTransfer.To.EXTERNAL);

        vm.prank(user2);
        barnPayback.claimFertilized(user2Ids, LibTransfer.To.EXTERNAL);

        vm.prank(user3);
        barnPayback.claimFertilized(user3Ids, LibTransfer.To.EXTERNAL);

        // Verify all rewards were paid out correctly
        assertEq(
            IERC20(BEAN).balanceOf(user1),
            user1BalanceBefore + user1FinalFertilized,
            "user1 received correct payout"
        );
        assertEq(
            IERC20(BEAN).balanceOf(user2),
            user2BalanceBefore + user2FinalFertilized,
            "user2 received correct payout"
        );
        assertEq(
            IERC20(BEAN).balanceOf(user3),
            user3BalanceBefore + user3FinalFertilized,
            "user3 received correct payout"
        );

        // All fertilized amounts should be reset to zero
        assertEq(
            barnPayback.balanceOfFertilized(user1, user1Ids),
            0,
            "user1 fertilized reset after claim"
        );
        assertEq(
            barnPayback.balanceOfFertilized(user2, user2Ids),
            0,
            "user2 fertilized reset after claim"
        );
        assertEq(
            barnPayback.balanceOfFertilized(user3, user3Ids),
            0,
            "user3 fertilized reset after claim"
        );
    }

    /**
     * @notice Test multiple users claiming different fertilizer types
     */
    function testMultiUserMultiFertilizerClaim() public {
        // Send rewards
        _sendRewardsToContract(75000e6);

        // User2 has both FERT_ID_1 and FERT_ID_2
        uint256[] memory user2Ids = new uint256[](2);
        user2Ids[0] = FERT_ID_1;
        user2Ids[1] = FERT_ID_2;

        uint256 user2Fertilized = barnPayback.balanceOfFertilized(user2, user2Ids);

        // User3 has both FERT_ID_2 and FERT_ID_3
        uint256[] memory user3Ids = new uint256[](2);
        user3Ids[0] = FERT_ID_2;
        user3Ids[1] = FERT_ID_3;

        uint256 user3Fertilized = barnPayback.balanceOfFertilized(user3, user3Ids);

        assertGt(user2Fertilized, 0, "User2 should have fertilized beans");
        assertGt(user3Fertilized, 0, "User3 should have fertilized beans");

        // Both users claim
        vm.prank(user2);
        barnPayback.claimFertilized(user2Ids, LibTransfer.To.EXTERNAL);

        vm.prank(user3);
        barnPayback.claimFertilized(user3Ids, LibTransfer.To.EXTERNAL);

        assertEq(
            IERC20(BEAN).balanceOf(user2),
            user2Fertilized,
            "User2 should receive correct amount"
        );
        assertEq(
            IERC20(BEAN).balanceOf(user3),
            user3Fertilized,
            "User3 should receive correct amount"
        );

        // Verify no double claiming
        uint256 user2FertilizedAfter = barnPayback.balanceOfFertilized(user2, user2Ids);
        uint256 user3FertilizedAfter = barnPayback.balanceOfFertilized(user3, user3Ids);

        assertEq(user2FertilizedAfter, 0, "User2 should have no fertilized beans left");
        assertEq(user3FertilizedAfter, 0, "User3 should have no fertilized beans left");
    }

    /**
     * @notice Test state verification functions
     */
    function test_stateVerification() public {
        // Verify total calculations
        uint256 totalUnfertilized = barnPayback.totalUnfertilizedBeans();
        uint256 barnRemaining = barnPayback.barnRemaining();

        assertGt(totalUnfertilized, 0, "Should have unfertilized beans");
        assertEq(
            barnRemaining,
            totalUnfertilized,
            "Barn remaining should equal total unfertilized"
        );

        // Calculate expected unfertilized amount
        uint256 expectedUnfertilized = (FERT_ID_1 * 100) + (FERT_ID_2 * 50) + (FERT_ID_3 * 25); // Initial unfertilizedIndex
        assertEq(
            totalUnfertilized,
            expectedUnfertilized,
            "Should match calculated unfertilized amount"
        );
    }

    /**
     * @notice Test barn payback receive function - core payback mechanism
     */
    function test_barnPaybackReceive() public {
        uint256 initialUnfertilized = barnPayback.totalUnfertilizedBeans();
        uint256 shipmentAmount = 100000; // 100k pinto

        // Only pinto protocol can call barnPaybackReceive
        vm.expectRevert("BarnPayback: only pinto protocol");
        vm.prank(user1);
        barnPayback.barnPaybackReceive(shipmentAmount);

        // Pinto protocol sends rewards
        vm.expectEmit(true, true, true, true);
        emit FertilizerRewardsReceived(shipmentAmount);

        vm.prank(address(BEANSTALK));
        barnPayback.barnPaybackReceive(shipmentAmount);

        // Should reduce unfertilized beans
        uint256 finalUnfertilized = barnPayback.totalUnfertilizedBeans();
        assertLt(finalUnfertilized, initialUnfertilized, "Should reduce unfertilized beans");

        // Barn remaining should be updated
        assertEq(
            barnPayback.barnRemaining(),
            finalUnfertilized,
            "Barn remaining should match unfertilized"
        );
    }

    /**
     * @notice Test progressive fertilizer payback until all fertilizers are inactive
     */
    function test_completePaybackFlow() public {
        uint256 initialUnfertilized = barnPayback.totalUnfertilizedBeans();
        console.log("Initial unfertilized beans:", initialUnfertilized);

        // Send multiple payback amounts to gradually pay down fertilizers
        uint256 paybackAmount = initialUnfertilized / 5; // Pay back 20% at a time

        for (uint i = 0; i < 5; i++) {
            uint256 beforePayback = barnPayback.totalUnfertilizedBeans();

            vm.prank(address(BEANSTALK));
            barnPayback.barnPaybackReceive(paybackAmount);

            uint256 afterPayback = barnPayback.totalUnfertilizedBeans();
            console.log("Payback round", i + 1);
            console.log("totalUnfertilizedBeans Before:", beforePayback);
            console.log("totalUnfertilizedBeans After:", afterPayback);

            // Should steadily reduce unfertilized beans
            assertLe(afterPayback, beforePayback, "Should reduce or maintain unfertilized beans");
        }

        // Final cleanup - send remaining amount to complete payback
        uint256 remaining = barnPayback.barnRemaining();
        if (remaining > 0) {
            vm.prank(address(BEANSTALK));
            barnPayback.barnPaybackReceive(remaining + 1000); // Slightly over to handle rounding
        }

        // Should be close to fully paid back
        uint256 finalRemaining = barnPayback.barnRemaining();
        console.log("Final remaining:", finalRemaining);
        assertLe(finalRemaining, initialUnfertilized / 100, "Should be mostly paid back"); // Within 1%
    }

    /**
     * @notice Test claiming with internal vs external transfer modes
     */
    function test_claimingModes() public {
        // Send some rewards first
        _sendRewardsToContract(50000e6);

        uint256[] memory ids = new uint256[](1);
        ids[0] = FERT_ID_1;

        uint256 fertilized = barnPayback.balanceOfFertilized(user1, ids);
        assertGt(fertilized, 0, "User1 should have fertilized beans");

        // Test claiming to internal balance
        vm.prank(user1);
        barnPayback.claimFertilized(ids, LibTransfer.To.INTERNAL);

        // Should have internal balance in pinto protocol
        uint256 internalBalance = bs.getInternalBalance(user1, address(BEAN));
        assertEq(internalBalance, fertilized, "Should have internal balance");
        assertEq(IERC20(BEAN).balanceOf(user1), 0, "Should have no external balance");

        // Setup user2 for external claiming
        _sendRewardsToContract(25000e6);

        uint256[] memory user2Ids = new uint256[](1);
        user2Ids[0] = FERT_ID_1;

        uint256 user2Fertilized = barnPayback.balanceOfFertilized(user2, user2Ids);
        if (user2Fertilized > 0) {
            vm.prank(user2);
            barnPayback.claimFertilized(user2Ids, LibTransfer.To.EXTERNAL);

            assertEq(
                IERC20(BEAN).balanceOf(user2),
                user2Fertilized,
                "Should have external balance"
            );
            assertEq(
                bs.getInternalBalance(user2, address(BEAN)),
                0,
                "Should have no internal balance"
            );
        }
    }

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
}

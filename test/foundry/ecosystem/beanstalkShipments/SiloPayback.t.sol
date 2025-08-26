// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {SiloPayback} from "contracts/ecosystem/beanstalkShipments/SiloPayback.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SiloPaybackTest is TestHelper {
    // Events
    event TokenHookCalled(address indexed token, address indexed target, bytes4 selector);

    SiloPayback public siloPayback;
    MockToken public pintoToken;

    // Test users
    address public farmer1 = makeAddr("farmer1");
    address public farmer2 = makeAddr("farmer2");
    address public farmer3 = makeAddr("farmer3");
    address public owner = makeAddr("owner");

    // Constants for testing
    uint256 constant TOKEN_DECIMALS = 6;
    uint256 constant PINTO_DECIMALS = 6;
    uint256 constant PRECISION = 1e18;
    uint256 constant INITIAL_MINT_AMOUNT = 1000e6; // 1000 tokens with 6 decimals

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // Deploy implementation contract
        SiloPayback siloPaybackImpl = new SiloPayback();

        // Encode initialization data
        vm.startPrank(owner);
        bytes memory data = abi.encodeWithSelector(
            SiloPayback.initialize.selector,
            address(BEAN),
            address(BEANSTALK)
        );

        // Deploy proxy contract
        TransparentUpgradeableProxy siloPaybackProxy = new TransparentUpgradeableProxy(
            address(siloPaybackImpl), // implementation
            owner, // initial owner
            data // initialization data
        );

        vm.stopPrank();

        // set the silo payback proxy
        siloPayback = SiloPayback(address(siloPaybackProxy));

        // whitelist the pre-transfer token hook
        vm.prank(deployer);
        bs.whitelistTokenHook(
            address(siloPayback),
            IMockFBeanstalk.TokenHook({
                target: address(siloPayback),
                selector: siloPayback.protocolUpdate.selector,
                encodeType: 0x00
            })
        );

        vm.label(farmer1, "farmer1");
        vm.label(farmer2, "farmer2");
        vm.label(farmer3, "farmer3");
        vm.label(owner, "owner");
        vm.label(address(siloPayback), "SiloPaybackProxy");
    }

    ////////////// Shipment receiving //////////////

    function test_siloPaybackReceivePintoRewards() public {
        // mint 400e6 and 600e6 to farmer1 and farmer2
        address[] memory recipients = new address[](2);
        recipients[0] = farmer1;
        recipients[1] = farmer2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 400e6;
        amounts[1] = 600e6;
        _mintTokensToUsers(recipients, amounts);

        // try to update state from non protocol, expect revert
        vm.prank(farmer1);
        vm.expectRevert();
        siloPayback.siloPaybackReceive(100e6);

        // Send rewards to contract and call receiveRewards
        uint256 rewardAmount = 100e6; // 10% of total supply
        _sendRewardsToContract(rewardAmount);
        uint256 expectedRewardPerToken = (rewardAmount * PRECISION) / siloPayback.totalSupply();
        console.log("expectedRewardPerToken: ", expectedRewardPerToken);

        // Check global reward state updated correctly
        assertEq(siloPayback.rewardPerTokenStored(), expectedRewardPerToken);
        assertEq(siloPayback.totalReceived(), rewardAmount);

        // check that total remaining is totalSupply - totalReceived (1000e6 - 100e6)
        assertEq(siloPayback.siloRemaining(), 900e6);
    }

    /////////////// Earned calculation ///////////////

    function test_siloPaybackEarnedCalculationMultipleUsers() public {
        // Mint tokens: farmer1 40%, farmer2 60%
        _mintTokensToUser(farmer1, 400e6, LibTransfer.To.EXTERNAL);
        _mintTokensToUser(farmer2, 600e6, LibTransfer.To.EXTERNAL);

        // Send rewards
        uint256 rewardAmount = 150e6;
        _sendRewardsToContract(rewardAmount);

        // Check proportional rewards
        assertEq(siloPayback.earned(farmer1), 60e6); // 40% of 150
        assertEq(siloPayback.earned(farmer2), 90e6); // 60% of 150

        // Total should equal reward amount
        assertEq(siloPayback.earned(farmer1) + siloPayback.earned(farmer2), rewardAmount);
    }

    ////////////// Claim //////////////

    /**
     * @dev test that two users can claim their rewards pro rata to their combined balance
     * - farmer1 claims after each distribution
     * - farmer2 waits until the end
     */
    function test_siloPayback2UsersLateFullClaim() public {
        // Setup: farmer1 claims after each distribution, farmer2 waits until the end
        _mintTokensToUser(farmer1, 400e6, LibTransfer.To.EXTERNAL); // farmer1 has 40%
        _mintTokensToUser(farmer2, 600e6, LibTransfer.To.EXTERNAL); // farmer2 has 60%

        // First distribution: 100 BEAN rewards
        _sendRewardsToContract(100e6);

        // Check initial earned amounts
        uint256 farmer1Earned1 = siloPayback.earned(farmer1); // 40% of 100 = 40
        uint256 farmer2Earned1 = siloPayback.earned(farmer2); // 60% of 100 = 60
        assertEq(farmer1Earned1, 40e6);
        assertEq(farmer2Earned1, 60e6);

        // farmer1 claims immediately after first distribution (claiming every season)
        uint256 farmer1BalanceBefore = IERC20(BEAN).balanceOf(farmer1);
        vm.prank(farmer1);
        siloPayback.claim(farmer1, LibTransfer.To.EXTERNAL);

        // Verify farmer1 received rewards and state is updated
        assertEq(IERC20(BEAN).balanceOf(farmer1), farmer1BalanceBefore + farmer1Earned1);
        assertEq(siloPayback.earned(farmer1), 0);
        assertEq(siloPayback.rewards(farmer1), 0);
        assertEq(siloPayback.userRewardPerTokenPaid(farmer1), siloPayback.rewardPerTokenStored());

        // farmer2 does NOT claim, so their rewards should remain
        assertEq(siloPayback.earned(farmer2), farmer2Earned1);

        // Second distribution: 200 BEAN rewards
        _sendRewardsToContract(200e6);

        // After second distribution:
        // farmer1 should earn 40% of new 200 = 80 BEAN (since they claimed and reset)
        // farmer2 should have 60 (from first) + 60% of 200 = 60 + 120 = 180 BEAN total
        uint256 farmer1Earned2 = siloPayback.earned(farmer1);
        uint256 farmer2Earned2 = siloPayback.earned(farmer2);

        assertEq(farmer1Earned2, 80e6, "farmer1 should earn 40% of second distribution");
        assertEq(
            farmer2Earned2,
            180e6,
            "farmer2 should have accumulated rewards from both distributions"
        );

        // Now farmer1 claims again (claiming every season)
        uint256 farmer1BalanceBeforeClaim2 = IERC20(BEAN).balanceOf(farmer1);
        vm.prank(farmer1);
        siloPayback.claim(farmer1, LibTransfer.To.EXTERNAL);

        // farmer1 should have received their second round rewards
        assertEq(IERC20(BEAN).balanceOf(farmer1), farmer1BalanceBeforeClaim2 + farmer1Earned2);
        assertEq(siloPayback.earned(farmer1), 0);

        // farmer2 finally claims all accumulated rewards
        uint256 farmer2BalanceBefore = IERC20(BEAN).balanceOf(farmer2);
        vm.prank(farmer2);
        siloPayback.claim(farmer2, LibTransfer.To.EXTERNAL);

        // farmer2 should receive all their accumulated rewards
        assertEq(IERC20(BEAN).balanceOf(farmer2), farmer2BalanceBefore + farmer2Earned2);
        assertEq(siloPayback.earned(farmer2), 0);
    }

    /**
     * @dev test that two users can claim their rewards to their internal balance
     */
    function test_siloPaybackFullClaimToInternalBalance2Users() public {
        // Simple test: Both farmers claim rewards to their internal balance
        _mintTokensToUser(farmer1, 600e6, LibTransfer.To.EXTERNAL); // 60%
        _mintTokensToUser(farmer2, 400e6, LibTransfer.To.EXTERNAL); // 40%

        // Distribute rewards
        uint256 rewardAmount = 150e6;
        _sendRewardsToContract(rewardAmount);

        uint256 farmer1Earned = siloPayback.earned(farmer1); // 90 BEAN (60%)
        uint256 farmer2Earned = siloPayback.earned(farmer2); // 60 BEAN (40%)
        assertEq(farmer1Earned, 90e6);
        assertEq(farmer2Earned, 60e6);

        // Get initial internal balances
        uint256 farmer1InternalBefore = bs.getInternalBalance(farmer1, address(BEAN));
        uint256 farmer2InternalBefore = bs.getInternalBalance(farmer2, address(BEAN));

        // Both farmers claim to INTERNAL balance
        vm.prank(farmer1);
        siloPayback.claim(farmer1, LibTransfer.To.INTERNAL);

        vm.prank(farmer2);
        siloPayback.claim(farmer2, LibTransfer.To.INTERNAL);

        // Verify both farmers' rewards went to internal balance
        uint256 farmer1InternalAfter = bs.getInternalBalance(farmer1, address(BEAN));
        uint256 farmer2InternalAfter = bs.getInternalBalance(farmer2, address(BEAN));

        assertEq(
            farmer1InternalAfter,
            farmer1InternalBefore + farmer1Earned,
            "farmer1 internal balance should increase by earned amount"
        );
        assertEq(
            farmer2InternalAfter,
            farmer2InternalBefore + farmer2Earned,
            "farmer2 internal balance should increase by earned amount"
        );

        // Both users should have zero earned rewards after claiming
        assertEq(siloPayback.earned(farmer1), 0, "farmer1 earned should reset after claim");
        assertEq(siloPayback.earned(farmer2), 0, "farmer2 earned should reset after claim");

        // Verify total internal balance increases equal total distributed rewards
        uint256 totalInternalIncrease = (farmer1InternalAfter - farmer1InternalBefore) +
            (farmer2InternalAfter - farmer2InternalBefore);
        assertEq(
            totalInternalIncrease,
            rewardAmount,
            "Total internal balance increase should equal total distributed rewards"
        );
    }

    ////////////// Double claim and transfer logic //////////////

    function test_siloPaybackDoubleClaimAndExternalTransferNoClaiming() public {
        // Step 1: Setup users with different token amounts
        _mintTokensToUser(farmer1, 600e6, LibTransfer.To.EXTERNAL); // 60% ownership
        _mintTokensToUser(farmer2, 400e6, LibTransfer.To.EXTERNAL); // 40% ownership

        // Step 2: First reward distribution - both users earn proportionally
        _sendRewardsToContract(150e6);

        uint256 farmer1InitialEarned = siloPayback.earned(farmer1); // 90 BEAN (60%)
        uint256 farmer2InitialEarned = siloPayback.earned(farmer2); // 60 BEAN (40%)
        assertEq(farmer1InitialEarned, 90e6, "farmer1 should earn 60% of first distribution");
        assertEq(farmer2InitialEarned, 60e6, "farmer2 should earn 40% of first distribution");

        // Step 3: Transfer updates rewards (prevents gaming through checkpoint sync)
        uint256 farmer1PreTransferCheckpoint = siloPayback.userRewardPerTokenPaid(farmer1);
        uint256 farmer2PreTransferCheckpoint = siloPayback.userRewardPerTokenPaid(farmer2);

        // farmer1 transfers 200 tokens to farmer2
        vm.prank(farmer1);
        siloPayback.transfer(farmer2, 200e6);

        // Verify that transfer hook captured earned rewards and updated checkpoints
        assertEq(
            siloPayback.rewards(farmer1),
            farmer1InitialEarned,
            "farmer1 rewards should be captured in storage"
        );
        assertEq(
            siloPayback.rewards(farmer2),
            farmer2InitialEarned,
            "farmer2 rewards should be captured in storage"
        );
        assertEq(
            siloPayback.userRewardPerTokenPaid(farmer1),
            siloPayback.rewardPerTokenStored(),
            "farmer1 checkpoint updated"
        );
        assertEq(
            siloPayback.userRewardPerTokenPaid(farmer2),
            siloPayback.rewardPerTokenStored(),
            "farmer2 checkpoint updated"
        );

        // Verify that earned amounts remain the same after transfer (no double counting)
        assertEq(
            siloPayback.earned(farmer1),
            farmer1InitialEarned,
            "farmer1 earned should remain same after transfer"
        );
        assertEq(
            siloPayback.earned(farmer2),
            farmer2InitialEarned,
            "farmer2 earned should remain same after transfer"
        );

        // Verify that token balances updated correctly
        assertEq(siloPayback.balanceOf(farmer1), 400e6, "farmer1 balance after transfer");
        assertEq(siloPayback.balanceOf(farmer2), 600e6, "farmer2 balance after transfer");

        // Step 4: farmer1 tries to double claim by transferring to farmer3 (new user)
        vm.prank(farmer1);
        siloPayback.transfer(farmer3, 200e6);

        // Verify that farmer3 starts fresh with no previous rewards
        assertEq(
            siloPayback.earned(farmer3),
            0,
            "farmer3 should have no rewards from before they held tokens"
        );
        assertEq(
            siloPayback.userRewardPerTokenPaid(farmer3),
            siloPayback.rewardPerTokenStored(),
            "farmer3 synced to current state"
        );
        assertEq(siloPayback.balanceOf(farmer3), 200e6, "farmer3 received tokens");

        // farmer1 still has their original earned rewards
        assertEq(
            siloPayback.earned(farmer1),
            farmer1InitialEarned,
            "farmer1 retains original rewards"
        );

        // Step 5: Second reward distribution - new proportional split
        _sendRewardsToContract(300e6);

        // Current balances: farmer1=200, farmer2=600, farmer3=200 (total=1000)
        // New rewards: 300 BEAN should be split: 20%, 60%, 20%

        uint256 farmer1FinalEarned = siloPayback.earned(farmer1); // 90 (original) + 60 (20% of 300)
        uint256 farmer2FinalEarned = siloPayback.earned(farmer2); // 60 (original) + 180 (60% of 300)
        uint256 farmer3FinalEarned = siloPayback.earned(farmer3); // 0 (original) + 60 (20% of 300)

        assertEq(farmer1FinalEarned, 150e6, "farmer1: 90 original + 60 new rewards");
        assertEq(farmer2FinalEarned, 240e6, "farmer2: 60 original + 180 new rewards");
        assertEq(farmer3FinalEarned, 60e6, "farmer3: 0 original + 60 new rewards");

        // Step 6: Verify total conservation - no rewards lost or duplicated
        uint256 totalEarned = farmer1FinalEarned + farmer2FinalEarned + farmer3FinalEarned;
        uint256 totalDistributed = 150e6 + 300e6; // 450 total
        assertEq(totalEarned, totalDistributed, "Total earned must equal total distributed");

        // Step 7: All users claim and verify final balances
        uint256 farmer1BalanceBefore = IERC20(BEAN).balanceOf(farmer1);
        uint256 farmer2BalanceBefore = IERC20(BEAN).balanceOf(farmer2);
        uint256 farmer3BalanceBefore = IERC20(BEAN).balanceOf(farmer3);

        // Claim for all users
        vm.prank(farmer1);
        siloPayback.claim(farmer1, LibTransfer.To.EXTERNAL);

        vm.prank(farmer2);
        siloPayback.claim(farmer2, LibTransfer.To.EXTERNAL);

        vm.prank(farmer3);
        siloPayback.claim(farmer3, LibTransfer.To.EXTERNAL);

        // Verify all rewards were paid out correctly
        assertEq(
            IERC20(BEAN).balanceOf(farmer1),
            farmer1BalanceBefore + farmer1FinalEarned,
            "farmer1 received correct payout"
        );
        assertEq(
            IERC20(BEAN).balanceOf(farmer2),
            farmer2BalanceBefore + farmer2FinalEarned,
            "farmer2 received correct payout"
        );
        assertEq(
            IERC20(BEAN).balanceOf(farmer3),
            farmer3BalanceBefore + farmer3FinalEarned,
            "farmer3 received correct payout"
        );

        // Contract should be empty after all claims
        assertEq(
            IERC20(BEAN).balanceOf(address(siloPayback)),
            0,
            "Contract should have no remaining BEAN"
        );

        // All earned amounts should be reset to zero
        assertEq(siloPayback.earned(farmer1), 0, "farmer1 earned reset after claim");
        assertEq(siloPayback.earned(farmer2), 0, "farmer2 earned reset after claim");
        assertEq(siloPayback.earned(farmer3), 0, "farmer3 earned reset after claim");
    }

    /////////////////// Internal Transfer Support With Hook ///////////////////

    /**
     * @dev Internal --> Internal
     * Before the hook: Neither the sender nor the recipient rewards are checkpointed.
     * After the hook: Both the sender and the recipient rewards are checkpointed.
     */
    function test_siloPaybackDoubleClaimInternalToInternalTransfer() public {
        _mintTokensToUser(farmer1, 100e6, LibTransfer.To.INTERNAL); // farmer1 has 50% of total in internal
        _mintTokensToUser(farmer2, 100e6, LibTransfer.To.INTERNAL); // farmer2 has 50% of total in internal

        // distribution
        _sendRewardsToContract(100e6);

        // get the state of rewards pre-internal transfer
        // farmer1
        uint256 farmer1Earned = siloPayback.earned(farmer1);
        assertEq(farmer1Earned, 50e6); // 50% of 100
        // farmer2
        uint256 farmer2Earned = siloPayback.earned(farmer2);
        assertEq(farmer2Earned, 50e6); // 50% of 100

        // farmer1 transfers 100 tokens to farmer3 in internal balance
        // internal --> internal transfer
        _transferTokensToUser(
            farmer1,
            farmer2,
            100e6,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );

        // farmer1: 0 external, 0 internal, 50 rewards
        assertEq(siloPayback.getBalanceCombined(farmer1), 0, "farmer1 balance not updated");
        assertEq(siloPayback.earned(farmer1), 50e6, "farmer1 earned should remain the same");

        // farmer2: 0 external, 200 internal, 50 rewards
        // Even though getBalanceCombined is 200e6, and no claims have occured
        // The reward indexes are synced because of the pre transfer hook
        assertEq(siloPayback.getBalanceCombined(farmer2), 200e6, "farmer2 balance not updated");
        assertEq(siloPayback.balanceOf(farmer2), 0, "farmer2 external balance not updated");
        assertEq(siloPayback.earned(farmer2), 50e6, "farmer2 earned should stay the same");
    }

    /**
     * @dev External --> Internal
     * SiloPayback knows the following when doing the ERC20 transfer:
     * - sender = farmer1 | recipient = Pinto Diamond
     * - Without the hook: Sender rewards do get checkpointed but the recipient rewards are not since it is the address of the diamond.
     * - With the hook: Sender rewards do get checkpointed and the recipient rewards are also checkpointed.
     */
    function test_siloPaybackDoubleClaimExternalToInternalTransfer() public {
        _mintTokensToUser(farmer1, 100e6, LibTransfer.To.EXTERNAL); // farmer1 has 50% of total, half in external
        _mintTokensToUser(farmer2, 100e6, LibTransfer.To.EXTERNAL); // farmer2 has 50% of total all in external

        // distribution
        _sendRewardsToContract(100e6);

        // get the state of rewards pre-internal transfer
        // farmer1
        uint256 farmer1Earned = siloPayback.earned(farmer1);
        assertEq(farmer1Earned, 50e6); // 50% of 100
        // farmer2
        uint256 farmer2Earned = siloPayback.earned(farmer2);
        assertEq(farmer2Earned, 50e6); // 50% of 100

        // farmer1 transfers 100 tokens to farmer2 in internal balance
        // external --> internal transfer
        _transferTokensToUser(
            farmer1,
            farmer2,
            100e6,
            LibTransfer.From.EXTERNAL,
            LibTransfer.To.INTERNAL
        );

        // farmer1: 0 external, 0 internal, 0 rewards
        assertEq(siloPayback.getBalanceCombined(farmer1), 0, "farmer1 balance not updated");
        assertEq(siloPayback.earned(farmer1), 50e6, "farmer1 earned should remain the same");

        // farmer2: 100 external, 100 internal, 50 unclaimed rewards
        assertEq(siloPayback.getBalanceCombined(farmer2), 200e6, "farmer2 balance not updated");
        assertEq(siloPayback.balanceOf(farmer2), 100e6, "farmer2 external balance not updated");
        assertEq(siloPayback.earned(farmer2), 50e6, "farmer2 earned should remain the same");
    }

    /**
     * @dev Internal --> External
     * SiloPayback knows the following when doing the ERC20 transfer:
     * - sender = Pinto Diamond | recipient = farmer2
     * - Without the hook: Sender rewards do not get checkpointed since sender is the diamond. Recipient rewards do get checkpointed.
     * - With the hook: Both sender and recipient rewards are checkpointed.
     */
    function test_siloPaybackDoubleClaimInternalToExternalTransfer() public {
        _mintTokensToUser(farmer1, 100e6, LibTransfer.To.INTERNAL); // farmer1 has 50% of total, half in internal
        _mintTokensToUser(farmer2, 100e6, LibTransfer.To.EXTERNAL); // farmer2 has 50% of total all in external

        // distribution
        _sendRewardsToContract(100e6);

        // get the state of rewards pre-internal transfer
        // farmer1
        uint256 farmer1Earned = siloPayback.earned(farmer1);
        assertEq(farmer1Earned, 50e6); // 50% of 100
        // farmer2
        uint256 farmer2Earned = siloPayback.earned(farmer2);
        assertEq(farmer2Earned, 50e6); // 50% of 100

        // farmer1 transfers 100 tokens to farmer2 in external balance
        // internal --> external transfer
        _transferTokensToUser(
            farmer1,
            farmer2,
            100e6,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.EXTERNAL
        );

        // farmer1: 0 external, 0 internal, 50 rewards still unclaimed
        assertEq(siloPayback.getBalanceCombined(farmer1), 0, "farmer1 balance not updated");
        assertEq(siloPayback.earned(farmer1), 50e6, "farmer1 earned should remain the same");

        // farmer2: 200 external, 0 internal, 50 rewards still unclaimed
        // Even though getBalanceCombined is 200e6, and no claims have occured
        // The reward indexes are synced because of the pre transfer hook
        assertEq(siloPayback.balanceOf(farmer2), 200e6, "farmer2 balance not updated");
        assertEq(siloPayback.earned(farmer2), 50e6, "farmer2 earned should remain the same");
    }

    ////////////// HELPER FUNCTIONS //////////////

    function _mintTokensToUsers(address[] memory recipients, uint256[] memory amounts) internal {
        require(recipients.length == amounts.length, "Arrays must have equal length");
        SiloPayback.UnripeBdvTokenData[] memory receipts = new SiloPayback.UnripeBdvTokenData[](
            recipients.length
        );
        for (uint256 i = 0; i < recipients.length; i++) {
            receipts[i] = SiloPayback.UnripeBdvTokenData(recipients[i], amounts[i]);
        }
        vm.prank(owner);
        siloPayback.batchMint(receipts);
    }

    function _mintTokensToUser(address user, uint256 amount, LibTransfer.To toMode) internal {
        SiloPayback.UnripeBdvTokenData[] memory receipts = new SiloPayback.UnripeBdvTokenData[](1);
        receipts[0] = SiloPayback.UnripeBdvTokenData(user, amount);
        vm.prank(owner);
        siloPayback.batchMint(receipts);

        _transferTokensToUser(user, user, amount, LibTransfer.From.EXTERNAL, toMode);
    }

    function _transferTokensToUser(
        address sender,
        address receipient,
        uint256 amount,
        LibTransfer.From fromMode,
        LibTransfer.To toMode
    ) internal {
        vm.startPrank(sender);
        IERC20(address(siloPayback)).approve(address(bs), amount);
        // if from internal and to internal, expect pre transfer hook event to be emitted
        if (fromMode == LibTransfer.From.INTERNAL && toMode == LibTransfer.To.INTERNAL) {
            vm.expectEmit(true, true, true, true);
            emit TokenHookCalled(
                address(siloPayback),
                address(siloPayback),
                siloPayback.protocolUpdate.selector
            );
        }
        bs.transferToken(address(siloPayback), receipient, amount, uint8(fromMode), uint8(toMode));
        vm.stopPrank();
    }

    function _sendRewardsToContract(uint256 amount) internal {
        deal(address(BEAN), address(owner), amount, true);
        // owner transfers BEAN to siloPayback
        // (we use an intermidiary because deal overwrites the balance of the owner)
        vm.prank(owner);
        IERC20(BEAN).transfer(address(siloPayback), amount);

        // Call receiveRewards to update the global state
        vm.prank(BEANSTALK);
        siloPayback.siloPaybackReceive(amount);
    }
}

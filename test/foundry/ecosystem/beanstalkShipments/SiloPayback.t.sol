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

    event Claimed(address indexed user, uint256 amount, uint256 rewards);
    event RewardsReceived(uint256 amount, uint256 newIndex);

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
        siloPayback.receiveRewards(100e6);

        // Send rewards to contract and call receiveRewards
        uint256 rewardAmount = 100e6; // 10% of total supply
        _sendRewardsToContract(rewardAmount);
        uint256 expectedRewardPerToken = (rewardAmount * PRECISION) / siloPayback.totalSupply();

        console.log("rewardPerTokenStored", siloPayback.rewardPerTokenStored());
        console.log("totalReceived", siloPayback.totalReceived());

        // Check global reward state updated correctly
        assertEq(siloPayback.rewardPerTokenStored(), expectedRewardPerToken);
        assertEq(siloPayback.totalReceived(), rewardAmount);

        // check that total remaining is totalSupply - totalReceived (1000e6 - 100e6)
        assertEq(siloPayback.siloRemaining(), 900e6);
    }

    /////////////// Earned calculation ///////////////

    function test_siloPaybackEarnedCalculationMultipleUsers() public {
        // Mint tokens: farmer1 40%, farmer2 60%
        _mintTokensToUser(farmer1, 400e6);
        _mintTokensToUser(farmer2, 600e6);

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

    // todo: add test to claim after 2 distributions have happened with 1 user claiming every season and one who doesnt

    function test_siloPaybackClaimMultipleUsers() public {
        // Setup users with different balances
        _mintTokensToUser(farmer1, 300e6);
        _mintTokensToUser(farmer2, 700e6);

        // Send rewards
        uint256 rewardAmount = 200e6;
        _sendRewardsToContract(rewardAmount);

        uint256 farmer1Rewards = siloPayback.earned(farmer1); // 60 tokens
        assertEq(farmer1Rewards, 60e6);
        uint256 farmer2Rewards = siloPayback.earned(farmer2); // 140 tokens
        assertEq(farmer2Rewards, 140e6);

        // farmer1 claims first
        vm.prank(farmer1);
        siloPayback.claim(farmer1, LibTransfer.To.EXTERNAL);

        assertEq(IERC20(BEAN).balanceOf(farmer1), farmer1Rewards);
        assertEq(siloPayback.earned(farmer1), 0);

        // farmer2's earnings should be unaffected
        assertEq(siloPayback.earned(farmer2), farmer2Rewards);

        // farmer2 claims
        vm.prank(farmer2);
        siloPayback.claim(farmer2, LibTransfer.To.EXTERNAL);

        assertEq(IERC20(BEAN).balanceOf(farmer2), farmer2Rewards);
        assertEq(siloPayback.earned(farmer2), 0);

        // assert no more underlying BEAN in the contract
        assertEq(IERC20(BEAN).balanceOf(address(siloPayback)), 0);
    }

    ////////////// Double claim and transfer logic //////////////

    function test_siloPaybackTransferUpdatesRewards() public {
        // Setup: farmer1 and farmer2 have tokens, rewards are distributed
        _mintTokensToUser(farmer1, 500e6); // 50% of total supply
        _mintTokensToUser(farmer2, 500e6); // 50% of total supply

        uint256 rewardAmount = 200e6;
        _sendRewardsToContract(rewardAmount);

        uint256 farmer1EarnedBefore = siloPayback.earned(farmer1);
        assertEq(farmer1EarnedBefore, 100e6);
        uint256 farmer2EarnedBefore = siloPayback.earned(farmer2);
        assertEq(farmer2EarnedBefore, 100e6);

        // farmer1 transfers tokens to farmer2
        vm.prank(farmer1);
        siloPayback.transfer(farmer2, 200e6);

        // Check that rewards were captured for both users
        // aka no matter if you transfer, your reward index is still the same
        assertEq(siloPayback.earned(farmer1), farmer1EarnedBefore);
        assertEq(siloPayback.earned(farmer2), farmer2EarnedBefore);
        // check that the userRewardPerTokenPaid is updated to the latest checkpoint
        assertEq(siloPayback.userRewardPerTokenPaid(farmer1), siloPayback.rewardPerTokenStored());
        assertEq(siloPayback.userRewardPerTokenPaid(farmer2), siloPayback.rewardPerTokenStored());

        // Check balances updated
        assertEq(siloPayback.balanceOf(farmer1), 300e6);
        assertEq(siloPayback.balanceOf(farmer2), 700e6);
    }

    function test_siloPaybackTransferPreventsDoubleClaiming() public {
        // Scenario: farmer1 tries to game by transferring tokens to get more rewards
        _mintTokensToUser(farmer1, 1000e6);

        // First round of rewards
        _sendRewardsToContract(100e6);
        uint256 firstRewards = siloPayback.earned(farmer1);

        // check that farmer3 balance is 0 and no rewards
        assertEq(siloPayback.earned(farmer3), 0);
        assertEq(siloPayback.balanceOf(farmer3), 0);

        // farmer1 transfers all tokens to another address he controls
        vm.prank(farmer1);
        siloPayback.transfer(farmer3, 1000e6);

        // check that farmer3 balance is increased to 1000e6 but rewards are still 0
        assertEq(siloPayback.earned(farmer3), 0);
        assertEq(siloPayback.balanceOf(farmer3), 1000e6);

        // Second round of rewards
        _sendRewardsToContract(100e6);

        // farmer1 should only have rewards from first round
        // farmer3 should only have rewards from second round
        assertEq(siloPayback.earned(farmer1), firstRewards);
        assertEq(siloPayback.earned(farmer3), 100e6); // Only second round rewards

        // Total rewards should be conserved
        assertEq(siloPayback.earned(farmer1) + siloPayback.earned(farmer3), 200e6);
    }

    function test_siloPaybackTransferToNewUserStartsFreshRewards() public {
        _mintTokensToUser(farmer1, 1000e6);

        // farmer1 earns rewards
        _sendRewardsToContract(100e6);

        // Transfer to farmer3 (new user)
        vm.prank(farmer1);
        siloPayback.transfer(farmer3, 500e6);

        // farmer3 should have checkpoint synced but no earned rewards yet
        assertEq(siloPayback.earned(farmer3), 0);
        assertEq(siloPayback.userRewardPerTokenPaid(farmer3), siloPayback.rewardPerTokenStored());

        // New rewards distributed
        _sendRewardsToContract(200e6);

        // farmer3 should get rewards proportional to his balance
        uint256 expectedfarmer3Rewards = (500e6 * 200e6) / 1000e6; // 50% of new rewards
        assertEq(siloPayback.earned(farmer3), expectedfarmer3Rewards);
    }

    ////////////// COMPLEX SCENARIOS //////////////

    function test_siloPaybackMultipleRewardDistributionsAndClaims() public {
        _mintTokensToUser(farmer1, 400e6);
        _mintTokensToUser(farmer2, 600e6);

        // First reward distribution
        _sendRewardsToContract(100e6);
        uint256 farmer1Rewards1 = siloPayback.earned(farmer1); // 40
        uint256 farmer2Rewards1 = siloPayback.earned(farmer2); // 60

        // farmer1 claims
        vm.prank(farmer1);
        siloPayback.claim(farmer1, LibTransfer.To.EXTERNAL);

        // Second reward distribution
        _sendRewardsToContract(200e6);

        // farmer1 should have new rewards, farmer2 should have accumulated
        uint256 farmer1Rewards2 = siloPayback.earned(farmer1); // 80 (40% of 200)
        uint256 farmer2Rewards2 = siloPayback.earned(farmer2); // 180 (60 + 120)

        assertEq(farmer1Rewards2, 80e6);
        assertEq(farmer2Rewards2, 180e6);

        // Verify farmer1 received first claim
        assertEq(IERC20(BEAN).balanceOf(farmer1), farmer1Rewards1);
    }

    function test_siloPaybackRewardsWithTransfersOverTime() public {
        _mintTokensToUser(farmer1, 1000e6);

        // Initial rewards
        _sendRewardsToContract(100e6);

        // Transfer half to farmer2
        vm.prank(farmer1);
        siloPayback.transfer(farmer2, 500e6);

        // More rewards
        _sendRewardsToContract(200e6);

        // farmer1 should have: 100 (from first round) + 100 (50% of second round)
        // farmer2 should have: 0 (wasn't holder for first round) + 100 (50% of second round)
        assertEq(siloPayback.earned(farmer1), 200e6);
        assertEq(siloPayback.earned(farmer2), 100e6);
    }

    ////////////// EDGE CASES AND ERROR CONDITIONS //////////////

    // todo: pinto sent without total supply being 0
    // todo: precision with small amounts

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

    function _mintTokensToUser(address user, uint256 amount) internal {
        SiloPayback.UnripeBdvTokenData[] memory receipts = new SiloPayback.UnripeBdvTokenData[](1);
        receipts[0] = SiloPayback.UnripeBdvTokenData(user, amount);
        vm.prank(owner);
        siloPayback.batchMint(receipts);
    }

    function _sendRewardsToContract(uint256 amount) internal {
        deal(address(BEAN), address(siloPayback), amount, true);

        // Call receiveRewards to update the global state
        vm.prank(BEANSTALK);
        siloPayback.receiveRewards(amount);
    }

    function logRewardState() internal {
        console.log("rewardPerTokenStored: ", siloPayback.rewardPerTokenStored());
        console.log("totalReceived: ", siloPayback.totalReceived());
        console.log("totalSupply: ", siloPayback.totalSupply());
    }
}

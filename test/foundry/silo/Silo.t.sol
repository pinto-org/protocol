// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";
import {MockSiloFacet} from "contracts/mocks/mockFacets/MockSiloFacet.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {console} from "forge-std/console.sol";
/**
 * @notice Tests the functionality of the Silo.
 */
contract SiloTest is TestHelper {
    // Interfaces.
    MockSiloFacet silo = MockSiloFacet(BEANSTALK);

    // test accounts
    address[] farmers;

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // initalize farmers from farmers (farmer0 == diamond deployer)
        farmers.push(users[1]);
        farmers.push(users[2]);

        // max approve.
        maxApproveBeanstalk(farmers);

        // Initialize well to balances. (1000 BEAN/ETH)
        addLiquidityToWell(
            BEAN_ETH_WELL,
            10000e6, // 10,000 Beans
            10 ether // 10 ether.
        );

        addLiquidityToWell(
            BEAN_WSTETH_WELL,
            10000e6, // 10,000 Beans
            10 ether // 10 ether.
        );
    }

    /**
     * @notice verfies that a farmer's deposit list is updated correctly.
     * @dev partial transfers, withdraws, and converts are tested here. See {SiloTest.test_siloDepositList} for full deposits.
     */
    function test_siloDepositList(uint256 amount, uint256 portion) public {
        uint256[] memory depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        IMockFBeanstalk.TokenDepositId memory deposit = bs.getTokenDepositsForAccount(
            farmers[0],
            BEAN
        );
        verifyDepositIdLengths(depositIds, deposit, BEAN, 0);

        amount = bound(amount, 100, 1e22);
        portion = bound(portion, 1, amount - 1);
        mintTokensToUser(farmers[0], BEAN, amount);

        //////////// DEPOSIT ////////////
        vm.prank(farmers[0]);
        bs.deposit(BEAN, portion, 0);

        // verify depositList.
        depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[0], BEAN);
        IMockFBeanstalk.TokenDepositId[] memory allDeposits = bs.getDepositsForAccount(farmers[0]);

        verifyDepositIdLengths(depositIds, deposit, BEAN, 1);
        assertEq(bs.getIndexForDepositId(farmers[0], BEAN, depositIds[0]), 0);
        (address token, int96 stem) = LibBytes.unpackAddressAndStem(depositIds[0]);
        assertEq(token, deposit.token);
        assertEq(stem, bs.stemTipForToken(token));
        assertEq(deposit.tokenDeposits[0].amount, portion);
        for (uint i; i < allDeposits.length; i++) {
            assertEq(allDeposits[i].token, bs.getWhitelistedTokens()[i]);
            if (allDeposits[i].token != BEAN) {
                assertEq(allDeposits[i].depositIds.length, 0);
                assertEq(allDeposits[i].tokenDeposits.length, 0);
            }
        }

        vm.prank(farmers[0]);
        bs.deposit(BEAN, amount - portion, 0);

        // verify depositList index does not increase.
        depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[0], BEAN);
        verifyDepositIdLengths(depositIds, deposit, BEAN, 1);
        (token, stem) = LibBytes.unpackAddressAndStem(depositIds[0]);
        assertEq(token, deposit.token);
        assertEq(stem, bs.stemTipForToken(token));
        assertEq(deposit.tokenDeposits[0].amount, amount);

        uint256 snapshot = vm.snapshot();

        //////////// TRANSFER ////////////
        vm.prank(farmers[0]);
        bs.transferDeposit(farmers[0], farmers[1], BEAN, stem, portion);

        // verify depositList for sender.
        depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[0], BEAN);
        verifyDepositIdLengths(depositIds, deposit, BEAN, 1);
        assertEq(bs.getIndexForDepositId(farmers[0], BEAN, depositIds[0]), 0);
        assertEq(deposit.tokenDeposits[0].amount, amount - portion);

        // verify depositList for recipient.
        depositIds = bs.getTokenDepositIdsForAccount(farmers[1], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[1], BEAN);
        verifyDepositIdLengths(depositIds, deposit, BEAN, 1);
        assertEq(bs.getIndexForDepositId(farmers[1], BEAN, depositIds[0]), 0);
        assertEq(deposit.tokenDeposits[0].amount, portion);

        vm.revertTo(snapshot);

        // withdraw `portion` of deposit.
        vm.prank(farmers[0]);
        bs.withdrawDeposit(BEAN, stem, portion, 0);

        // verify depositList.
        depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[0], BEAN);
        verifyDepositIdLengths(depositIds, deposit, BEAN, 1);
        assertEq(deposit.tokenDeposits[0].amount, amount - portion);

        //////////// CONVERT ////////////

        vm.revertTo(snapshot);
        // increase deltaB. 1e22 / 1e6 = 1e16 ethers.
        addLiquidityToWell(BEAN_ETH_WELL, 0, 1e16 ether);

        bytes memory convertData = createBeanToLPConvert(BEAN_ETH_WELL, portion);

        int96[] memory stems = new int96[](1);
        stems[0] = stem;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = portion;

        // skip germination as germinating deposits cannot be converted.
        bs.siloSunrise(0);
        bs.siloSunrise(0);

        vm.prank(farmers[0]);
        bs.convert(convertData, stems, amounts);

        // verify depositList.
        depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[0], BEAN);
        verifyDepositIdLengths(depositIds, deposit, BEAN, 1);
        assertEq(deposit.tokenDeposits[0].amount, amount - portion);

        depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN_ETH_WELL);
        deposit = bs.getTokenDepositsForAccount(farmers[0], BEAN_ETH_WELL);
        verifyDepositIdLengths(depositIds, deposit, BEAN_ETH_WELL, 1);
        assertGe(deposit.tokenDeposits[0].amount, 0);
    }

    /**
     * @notice performs a series of interactions with deposits and verifies that the depositlist is updated correctly.
     * 1. depositing properly increments the depositId index, if the deposit occured in different seasons.
     * 2. transfering a deposit properly decrements the senders' depositId,
     * and increments the recipients' depositId.
     * 3. withdrawing a deposit properly decrements the depositId list.
     * 4. converting a deposit properly decrements the depositId list.
     */
    function test_siloMultipleDepositLists() public {
        //////////// DEPOSIT ////////////
        uint256 depositAmount = rand(1, 10e6);
        uint256 deposits = rand(1, 50);
        for (uint256 i; i < deposits; i++) {
            mintTokensToUser(farmers[0], BEAN, depositAmount);
            vm.prank(farmers[0]);
            bs.deposit(BEAN, depositAmount, 0);
            bs.siloSunrise(0);
        }

        // verify depositList.
        uint256[] memory depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        IMockFBeanstalk.TokenDepositId memory deposit = bs.getTokenDepositsForAccount(
            farmers[0],
            BEAN
        );
        verifyDepositIdLengths(depositIds, deposit, BEAN, deposits);
        for (uint256 i; i < deposits; i++) {
            assertEq(deposit.tokenDeposits[i].amount, depositAmount);
        }

        //////////// TRANSFER ////////////

        // transfers a random amount of deposits to farmer[1].
        uint256 transfers = rand(1, ((deposits - 1) / 2) + 1);
        vm.startPrank(farmers[0]);
        uint256 _stalkEarnedPerSeason = stalkEarnedPerSeason(BEAN);
        int96[] memory stems = new int96[](transfers);
        uint256[] memory amounts = new uint256[](transfers);
        for (uint256 i; i < transfers; i++) {
            stems[i] = int96(uint96(i * _stalkEarnedPerSeason));
            amounts[i] = depositAmount;
        }
        bs.transferDeposits(farmers[0], farmers[1], BEAN, stems, amounts);
        vm.stopPrank();

        depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[0], BEAN);
        verifyDepositIdLengths(depositIds, deposit, BEAN, deposits - transfers);

        depositIds = bs.getTokenDepositIdsForAccount(farmers[1], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[1], BEAN);
        verifyDepositIdLengths(depositIds, deposit, BEAN, transfers);

        //////////// CONVERT ////////////

        // increase deltaB.
        addLiquidityToWell(BEAN_ETH_WELL, 0, 100 ether);
        // skip germination as germinating deposits cannot be converted.
        bs.siloSunrise(0);
        bs.siloSunrise(0);

        // converts deposits for farmer[1].
        vm.startPrank(farmers[1]);
        bs.convert(createBeanToLPConvert(BEAN_ETH_WELL, depositAmount * transfers), stems, amounts);
        vm.stopPrank();

        depositIds = bs.getTokenDepositIdsForAccount(farmers[1], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[1], BEAN);
        verifyDepositIdLengths(depositIds, deposit, BEAN, 0);

        depositIds = bs.getTokenDepositIdsForAccount(farmers[1], BEAN_ETH_WELL);
        deposit = bs.getTokenDepositsForAccount(farmers[1], BEAN_ETH_WELL);
        verifyDepositIdLengths(depositIds, deposit, BEAN_ETH_WELL, 1);

        //////////// WITHDRAW ////////////

        // withdraws deposits from farmer[0]
        stems = new int96[](deposits - transfers);
        amounts = new uint256[](deposits - transfers);
        for (uint256 i; i < deposits - transfers; i++) {
            stems[i] = int96(uint96((i + transfers) * _stalkEarnedPerSeason));
            amounts[i] = depositAmount;
        }
        vm.startPrank(farmers[0]);
        bs.withdrawDeposits(BEAN, stems, amounts, 0);
        depositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        deposit = bs.getTokenDepositsForAccount(farmers[0], BEAN);
        verifyDepositIdLengths(depositIds, deposit, BEAN, 0);
    }

    function test_setSortedDepositIds(uint256 swapPosition) public {
        // Create multiple deposits in different seasons
        uint256 depositAmount = 1e6;
        uint256 numDeposits = 5;
        mintTokensToUser(farmers[1], BEAN, depositAmount * numDeposits);
        vm.prank(farmers[1]);
        (uint256 amount, uint256 _bdv, int96 ogStem) = bs.deposit(BEAN, depositAmount, 0);
        bs.siloSunrise(0);
        mintTokensToUser(farmers[0], BEAN, depositAmount * numDeposits);
        for (uint256 i = 1; i < numDeposits; i++) {
            vm.prank(farmers[0]);
            bs.deposit(BEAN, depositAmount, 0);
            bs.siloSunrise(0);
        }

        // transfer deposit to farmers[0]
        vm.prank(farmers[1]);
        bs.transferDeposit(farmers[1], farmers[0], BEAN, ogStem, depositAmount);

        // Get current deposit IDs
        uint256[] memory originalDepositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        assertEq(originalDepositIds.length, numDeposits, "Should have correct number of deposits");

        // Create a new sorted array in ascending order
        uint256[] memory sortedDepositIds = new uint256[](numDeposits);
        for (uint256 i; i < numDeposits; i++) {
            if (i == 0) {
                // last deposit should be first
                sortedDepositIds[0] = originalDepositIds[numDeposits - 1];
            } else {
                sortedDepositIds[i] = originalDepositIds[i - 1];
            }
        }

        // Update the sorted deposit IDs
        vm.prank(farmers[0]);
        bs.updateSortedDepositIds(farmers[0], BEAN, sortedDepositIds);

        // Verify the new order matches what we set
        uint256[] memory newDepositIds = bs.getTokenDepositIdsForAccount(farmers[0], BEAN);
        assertEq(newDepositIds.length, sortedDepositIds.length, "Length should match");

        for (uint256 i; i < newDepositIds.length; i++) {
            assertEq(newDepositIds[i], sortedDepositIds[i], "IDs should match in order");
        }

        // Test that submitting unsorted deposit IDs reverts
        // Create an unsorted array by swapping two elements
        uint256[] memory unsortedDepositIds = new uint256[](numDeposits);
        for (uint256 i; i < numDeposits; i++) {
            unsortedDepositIds[i] = newDepositIds[i];
        }

        // Use bounded swap position to select which adjacent elements to swap
        uint256 swapIndex = bound(swapPosition, 0, numDeposits - 2);

        // Swap adjacent elements to break the ascending order
        (unsortedDepositIds[swapIndex], unsortedDepositIds[swapIndex + 1]) = (
            unsortedDepositIds[swapIndex + 1],
            unsortedDepositIds[swapIndex]
        );

        // verify the idIndex is updated correctly
        for (uint256 i; i < numDeposits; i++) {
            assertEq(bs.getIndexForDepositId(farmers[0], BEAN, newDepositIds[i]), i);
        }

        uint256 snapshot = vm.snapshot();
        {
            IMockFBeanstalk.TokenDepositId memory deposit = bs.getTokenDepositsForAccount(
                farmers[0],
                BEAN
            );
            // verify a user can withdraw all deposits

            vm.prank(farmers[0]);
            int96[] memory stems = new int96[](numDeposits);
            uint256[] memory amounts = new uint256[](numDeposits);
            for (uint256 i; i < numDeposits; i++) {
                (address token, int96 stem) = LibBytes.unpackAddressAndStem(deposit.depositIds[i]);
                stems[i] = stem;
                amounts[i] = deposit.tokenDeposits[i].amount;
            }
            bs.withdrawDeposits(BEAN, stems, amounts, 0);
        }

        vm.revertTo(snapshot);

        // Verify that updating with unsorted IDs reverts
        vm.prank(farmers[0]);
        vm.expectRevert("Deposit IDs not sorted");
        bs.updateSortedDepositIds(farmers[0], BEAN, unsortedDepositIds);

        // Test that submitting a list with an ID not in the current list reverts
        uint256[] memory invalidDepositIds = new uint256[](numDeposits);
        for (uint256 i; i < numDeposits; i++) {
            invalidDepositIds[i] = newDepositIds[i];
        }
        // Use bounded swap position to select which ID to make invalid
        uint256 invalidIndex = bound(swapPosition, 0, numDeposits - 1);

        // Modify one ID to be invalid by changing its stem value
        (address token, int96 stem) = LibBytes.unpackAddressAndStem(
            invalidDepositIds[invalidIndex]
        );
        invalidDepositIds[invalidIndex] = LibBytes.packAddressAndStem(token, stem - 1);

        // Verify that updating with an invalid ID reverts
        vm.prank(farmers[0]);
        vm.expectRevert("ID not found in current list");
        bs.updateSortedDepositIds(farmers[0], BEAN, invalidDepositIds);

        // Note: We don't need to test for "Duplicate ID" explicitly because the sorting check
        // `require(stem > lastStem, "Deposit IDs not sorted")` prevents duplicates by requiring
        // strictly increasing stems. Any attempt to include duplicate IDs will fail the sorting
        // check first.
    }

    function test_approveAll() public {
        mintTokensToUser(farmers[0], BEAN, 1000e6);

        //////////// DEPOSIT ////////////
        vm.prank(farmers[0]);
        bs.deposit(BEAN, 1000e6, 0);

        //verify farmer 1 cannot transfer
        vm.prank(farmers[1]);
        vm.expectRevert("Silo: insufficient allowance");
        uint256 depositId = LibBytes.packAddressAndStem(BEAN, 0);
        bs.safeTransferFrom(farmers[0], farmers[1], depositId, 1000e6, "");

        vm.prank(farmers[0]);
        bs.setApprovalForAll(farmers[1], true);
        assertEq(bs.isApprovedForAll(farmers[0], farmers[1]), true);

        vm.prank(farmers[1]);
        bs.safeTransferFrom(farmers[0], farmers[1], depositId, 1000e6, "");
    }

    // silo list helpers //
    function verifyDepositIdLengths(
        uint256[] memory depositIds,
        IMockFBeanstalk.TokenDepositId memory deposit,
        address token,
        uint256 length
    ) internal pure {
        assertEq(depositIds.length, length);
        assertEq(depositIds.length, deposit.depositIds.length);
        assertEq(depositIds.length, deposit.tokenDeposits.length);
        assertEq(deposit.token, token);
    }

    function stalkEarnedPerSeason(address token) internal returns (uint40) {
        return (bs.tokenSettings(token)).stalkEarnedPerSeason;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestHelper, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {MockFieldFacet} from "contracts/mocks/mockFacets/MockFieldFacet.sol";
import {C} from "contracts/C.sol";

contract ListingTest is TestHelper {
    // test accounts
    address[] farmers;

    MockFieldFacet field = MockFieldFacet(BEANSTALK);

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        season.siloSunrise(0);

        // initalize farmers from farmers (farmer0 == diamond deployer)
        farmers.push(users[1]);
        farmers.push(users[2]);

        // max approve.
        maxApproveBeanstalk(farmers);

        mintTokensToUsers(farmers, BEAN, MAX_DEPOSIT_BOUND);

        field.incrementTotalSoilE(1000e18);

        // mine 300 blocks
        vm.roll(300);

        //set temp
        bs.setYieldE(0);

        console.log("bs.activeField(): ", bs.activeField());

        // sow 1000
        vm.prank(users[1]);
        uint256 pods = bs.sow(1000e6, 0, 0);
        console.log("Pods: ", pods);
        vm.prank(users[2]);
        bs.sow(1000e6, 0, 0);
    }

    function testCreatePodListing_InvalidMinFillAmount() public {
        IMockFBeanstalk.PodListing memory podListing = IMockFBeanstalk.PodListing({
            lister: users[1],
            fieldId: bs.activeField(),
            index: 0,
            start: 0,
            podAmount: 50000000,
            pricePerPod: 1000000,
            maxHarvestableIndex: type(uint256).max,
            minFillAmount: 60000000,
            mode: 0
        });

        vm.expectRevert("Marketplace: minFillAmount must be <= podAmount.");
        vm.prank(users[1]);
        bs.createPodListing(podListing);
    }

    function testCreatePodListing_ValidMinFillAmount() public {
        IMockFBeanstalk.PodListing memory podListing = IMockFBeanstalk.PodListing({
            lister: users[1],
            fieldId: bs.activeField(),
            index: 0,
            start: 0,
            podAmount: 50000000,
            pricePerPod: 1000000,
            maxHarvestableIndex: type(uint256).max,
            minFillAmount: 30000000,
            mode: 0
        });
        vm.prank(users[1]);
        bs.createPodListing(podListing);
    }

    function testMultiFlow_MultipleListings() public {
        uint256 fieldId = bs.activeField();

        // Sow 2 additional plots to have 3 total plots
        vm.prank(users[1]);
        bs.sow(100e6, 0, 0);
        vm.prank(users[1]);
        bs.sow(100e6, 0, 0);

        // Get all plot indices
        uint256[] memory plotIndexes = field.getPlotIndexesFromAccount(users[1], fieldId);
        require(plotIndexes.length >= 3, "Not enough plots");

        // Create 3 listings on different plot indices
        IMockFBeanstalk.PodListing[] memory listings = new IMockFBeanstalk.PodListing[](3);
        for (uint256 i = 0; i < 3; i++) {
            listings[i] = IMockFBeanstalk.PodListing({
                lister: users[1],
                fieldId: fieldId,
                index: plotIndexes[i],
                start: 0,
                podAmount: 50000000,
                pricePerPod: 1000000,
                maxHarvestableIndex: type(uint256).max,
                minFillAmount: 10000000,
                mode: 0
            });
        }

        vm.prank(users[1]);
        bs.multiCreatePodListing(listings);

        // Verify all created
        for (uint256 i = 0; i < 3; i++) {
            assertNotEq(bs.getPodListing(fieldId, plotIndexes[i]), bytes32(0));
        }

        // Cancel all 3 using different indices
        IMockFBeanstalk.CancelPodListingParams[]
            memory params = new IMockFBeanstalk.CancelPodListingParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            params[i] = IMockFBeanstalk.CancelPodListingParams({
                fieldId: fieldId,
                index: plotIndexes[i]
            });
        }

        vm.prank(users[1]);
        bs.multiCancelPodListing(params);

        // Verify all cancelled
        for (uint256 i = 0; i < 3; i++) {
            assertEq(bs.getPodListing(fieldId, plotIndexes[i]), bytes32(0));
        }
    }

    function testMultiFlow_MultipleOrders() public {
        uint256 fieldId = bs.activeField();

        // Create 3 orders
        IMockFBeanstalk.CreatePodOrderParams[]
            memory params = new IMockFBeanstalk.CreatePodOrderParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            params[i] = IMockFBeanstalk.CreatePodOrderParams({
                order: IMockFBeanstalk.PodOrder({
                    orderer: users[2],
                    fieldId: fieldId,
                    pricePerPod: uint24(1000000 - (i * 50000)),
                    maxPlaceInLine: type(uint256).max,
                    minFillAmount: 50e6
                }),
                beanAmount: 500e6
            });
        }

        vm.prank(users[2]);
        bytes32[] memory ids = bs.multiCreatePodOrder(params, 0);

        // Verify all created
        assertEq(ids.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertGt(bs.getPodOrder(ids[i]), 0);
        }

        // Cancel all 3
        IMockFBeanstalk.PodOrder[] memory orders = new IMockFBeanstalk.PodOrder[](3);
        for (uint256 i = 0; i < 3; i++) {
            orders[i] = params[i].order;
        }

        vm.prank(users[2]);
        bs.multiCancelPodOrder(orders, 0);

        // Verify all cancelled
        for (uint256 i = 0; i < 3; i++) {
            assertEq(bs.getPodOrder(ids[i]), 0);
        }
    }

    function testMultiFlow_CreateAndFillMultipleListings() public {
        uint256 fieldId = bs.activeField();

        // Sow 2 additional plots to have 3 total plots
        vm.prank(users[1]);
        bs.sow(100e6, 0, 0);
        vm.prank(users[1]);
        bs.sow(100e6, 0, 0);

        // Get all plot indices
        uint256[] memory plotIndexes = field.getPlotIndexesFromAccount(users[1], fieldId);
        require(plotIndexes.length >= 3, "Not enough plots");

        uint256[] memory plotSizes = new uint256[](3);
        plotSizes[0] = 1000000000;
        plotSizes[1] = 100000000;
        plotSizes[2] = 100000000;

        // Create 3 listings on different plot indices
        IMockFBeanstalk.PodListing[] memory listings = new IMockFBeanstalk.PodListing[](3);
        for (uint256 i = 0; i < 3; i++) {
            listings[i] = IMockFBeanstalk.PodListing({
                lister: users[1],
                fieldId: fieldId,
                index: plotIndexes[i],
                start: 0,
                podAmount: plotSizes[i],
                pricePerPod: 1000000,
                maxHarvestableIndex: type(uint256).max,
                minFillAmount: 10e6,
                mode: 0
            });
        }

        vm.prank(users[1]);
        bs.multiCreatePodListing(listings);

        // Verify all created
        for (uint256 i = 0; i < 3; i++) {
            assertNotEq(bs.getPodListing(fieldId, plotIndexes[i]), bytes32(0));
        }

        // Fill all 3 listings using multiFillPodListing
        IMockFBeanstalk.FillPodListingParams[]
            memory fillParams = new IMockFBeanstalk.FillPodListingParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            fillParams[i] = IMockFBeanstalk.FillPodListingParams({
                listing: listings[i],
                beanAmount: plotSizes[i]
            });
        }

        vm.prank(users[2]);
        bs.multiFillPodListing(fillParams, 0);

        // Verify all filled (listings cleared after full fill)
        for (uint256 i = 0; i < 3; i++) {
            assertEq(bs.getPodListing(fieldId, plotIndexes[i]), bytes32(0));
        }
    }

    function testMultiFlow_CreateAndFillMultipleOrders() public {
        uint256 fieldId = bs.activeField();

        // Sow 2 additional plots to have 3 total plots
        vm.prank(users[1]);
        bs.sow(150e6, 0, 0);
        vm.prank(users[1]);
        bs.sow(150e6, 0, 0);

        // Get all plot indices
        uint256[] memory plotIndexes = field.getPlotIndexesFromAccount(users[1], fieldId);
        require(plotIndexes.length >= 3, "Not enough plots");

        // Create 3 orders using multiCreatePodOrder
        IMockFBeanstalk.CreatePodOrderParams[]
            memory orderParams = new IMockFBeanstalk.CreatePodOrderParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            orderParams[i] = IMockFBeanstalk.CreatePodOrderParams({
                order: IMockFBeanstalk.PodOrder({
                    orderer: users[2],
                    fieldId: fieldId,
                    pricePerPod: uint24(1000000 - (i * 1000)),
                    maxPlaceInLine: type(uint256).max,
                    minFillAmount: 50e6
                }),
                beanAmount: 100e6
            });
        }

        vm.prank(users[2]);
        bytes32[] memory orderIds = bs.multiCreatePodOrder(orderParams, 0);

        // Verify all created
        assertEq(orderIds.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertGt(bs.getPodOrder(orderIds[i]), 0);
        }

        // Fill all 3 orders using multiFillPodOrder
        uint256[] memory podAmounts = new uint256[](3);
        podAmounts[0] = 100000000;
        podAmounts[1] = 100100101;
        podAmounts[2] = 100200401;

        IMockFBeanstalk.FillPodOrderParams[]
            memory fillParams = new IMockFBeanstalk.FillPodOrderParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            fillParams[i] = IMockFBeanstalk.FillPodOrderParams({
                order: orderParams[i].order,
                index: plotIndexes[i],
                start: 0,
                amount: podAmounts[i]
            });
        }

        vm.prank(users[1]);
        bs.multiFillPodOrder(fillParams, 0);

        // Verify all filled (orders cleared)
        for (uint256 i = 0; i < 3; i++) {
            assertEq(bs.getPodOrder(orderIds[i]), 0);
        }
    }
}

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
            podAmount: 50,
            pricePerPod: 100,
            maxHarvestableIndex: 100,
            minFillAmount: 60, // Invalid: greater than podAmount
            mode: 0
        });

        vm.expectRevert("Marketplace: minFillAmount must be <= podAmount.");
        vm.prank(users[1]);
        bs.createPodListing(podListing);
    }

    function testCreatePodListing_ValidMinFillAmount() public {
        // no revert
        IMockFBeanstalk.PodListing memory podListing = IMockFBeanstalk.PodListing({
            lister: users[1],
            fieldId: bs.activeField(),
            index: 0,
            start: 0,
            podAmount: 50,
            pricePerPod: 100,
            maxHarvestableIndex: 100,
            minFillAmount: 30, // Valid: less than or equal to podAmount
            mode: 0
        });
        vm.prank(users[1]);
        bs.createPodListing(podListing);
    }

    function testMultiCancelPodListing_Success() public {
        uint256 fieldId = bs.activeField();

        // Create 2 listings using batch function
        IMockFBeanstalk.PodListing[] memory listings = new IMockFBeanstalk.PodListing[](2);
        listings[0] = IMockFBeanstalk.PodListing({
            lister: users[1],
            fieldId: fieldId,
            index: 0,
            start: 0,
            podAmount: 50,
            pricePerPod: 100,
            maxHarvestableIndex: 1000,
            minFillAmount: 10,
            mode: 0
        });
        listings[1] = IMockFBeanstalk.PodListing({
            lister: users[1],
            fieldId: fieldId,
            index: 0,
            start: 50,
            podAmount: 50,
            pricePerPod: 100,
            maxHarvestableIndex: 1000,
            minFillAmount: 10,
            mode: 0
        });

        vm.prank(users[1]);
        bs.multiCreatePodListing(listings);

        // Cancel both in one batch
        IMockFBeanstalk.CancelPodListingParams[] memory params = new IMockFBeanstalk.CancelPodListingParams[](2);
        params[0] = IMockFBeanstalk.CancelPodListingParams({fieldId: fieldId, index: 0});
        params[1] = IMockFBeanstalk.CancelPodListingParams({fieldId: fieldId, index: 0});

        vm.prank(users[1]);
        bs.multiCancelPodListing(params);

        // Verify cancelled
        assertEq(bs.getPodListing(fieldId, 0), bytes32(0));
    }

    function testMultiCreatePodListing_Success() public {
        uint256 fieldId = bs.activeField();

        // Create 2 listings in one batch
        IMockFBeanstalk.PodListing[] memory listings = new IMockFBeanstalk.PodListing[](2);
        listings[0] = IMockFBeanstalk.PodListing({
            lister: users[1],
            fieldId: fieldId,
            index: 0,
            start: 0,
            podAmount: 50,
            pricePerPod: 100,
            maxHarvestableIndex: 1000,
            minFillAmount: 10,
            mode: 0
        });
        listings[1] = IMockFBeanstalk.PodListing({
            lister: users[1],
            fieldId: fieldId,
            index: 0,
            start: 50,
            podAmount: 50,
            pricePerPod: 100,
            maxHarvestableIndex: 1000,
            minFillAmount: 10,
            mode: 0
        });

        vm.prank(users[1]);
        bs.multiCreatePodListing(listings);

        // Verify listings created
        assertNotEq(bs.getPodListing(fieldId, 0), bytes32(0));
    }

    function testMultiCancelPodOrder_Success() public {
        uint256 fieldId = bs.activeField();

        // Create 2 orders using batch function
        IMockFBeanstalk.CreatePodOrderParams[] memory params = new IMockFBeanstalk.CreatePodOrderParams[](2);
        params[0] = IMockFBeanstalk.CreatePodOrderParams({
            order: IMockFBeanstalk.PodOrder({
                orderer: users[2],
                fieldId: fieldId,
                pricePerPod: 100,
                maxPlaceInLine: 1000,
                minFillAmount: 50
            }),
            beanAmount: 1000e6
        });
        params[1] = IMockFBeanstalk.CreatePodOrderParams({
            order: IMockFBeanstalk.PodOrder({
                orderer: users[2],
                fieldId: fieldId,
                pricePerPod: 90,
                maxPlaceInLine: 2000,
                minFillAmount: 50
            }),
            beanAmount: 1000e6
        });

        vm.prank(users[2]);
        bytes32[] memory ids = bs.multiCreatePodOrder(params, 0);

        // Cancel both in one batch
        IMockFBeanstalk.PodOrder[] memory orders = new IMockFBeanstalk.PodOrder[](2);
        orders[0] = params[0].order;
        orders[1] = params[1].order;

        vm.prank(users[2]);
        bs.multiCancelPodOrder(orders, 0);

        // Verify cancelled
        assertEq(bs.getPodOrder(ids[0]), 0);
        assertEq(bs.getPodOrder(ids[1]), 0);
    }

    function testMultiCreatePodOrder_Success() public {
        uint256 fieldId = bs.activeField();

        // Create 2 orders in one batch
        IMockFBeanstalk.CreatePodOrderParams[] memory params = new IMockFBeanstalk.CreatePodOrderParams[](2);
        params[0] = IMockFBeanstalk.CreatePodOrderParams({
            order: IMockFBeanstalk.PodOrder({
                orderer: users[2],
                fieldId: fieldId,
                pricePerPod: 100,
                maxPlaceInLine: 1000,
                minFillAmount: 50
            }),
            beanAmount: 1000e6
        });
        params[1] = IMockFBeanstalk.CreatePodOrderParams({
            order: IMockFBeanstalk.PodOrder({
                orderer: users[2],
                fieldId: fieldId,
                pricePerPod: 90,
                maxPlaceInLine: 2000,
                minFillAmount: 50
            }),
            beanAmount: 1000e6
        });

        vm.prank(users[2]);
        bytes32[] memory ids = bs.multiCreatePodOrder(params, 0);

        // Verify orders created
        assertEq(ids.length, 2);
        assertNotEq(ids[0], bytes32(0));
        assertNotEq(ids[1], bytes32(0));
        assertGt(bs.getPodOrder(ids[0]), 0);
        assertGt(bs.getPodOrder(ids[1]), 0);
    }
}

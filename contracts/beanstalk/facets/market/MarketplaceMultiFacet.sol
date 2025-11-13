/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {Order} from "./abstract/Order.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {LibMarket} from "contracts/libraries/LibMarket.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";

/**
 * @title MarketplaceMultiFacet
 * @notice Handles batch (multi*) marketplace operations
 * for pod listings and orders.
 */
contract MarketplaceMultiFacet is Invariable, Order {
    /**
     * @notice Parameters for cancelling a pod listing.
     * @param fieldId The field identifier where the plot is located
     * @param index The index of the plot to cancel listing for
     */
    struct CancelPodListingParams {
        uint256 fieldId;
        uint256 index;
    }

    /**
     * @notice Parameters for filling a pod listing.
     * @param listing The pod listing to fill
     * @param beanAmount The amount of beans to spend filling the listing
     */
    struct FillPodListingParams {
        PodListing listing;
        uint256 beanAmount;
    }

    /**
     * @notice Parameters for creating a pod order.
     * @param order The pod order to create
     * @param beanAmount The amount of beans to lock in the order
     */
    struct CreatePodOrderParams {
        PodOrder order;
        uint256 beanAmount;
    }

    /**
     * @notice Parameters for filling a pod order.
     * @param order The pod order to fill
     * @param index The index of the plot to sell
     * @param start The starting position within the plot
     * @param amount The amount of pods to sell
     */
    struct FillPodOrderParams {
        PodOrder order;
        uint256 index;
        uint256 start;
        uint256 amount;
    }

    /*
     * Pod Listing Batch Operations
     */

    /**
     * @notice Creates multiple pod listings in a single transaction.
     * @dev All-or-nothing: if any listing creation fails, entire batch reverts.
     * @dev Emits individual PodListingCreated events for each listing.
     * @param podListings Array of pod listings to create
     */
    function multiCreatePodListing(
        PodListing[] calldata podListings
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        address user = LibTractor._user();
        for (uint256 i; i < podListings.length; i++) {
            require(podListings[i].lister == user, "Marketplace: Non-user create listing.");
            _createPodListing(podListings[i]);
        }
    }

    /**
     * @notice Fills multiple pod listings in a single transaction.
     * @dev All-or-nothing: if any fill fails, entire batch reverts
     * @dev Emits individual PodListingFilled events for each listing
     * @dev All listings use the same transfer mode for the filler
     * @param params Array of fill parameters for each listing
     * @param mode The transfer mode for the filler's bean payments
     */
    function multiFillPodListing(
        FillPodListingParams[] calldata params,
        LibTransfer.From mode
    ) external payable fundsSafu noSupplyChange oneOutFlow(s.sys.bean) nonReentrant {
        address user = LibTractor._user();
        for (uint256 i; i < params.length; i++) {
            uint256 beanAmount = LibTransfer.transferToken(
                BeanstalkERC20(s.sys.bean),
                user,
                params[i].listing.lister,
                params[i].beanAmount,
                mode,
                params[i].listing.mode
            );
            _fillListing(params[i].listing, user, beanAmount);
        }
    }

    /**
     * @notice Cancels multiple pod listings in a single transaction.
     * @dev All-or-nothing: if any cancellation fails, entire batch reverts.
     * @dev Emits individual PodListingCancelled events for each listing.
     * @param params Array of cancellation parameters for each listing
     */
    function multiCancelPodListing(
        CancelPodListingParams[] calldata params
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        address user = LibTractor._user();
        for (uint256 i; i < params.length; i++) {
            LibMarket._cancelPodListing(user, params[i].fieldId, params[i].index);
        }
    }

    /*
     * Pod Order Batch Operations
     */

    /**
     * @notice Creates multiple pod orders in a single transaction.
     * @dev All-or-nothing: if any order creation fails, entire batch reverts.
     * @dev Emits individual PodOrderCreated events for each order.
     * @dev All orders use the same transfer mode for locking beans.
     * @param params Array of order creation parameters
     * @param mode The transfer mode for locking beans in orders
     * @return ids Array of order IDs created
     */
    function multiCreatePodOrder(
        CreatePodOrderParams[] calldata params,
        LibTransfer.From mode
    )
        external
        payable
        fundsSafu
        noSupplyChange
        noOutFlow
        nonReentrant
        returns (bytes32[] memory ids)
    {
        address user = LibTractor._user();
        ids = new bytes32[](params.length);
        for (uint256 i; i < params.length; i++) {
            require(params[i].order.orderer == user, "Marketplace: Non-user create order.");
            uint256 beanAmount = LibTransfer.receiveToken(
                BeanstalkERC20(s.sys.bean),
                params[i].beanAmount,
                user,
                mode
            );
            ids[i] = _createPodOrder(params[i].order, beanAmount);
        }
    }

    /**
     * @notice Fills multiple pod orders in a single transaction.
     * @dev All-or-nothing: if any fill fails, entire batch reverts.
     * @dev Emits individual PodOrderFilled events for each order.
     * @dev All orders use the same transfer mode for receiving beans.
     * @param params Array of fill parameters for each order
     * @param mode The transfer mode for receiving beans from orders
     */
    function multiFillPodOrder(
        FillPodOrderParams[] calldata params,
        LibTransfer.To mode
    ) external payable fundsSafu noSupplyChange oneOutFlow(s.sys.bean) nonReentrant {
        address user = LibTractor._user();
        for (uint256 i; i < params.length; i++) {
            _fillPodOrder(
                params[i].order,
                user,
                params[i].index,
                params[i].start,
                params[i].amount,
                mode
            );
        }
    }

    /**
     * @notice Cancels multiple pod orders in a single transaction.
     * @dev All-or-nothing: if any cancellation fails, entire batch reverts.
     * @dev Emits individual PodOrderCancelled events for each order.
     * @dev All orders use the same transfer mode for returning beans.
     * @param podOrders Array of pod orders to cancel
     * @param mode The transfer mode for returning beans to the orderer
     */
    function multiCancelPodOrder(
        PodOrder[] calldata podOrders,
        LibTransfer.To mode
    ) external payable fundsSafu noSupplyChange oneOutFlow(s.sys.bean) nonReentrant {
        address user = LibTractor._user();
        for (uint256 i; i < podOrders.length; i++) {
            require(podOrders[i].orderer == user, "Marketplace: Non-user cancel order.");
            _cancelPodOrder(podOrders[i], mode);
        }
    }
}

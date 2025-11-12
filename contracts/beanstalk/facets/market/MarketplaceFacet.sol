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
 **/

contract MarketplaceFacet is Invariable, Order {
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
     * Pod Listing
     */

    function createPodListing(
        PodListing calldata podListing
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        require(podListing.lister == LibTractor._user(), "Marketplace: Non-user create listing.");
        _createPodListing(podListing);
    }

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

    // Fill
    function fillPodListing(
        PodListing calldata podListing,
        uint256 beanAmount,
        LibTransfer.From mode
    ) external payable fundsSafu noSupplyChange oneOutFlow(s.sys.bean) nonReentrant {
        beanAmount = LibTransfer.transferToken(
            BeanstalkERC20(s.sys.bean),
            LibTractor._user(),
            podListing.lister,
            beanAmount,
            mode,
            podListing.mode
        );
        _fillListing(podListing, LibTractor._user(), beanAmount);
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

    // Cancel
    function cancelPodListing(
        uint256 fieldId,
        uint256 index
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        LibMarket._cancelPodListing(LibTractor._user(), fieldId, index);
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

    function getPodListing(uint256 fieldId, uint256 index) external view returns (bytes32 id) {
        return s.sys.podListings[fieldId][index];
    }

    /*
     * Pod Orders
     */

    // Create
    function createPodOrder(
        PodOrder calldata podOrder,
        uint256 beanAmount,
        LibTransfer.From mode
    ) external payable fundsSafu noSupplyChange noOutFlow nonReentrant returns (bytes32 id) {
        require(podOrder.orderer == LibTractor._user(), "Marketplace: Non-user create order.");
        beanAmount = LibTransfer.receiveToken(
            BeanstalkERC20(s.sys.bean),
            beanAmount,
            LibTractor._user(),
            mode
        );
        return _createPodOrder(podOrder, beanAmount);
    }

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
    ) external payable fundsSafu noSupplyChange noOutFlow nonReentrant returns (bytes32[] memory ids) {
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

    // Fill
    function fillPodOrder(
        PodOrder calldata podOrder,
        uint256 index,
        uint256 start,
        uint256 amount,
        LibTransfer.To mode
    ) external payable fundsSafu noSupplyChange oneOutFlow(s.sys.bean) nonReentrant {
        _fillPodOrder(podOrder, LibTractor._user(), index, start, amount, mode);
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

    // Cancel
    function cancelPodOrder(
        PodOrder calldata podOrder,
        LibTransfer.To mode
    ) external payable fundsSafu noSupplyChange oneOutFlow(s.sys.bean) nonReentrant {
        require(podOrder.orderer == LibTractor._user(), "Marketplace: Non-user cancel order.");
        _cancelPodOrder(podOrder, mode);
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

    // Get

    function getOrderId(PodOrder calldata podOrder) external pure returns (bytes32 id) {
        return _getOrderId(podOrder);
    }

    function getPodOrder(bytes32 id) external view returns (uint256) {
        return s.sys.podOrders[id];
    }

    /*
     * Transfer Plot
     */

    /**
     * @notice transfers a plot from `sender` to `recipient`.
     */
    function transferPlot(
        address sender,
        address recipient,
        uint256 fieldId,
        uint256 index,
        uint256 start,
        uint256 end
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        require(
            sender != address(0) && recipient != address(0),
            "Field: Transfer to/from 0 address."
        );
        uint256 transferAmount = validatePlotAndReturnPods(fieldId, sender, index, start, end);
        if (
            LibTractor._user() != sender &&
            allowancePods(sender, LibTractor._user(), fieldId) != type(uint256).max
        ) {
            decrementAllowancePods(sender, LibTractor._user(), fieldId, transferAmount);
        }

        if (s.sys.podListings[fieldId][index] != bytes32(0)) {
            LibMarket._cancelPodListing(sender, fieldId, index);
        }
        _transferPlot(sender, recipient, fieldId, index, start, transferAmount);
    }

    /**
     * @notice transfers multiple plots from `sender` to `recipient`.
     */
    function transferPlots(
        address sender,
        address recipient,
        uint256 fieldId,
        uint256[] calldata ids,
        uint256[] calldata starts,
        uint256[] calldata ends
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        require(
            sender != address(0) && recipient != address(0),
            "Field: Transfer to/from 0 address."
        );
        require(
            ids.length == starts.length && ids.length == ends.length,
            "Field: Array length mismatch."
        );
        uint256 totalAmount = _transferPlots(sender, recipient, fieldId, ids, starts, ends);

        // Decrement allowance is done on totalAmount rather than per plot.
        if (
            LibTractor._user() != sender &&
            allowancePods(sender, LibTractor._user(), fieldId) != type(uint256).max
        ) {
            decrementAllowancePods(sender, LibTractor._user(), fieldId, totalAmount);
        }
    }

    /**
     * @notice internal function to transfer multiple plots from `sender` to `recipient`.
     * @dev placed in a function due to stack.
     */
    function _transferPlots(
        address sender,
        address recipient,
        uint256 fieldId,
        uint256[] calldata ids,
        uint256[] calldata starts,
        uint256[] calldata ends
    ) internal returns (uint256 totalAmount) {
        for (uint256 i; i < ids.length; i++) {
            uint256 amount = validatePlotAndReturnPods(fieldId, sender, ids[i], starts[i], ends[i]);
            if (s.sys.podListings[fieldId][ids[i]] != bytes32(0)) {
                LibMarket._cancelPodListing(sender, fieldId, ids[i]);
            }
            _transferPlot(sender, recipient, fieldId, ids[i], starts[i], amount);
            totalAmount += amount;
        }
    }

    /**
     * @notice validates the plot is valid and returns the pod being sent.
     */
    function validatePlotAndReturnPods(
        uint256 fieldId,
        address sender,
        uint256 id,
        uint256 start,
        uint256 end
    ) internal view returns (uint256 amount) {
        amount = s.accts[sender].fields[fieldId].plots[id];
        require(amount > 0, "Field: Plot not owned by user.");
        require(end > start && amount >= end, "Field: Pod range invalid.");
        amount = end - start;
    }

    /**
     * @notice Approves pods to be spent by `spender`.
     */
    function approvePods(
        address spender,
        uint256 fieldId,
        uint256 amount
    ) external payable fundsSafu noNetFlow noSupplyChange nonReentrant {
        require(spender != address(0), "Field: Pod Approve to 0 address.");
        setAllowancePods(LibTractor._user(), spender, fieldId, amount);
        emit PodApproval(LibTractor._user(), spender, fieldId, amount);
    }
}

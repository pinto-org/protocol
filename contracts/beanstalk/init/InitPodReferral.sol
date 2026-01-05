/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";

/**
 * @title InitPodReferral
 * @notice Initializes the Pod referral system
 * @dev Sets the referralPercentage in System storage
 **/
contract InitPodReferral {
    /// @notice Emitted when the referral percentage is changed (with 1e18 precision)
    event ReferralPercentageChanged(uint128 newReferrerPercentage);
    event RefereePercentageChanged(uint128 newRefereePercentage);
    event MaximumReferralPodsChanged(uint128 newMaximumReferralPods);

    uint128 internal constant INIT_REFERRER_PERCENTAGE = 0.1e18; // 10%
    uint128 internal constant INIT_REFEREE_PERCENTAGE = 0.1e18; // 10%
    uint128 internal constant MAXIMUM_REFERRAL_PODS = 100_000_000e6; // maximum number of pods that can be earned from the referral system.

    /**
     * @notice Initialize the Pod referral system.
     * @dev sets the percentages of referral, as well as initialize the addresses who are allowed to refer.
     */
    function initPodReferral(address[] memory allowedReferrers) internal {
        updateReferrerPercentage(INIT_REFERRER_PERCENTAGE);
        updateRefereePercentage(INIT_REFEREE_PERCENTAGE);
        setMaximumReferralPods(MAXIMUM_REFERRAL_PODS);
        initializeReferrers(allowedReferrers);
    }

    function updateReferrerPercentage(uint128 newReferrerPercentage) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.referrerPercentage = newReferrerPercentage;
        emit ReferralPercentageChanged(newReferrerPercentage);
    }

    function updateRefereePercentage(uint128 newRefereePercentage) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.refereePercentage = newRefereePercentage;
        emit RefereePercentageChanged(newRefereePercentage);
    }

    function setMaximumReferralPods(uint128 newMaximumReferralPods) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.maximumReferralPods = newMaximumReferralPods;
        emit MaximumReferralPodsChanged(newMaximumReferralPods);
    }

    function initializeReferrers(address[] memory allowedReferrers) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 activeField = s.sys.activeField;
        for (uint256 i = 0; i < allowedReferrers.length; i++) {
            s.accts[allowedReferrers[i]].fields[activeField].referral.eligibility = true;
        }
    }
}

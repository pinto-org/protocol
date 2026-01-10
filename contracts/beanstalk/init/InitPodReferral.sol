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
    event TargetReferralPodsChanged(uint128 newTargetReferralPods);
    event BeanSownEligibilityThresholdChanged(uint128 newBeanSownEligibilityThreshold);

    uint128 internal constant INIT_REFERRER_PERCENTAGE = 0.1e6; // 10%
    uint128 internal constant INIT_REFEREE_PERCENTAGE = 0.05e6; // 5%
    uint128 internal constant MAXIMUM_REFERRAL_PODS = 2_000_000e6; // maximum number of pods that can be earned from the referral system.
    uint128 internal constant INIT_BEANS_FOR_ELIGIBILITY = 1000e6; // the number of beans that a user will need to sow to be eligible for referral rewards.
    /**
     * @notice Initialize the Pod referral system.
     * @dev sets the percentages of referral, as well as initialize the addresses who are allowed to refer.
     */
    function init(address[] memory allowedReferrers) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        updateReferrerPercentage(s, INIT_REFERRER_PERCENTAGE);
        updateRefereePercentage(s, INIT_REFEREE_PERCENTAGE);
        setTargetReferralPods(s, MAXIMUM_REFERRAL_PODS);
        setBeanSownEligibilityThreshold(s, INIT_BEANS_FOR_ELIGIBILITY);
        initializeReferrers(s,allowedReferrers);
    }

    function updateReferrerPercentage(AppStorage storage s, uint128 newReferrerPercentage) internal {
        s.sys.referrerPercentage = newReferrerPercentage;
        emit ReferralPercentageChanged(newReferrerPercentage);
    }

    function updateRefereePercentage(AppStorage storage s, uint128 newRefereePercentage) internal {
        s.sys.refereePercentage = newRefereePercentage;
        emit RefereePercentageChanged(newRefereePercentage);
    }

    function setTargetReferralPods(AppStorage storage s, uint128 newTargetReferralPods) internal {
        s.sys.targetReferralPods = newTargetReferralPods;
        emit TargetReferralPodsChanged(newTargetReferralPods);
    }

    function setBeanSownEligibilityThreshold(AppStorage storage s, uint128 newBeanSownEligibilityThreshold) internal {
        s.sys.referralBeanSownEligibilityThreshold = newBeanSownEligibilityThreshold;
        emit BeanSownEligibilityThresholdChanged(newBeanSownEligibilityThreshold);
    }

    function initializeReferrers(AppStorage storage s, address[] memory allowedReferrers) internal {
        uint256 activeField = s.sys.activeField;
        for (uint256 i = 0; i < allowedReferrers.length; i++) {
            s.accts[allowedReferrers[i]].fields[activeField].referral.eligibility = true;
            s.accts[allowedReferrers[i]].fields[activeField].referral.beans = INIT_BEANS_FOR_ELIGIBILITY;
        }
    }
}

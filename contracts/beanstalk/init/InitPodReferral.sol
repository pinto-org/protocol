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

    uint128 internal constant INIT_REFERRER_PERCENTAGE = 0.01e18; // 10%
    uint128 internal constant INIT_REFEREE_PERCENTAGE = 0.01e18; // 10%

    /**
     * @notice Initialize the Pod referral system
     */
    function init() external {
        updateReferrerPercentage(INIT_REFERRER_PERCENTAGE);
        updateRefereePercentage(INIT_REFEREE_PERCENTAGE);
    }

    function updateReferrerPercentage(uint128 newReferrerPercentage) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.referrerPercentage = newReferrerPercentage;
        emit ReferralPercentageChanged(newReferrerPercentage);
    }

    function updateRefereePercentage(uint128 newRefereePercentage) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.refereePercentage = newRefereePercentage;
        emit ReferralPercentageChanged(newRefereePercentage);
    }
}

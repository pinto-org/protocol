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
    /// @notice Emitted when the referral percentage is changed
    /// @param newReferralPercentage The new referral percentage (with 1e18 precision)
    event ReferralPercentageChanged(uint256 newReferralPercentage);

    uint256 internal constant INIT_REFERRAL_PERCENTAGE = 0.01e18; // 10%

    /**
     * @notice Initialize the Pod referral system
     */
    function init() external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // Set initial referral percentage to 5%
        s.sys.referralPercentage = INIT_REFERRAL_PERCENTAGE;

        emit ReferralPercentageChanged(INIT_REFERRAL_PERCENTAGE);
    }
}

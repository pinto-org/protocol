/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {C} from "contracts/C.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {ReentrancyGuard} from "contracts/beanstalk/ReentrancyGuard.sol";
import {LibRedundantMath32} from "contracts/libraries/Math/LibRedundantMath32.sol";
import {LibRedundantMath128} from "contracts/libraries/Math/LibRedundantMath128.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {LibDibbler} from "contracts/libraries/LibDibbler.sol";
import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {LibMarket} from "contracts/libraries/LibMarket.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";

interface IBeanstalk {
    function cancelPodListing(uint256 fieldId, uint256 index) external;
}

/**
 * @title FieldFacet
 * @notice The Field is where Beans are Sown and Pods are Harvested.
 */
contract FieldFacet is Invariable, ReentrancyGuard {
    using LibRedundantMath256 for uint256;
    using LibRedundantMath32 for uint32;
    using LibRedundantMath128 for uint128;

    /**
     * @notice Plot struct contains the plot index and amount of pods the plot contains.
     */
    struct Plot {
        uint256 index;
        uint256 pods;
    }

    /**
     * @notice Emitted when a new Field is added.
     * @param fieldId The index of the Field that was added.
     */
    event FieldAdded(uint256 fieldId);

    /**
     * @notice Emitted when the active Field is modified.
     * @param fieldId The index of the Field that was set to active.
     */
    event ActiveFieldSet(uint256 fieldId);

    /**
     * @notice Emitted when `account` claims the Beans associated with Harvestable Pods.
     * @param account The account that owns the `plots`
     * @param plots The indices of Plots that were harvested
     * @param beans The amount of Beans transferred to `account`
     */
    event Harvest(address indexed account, uint256 fieldId, uint256[] plots, uint256 beans);

    //////////////////// SOW ////////////////////

    /**
     * @notice Sow Beans in exchange for Pods.
     * @param beans The number of Beans to Sow
     * @param minTemperature The minimum Temperature at which to Sow
     * @param mode The balance to transfer Beans from; see {LibTransfer.From}
     * @return pods The number of Pods received
     * @dev
     *
     * `minTemperature` has precision of 1e6. Wraps {sowWithMin} with `minSoil = beans`.
     *
     * NOTE: previously minTemperature was measured to 1e2 (1% = 1)
     *
     * Rationale for {sow} accepting a `minTemperature` parameter:
     * If someone sends a Sow transaction at the end of a Season, it could be
     * executed early in the following Season, at which time the temperature may be
     * significantly lower due to Morning Auction functionality.
     */
    function sow(
        uint256 beans,
        uint256 minTemperature,
        LibTransfer.From mode
    )
        external
        payable
        fundsSafu
        noSupplyIncrease
        oneOutFlow(s.sys.bean)
        nonReentrant
        returns (uint256 pods)
    {
        (pods, , ) = LibDibbler.sowWithMin(beans, minTemperature, beans, mode, address(0));
    }

    /**
     * @notice Sow Beans in exchange for Pods. Use at least `minSoil`.
     * @param beans The number of Beans to Sow
     * @param minTemperature The minimum Temperature at which to Sow
     * @param minSoil The minimum amount of Soil to use; reverts if there is
     * less than this much Soil available upon execution
     * @param mode The balance to transfer Beans from; see {LibTrasfer.From}
     * @return pods The number of Pods received
     */
    function sowWithMin(
        uint256 beans,
        uint256 minTemperature,
        uint256 minSoil,
        LibTransfer.From mode
    )
        external
        payable
        fundsSafu
        noSupplyIncrease
        oneOutFlow(s.sys.bean)
        nonReentrant
        returns (uint256 pods)
    {
        (pods, , ) = LibDibbler.sowWithMin(beans, minTemperature, minSoil, mode, address(0));
    }

    /**
     * @notice Sow Beans in exchange for Pods with a referral. See {FieldFacet.sowWithMin} for more details.
     * @dev If the referral is not valid, the function will silently return 0 for referrerPods and refereePods.
     */
    function sowWithReferral(
        uint256 beans,
        uint256 minTemperature,
        uint256 minSoil,
        LibTransfer.From mode,
        address referral
    )
        external
        fundsSafu
        noSupplyIncrease
        oneOutFlow(s.sys.bean)
        nonReentrant
        returns (uint256 pods, uint256 referrerPods, uint256 refereePods)
    {
        return LibDibbler.sowWithMin(beans, minTemperature, minSoil, mode, referral);
    }

    //////////////////// HARVEST ////////////////////

    /**
     * @notice Harvest Pods from the Field.
     * @param fieldId The index of the Field to Harvest from.
     * @param plots List of plot IDs to Harvest
     * @param mode The balance to transfer Beans to; see {LibTrasfer.To}
     * @dev Redeems Pods for Beans. When Pods become Harvestable, they are
     * redeemable for 1 Bean each.
     *
     * The Beans used to pay Harvestable Pods are minted during {Sun.stepSun}.
     * Beanstalk holds these Beans until `harvest()` is called.
     *
     * Pods are "burned" when the corresponding Plot is deleted from
     * `s.accts[account].fields[fieldId].plots`.
     */
    function harvest(
        uint256 fieldId,
        uint256[] calldata plots,
        LibTransfer.To mode
    )
        external
        payable
        fundsSafu
        noSupplyChange
        oneOutFlow(s.sys.bean)
        nonReentrant
        returns (uint256 beansHarvested)
    {
        beansHarvested = _harvest(fieldId, plots);
        LibTransfer.sendToken(BeanstalkERC20(s.sys.bean), beansHarvested, LibTractor._user(), mode);
    }

    /**
     * @dev Ensure that each Plot is at least partially harvestable, burn the Plot,
     * update the total harvested, and emit a {Harvest} event.
     */
    function _harvest(
        uint256 fieldId,
        uint256[] calldata plots
    ) internal returns (uint256 beansHarvested) {
        for (uint256 i; i < plots.length; ++i) {
            // The Plot is partially harvestable if its index is less than
            // the current harvestable index.
            require(plots[i] < s.sys.fields[fieldId].harvestable, "Field: Plot not Harvestable");
            uint256 harvested = _harvestPlot(LibTractor._user(), fieldId, plots[i]);
            beansHarvested += harvested;
        }
        s.sys.fields[fieldId].harvested += beansHarvested;
        emit Harvest(LibTractor._user(), fieldId, plots, beansHarvested);
    }

    /**
     * @dev Check if a Plot is at least partially Harvestable; calculate how many
     * Pods are Harvestable, create a new Plot if necessary.
     */
    function _harvestPlot(
        address account,
        uint256 fieldId,
        uint256 index
    ) private returns (uint256 harvestablePods) {
        // Check that `account` holds this Plot.
        uint256 pods = s.accts[account].fields[fieldId].plots[index];
        require(pods > 0, "Field: no plot");

        // Calculate how many Pods are harvestable.
        // The upstream _harvest function checks that at least some Pods
        // are harvestable.
        harvestablePods = s.sys.fields[fieldId].harvestable.sub(index);

        LibMarket._cancelPodListing(LibTractor._user(), fieldId, index);

        delete s.accts[account].fields[fieldId].plots[index];
        LibDibbler.removePlotIndexFromAccount(account, fieldId, index);

        // If the entire Plot was harvested, exit.
        if (harvestablePods >= pods) {
            return pods;
        }

        // Create a new Plot with remaining Pods.
        uint256 newIndex = index.add(harvestablePods);
        s.accts[account].fields[fieldId].plots[newIndex] = pods.sub(harvestablePods);
        s.accts[account].fields[fieldId].plotIndexes.push(newIndex);
        s.accts[account].fields[fieldId].piIndex[newIndex] =
            s.accts[account].fields[fieldId].plotIndexes.length -
            1;
    }

    //////////////////// CONFIG /////////////////////

    /**
     * @notice Add a new Field to the system.
     * @dev It is not possible to remove a Field, but a Field's Plan can be nullified.
     */
    function addField() public fundsSafu noSupplyChange noNetFlow nonReentrant {
        LibDiamond.enforceIsOwnerOrContract();
        uint256 fieldId = s.sys.fieldCount;
        s.sys.fieldCount++;
        emit FieldAdded(fieldId);
    }

    /**
     * @notice Set the active Field. Only the active field is accrues Soil.
     * @param fieldId ID of the Field to set as active. ID is the Field Number.
     */
    function setActiveField(
        uint256 fieldId,
        uint32 _temperature
    ) public fundsSafu noSupplyChange noNetFlow nonReentrant {
        LibDiamond.enforceIsOwnerOrContract();
        require(fieldId < s.sys.fieldCount, "Field: Field does not exist");
        s.sys.activeField = fieldId;

        // Reset weather.
        s.sys.weather.temp = _temperature;
        s.sys.weather.thisSowTime = type(uint32).max;
        s.sys.weather.lastSowTime = type(uint32).max;
        s.sys.weather.lastDeltaSoil = 0;

        emit ActiveFieldSet(fieldId);
    }

    //////////////////// GETTERS ////////////////////

    /**
     * @notice Returns the total number of Pods ever minted in the Field.
     * @param fieldId The index of the Field to query.
     */
    function podIndex(uint256 fieldId) public view returns (uint256) {
        return s.sys.fields[fieldId].pods;
    }

    /**
     * @notice Returns the index below which Pods are Harvestable.
     * @param fieldId The index of the Field to query.
     */
    function harvestableIndex(uint256 fieldId) public view returns (uint256) {
        return s.sys.fields[fieldId].harvestable;
    }

    /**
     * @notice Returns the number of outstanding Pods. Includes Pods that are
     * currently Harvestable but have not yet been Harvested.
     * @param fieldId The index of the Field to query.
     */
    function totalPods(uint256 fieldId) public view returns (uint256) {
        return s.sys.fields[fieldId].pods - s.sys.fields[fieldId].harvested;
    }

    /**
     * @notice Returns the number of Pods that have ever been Harvested.
     * @param fieldId The index of the Field to query.
     */
    function totalHarvested(uint256 fieldId) public view returns (uint256) {
        return s.sys.fields[fieldId].harvested;
    }

    /**
     * @notice Returns the number of Pods that are currently Harvestable but
     * have not yet been Harvested.
     * @dev This is the number of Pods that Beanstalk is prepared to pay back,
     * but that haven’t yet been claimed via the `harvest()` function.
     * @param fieldId The index of the Field to query.
     */
    function totalHarvestable(uint256 fieldId) public view returns (uint256) {
        return s.sys.fields[fieldId].harvestable - s.sys.fields[fieldId].harvested;
    }

    /**
     * @notice Returns the number of Pods that are currently Harvestable for the active Field.
     */
    function totalHarvestableForActiveField() public view returns (uint256) {
        return
            s.sys.fields[s.sys.activeField].harvestable - s.sys.fields[s.sys.activeField].harvested;
    }

    /**
     * @notice Returns the number of Pods that are not yet Harvestable. Also known as the Pod Line.
     * @param fieldId The index of the Field to query.
     */
    function totalUnharvestable(uint256 fieldId) public view returns (uint256) {
        return s.sys.fields[fieldId].pods - s.sys.fields[fieldId].harvestable;
    }

    /**
     * @notice Returns the number of Pods that are not yet Harvestable for the active Field.
     */
    function totalUnharvestableForActiveField() public view returns (uint256) {
        return s.sys.fields[s.sys.activeField].pods - s.sys.fields[s.sys.activeField].harvestable;
    }

    /**
     * @notice Returns the number of Pods that were made Harvestable during the last Season as a result of flooding.
     */
    function floodHarvestablePods() public view returns (uint256) {
        return s.sys.rain.floodHarvestablePods;
    }

    /**
     * @notice Returns true if there exists un-harvestable pods.
     * @param fieldId The index of the Field to query.
     */
    function isHarvesting(uint256 fieldId) public view returns (bool) {
        return totalUnharvestable(fieldId) > 0;
    }

    /**
     * @notice Returns the number of Pods remaining in a Plot.
     * @dev Plots are only stored in the `s.accts[account].fields[fieldId].plots` mapping.
     * @param fieldId The index of the Field to query.
     */
    function plot(address account, uint256 fieldId, uint256 index) public view returns (uint256) {
        return s.accts[account].fields[fieldId].plots[index];
    }

    function activeField() public view returns (uint256) {
        return s.sys.activeField;
    }

    function fieldCount() public view returns (uint256) {
        return s.sys.fieldCount;
    }

    //////////////////// GETTERS: SOIL ////////////////////

    /**
     * @notice Returns the total amount of available Soil. 1 Bean can be Sown in
     * 1 Soil for Pods.
     * @dev When above peg, Soil is dynamic because the number of Pods that
     * Beanstalk is willing to mint is fixed.
     */
    function totalSoil() external view returns (uint256) {
        // Below peg: Soil is fixed to the amount set during {calcCaseId}.
        if (!s.sys.season.abovePeg) {
            return uint256(s.sys.soil);
        }

        // Above peg: Soil is dynamic
        return
            LibDibbler.scaleSoilUp(
                uint256(s.sys.soil), // min soil
                uint256(s.sys.weather.temp), // max temperature (1e6 precision)
                LibDibbler.morningTemperature() // temperature adjusted by number of blocks since Sunrise
            );
    }

    function initialSoil() external view returns (uint256) {
        return uint256(s.sys.soil);
    }

    /**
     * @notice Returns the threshold at which soil is considered sold out.
     * @dev Soil is considered sold out if it has less than SOLD_OUT_THRESHOLD_PERCENT% of the initial soil left
     * @return soilSoldOutThreshold The threshold at which soil is considered sold out.
     */
    function getSoilSoldOutThreshold() external view returns (uint256) {
        return LibDibbler.getSoilSoldOutThreshold(uint256(s.sys.initialSoil));
    }

    /**
     * @notice Returns the threshold at which soil is considered mostly sold out.
     * @dev Soil is considered mostly sold out if it has less than ALMOST_SOLD_OUT_THRESHOLD_PERCENT% + soilSoldOutThreshold of the initial soil left
     * @return soilMostlySoldOutThreshold The threshold at which soil is considered mostly sold out.
     */
    function getSoilMostlySoldOutThreshold() external view returns (uint256) {
        uint256 startingSoil = uint256(s.sys.initialSoil);
        uint256 soilSoldOutThreshold = LibDibbler.getSoilSoldOutThreshold(startingSoil);
        return LibDibbler.getSoilMostlySoldOutThreshold(startingSoil, soilSoldOutThreshold);
    }

    //////////////////// GETTERS: TEMPERATURE ////////////////////

    /**
     * @notice Returns the current Temperature, the interest rate offered by Beanstalk.
     * The Temperature scales up during the first 25 blocks after Sunrise.
     */
    function temperature() external view returns (uint256) {
        return LibDibbler.morningTemperature();
    }

    /**
     * @notice Returns the max Temperature that Beanstalk is willing to offer this Season.
     * @dev For gas efficiency, Beanstalk stores `s.sys.weather.temp` as a uint64 with precision of 1e6.
     */
    function maxTemperature() external view returns (uint256) {
        return uint256(s.sys.weather.temp);
    }

    //////////////////// GETTERS: PODS ////////////////////

    /**
     * @notice Returns the remaining Pods that could be issued this Season.
     */
    function remainingPods() external view returns (uint256) {
        return uint256(LibDibbler.remainingPods());
    }

    /**
     * @notice returns the plotIndexes owned by `account`.
     */
    function getPlotIndexesFromAccount(
        address account,
        uint256 fieldId
    ) external view returns (uint256[] memory plotIndexes) {
        return s.accts[account].fields[fieldId].plotIndexes;
    }

    /**
     * @notice returns the plots owned by `account`.
     */
    function getPlotsFromAccount(
        address account,
        uint256 fieldId
    ) external view returns (Plot[] memory plots) {
        uint256[] memory plotIndexes = s.accts[account].fields[fieldId].plotIndexes;
        if (plotIndexes.length == 0) return plots;
        plots = new Plot[](plotIndexes.length);
        for (uint256 i = 0; i < plotIndexes.length; i++) {
            uint256 index = plotIndexes[i];
            plots[i] = Plot(index, s.accts[account].fields[fieldId].plots[index]);
        }
    }

    /**
     * @notice returns the number of pods owned by `account` in a field.
     */
    function balanceOfPods(address account, uint256 fieldId) external view returns (uint256 pods) {
        uint256[] memory plotIndexes = s.accts[account].fields[fieldId].plotIndexes;
        for (uint256 i = 0; i < plotIndexes.length; i++) {
            pods += s.accts[account].fields[fieldId].plots[plotIndexes[i]];
        }
    }

    /**
     * @notice Returns the number of Beans that have been Sown this season.
     */
    function beanSown() external view returns (uint256) {
        return s.sys.beanSown;
    }

    function getReferrerPercentage() external view returns (uint256) {
        return s.sys.referrerPercentage;
    }

    function getRefereePercentage() external view returns (uint256) {
        return s.sys.refereePercentage;
    }

    function getBeanSownEligibilityThreshold() external view returns (uint256) {
        return s.sys.referralBeanSownEligibilityThreshold;
    }

    function isValidReferrer(address referrer) external view returns (bool) {
        uint256 af = s.sys.activeField;
        return s.accts[referrer].fields[af].referral.eligibility;
    }

    function getBeansSownForReferral(address referrer) external view returns (uint256) {
        uint256 af = s.sys.activeField;
        return s.accts[referrer].fields[af].referral.beans;
    }
}

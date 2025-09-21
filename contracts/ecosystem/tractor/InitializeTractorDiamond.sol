// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {IDiamondCut} from "contracts/interfaces/IDiamondCut.sol";
import {ITractorDiamond} from "contracts/ecosystem/tractor/ITractorDiamond.sol";

/**
 * @title InitializeTractorDiamond
 * @notice Initialization contract for TractorDiamond, sets up Tractor-specific facets and selectors.
 */
contract InitializeTractorDiamond is ITractorDiamond {
    // @notice Publish Tractor data
    // @param version The version of the Tractor data
    // @param data The Tractor data
    function publishTractorData(uint8 version, bytes calldata data) external {
        emit TractorDataPublished(version, data);
    }

    // @notice Publish multiple Tractor data
    // @param version The version of the Tractor data
    // @param data The Tractor data
    function publishMultiTractorData(uint8 version, bytes[] calldata data) external {
        emit MultiTractorDataPublished(version, data);
    }

    function addTractorDiamondImmutables() internal {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        bytes4[] memory functionSelectors = new bytes4[](2);
        functionSelectors[0] = ITractorDiamond.publishTractorData.selector;
        functionSelectors[1] = ITractorDiamond.publishMultiTractorData.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(this),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectors
        });
        LibDiamond.diamondCut(cut, address(0), "");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/******************************************************************************\
* Authors: Nick Mudge (https://twitter.com/mudgen)
*
* Implementation of a diamond.
/******************************************************************************/

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {DiamondCutFacet} from "../beanstalk/facets/diamond/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../beanstalk/facets/diamond/DiamondLoupeFacet.sol";
import {AppStorage} from "../beanstalk/storage/AppStorage.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";

contract MockDiamond {
    AppStorage internal s;

    receive() external payable {}

    function mockInit(address _contractOwner) external {
        LibDiamond.setContractOwner(_contractOwner);
        LibDiamond.addDiamondFunctions(
            address(new DiamondCutFacet()),
            address(new DiamondLoupeFacet())
        );
    }

    // Find facet for function that is called and execute the
    // function if a facet is found and return any value.
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: Function does not exist");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }
}

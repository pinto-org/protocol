/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {SeasonGettersFacet} from "../../beanstalk/facets/sun/SeasonGettersFacet.sol";
import {LibDeltaB} from "contracts/libraries/Oracle/LibDeltaB.sol";
import {LibAppStorage, AppStorage} from "contracts/libraries/LibAppStorage.sol";
import "forge-std/console.sol";

/**
 * @title Mock Season Getters Facet
 **/
contract MockSeasonGettersFacet is SeasonGettersFacet {
    // this mock removes the isWell check, so that a well's deltaB can be checked without requiring whitelisting
    function poolCurrentDeltaBMock(address pool) public view returns (int256 deltaB) {
        console.log("poolCurrentDeltaB");
        (deltaB) = LibDeltaB.currentDeltaB(pool);
        return deltaB;
    }

    function mockInitState() public {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.bean = 0xBEA0000029AD1c77D3d5D23Ba2D8893dB9d1Efab;
    }
}

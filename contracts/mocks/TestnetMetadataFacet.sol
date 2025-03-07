/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import "contracts/beanstalk/facets/metadata/abstract/MetadataImage.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";
import {LibTokenSilo} from "contracts/libraries/Silo/LibTokenSilo.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";

/**
 * @title MockMetadataFacet is a Mock version of MetadataFacet.
 * @dev used to deploy on testnets to verify that json data and SVG encoding is correct.
 * Steps for testing:
 * 1: deploy MockMetadataFacet
 * 2: deploy MetadataMockERC1155 with the address of the MockMetadataFacet.
 * (MockMetadataFacet with ERC1155 exceeds the contract size limit.)
 **/
contract TestnetMetadataFacet is MetadataImage {
    using LibRedundantMath256 for uint256;

    // initial conditions: 2 seeds, 1000 seasons has elapsed from milestone season.
    uint256 public stalkEarnedPerSeason = 2e6;
    uint256 public seasonsElapsed = 1000;
    uint256 public stalkIssuedPerBdv = 10000;

    using Strings for uint256;
    using Strings for int256;

    event URI(string _uri, uint256 indexed _id);

    /**
     * @notice Returns the URI for a given depositId.
     * @param depositId - the id of the deposit
     * @dev the URI is a base64 encoded JSON object that contains the metadata and base64 encoded svg.
     * Deposits are stored as a mapping of a uint256 to a Deposit struct.
     * ERC20 deposits are represented by the concatination of the token address and the stem. (20 + 12 bytes).
     */
    function uri(uint256 depositId) public view returns (string memory) {
        (address token, int96 stem) = LibBytes.unpackAddressAndStem(depositId);
        int96 stemTip = int96(int256(stalkEarnedPerSeason.mul(seasonsElapsed)));
        bytes memory attributes = abi.encodePacked(
            ', "attributes": [ { "trait_type": "Token", "value": "',
            getTokenName(token),
            '"}, { "trait_type": "Token Address", "value": "',
            Strings.toHexString(uint256(uint160(token)), 20),
            '"}, { "trait_type": "Id", "value": "',
            depositId.toHexString(32),
            '"}, { "trait_type": "stem", "display_type": "number", "value": ',
            int256(stem).toStringSigned(),
            '}, { "trait_type": "initial stalk per PDV", "display_type": "number", "value": ',
            stalkIssuedPerBdv.toString(),
            '}, { "trait_type": "grown stalk per PDV", "display_type": "number", "value": ',
            uint256(int256(stemTip - stem)).toString(),
            '}, { "trait_type": "stalk grown per PDV per season", "display_type": "number", "value": ',
            stalkEarnedPerSeason.toString()
        );
        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    LibBytes64.encode(
                        abi.encodePacked(
                            "{",
                            '"name": "Silo Deposits", "description": "An ERC1155 representing an asset deposited in the Silo. Silo Deposits gain stalk and pinto seignorage. ',
                            '\\n\\nDISCLAIMER: Due diligence is imperative when assessing this NFT. Opensea and other NFT marketplaces cache the svg output and thus, may require the user to refresh the metadata to properly show the correct values."',
                            attributes,
                            string(abi.encodePacked('}], "image": "', imageURI(token, stem), '"')),
                            "}"
                        )
                    )
                )
            );
    }

    function name() external pure returns (string memory) {
        return "Silo Deposits";
    }

    function symbol() external pure returns (string memory) {
        return "DEPOSIT";
    }

    function setSeeds(uint256 _stalkEarnedPerSeason) external {
        stalkEarnedPerSeason = _stalkEarnedPerSeason;
    }

    function setSeasonElapsed(uint256 _seasonsElapsed) external {
        seasonsElapsed = _seasonsElapsed;
    }

    function setStalkIssuedPerBdv(uint256 _stalkIssuedPerBdv) external {
        stalkIssuedPerBdv = _stalkIssuedPerBdv;
    }
}

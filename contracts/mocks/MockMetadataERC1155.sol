// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/**
 * @dev used to deploy on testnets to verify that json data and SVG encoding is correct.
 * Steps for testing:
 * 1: deploy MockMetadataFacet
 * 2: deploy MetadataMockERC1155 with the address of the MockMetadataFacet.
 * (MockMetadataFacet with ERC1155 exceeds the contract size limit.)
 **/

interface IMetadataFacet {
    function uri(uint256 depositId) external view returns (string memory);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);
}

contract MockMetadataERC1155 is ERC1155 {
    address public mockMetadataFacetaddress;

    constructor(string memory name, address metadataAddress) ERC1155(name) {
        mockMetadataFacetaddress = metadataAddress;
    }

    function mockMint(address account, uint256 id, uint256 amount) external {
        _mint(account, id, amount, new bytes(0));
    }

    function changeMetadataFacet(address metadataAddress) external {
        mockMetadataFacetaddress = metadataAddress;
    }

    function uri(uint256 depositId) public view override returns (string memory) {
        return IMetadataFacet(mockMetadataFacetaddress).uri(depositId);
    }

    function symbol() external view returns (string memory) {
        return IMetadataFacet(mockMetadataFacetaddress).symbol();
    }
}

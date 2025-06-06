// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
pragma abicoder v2;

import "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";
import {LibWeth} from "contracts/libraries/Token/LibWeth.sol";

/**
 * @dev common utilities for forge tests
 */
contract Utils is Test {
    // beanstalk
    address payable constant BEANSTALK =
        payable(address(0xC1E088fC1323b20BCBee9bd1B9fC9546db5624C5));

    address constant PINTO = address(0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f);

    // bean tokens
    address constant L2_PINTO = address(0xb170000aeeFa790fa61D6e837d1035906839a3c8);

    address internal constant BEAN = 0xBEA0000029AD1c77D3d5D23Ba2D8893dB9d1Efab;
    address internal constant WETH = LibWeth.WETH;
    address internal constant L1_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant USDC_MINTER_BASE = 0x880AD1D79c50f9FA0050CDdAd139E52e06B9C725;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant BEAN_ETH_WELL = 0xBEA0e11282e2bB5893bEcE110cF199501e872bAd;
    address internal constant BEAN_WSTETH_WELL = 0xBeA0000113B0d182f4064C86B71c315389E4715D;
    address payable internal constant PIPELINE =
        payable(0xb1bE0001f5a373b69b1E132b420e6D9687155e80);

    IMockFBeanstalk bs;
    address internal deployer;

    using Strings for uint256;
    using Strings for bytes;
    address payable[] internal users;

    bytes32 internal nextUser = keccak256(abi.encodePacked("user address"));

    // Store private keys and their corresponding addresses
    mapping(address => uint256) internal _privateKeys;

    /// @dev impersonate `from`
    modifier prank(address from) {
        vm.startPrank(from);
        _;
        vm.stopPrank();
    }

    function getNextUserAddress() public returns (address payable) {
        //bytes32 to address conversion
        address payable user = payable(address(bytes20(nextUser)));
        nextUser = keccak256(abi.encodePacked(nextUser));
        return user;
    }

    // create users with 100 ether balance
    function createUsers(uint256 userNum) public returns (address payable[] memory) {
        address payable[] memory _users = new address payable[](userNum);
        for (uint256 i = 0; i < userNum; i++) {
            // Create deterministic private key
            uint256 privateKey = 0x1234 + i;
            // Get the corresponding address
            address payable user = payable(vm.addr(privateKey));

            // Store the private key
            _privateKeys[user] = privateKey;

            vm.label(user, string(abi.encodePacked("Farmer ", i.toString())));
            vm.deal(user, 100 ether);
            _users[i] = user;
        }
        return _users;
    }

    // Helper to get private key for an address
    function getPrivateKey(address user) public view returns (uint256) {
        return _privateKeys[user];
    }

    function toStalk(uint256 stalk) public pure returns (uint256) {
        return stalk * 1e10;
    }
}

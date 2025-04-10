/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {C} from "contracts/C.sol";
import {Invariable} from "contracts/beanstalk/Invariable.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {LibAppStorage} from "contracts/libraries/LibAppStorage.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {LibBalance} from "contracts/libraries/Token/LibBalance.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";
import {LibWeth} from "contracts/libraries/Token/LibWeth.sol";

/**
 * @title Mock Attack Facet
 * @notice Facet for simulating attacks by directly manipulating underlying Beanstalk state.
 **/
contract MockAttackFacet is Invariable {
    AppStorage internal s;

    address constant BEAN_ETH_WELL = 0xBEA0e11282e2bB5893bEcE110cF199501e872bAd;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function revert_netFlow() external noNetFlow {
        BeanstalkERC20(s.sys.bean).transferFrom(msg.sender, address(this), 1);
    }

    function revert_outFlow() external noOutFlow {
        BeanstalkERC20(s.sys.bean).transfer(msg.sender, 1);
    }

    function revert_oneOutFlow() external oneOutFlow(s.sys.bean) {
        BeanstalkERC20(s.sys.bean).transfer(msg.sender, 1);
        IERC20(WETH).transfer(msg.sender, 1);
    }

    function revert_supplyChange() external noSupplyChange {
        BeanstalkERC20(s.sys.bean).burn(1);
    }

    function revert_supplyIncrease() external noSupplyIncrease {
        BeanstalkERC20(s.sys.bean).mint(msg.sender, 1);
    }

    ////// Variations of asset theft, internal and external ///////

    /**
     * @notice Simulates stealing of Bean from Beanstalk diamond.
     * @dev Does not directly trigger an invariant failure.
     */
    function stealBeans(uint256 amount) external {
        BeanstalkERC20(s.sys.bean).transfer(msg.sender, amount);
    }

    function exploitUserInternalTokenBalance() public {
        LibBalance.increaseInternalBalance(msg.sender, IERC20(s.sys.bean), 100_000_000);
    }

    function exploitUserSendTokenInternal() public {
        LibTransfer.sendToken(
            IERC20(BEAN_ETH_WELL),
            100_000_000_000,
            msg.sender,
            LibTransfer.To.INTERNAL
        );
    }

    function exploitSop() public {
        s.sys.sop.plentyPerSopToken[WETH] = 100_000_000;
    }

    function exploitPodOrderBeans() public {
        s.sys.orderLockedBeans = 100_000_000;
    }
}

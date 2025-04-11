// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TractorHelpers} from "contracts/ecosystem/TractorHelpers.sol";
import {SowBlueprintv0} from "contracts/ecosystem/SowBlueprintv0.sol";
import {PriceManipulation} from "contracts/ecosystem/PriceManipulation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TractorHelper} from "test/foundry/utils/TractorHelper.sol";
import {PerFunctionPausable} from "contracts/ecosystem/PerFunctionPausable.sol";
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";

contract PerFunctionPausableTest is TractorHelper {
    address[] farmers;
    PriceManipulation priceManipulation;

    // Add constant for max grown stalk limit
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        farmers = createUsers(2);

        // Deploy price contract (needed for TractorHelpers)
        BeanstalkPrice beanstalkPrice = new BeanstalkPrice(address(bs));
        vm.label(address(beanstalkPrice), "BeanstalkPrice");

        // Deploy PriceManipulation first
        priceManipulation = new PriceManipulation(address(bs));
        vm.label(address(priceManipulation), "PriceManipulation");

        // Deploy TractorHelpers with PriceManipulation address
        tractorHelpers = new TractorHelpers(
            address(bs),
            address(beanstalkPrice),
            address(this),
            address(priceManipulation)
        );
        vm.label(address(tractorHelpers), "TractorHelpers");

        // Deploy SowBlueprintv0 with TractorHelpers address
        sowBlueprintv0 = new SowBlueprintv0(address(bs), address(this), address(tractorHelpers));
        vm.label(address(sowBlueprintv0), "SowBlueprintv0");

        setTractorHelpers(address(tractorHelpers));
        setSowBlueprintv0(address(sowBlueprintv0));
    }

    function test_pause() public {
        // Get function selectors for the functions we want to test
        bytes4 sowSelector = SowBlueprintv0.sowBlueprintv0.selector;
        bytes4 withdrawSelector = TractorHelpers.withdrawBeansFromSources.selector;

        // Test initial state
        assertFalse(
            sowBlueprintv0.functionPaused(sowSelector),
            "sowBlueprintv0 should not be paused initially"
        );
        assertFalse(
            tractorHelpers.functionPaused(withdrawSelector),
            "withdrawBeansFromSources should not be paused initially"
        );

        // Test non-owner access control
        vm.prank(farmers[1]);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, farmers[1])
        );
        sowBlueprintv0.pauseFunction(sowSelector);

        vm.prank(farmers[1]);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, farmers[1])
        );
        tractorHelpers.pauseFunction(withdrawSelector);

        // Test pausing individual functions
        vm.startPrank(address(this));
        sowBlueprintv0.pauseFunction(sowSelector);
        tractorHelpers.pauseFunction(withdrawSelector);
        vm.stopPrank();

        assertTrue(sowBlueprintv0.functionPaused(sowSelector), "sowBlueprintv0 should be paused");
        assertTrue(
            tractorHelpers.functionPaused(withdrawSelector),
            "withdrawBeansFromSources should be paused"
        );

        // Setup test state
        bs.setSoilE(100_000e6);
        mintTokensToUser(farmers[0], BEAN, 4000e6);
        vm.startPrank(farmers[0]);
        IERC20(BEAN).approve(address(bs), type(uint256).max);
        bs.deposit(BEAN, 4000e6, uint8(LibTransfer.From.EXTERNAL));
        vm.stopPrank();

        // Skip germination
        bs.siloSunrise(0);
        bs.siloSunrise(0);

        // Test sow function when paused
        (IMockFBeanstalk.Requisition memory req, ) = setupSowBlueprintv0Blueprint(
            farmers[0],
            SourceMode.PURE_PINTO,
            makeSowAmountsArray(1000e6, 1000e6, type(uint256).max),
            0, // minTemp
            int256(10e6), // tipAmount
            address(this),
            type(uint256).max, // maxPodlineLength
            MAX_GROWN_STALK_PER_BDV,
            0 // No runBlocksAfterSunrise
        );

        vm.prank(farmers[0]);
        bs.publishRequisition(req);

        vm.expectRevert("Function is paused");
        bs.tractor(
            IMockFBeanstalk.Requisition(req.blueprint, req.blueprintHash, req.signature),
            ""
        );

        // Test withdraw function when paused
        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = 0; // Bean token index

        req = setupWithdrawBeansBlueprint(
            farmers[0],
            100e6,
            sourceTokenIndices,
            MAX_GROWN_STALK_PER_BDV,
            LibTransfer.To.INTERNAL
        );

        vm.prank(farmers[0]);
        bs.publishRequisition(req);

        vm.expectRevert("Function is paused");
        vm.prank(farmers[0]);
        bs.tractor(
            IMockFBeanstalk.Requisition(req.blueprint, req.blueprintHash, req.signature),
            ""
        );

        // Test non-owner cannot unpause
        vm.prank(farmers[1]);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, farmers[1])
        );
        sowBlueprintv0.unpauseFunction(sowSelector);

        vm.prank(farmers[1]);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, farmers[1])
        );
        tractorHelpers.unpauseFunction(withdrawSelector);

        // Test unpausing functions
        vm.startPrank(address(this));
        sowBlueprintv0.unpauseFunction(sowSelector);
        tractorHelpers.unpauseFunction(withdrawSelector);
        vm.stopPrank();

        assertFalse(
            sowBlueprintv0.functionPaused(sowSelector),
            "sowBlueprintv0 should be unpaused"
        );
        assertFalse(
            tractorHelpers.functionPaused(withdrawSelector),
            "withdrawBeansFromSources should be unpaused"
        );

        (req, ) = setupSowBlueprintv0Blueprint(
            farmers[0],
            SourceMode.PURE_PINTO,
            makeSowAmountsArray(1000e6, 1000e6, type(uint256).max),
            0,
            int256(10e6),
            address(this),
            type(uint256).max,
            MAX_GROWN_STALK_PER_BDV,
            0
        );

        // Test functions work after unpausing
        executeRequisition(address(this), req, address(bs));

        // Verify sow succeeded
        assertEq(bs.totalSoil(), 100000e6 - 1000e6, "Soil should be reduced after successful sow");

        // Test withdraw works after unpausing
        req = setupWithdrawBeansBlueprint(
            farmers[0],
            100e6,
            sourceTokenIndices,
            MAX_GROWN_STALK_PER_BDV,
            LibTransfer.To.INTERNAL
        );

        vm.prank(farmers[0]);
        bs.publishRequisition(req);
        vm.prank(farmers[0]);
        bs.tractor(
            IMockFBeanstalk.Requisition(req.blueprint, req.blueprintHash, req.signature),
            ""
        );
    }

    // Helper function from SowBlueprintv0Test
    function makeSowAmountsArray(
        uint256 amountToSow,
        uint256 minAmountToSow,
        uint256 maxAmountToSowPerSeason
    ) internal pure returns (SowBlueprintv0.SowAmounts memory) {
        return
            SowBlueprintv0.SowAmounts({
                totalAmountToSow: amountToSow,
                minAmountToSowPerSeason: minAmountToSow,
                maxAmountToSowPerSeason: maxAmountToSowPerSeason
            });
    }
}

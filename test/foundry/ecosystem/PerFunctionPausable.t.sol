// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TractorHelpers} from "contracts/ecosystem/TractorHelpers.sol";
import {SowBlueprint} from "contracts/ecosystem/SowBlueprint.sol";
import {PriceManipulation} from "contracts/ecosystem/PriceManipulation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TractorTestHelper} from "test/foundry/utils/TractorTestHelper.sol";
import {PerFunctionPausable} from "contracts/ecosystem/PerFunctionPausable.sol";
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {SiloHelpers} from "contracts/ecosystem/SiloHelpers.sol";

contract PerFunctionPausableTest is TractorTestHelper {
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
        tractorHelpers = new TractorHelpers(address(bs), address(beanstalkPrice));
        vm.label(address(tractorHelpers), "TractorHelpers");

        // Deploy SiloHelpers first
        siloHelpers = new SiloHelpers(
            address(bs),
            address(tractorHelpers),
            address(priceManipulation)
        );
        vm.label(address(siloHelpers), "SiloHelpers");

        // Deploy SowBlueprint with TractorHelpers and SiloHelpers addresses
        sowBlueprint = new SowBlueprint(
            address(bs),
            address(this),
            address(tractorHelpers),
            address(siloHelpers)
        );
        vm.label(address(sowBlueprint), "SowBlueprint");

        setTractorHelpers(address(tractorHelpers));
        setSowBlueprintv0(address(sowBlueprint));
        setSiloHelpers(address(siloHelpers));
    }

    function test_pause() public {
        // Get function selectors for the functions we want to test
        bytes4 sowSelector = SowBlueprint.sowBlueprint.selector;

        // Test initial state
        assertFalse(
            sowBlueprint.functionPaused(sowSelector),
            "sowBlueprint should not be paused initially"
        );

        // Test non-owner access control
        vm.prank(farmers[1]);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, farmers[1])
        );
        sowBlueprint.pauseFunction(sowSelector);

        // Test pausing individual functions
        vm.startPrank(address(this));
        sowBlueprint.pauseFunction(sowSelector);
        vm.stopPrank();

        assertTrue(sowBlueprint.functionPaused(sowSelector), "sowBlueprint should be paused");

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

        // Test non-owner cannot unpause
        vm.prank(farmers[1]);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, farmers[1])
        );
        sowBlueprint.unpauseFunction(sowSelector);

        // Test unpausing functions
        vm.startPrank(address(this));
        sowBlueprint.unpauseFunction(sowSelector);
        vm.stopPrank();

        assertFalse(sowBlueprint.functionPaused(sowSelector), "sowBlueprint should be unpaused");

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
    }

    // Helper function from SowBlueprintv0Test
    function makeSowAmountsArray(
        uint256 amountToSow,
        uint256 minAmountToSow,
        uint256 maxAmountToSowPerSeason
    ) internal pure returns (SowBlueprint.SowAmounts memory) {
        return
            SowBlueprint.SowAmounts({
                totalAmountToSow: amountToSow,
                minAmountToSowPerSeason: minAmountToSow,
                maxAmountToSowPerSeason: maxAmountToSowPerSeason
            });
    }
}

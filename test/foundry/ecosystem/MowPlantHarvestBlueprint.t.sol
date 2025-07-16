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
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {OperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {MowPlantHarvestBlueprint} from "contracts/ecosystem/MowPlantHarvestBlueprint.sol";
import "forge-std/console.sol";

contract MowPlantHarvestBlueprintTest is TractorHelper {
    address[] farmers;
    PriceManipulation priceManipulation;
    BeanstalkPrice beanstalkPrice;

    uint256 STALK_DECIMALS = 1e10;
    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16; // Stalk is 1e16

    struct TestState {
        address user;
        address operator;
        address beanToken;
        uint256 initialUserBeanBalance;
        uint256 initialOperatorBeanBalance;
        uint256 mintAmount;
        int256 tipAmount;
    }

    function setUp() public {
        initializeBeanstalkTestState(true, false);
        farmers = createUsers(2);

        // Deploy PriceManipulation (unused here but needed for TractorHelpers)
        priceManipulation = new PriceManipulation(address(bs));
        vm.label(address(priceManipulation), "PriceManipulation");

        // Deploy BeanstalkPrice (unused here but needed for TractorHelpers)
        beanstalkPrice = new BeanstalkPrice(address(bs));
        vm.label(address(beanstalkPrice), "BeanstalkPrice");

        // Deploy TractorHelpers with PriceManipulation address
        tractorHelpers = new TractorHelpers(
            address(bs),
            address(beanstalkPrice),
            address(this),
            address(priceManipulation)
        );
        vm.label(address(tractorHelpers), "TractorHelpers");

        // Deploy MowPlantHarvestBlueprint with TractorHelpers address
        mowPlantHarvestBlueprint = new MowPlantHarvestBlueprint(
            address(bs),
            address(this),
            address(tractorHelpers)
        );
        vm.label(address(mowPlantHarvestBlueprint), "MowPlantHarvestBlueprint");

        setTractorHelpers(address(tractorHelpers));
        setMowPlantHarvestBlueprint(address(mowPlantHarvestBlueprint));

        // Advance season to grow stalk
        advanceSeason();
    }

    // Break out the setup into a separate function
    function setupMowPlantHarvestBlueprintTest(
        bool shouldMow, // if should mow, set up conditions for mowing
        bool shouldPlant, // if should plant, set up conditions for planting
        bool shouldHarvest, // if should harvest, set up conditions for harvesting
        bool abovePeg // if above peg, set up conditions for above peg
    ) internal returns (TestState memory) {
        // Create test state
        TestState memory state;
        state.user = farmers[0];
        state.operator = address(this);
        state.beanToken = bs.getBeanToken();
        state.initialUserBeanBalance = IERC20(state.beanToken).balanceOf(state.user);
        state.initialOperatorBeanBalance = bs.getInternalBalance(state.operator, state.beanToken);
        state.mintAmount = 100000e6;
        state.tipAmount = 10e6; // 10 BEAN

        // Mint 2x the amount to ensure we have enough for all test cases
        mintTokensToUser(state.user, state.beanToken, state.mintAmount);

        vm.prank(state.user);
        IERC20(state.beanToken).approve(address(bs), type(uint256).max);

        vm.prank(state.user);
        bs.deposit(state.beanToken, state.mintAmount, uint8(LibTransfer.From.EXTERNAL));

        // For farmer 1, deposit 1000e6 beans, and mint them 1000e6 beans
        mintTokensToUser(farmers[1], state.beanToken, 1000e6);
        vm.prank(farmers[1]);
        bs.deposit(state.beanToken, 1000e6, uint8(LibTransfer.From.EXTERNAL));

        // Add liquidity to manipulate deltaB
        if (abovePeg) {
            addLiquidityToWell(
                BEAN_ETH_WELL,
                10000e6, // 10,000 Beans
                11 ether // 10 ether.
            );
            addLiquidityToWell(
                BEAN_WSTETH_WELL,
                10010e6, // 10,010 Beans
                11 ether // 10 ether.
            );
        } else {
            addLiquidityToWell(
                BEAN_ETH_WELL,
                10000e6, // 10,000 Beans
                10 ether // 10 ether.
            );
            addLiquidityToWell(
                BEAN_WSTETH_WELL,
                10000e6, // 10,010 Beans
                10 ether // 10 ether.
            );
        }

        return state;
    }

    // Advance to the next season and update oracles
    function advanceSeason() internal {
        warpToNextSeasonTimestamp();
        bs.sunrise();
        updateAllChainlinkOraclesWithPreviousData();
    }

    /////////////////////////// TESTS ///////////////////////////

    function test_mowPlantHarvestBlueprint_smartMow() public {
        // Setup test state
        TestState memory state = setupMowPlantHarvestBlueprintTest(true, true, true, true);

        // Advance season to grow stalk
        advanceSeason();

        // get user state before mow see SiloGettersFacet
        uint256 userGrownStalk = bs.balanceOfGrownStalk(state.user, state.beanToken);
        console.log("userGrownStalk before mow", userGrownStalk);

        // log totalDeltaB
        console.log("totalDeltaB", bs.totalDeltaB());

        // Setup mowPlantHarvestBlueprint
        (IMockFBeanstalk.Requisition memory req, ) = setupMowPlantHarvestBlueprint(
            state.user, // account
            SourceMode.PURE_PINTO,
            1 * STALK_DECIMALS, // minMowAmount (1 stalk)
            10e6, // mintwaDeltaB
            type(uint256).max, // minPlantAmount
            type(uint256).max, // minHarvestAmount
            state.operator, // tipAddress
            state.tipAmount, // operatorTipAmount
            MAX_GROWN_STALK_PER_BDV // maxGrownStalkPerBdv
        );

        executeRequisition(state.operator, req, address(bs));

        // get user state after mow see SiloGettersFacet
        uint256 userGrownStalkAfterMow = bs.balanceOfGrownStalk(state.user, state.beanToken);
        // assert that this is 0 (all the grown stalk was mowed)
        assertEq(userGrownStalkAfterMow, 0);
    }
}

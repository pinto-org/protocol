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

contract MowPlantHarvestBlueprintTest is TractorHelper {
    address[] farmers;
    PriceManipulation priceManipulation;
    BeanstalkPrice beanstalkPrice;



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

        addLiquidityToWell(
            BEAN_ETH_WELL,
            10000e6, // 10,000 Beans
            10 ether // 10 ether.
        );

        addLiquidityToWell(
            BEAN_WSTETH_WELL,
            10010e6, // 10,010 Beans
            10 ether // 10 ether.
        );
    }

    // Break out the setup into a separate function
    // function setupMowPlantHarvestBlueprintTest(
    //     bool shouldMow, // if should mow, set up conditions for mowing
    //     bool shouldPlant, // if should plant, set up conditions for planting
    //     bool shouldHarvest // if should harvest, set up conditions for harvesting
    // ) internal returns (TestState memory) {
        // TestState memory state;
        // state.user = farmers[0];
        // state.operator = address(this);
        // state.beanToken = bs.getBeanToken();
        // state.initialUserBeanBalance = IERC20(state.beanToken).balanceOf(state.user);
        // state.initialOperatorBeanBalance = bs.getInternalBalance(state.operator, state.beanToken);
        // state.sowAmount = 1000e6; // 1000 BEAN
        // state.tipAmount = 10e6; // 10 BEAN
        // state.initialSoil = 100000e6; // 100,000 BEAN

        // // For test case 6, we need to deposit more than initialSoil
        // uint256 extraAmount = state.initialSoil + 1e6;

        // // Setup initial conditions with extra amount for test case 6
        // // Mint 2x the amount to ensure we have enough for all test cases
        // mintTokensToUser(state.user, state.beanToken, (extraAmount + uint256(state.tipAmount)) * 2);

        // vm.prank(state.user);
        // IERC20(state.beanToken).approve(address(bs), type(uint256).max);

        // bs.setSoilE(state.initialSoil);

        // vm.prank(state.user);
        // bs.deposit(
        //     state.beanToken,
        //     extraAmount + uint256(state.tipAmount),
        //     uint8(LibTransfer.From.EXTERNAL)
        // );

        // // For farmer 1, deposit 1000e6 beans, and mint them 1000e6 beans
        // mintTokensToUser(farmers[1], state.beanToken, 1000e6);
        // vm.prank(farmers[1]);
        // bs.deposit(state.beanToken, 1000e6, uint8(LibTransfer.From.EXTERNAL));

        // return state;
    // }
}

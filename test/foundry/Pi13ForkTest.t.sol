// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TestHelper, C} from "test/foundry/utils/TestHelper.sol";
import {GaugeId} from "contracts/beanstalk/storage/System.sol";
import "forge-std/console.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibGaugeHelpers} from "contracts/libraries/LibGaugeHelpers.sol";
import {InitPI13} from "contracts/beanstalk/init/InitPI13.sol";
import {LibConvertData} from "contracts/libraries/Convert/LibConvertData.sol";
import {LibBytes} from "contracts/libraries/LibBytes.sol";

/**
 * @dev forks base and tests different cultivation factor scenarios
 * InitPI13Mock is used as the init facet to init the cultivation temperatures to 748.5e6 instead of 0
 **/
contract Pi13ForkTest is TestHelper {
    // address with substantial LP deposits to simulate conversions.
    address farmer = address(0xaad938805E85f3404E3dbD5a501F9E43672037BB);
    address well = 0x3e11226fe3d85142B734ABCe6e58918d5828d1b4;
    string constant CSV_PATH = "convert_up_data.csv";

    function setUp() public {
        uint256 forkBlock = 35363162;
        forkMainnetAndUpgradeAllFacets(
            forkBlock,
            vm.envString("BASE_RPC"),
            PINTO,
            "InitPI13",
            abi.encodeWithSelector(InitPI13.init.selector, 1e9, 960_000e6) // initialize bonus stalk per bdv and twa delta b
        );
        bs = IMockFBeanstalk(PINTO);
    }

    /////////////////// TEST FUNCTIONS ///////////////////

    /**
     * @notice simulates the convert up bonus gauge with no orders
     */
    function test_forkBase_convertUp_noOrders() public {
        uint256 lastBonus;
        uint256 lastCapacityFactor = 1e6;

        for (uint256 i = 0; i < 10; i++) {
            stepSeason();
            logSeasonData(i);

            (
                LibGaugeHelpers.ConvertBonusGaugeValue memory gv,
                LibGaugeHelpers.ConvertBonusGaugeData memory gd
            ) = getConvertUpData();

            // verify that the bonus stalk per bdv is greater than the last season
            assertGe(
                gv.bonusStalkPerBdv,
                lastBonus,
                "bonusStalkPerBdv is not greater than the last season"
            );
            // verify that the capacity factor is the same as the last season
            assertEq(
                gv.convertCapacityFactor,
                lastCapacityFactor,
                "convertCapacityFactor is not the same as the last season"
            );
            assertEq(
                gd.bdvConvertedThisSeason,
                gd.bdvConvertedLastSeason,
                "bdvConvertedThisSeason is not the same as the last season"
            );

            lastBonus = gv.bonusStalkPerBdv;
            lastCapacityFactor = gv.convertCapacityFactor;
        }
    }

    /**
     * @notice simulates the behavior of the protocol when there is significant demand for the convert bonus,
     * then no demand for converts.
     */
    function test_forkBase_convertUp_oneOrder_max_convert() public {
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv;
        LibGaugeHelpers.ConvertBonusGaugeData memory gd;
        stepSeason();
        (gv, gd) = getConvertUpData();
        uint256 lastBonus = gv.bonusStalkPerBdv;
        uint256 lastCapacityFactor = gv.convertCapacityFactor;
        uint256 lastBdvConvertedLastSeason = 0;
        uint256 lastMaxConvertCapacity = gv.maxConvertCapacity;

        // converts of 5,
        for (uint256 i = 0; i < 5; i++) {
            // convert all the bonus.
            vm.warp(block.timestamp + 1800 seconds);
            convertAllAtBonus(farmer, 1);
            logSeasonData(i);
            (gv, gd) = getConvertUpData();
            stepSeason();

            // verify that the bonus stalk per bdv eq or less than the last season
            assertLe(
                gv.bonusStalkPerBdv,
                lastBonus,
                "bonusStalkPerBdv is not less than or equal to the last season"
            );
            // verify that the capacity factor and max convert capacity is greater than the last season
            assertGe(
                gv.convertCapacityFactor,
                lastCapacityFactor,
                "convertCapacityFactor is not greater than the last season"
            );
            assertGe(
                gv.maxConvertCapacity,
                lastMaxConvertCapacity,
                "maxConvertCapacity is not greater than the last season"
            );
            // verify that the bdv converted last season is the same as the bdv converted last season previously
            assertEq(
                lastBdvConvertedLastSeason,
                gd.bdvConvertedLastSeason,
                "bdvConvertedLastSeason is not the same as the last season"
            );
            // verify that the last convert bonus taken is greater than or equal to the bonus stalk per bdv
            if (i != 0) {
                assertGe(
                    gd.lastConvertBonusTaken,
                    gv.bonusStalkPerBdv,
                    "lastConvertBonusTaken is not the same as the bonus stalk per bdv"
                );
            }
            lastBonus = gv.bonusStalkPerBdv;
            lastBdvConvertedLastSeason = gd.bdvConvertedThisSeason;
            lastCapacityFactor = gv.convertCapacityFactor;
            lastMaxConvertCapacity = gv.maxConvertCapacity;
        }
        logSeasonData(1000);
        (gv, gd) = getConvertUpData();
        lastBonus = gv.bonusStalkPerBdv;
        lastMaxConvertCapacity = gv.maxConvertCapacity;
        lastBdvConvertedLastSeason = gd.bdvConvertedThisSeason;
        uint256 lastConvertBonusTaken = gd.lastConvertBonusTaken;

        // if demand stops for conversions, the protocol does not decrease the capacity until the bonus is at or exceeds the last taken bonus.
        uint256 i = 0;
        while (gd.lastConvertBonusTaken > gv.bonusStalkPerBdv) {
            console.log("-------------converts stopped-------------------");
            stepSeason(); // step season without converting
            logSeasonData(i++);

            (gv, gd) = getConvertUpData();

            // verify that the capacity is not decreasing
            assertEq(
                gv.maxConvertCapacity,
                lastMaxConvertCapacity,
                "maxConvertCapacity is not the same as the last season"
            );
            lastConvertBonusTaken = gd.lastConvertBonusTaken;
        }

        for (uint256 i = 0; i < 5; i++) {
            stepSeason();
            logSeasonData(i);

            (
                LibGaugeHelpers.ConvertBonusGaugeValue memory gv,
                LibGaugeHelpers.ConvertBonusGaugeData memory gd
            ) = getConvertUpData();

            // verify that the bonus stalk per bdv is greater than the last season
            assertGe(
                gv.bonusStalkPerBdv,
                lastBonus,
                "bonusStalkPerBdv is not greater than the last season"
            );

            // verify that the capacity factor and capacity are decreasing.
            assertLe(
                gv.convertCapacityFactor,
                lastCapacityFactor,
                "convertCapacityFactor is not less than the last season"
            );
            assertLe(
                gv.maxConvertCapacity,
                lastMaxConvertCapacity,
                "maxConvertCapacity is not less than the last season"
            );
            assertEq(
                gd.bdvConvertedThisSeason,
                gd.bdvConvertedLastSeason,
                "bdvConvertedThisSeason is not the same as the last season"
            );

            assertEq(
                gd.lastConvertBonusTaken,
                lastConvertBonusTaken,
                "lastConvertBonusTaken is not the same"
            );

            lastBonus = gv.bonusStalkPerBdv;
            lastCapacityFactor = gv.convertCapacityFactor; // no change
        }
    }

    /**
     * @notice simulates the behavior of the protocol when there is demand for converts at a certain bonus,
     * then a new order comes in that is below the bonus.
     */
    function test_forkBase_convertUp_oneOrder_at_bonus() public {
        bool write = false;
        if (write) {
            vm.writeFile(
                CSV_PATH,
                "step,season,convert_capacity_factor,max_convert_capacity,bonus_stalk_per_bdv,bdv_converted_this_season, bdv_converted_last_season, last_convert_bonus_taken\n"
            );
        }
        LibGaugeHelpers.ConvertBonusGaugeValue memory gvBefore;
        LibGaugeHelpers.ConvertBonusGaugeData memory gdBefore;
        LibGaugeHelpers.ConvertBonusGaugeValue memory gvAfter;
        LibGaugeHelpers.ConvertBonusGaugeData memory gdAfter;
        stepSeason();

        // converts of 50
        uint256 targetMaxConvertCapacity = 0;
        bool convertedLastSeasonOrder1 = false;
        bool convertedLastSeasonOrder2 = false;
        for (uint256 i = 0; i < 50; i++) {
            // convert all the bonus.
            vm.warp(block.timestamp + 1800 seconds);

            // for the first 10 seasons, convert all the bonus.
            // the protocol should slowly increase the capacity over time.
            if (i < 10) {
                convertedLastSeasonOrder1 = convertAllAtBonus(farmer, 0.995e9);
            } else {
                if (i == 10) {
                    targetMaxConvertCapacity = 100e6;
                }
                // for the next 10 seasons, convert some at any bonus.
                // the protocol should decrease the capacity until it reaches the target capacity.
                convertedLastSeasonOrder2 = convertSomeAtBonus(
                    farmer,
                    targetMaxConvertCapacity,
                    0.985e9
                );
            }

            logSeasonData(i);

            (gvBefore, gdBefore) = getConvertUpData();
            stepSeason();
            (gvAfter, gdAfter) = getConvertUpData();

            logSeasonData(i);
            if (write) {
                writeToCSV(vm.toString(i), gvBefore, gdBefore);
            }
            if (i < 10) {
                if (convertedLastSeasonOrder1) {
                    // if someone converted last season,
                    // capacity should increase,
                    // bdv converted last season should be greater than 0.
                    // bonus stalk per bdv should decrease.
                    assertGe(
                        gvAfter.convertCapacityFactor,
                        gvBefore.convertCapacityFactor,
                        "convertCapacityFactor is not greater than the last season"
                    );
                    assertGt(gdAfter.bdvConvertedLastSeason, 0, "bdvConvertedLastSeason is 0");
                    assertLe(
                        gvAfter.bonusStalkPerBdv,
                        gvBefore.bonusStalkPerBdv,
                        "bonusStalkPerBdv is not less than the last season"
                    );
                } else {
                    // if someone didnt convert last season,
                    // capacity should be the same,
                    // bdv converted last season should be the same as this season.
                    // bonus stalk per bdv should increase.
                    assertEq(
                        gvAfter.convertCapacityFactor,
                        gvBefore.convertCapacityFactor,
                        "convertCapacityFactor is not the same as the last season"
                    );
                    assertEq(
                        gdAfter.bdvConvertedThisSeason,
                        gdAfter.bdvConvertedLastSeason,
                        "bdvConvertedThisSeason is not the same as the last season"
                    );
                    assertGe(
                        gvAfter.bonusStalkPerBdv,
                        gvBefore.bonusStalkPerBdv,
                        "bonusStalkPerBdv is not greater than the last season"
                    );
                }
            }
        }
    }

    /////////////////// HELPER FUNCTIONS ///////////////////

    function getConvertUpData()
        internal
        view
        returns (
            LibGaugeHelpers.ConvertBonusGaugeValue memory,
            LibGaugeHelpers.ConvertBonusGaugeData memory
        )
    {
        bytes memory gaugeValue = bs.getGaugeValue(GaugeId.CONVERT_UP_BONUS);
        bytes memory gaugeData = bs.getGaugeData(GaugeId.CONVERT_UP_BONUS);

        LibGaugeHelpers.ConvertBonusGaugeValue memory gv = abi.decode(
            gaugeValue,
            (LibGaugeHelpers.ConvertBonusGaugeValue)
        );
        LibGaugeHelpers.ConvertBonusGaugeData memory gd = abi.decode(
            gaugeData,
            (LibGaugeHelpers.ConvertBonusGaugeData)
        );

        return (gv, gd);
    }

    function logSeasonData(uint256 iteration) internal view {
        (
            LibGaugeHelpers.ConvertBonusGaugeValue memory gv,
            LibGaugeHelpers.ConvertBonusGaugeData memory gd
        ) = getConvertUpData();
        console.log("Iteration:", iteration, "Season:", bs.season());
        console.log("--- Gauge Value After convert ---");
        console.log("Bonus Stalk per BDV:", gv.bonusStalkPerBdv);
        console.log(
            "Convert Capacity Factor:",
            gv.convertCapacityFactor,
            "| Max Convert Capacity:",
            gv.maxConvertCapacity
        );
        console.log("--- Gauge Data ---");
        console.log(
            "BDV Converted This Season:",
            gd.bdvConvertedThisSeason,
            "| BDV Converted Last Season:",
            gd.bdvConvertedLastSeason
        );
        console.log(
            "Max TWA DeltaB:",
            gd.maxTwaDeltaB,
            "| Last Convert Bonus Taken:",
            gd.lastConvertBonusTaken
        );
        console.log("------------fin--------------------");
    }

    function writeToCSV(
        string memory step,
        LibGaugeHelpers.ConvertBonusGaugeValue memory gv,
        LibGaugeHelpers.ConvertBonusGaugeData memory gd
    ) internal {
        string memory line = string.concat(
            step,
            ",",
            vm.toString(bs.season()),
            ",",
            vm.toString(gv.convertCapacityFactor),
            ",",
            vm.toString(gv.maxConvertCapacity),
            ",",
            vm.toString(gv.bonusStalkPerBdv),
            ",",
            vm.toString(gd.bdvConvertedThisSeason),
            ",",
            vm.toString(gd.bdvConvertedLastSeason),
            ",",
            vm.toString(gd.lastConvertBonusTaken)
        );
        vm.writeLine(CSV_PATH, line);
    }

    function stepSeason() internal {
        vm.warp(block.timestamp + 61 minutes);
        vm.roll(block.number + 1);
        bs.sunrise();
    }

    function convertAllAtBonus(address farmer, uint256 minBonus) internal returns (bool) {
        // get maximum convert capacity:
        (uint256 bonusStalkPerBdv, uint256 remainingCapacity) = bs
            .getConvertStalkPerBdvBonusAndRemainingCapacity();

        if (bonusStalkPerBdv < minBonus) {
            return false;
        }

        // get deposits for the farmer
        IMockFBeanstalk.TokenDepositId memory d = bs.getTokenDepositsForAccount(farmer, well);

        // get the deposits such that they exceed the lpCapacityInBdv.
        // a user needs to convert deposits such that the grown stalk of their deposit exceeds the total bonus stalk.
        int96[] memory stems = new int96[](d.tokenDeposits.length);
        uint256[] memory amounts = new uint256[](d.tokenDeposits.length);
        uint256 totalAmount = 0;
        int96 stemTip = bs.stemTipForToken(well);
        for (uint256 i = 0; i < d.tokenDeposits.length; i++) {
            (stems[i], amounts[i], remainingCapacity, totalAmount) = getStemsAndAmount(
                d,
                i,
                bonusStalkPerBdv,
                stemTip,
                totalAmount,
                remainingCapacity
            );

            if (remainingCapacity == 0) {
                uint256 length = i + 1;
                assembly {
                    mstore(stems, length)
                    mstore(amounts, length)
                }
                break;
            }
        }

        // create convertData for cbbtc converts:

        bytes memory convertData = abi.encode(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            totalAmount, // lp
            0, // min Beans
            well // Pinto:CBBTC well.
        );
        updateAllChainlinkOraclesWithPreviousData();

        vm.prank(farmer);
        bs.convert(convertData, stems, amounts);
        return true;
    }

    function convertSomeAtBonus(
        address farmer,
        uint256 targetBdvAmount,
        uint256 minBonus
    ) internal returns (bool) {
        // get maximum convert capacity:
        (uint256 bonusStalkPerBdv, uint256 remainingCapacity) = bs
            .getConvertStalkPerBdvBonusAndRemainingCapacity();
        remainingCapacity = targetBdvAmount;

        if (bonusStalkPerBdv < minBonus) {
            return false;
        }

        // get deposits for the farmer
        IMockFBeanstalk.TokenDepositId memory d = bs.getTokenDepositsForAccount(farmer, well);

        // get the deposits such that they exceed the lpCapacityInBdv.
        // a user needs to convert deposits such that the grown stalk of their deposit exceeds the total bonus stalk.
        int96[] memory stems = new int96[](d.tokenDeposits.length);
        uint256[] memory amounts = new uint256[](d.tokenDeposits.length);
        uint256 totalAmount = 0;
        int96 stemTip = bs.stemTipForToken(well);
        for (uint256 i = 0; i < d.tokenDeposits.length; i++) {
            (stems[i], amounts[i], remainingCapacity, totalAmount) = getStemsAndAmount(
                d,
                i,
                bonusStalkPerBdv,
                stemTip,
                totalAmount,
                remainingCapacity
            );

            if (remainingCapacity == 0) {
                uint256 length = i + 1;
                assembly {
                    mstore(stems, length)
                    mstore(amounts, length)
                }
                break;
            }
        }

        // create convertData for cbbtc converts:

        bytes memory convertData = abi.encode(
            LibConvertData.ConvertKind.WELL_LP_TO_BEANS,
            totalAmount, // lp
            0, // min Beans
            well // Pinto:CBBTC well.
        );
        updateAllChainlinkOraclesWithPreviousData();

        vm.prank(farmer);
        bs.convert(convertData, stems, amounts);
        return true;
    }

    function getStemsAndAmount(
        IMockFBeanstalk.TokenDepositId memory d,
        uint256 i,
        uint256 bonusStalkPerBdv,
        int96 stemTip,
        uint256 totalAmount,
        uint256 remainingCapacity
    )
        internal
        pure
        returns (int96 stem, uint256 amount, uint256 newRemainingCapacity, uint256 newTotalAmount)
    {
        uint256 bdvOfDeposit = d.tokenDeposits[i].bdv;
        uint256 amountOfDeposit = d.tokenDeposits[i].amount;
        (, int96 stemOfDeposit) = LibBytes.unpackAddressAndStem(d.depositIds[i]);
        uint256 grownStalkPerBdv = uint256(int256(stemTip - stemOfDeposit));
        if (grownStalkPerBdv > bonusStalkPerBdv) {
            if (bdvOfDeposit > remainingCapacity) {
                stem = stemOfDeposit;
                uint256 amountToBdvRatio = (amountOfDeposit * 1e18) / bdvOfDeposit;
                amount = (amountToBdvRatio * remainingCapacity) / 1e18;
                newRemainingCapacity = 0;
            } else {
                stem = stemOfDeposit;
                amount = amountOfDeposit;
                newRemainingCapacity = remainingCapacity - bdvOfDeposit;
            }
        } else {
            // if the grown stalk per bdv is less than the bonus stalk per bdv, then we need to scale in order to get the effective bdv.
            uint256 bonusStalk = remainingCapacity * bonusStalkPerBdv;
            uint256 depositStalk = grownStalkPerBdv * remainingCapacity;
            uint256 ratio = (bonusStalk * 1e18) / depositStalk;
            uint256 effectiveCapacity = (remainingCapacity * 1e18) / ratio;

            if (bdvOfDeposit > effectiveCapacity) {
                stem = stemOfDeposit;
                uint256 amountToBdvRatio = (amountOfDeposit * 1e18) / bdvOfDeposit;
                amount = (amountToBdvRatio * effectiveCapacity) / 1e18;
                console.log("amount", amount);
                newRemainingCapacity = 0;
            } else {
                stem = stemOfDeposit;
                amount = (amountOfDeposit * ratio) / 1e18;
                newRemainingCapacity = remainingCapacity - (bdvOfDeposit * ratio) / 1e18;
            }
        }
        newTotalAmount = totalAmount + amount;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWell} from "contracts/interfaces/basin/IWell.sol";
import {TractorHelpers} from "contracts/ecosystem/tractor/utils/TractorHelpers.sol";
import {SiloHelpers} from "contracts/ecosystem/tractor/utils/SiloHelpers.sol";
import {PriceManipulation} from "contracts/ecosystem/tractor/utils/PriceManipulation.sol";
import {BeanstalkPrice} from "contracts/ecosystem/price/BeanstalkPrice.sol";
import {GasCostCalculator} from "contracts/ecosystem/tractor/utils/GasCostCalculator.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title GasMeasurementForkTest
 * @notice Measures gas costs for BlueprintBase.GAS_USED_BEAN and GAS_USED_LP constants
 * @dev Run: forge test --match-contract GasMeasurementForkTest -vv
 */
contract GasMeasurementForkTest is Test {
    address constant PINTO_DIAMOND = 0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f;
    address constant PINTO_TOKEN = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;
    address constant PINTO_CBETH_WELL = 0x3e111115A82dF6190e36ADf0d552880663A4dBF1;
    address constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;

    /// @dev Tractor active publisher slot: keccak256("diamond.storage.tractor") + 2
    /// +2 because TractorStorage has two mappings (blueprintNonce, blueprintCounters)
    /// before the activePublisher field, each occupying one slot.
    bytes32 constant ACTIVE_PUBLISHER_SLOT =
        0x7efbaaac9214ca1879e26b4df38e29a72561affb741bba775ce66d5bb6a82a09;

    IMockFBeanstalk bs;
    TractorHelpers tractorHelpers;
    SiloHelpers siloHelpers;
    PriceManipulation priceManipulation;
    GasCostCalculator gasCostCalculator;

    address user;

    uint256 constant MAX_GROWN_STALK_PER_BDV = 1000e16;
    uint256 constant BEAN_DEPOSIT_AMOUNT = 100e6;
    uint256 constant LP_BEAN_AMOUNT = 100e6;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC"));
        bs = IMockFBeanstalk(PINTO_DIAMOND);

        BeanstalkPrice beanstalkPrice = new BeanstalkPrice(PINTO_DIAMOND);
        priceManipulation = new PriceManipulation(PINTO_DIAMOND);
        tractorHelpers = new TractorHelpers(PINTO_DIAMOND, address(beanstalkPrice));
        siloHelpers = new SiloHelpers(
            PINTO_DIAMOND,
            address(tractorHelpers),
            address(priceManipulation)
        );
        gasCostCalculator = new GasCostCalculator(
            address(beanstalkPrice),
            address(this),
            50000
        );

        user = makeAddr("gasMeasurementUser");
        vm.deal(user, 100 ether);
    }

    // ==================== Test ====================

    function test_measureAllGasCosts() public {
        console.log("============================================================");
        console.log("  GAS MEASUREMENT ON BASE MAINNET FORK");
        console.log("  Block: %d", block.number);
        console.log("============================================================");

        console.log("");
        console.log("=== calculateFeeInBean (real Chainlink + BeanstalkPrice) ===");
        uint256 calcFeeGas = _measureCalculateFeeGas();
        console.log("  Gas: %d", calcFeeGas);

        console.log("");
        console.log("=== TractorHelpers.tip ===");
        uint256 tipGas = _measureTipGas();
        console.log("  Gas: %d", tipGas);

        uint256[5] memory depositCounts = [uint256(1), 3, 5, 10, 20];

        console.log("");
        console.log("=== BEAN WITHDRAWAL (withdrawBeansFromSources) ===");
        console.log("  Deposits | Gas Used");
        console.log("  ---------|----------");

        uint256[] memory beanGasResults = new uint256[](depositCounts.length);
        for (uint256 i = 0; i < depositCounts.length; i++) {
            uint256 snapshot = vm.snapshot();
            beanGasResults[i] = _measureBeanWithdrawalGas(depositCounts[i]);
            console.log("  %d        | %d", depositCounts[i], beanGasResults[i]);
            vm.revertTo(snapshot);
        }

        console.log("");
        console.log("=== LP WITHDRAWAL (withdrawBeansFromSources via Well) ===");
        console.log("  Deposits | Gas Used");
        console.log("  ---------|----------");

        uint256[] memory lpGasResults = new uint256[](depositCounts.length);
        for (uint256 i = 0; i < depositCounts.length; i++) {
            uint256 snapshot = vm.snapshot();
            lpGasResults[i] = _measureLPWithdrawalGas(depositCounts[i]);
            console.log("  %d        | %d", depositCounts[i], lpGasResults[i]);
            vm.revertTo(snapshot);
        }

        uint256 beanTotal = calcFeeGas + beanGasResults[2] + tipGas;
        uint256 lpTotal = calcFeeGas + lpGasResults[2] + tipGas;

        console.log("");
        console.log("============================================================");
        console.log("  TOTAL OVERHEAD (calcFee + withdrawal[5 dep] + tip)");
        console.log("============================================================");
        console.log("  calculateFeeInBean:      %d", calcFeeGas);
        console.log("  tip:                     %d", tipGas);
        console.log("  Bean withdrawal (5 dep): %d", beanGasResults[2]);
        console.log("  LP withdrawal (5 dep):   %d", lpGasResults[2]);
        console.log("");
        console.log("  Bean path total:         %d", beanTotal);
        console.log("  LP path total:           %d", lpTotal);
        console.log("  Bean path (x1.5 margin): %d", (beanTotal * 150) / 100);
        console.log("  LP path (x1.5 margin):   %d", (lpTotal * 150) / 100);
        console.log("");
        console.log("  BlueprintBase constants:");
        console.log("    GAS_USED_BEAN:         3700000");
        console.log("    GAS_USED_LP:           4800000");
        console.log("============================================================");
    }

    // ==================== Internal Helpers ====================

    function _setTractorUser(address _user) internal {
        vm.store(PINTO_DIAMOND, ACTIVE_PUBLISHER_SLOT, bytes32(uint256(uint160(_user))));
    }

    function _clearTractorUser() internal {
        vm.store(PINTO_DIAMOND, ACTIVE_PUBLISHER_SLOT, bytes32(uint256(1)));
    }

    function _mintBean(address to, uint256 amount) internal {
        deal(PINTO_TOKEN, to, IERC20(PINTO_TOKEN).balanceOf(to) + amount);
    }

    /// @dev Advances one season via real sunrise() to produce distinct deposit stems.
    function _advanceSeason() internal {
        vm.warp(block.timestamp + 3600);
        bs.sunrise();
    }

    /// @dev Creates n Bean deposits across n seasons so each has a unique stem.
    function _createBeanDeposits(uint256 n, uint256 amountPerDeposit) internal {
        _mintBean(user, amountPerDeposit * n);

        vm.startPrank(user);
        IERC20(PINTO_TOKEN).approve(PINTO_DIAMOND, type(uint256).max);
        vm.stopPrank();

        for (uint256 i = 0; i < n; i++) {
            vm.prank(user);
            bs.deposit(PINTO_TOKEN, amountPerDeposit, uint8(LibTransfer.From.EXTERNAL));
            _advanceSeason();
        }
        // Pass germination period
        _advanceSeason();
    }

    /// @dev Creates n LP deposits across n seasons so each has a unique stem.
    function _createLPDeposits(uint256 n, uint256 beanAmountPerDeposit) internal {
        uint256[] memory reserves = IWell(PINTO_CBETH_WELL).getReserves();
        uint256 cbethPerDeposit = (beanAmountPerDeposit * reserves[1]) / reserves[0];
        cbethPerDeposit = (cbethPerDeposit * 101) / 100; // +1% to avoid rounding dust

        for (uint256 i = 0; i < n; i++) {
            _mintBean(user, beanAmountPerDeposit);
            deal(CBETH, user, IERC20(CBETH).balanceOf(user) + cbethPerDeposit);

            vm.startPrank(user);
            IERC20(PINTO_TOKEN).approve(PINTO_CBETH_WELL, beanAmountPerDeposit);
            IERC20(CBETH).approve(PINTO_CBETH_WELL, cbethPerDeposit);

            uint256[] memory tokenAmountsIn = new uint256[](2);
            tokenAmountsIn[0] = beanAmountPerDeposit;
            tokenAmountsIn[1] = cbethPerDeposit;

            IERC20(PINTO_CBETH_WELL).approve(PINTO_DIAMOND, type(uint256).max);

            uint256 lpAmountOut = IWell(PINTO_CBETH_WELL).addLiquidity(
                tokenAmountsIn,
                0,
                user,
                type(uint256).max
            );

            bs.deposit(PINTO_CBETH_WELL, lpAmountOut, 0);
            vm.stopPrank();

            _advanceSeason();
        }
        // Pass germination period
        _advanceSeason();
    }

    // ==================== Gas Measurement Functions ====================

    function _measureBeanWithdrawalGas(uint256 n) internal returns (uint256 gasUsed) {
        _createBeanDeposits(n, BEAN_DEPOSIT_AMOUNT);

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = tractorHelpers.getTokenIndex(PINTO_TOKEN);

        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams(
            MAX_GROWN_STALK_PER_BDV
        );
        LibSiloHelpers.WithdrawalPlan memory emptyPlan;

        _setTractorUser(user);

        uint256 gasBefore = gasleft();
        siloHelpers.withdrawBeansFromSources(
            user,
            sourceTokenIndices,
            BEAN_DEPOSIT_AMOUNT * n,
            filterParams,
            0.01e18,
            LibTransfer.To.INTERNAL,
            emptyPlan
        );
        gasUsed = gasBefore - gasleft();

        _clearTractorUser();
    }

    function _measureLPWithdrawalGas(uint256 n) internal returns (uint256 gasUsed) {
        _createLPDeposits(n, LP_BEAN_AMOUNT);

        uint8[] memory sourceTokenIndices = new uint8[](1);
        sourceTokenIndices[0] = tractorHelpers.getTokenIndex(PINTO_CBETH_WELL);

        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams(
            MAX_GROWN_STALK_PER_BDV
        );
        LibSiloHelpers.WithdrawalPlan memory emptyPlan;

        _setTractorUser(user);

        uint256 gasBefore = gasleft();
        siloHelpers.withdrawBeansFromSources(
            user,
            sourceTokenIndices,
            LP_BEAN_AMOUNT * n,
            filterParams,
            0.01e18,
            LibTransfer.To.INTERNAL,
            emptyPlan
        );
        gasUsed = gasBefore - gasleft();

        _clearTractorUser();
    }

    /// @dev Measures the real TractorHelpers.tip() gas (INTERNAL -> INTERNAL transfer + event).
    function _measureTipGas() internal returns (uint256 gasUsed) {
        _mintBean(user, 100e6);
        vm.prank(user);
        IERC20(PINTO_TOKEN).approve(PINTO_DIAMOND, type(uint256).max);
        vm.prank(user);
        bs.transferToken(
            PINTO_TOKEN,
            user,
            100e6,
            uint8(LibTransfer.From.EXTERNAL),
            uint8(LibTransfer.To.INTERNAL)
        );

        address tipRecipient = address(0xBEEF);
        _setTractorUser(user);

        uint256 gasBefore = gasleft();
        tractorHelpers.tip(
            PINTO_TOKEN,
            user,
            tipRecipient,
            10e6,
            LibTransfer.From.INTERNAL,
            LibTransfer.To.INTERNAL
        );
        gasUsed = gasBefore - gasleft();

        _clearTractorUser();
    }

    /// @dev Measures GasCostCalculator.calculateFeeInBean() with real Chainlink + BeanstalkPrice.
    function _measureCalculateFeeGas() internal returns (uint256 gasUsed) {
        vm.txGasPrice(0.1 gwei);

        uint256 gasBefore = gasleft();
        gasCostCalculator.calculateFeeInBean(300_000, 0);
        gasUsed = gasBefore - gasleft();
    }
}

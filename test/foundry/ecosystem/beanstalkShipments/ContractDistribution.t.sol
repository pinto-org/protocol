// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestHelper} from "test/foundry/utils/TestHelper.sol";
import {SiloPayback} from "contracts/ecosystem/beanstalkShipments/SiloPayback.sol";
import {BarnPayback} from "contracts/ecosystem/beanstalkShipments/barn/BarnPayback.sol";
import {BeanstalkFertilizer} from "contracts/ecosystem/beanstalkShipments/barn/BeanstalkFertilizer.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IMockFBeanstalk} from "contracts/interfaces/IMockFBeanstalk.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {L1ContractMessenger} from "contracts/ecosystem/beanstalkShipments/contractDistribution/L1ContractMessenger.sol";
import {FieldFacet} from "contracts/beanstalk/facets/field/FieldFacet.sol";
import {MockFieldFacet} from "contracts/mocks/mockFacets/MockFieldFacet.sol";
import {ContractPaybackDistributor, ICrossDomainMessenger} from "contracts/ecosystem/beanstalkShipments/contractDistribution/ContractPaybackDistributor.sol";

contract ContractDistributionTest is TestHelper {
    // Constants
    uint256 public constant INITIAL_BPF = 1e18;

    uint256 public constant FERTILIZER_ID = 10000000;
    uint256 public constant REPAYMENT_FIELD_ID = 1;

    // L1 messenger of the Superchain
    ICrossDomainMessenger public constant L1_MESSENGER =
        ICrossDomainMessenger(0x4200000000000000000000000000000000000007);
    // L1 sender
    address public constant L1_SENDER = 0xD2abd9a7E7F10e3bF4376fb03A07fca729A55b6f;

    address public constant EXPECTED_CONTRACT_PAYBACK_DISTRIBUTOR =
        0x5dC8F2e4F47F36F5d20B6456F7993b65A7994000;

    // Deployed contracts
    SiloPayback public siloPayback;
    BarnPayback public barnPayback;
    ContractPaybackDistributor public contractPaybackDistributor;

    // Test users
    address public owner = makeAddr("owner");
    address public contractAccount1 = makeAddr("contractAccount1"); // can claim direcly in L2
    address public contractAccount2 = makeAddr("contractAccount2"); // Needs to call the L1ContractMessenger contract
    address public receiver1 = makeAddr("receiver1");
    address public receiver2 = makeAddr("receiver2");

    function setUp() public {
        initializeBeanstalkTestState(true, false);

        // deploy the silo and barn payback contracts
        deploySiloPayback();
        deployBarnPayback();

        // set active field to be repayment field
        vm.startPrank(deployer);
        bs.addField();
        bs.setActiveField(REPAYMENT_FIELD_ID, 100e6);
        vm.stopPrank();

        // Deploy the ContractPaybackDistributor contract as transparent proxy
        // 1. Deploy implementation
        ContractPaybackDistributor distributorImpl = new ContractPaybackDistributor();

        // 2. Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            ContractPaybackDistributor.initialize.selector,
            address(bs),
            address(siloPayback),
            address(barnPayback)
        );

        // 3. Deploy proxy at expected address using deployCodeTo
        vm.prank(owner);
        deployCodeTo(
            "TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
            abi.encode(address(distributorImpl), owner, initData),
            EXPECTED_CONTRACT_PAYBACK_DISTRIBUTOR
        );

        contractPaybackDistributor = ContractPaybackDistributor(
            EXPECTED_CONTRACT_PAYBACK_DISTRIBUTOR
        );

        // Whitelisted contract accounts
        address[] memory contractAccounts = new address[](2);
        contractAccounts[0] = contractAccount1;
        contractAccounts[1] = contractAccount2;

        // assert owner is correct
        assertEq(contractPaybackDistributor.owner(), owner, "distributor owner");

        // Initialize the account data
        ContractPaybackDistributor.AccountData[] memory accountData = _createAccountData();
        vm.prank(owner);
        contractPaybackDistributor.initializeAccountData(contractAccounts, accountData);

        // mint the actual silo payback tokens to the distributor contract:
        // 500e6 for contractAccount1
        // 500e6 for contractAccount2
        _mintSiloPaybackTokensToUser(address(contractPaybackDistributor), 500e6);
        _mintSiloPaybackTokensToUser(address(contractPaybackDistributor), 500e6);

        // mint the actual barn payback fertilizers to the distributor contract:
        BarnPayback.Fertilizers[] memory fertilizerData = _createFertilizerAccountData(
            address(contractPaybackDistributor)
        );
        vm.startPrank(owner);
        barnPayback.mintFertilizers(fertilizerData);
        vm.stopPrank();

        // sow 2 plots for the distributor contract
        sowPodsForContractPaybackDistributor(100e6); // 0 --> 101e6 place in line
        sowPodsForContractPaybackDistributor(100e6); // 101e6 --> 202e6 place in line

        // assert the contract holds the silo and fertilizer tokens
        assertEq(
            siloPayback.balanceOf(address(contractPaybackDistributor)),
            1000e6,
            "siloPayback balance"
        );
        assertEq(
            barnPayback.balanceOf(address(contractPaybackDistributor), FERTILIZER_ID),
            80,
            "fertilizer balance"
        );

        // assert the contract holds the two plots
        IMockFBeanstalk.Plot[] memory plots = bs.getPlotsFromAccount(
            address(contractPaybackDistributor),
            REPAYMENT_FIELD_ID
        );
        // Plot 1
        assertEq(plots[0].index, 0, "plot 1 index");
        assertEq(plots[0].pods, 101e6, "plot 1 pods");
        // Plot 2
        assertEq(plots[1].index, 101e6, "plot 2 index");
        assertEq(plots[1].pods, 101e6, "plot 2 pods");
    }

    /**
     * @notice Test that the contract accounts can claim their rewards directly
     */
    function test_contractDistributionDirect() public {
        vm.startPrank(contractAccount1);
        contractPaybackDistributor.claimDirect(receiver1, LibTransfer.To.EXTERNAL);
        vm.stopPrank();

        // assert the receiver address holds all the assets for receiver1
        assertEq(siloPayback.balanceOf(receiver1), 500e6, "receiver siloPayback balance");
        assertEq(
            barnPayback.balanceOf(receiver1, FERTILIZER_ID),
            40,
            "receiver fertilizer balance"
        );
        // get the plots from the receiver1
        IMockFBeanstalk.Plot[] memory plots = bs.getPlotsFromAccount(receiver1, REPAYMENT_FIELD_ID);
        assertEq(plots.length, 1, "plots length");
        assertEq(plots[0].index, 0, "plot 0 index for receiver1");
        assertEq(plots[0].pods, 101e6, "plot 0 pods for receiver1");

        // assert the rest of the assets are still in the distributor
        assertEq(
            siloPayback.balanceOf(address(contractPaybackDistributor)),
            500e6,
            "distributor siloPayback balance"
        );
        assertEq(
            barnPayback.balanceOf(address(contractPaybackDistributor), FERTILIZER_ID),
            40,
            "distributor fertilizer balance"
        );

        // try to claim again from contractAccount1
        vm.startPrank(contractAccount1);
        vm.expectRevert("ContractPaybackDistributor: Caller already claimed");
        contractPaybackDistributor.claimDirect(receiver1, LibTransfer.To.EXTERNAL);
        vm.stopPrank();

        // Claim for contractAccount2
        vm.startPrank(contractAccount2);
        contractPaybackDistributor.claimDirect(receiver2, LibTransfer.To.EXTERNAL);
        vm.stopPrank();

        // assert the receiver address holds all the assets for receiver2
        assertEq(siloPayback.balanceOf(receiver2), 500e6, "receiver siloPayback balance");
        assertEq(
            barnPayback.balanceOf(receiver2, FERTILIZER_ID),
            40,
            "receiver fertilizer balance"
        );
        // get the plots from the receiver2
        plots = bs.getPlotsFromAccount(receiver2, REPAYMENT_FIELD_ID);
        assertEq(plots.length, 1, "plots length");
        assertEq(plots[0].index, 101e6, "plot 0 index for receiver2");
        assertEq(plots[0].pods, 101e6, "plot 0 pods for receiver2");
        // assert the no more assets are in the distributor
        assertEq(
            siloPayback.balanceOf(address(contractPaybackDistributor)),
            0,
            "distributor siloPayback balance"
        );
        assertEq(
            barnPayback.balanceOf(address(contractPaybackDistributor), FERTILIZER_ID),
            0,
            "distributor fertilizer balance"
        );
        // plots
        plots = bs.getPlotsFromAccount(address(contractPaybackDistributor), REPAYMENT_FIELD_ID);
        assertEq(plots.length, 0, "plots length");
    }

    /**
     * @notice Test that the contract accounts can claim their rewards from sending an L1 message
     * - Only the OP stack messenger at 0x42...7 can call the setReceiverFromL1Message function
     * - The call is successful only if the xDomainMessageSender is the L1 sender
     * - After delegation, the receiver must call claimDirect to get the assets
     */
    function test_contractDistributionFromL1Message() public {
        // try to set receiver from non-L1 messenger, expect revert
        vm.startPrank(address(contractAccount1));
        vm.expectRevert("ContractPaybackDistributor: Caller not L1 messenger");
        contractPaybackDistributor.setReceiverFromL1Message(contractAccount1, receiver1);
        vm.stopPrank();

        // try to set receiver from non-L1 sender, expect revert
        vm.startPrank(address(L1_MESSENGER));
        vm.mockCall(
            address(L1_MESSENGER),
            abi.encodeWithSelector(L1_MESSENGER.xDomainMessageSender.selector),
            abi.encode(makeAddr("nonL1Sender"))
        );
        vm.expectRevert("ContractPaybackDistributor: Bad origin");
        contractPaybackDistributor.setReceiverFromL1Message(contractAccount1, receiver1);
        vm.stopPrank();

        // delegate using the L1 message. Mock that the call was initiated by the L1 sender contract
        // on behalf of contractAccount1
        vm.startPrank(address(L1_MESSENGER));
        vm.mockCall(
            address(L1_MESSENGER),
            abi.encodeWithSelector(L1_MESSENGER.xDomainMessageSender.selector),
            abi.encode(L1_SENDER)
        );
        contractPaybackDistributor.setReceiverFromL1Message(contractAccount1, receiver1);
        vm.stopPrank();

        // now receiver1 can claim the assets directly
        vm.startPrank(receiver1);
        contractPaybackDistributor.claimDirect(receiver1, LibTransfer.To.EXTERNAL);
        vm.stopPrank();

        // assert the receiver address holds all the assets for receiver1
        assertEq(siloPayback.balanceOf(receiver1), 500e6, "receiver siloPayback balance");
        assertEq(
            barnPayback.balanceOf(receiver1, FERTILIZER_ID),
            40,
            "receiver fertilizer balance"
        );
        // get the plots from the receiver1
        IMockFBeanstalk.Plot[] memory plots = bs.getPlotsFromAccount(receiver1, REPAYMENT_FIELD_ID);
        assertEq(plots.length, 1, "plots length");
        assertEq(plots[0].index, 0, "plot 0 index for receiver1");
        assertEq(plots[0].pods, 101e6, "plot 0 pods for receiver1");

        // assert the rest of the assets are still in the distributor
        assertEq(
            siloPayback.balanceOf(address(contractPaybackDistributor)),
            500e6,
            "distributor siloPayback balance"
        );
        assertEq(
            barnPayback.balanceOf(address(contractPaybackDistributor), FERTILIZER_ID),
            40,
            "distributor fertilizer balance"
        );

        // try to delegate again from contractAccount1
        vm.startPrank(address(L1_MESSENGER));
        vm.mockCall(
            address(L1_MESSENGER),
            abi.encodeWithSelector(L1_MESSENGER.xDomainMessageSender.selector),
            abi.encode(L1_SENDER)
        );
        vm.expectRevert("ContractPaybackDistributor: Caller already claimed");
        contractPaybackDistributor.setReceiverFromL1Message(contractAccount1, receiver1);
        vm.stopPrank();

        // try to claim again for same account directly, expect revert
        vm.startPrank(address(contractAccount1));
        vm.expectRevert("ContractPaybackDistributor: Caller already claimed");
        contractPaybackDistributor.claimDirect(receiver1, LibTransfer.To.EXTERNAL);
        vm.stopPrank();

        // try to claim again from receiver1, expect revert
        vm.startPrank(receiver1);
        vm.expectRevert("ContractPaybackDistributor: Caller already claimed");
        contractPaybackDistributor.claimDirect(receiver1, LibTransfer.To.EXTERNAL);
        vm.stopPrank();
    }

    //////////////////////// HELPER FUNCTIONS ////////////////////////

    function deploySiloPayback() public {
        // Deploy implementation contract
        SiloPayback siloPaybackImpl = new SiloPayback();

        // Encode initialization data
        vm.startPrank(owner);
        bytes memory data = abi.encodeWithSelector(
            SiloPayback.initialize.selector,
            address(BEAN),
            address(BEANSTALK)
        );

        // Deploy proxy contract
        TransparentUpgradeableProxy siloPaybackProxy = new TransparentUpgradeableProxy(
            address(siloPaybackImpl), // implementation
            owner, // initial owner
            data // initialization data
        );

        vm.stopPrank();

        // set the silo payback proxy
        siloPayback = SiloPayback(address(siloPaybackProxy));
    }

    function _mintSiloPaybackTokensToUser(address user, uint256 amount) internal {
        SiloPayback.UnripeBdvTokenData[] memory receipts = new SiloPayback.UnripeBdvTokenData[](1);
        receipts[0] = SiloPayback.UnripeBdvTokenData(user, amount);
        vm.prank(owner);
        siloPayback.batchMint(receipts);
    }

    function deployBarnPayback() public {
        // Deploy implementation contract
        BarnPayback implementation = new BarnPayback();

        // Prepare system fertilizer state
        BeanstalkFertilizer.InitSystemFertilizer
            memory initSystemFert = _createInitSystemFertilizerData();

        // Encode initialization data
        vm.startPrank(owner);
        bytes memory data = abi.encodeWithSelector(
            BarnPayback.initialize.selector,
            address(BEAN),
            address(BEANSTALK),
            address(EXPECTED_CONTRACT_PAYBACK_DISTRIBUTOR),
            initSystemFert
        );

        // Deploy proxy contract
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation), // implementation
            owner, // initial owner
            data // initialization data
        );

        vm.stopPrank();

        // Set the barn payback proxy
        barnPayback = BarnPayback(address(proxy));

        // mint beans to the barn payback contract
        bean.mint(address(barnPayback), 1000e6);
    }

    /**
     * @notice Creates mock system fertilizer data for testing
     */
    function _createInitSystemFertilizerData()
        internal
        pure
        returns (BeanstalkFertilizer.InitSystemFertilizer memory)
    {
        uint128[] memory fertilizerIds = new uint128[](1);
        fertilizerIds[0] = uint128(FERTILIZER_ID);

        uint256[] memory fertilizerAmounts = new uint256[](1);
        fertilizerAmounts[0] = 100; // 100 units of FERT_ID_1

        return
            BeanstalkFertilizer.InitSystemFertilizer({
                fertilizerIds: fertilizerIds,
                fertilizerAmounts: fertilizerAmounts,
                activeFertilizer: 100,
                fertilizedIndex: 0,
                unfertilizedIndex: 100000e6,
                fertilizedPaidIndex: 0,
                fertFirst: uint128(FERTILIZER_ID), // Start of linked list
                fertLast: uint128(FERTILIZER_ID), // End of linked list
                bpf: 100000,
                leftoverBeans: 0
            });
    }

    /**
     * @notice Creates mock fertilizer account data for testing
     */
    function _createFertilizerAccountData(
        address receiver
    ) internal view returns (BarnPayback.Fertilizers[] memory) {
        BarnPayback.Fertilizers[] memory fertilizerData = new BarnPayback.Fertilizers[](1);

        // FERT_ID_1 holders
        BarnPayback.AccountFertilizerData[]
            memory accounts = new BarnPayback.AccountFertilizerData[](2);
        accounts[0] = BarnPayback.AccountFertilizerData({
            account: receiver,
            amount: 40, // 40 to contractAccount1
            lastBpf: 100
        });
        accounts[1] = BarnPayback.AccountFertilizerData({
            account: receiver,
            amount: 40, // 40 to contractAccount2
            lastBpf: 100
        });

        fertilizerData[0] = BarnPayback.Fertilizers({
            fertilizerId: uint128(FERTILIZER_ID),
            accountData: accounts
        });

        return fertilizerData;
    }

    function _createAccountData()
        internal
        view
        returns (ContractPaybackDistributor.AccountData[] memory)
    {
        ContractPaybackDistributor.AccountData[]
            memory accountData = new ContractPaybackDistributor.AccountData[](2);
        // Fertilizer data
        uint256[] memory fertilizerIds = new uint256[](1);
        fertilizerIds[0] = FERTILIZER_ID;
        uint256[] memory fertilizerAmounts1 = new uint256[](1);
        fertilizerAmounts1[0] = 40;
        uint256[] memory fertilizerAmounts2 = new uint256[](1);
        fertilizerAmounts2[0] = 40;
        // Plot data for contractAccount1 (plot 0)
        uint256[] memory plotIds1 = new uint256[](1);
        plotIds1[0] = 0; // 0 --> 101e6 place in line
        uint256[] memory plotStarts1 = new uint256[](1);
        plotStarts1[0] = 0; // start from the beginning of the plot
        uint256[] memory plotAmounts1 = new uint256[](1);
        plotAmounts1[0] = 101e6; // end at the end of the plot

        // Plot data for contractAccount2 (plot 1)
        uint256[] memory plotIds2 = new uint256[](1);
        plotIds2[0] = 101e6; // 101e6 --> 202e6 place in line
        uint256[] memory plotStarts2 = new uint256[](1);
        plotStarts2[0] = 0; // start from the beginning of the plot
        uint256[] memory plotAmounts2 = new uint256[](1);
        plotAmounts2[0] = 101e6; // end at the end of the plot
        // contractAccount1
        accountData[0] = ContractPaybackDistributor.AccountData({
            whitelisted: true,
            claimed: false,
            siloPaybackTokensOwed: 500e6,
            fertilizerIds: fertilizerIds,
            fertilizerAmounts: fertilizerAmounts1,
            plotIds: plotIds1,
            plotAmounts: plotAmounts1
        });
        // contractAccount2
        accountData[1] = ContractPaybackDistributor.AccountData({
            whitelisted: true,
            claimed: false,
            siloPaybackTokensOwed: 500e6,
            fertilizerIds: fertilizerIds,
            fertilizerAmounts: fertilizerAmounts2,
            plotIds: plotIds2,
            plotAmounts: plotAmounts2
        });
        return accountData;
    }

    function sowPodsForContractPaybackDistributor(uint256 amount) public {
        // max approve bs to contractPaybackDistributor
        vm.prank(address(contractPaybackDistributor));
        IERC20(BEAN).approve(address(bs), type(uint256).max);

        bs.setMaxTempE(100e6); // 1% effective temp
        season.setSoilE(100e6);
        // mint the beans
        bean.mint(address(contractPaybackDistributor), amount);
        // sow the beans
        vm.prank(address(contractPaybackDistributor));
        bs.sow(
            amount, // amt
            0, // min temperature
            uint8(LibTransfer.From.EXTERNAL)
        );
    }
}

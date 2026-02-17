// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {SowBlueprint} from "contracts/ecosystem/tractor/blueprints/SowBlueprint.sol";
import {SowBlueprintBase} from "contracts/ecosystem/tractor/blueprints/SowBlueprintBase.sol";
import {TractorHelpers} from "contracts/ecosystem/tractor/utils/TractorHelpers.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {SiloHelpers} from "contracts/ecosystem/tractor/utils/SiloHelpers.sol";
import {LibTractorHelpers} from "contracts/libraries/Silo/LibTractorHelpers.sol";
import {AutomateClaimBlueprint} from "contracts/ecosystem/AutomateClaimBlueprint.sol";
import {BlueprintBase} from "contracts/ecosystem/BlueprintBase.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import "forge-std/console.sol";

contract TractorTestHelper is TestHelper {
    // Add this at the top of the contract
    TractorHelpers internal tractorHelpers;
    SowBlueprint internal sowBlueprint;
    SiloHelpers internal siloHelpers;
    AutomateClaimBlueprint internal automateClaimBlueprint;

    uint256 public constant DEFAULT_FIELD_ID = 0;
    uint256 public constant PAYBACK_FIELD_ID = 1;

    enum SourceMode {
        PURE_PINTO,
        LOWEST_PRICE,
        LOWEST_SEED
    }

    function setTractorHelpers(address _tractorHelpers) internal {
        tractorHelpers = TractorHelpers(_tractorHelpers);
    }

    function setSowBlueprintv0(address _sowBlueprintv0) internal {
        sowBlueprint = SowBlueprint(_sowBlueprintv0);
    }

    function setSiloHelpers(address _siloHelpers) internal {
        siloHelpers = SiloHelpers(_siloHelpers);
    }

    function setAutomateClaimBlueprint(address _automateClaimBlueprint) internal {
        automateClaimBlueprint = AutomateClaimBlueprint(_automateClaimBlueprint);
    }

    function createRequisitionWithPipeCall(
        address account,
        bytes memory pipeCallData,
        address beanstalkAddress
    ) internal returns (IMockFBeanstalk.Requisition memory) {
        // Create the blueprint
        IMockFBeanstalk.Blueprint memory blueprint = IMockFBeanstalk.Blueprint({
            publisher: account,
            data: pipeCallData,
            operatorPasteInstrs: new bytes32[](0),
            maxNonce: type(uint256).max,
            startTime: block.timestamp,
            endTime: type(uint256).max
        });

        // Get the blueprint hash
        bytes32 blueprintHash = IMockFBeanstalk(beanstalkAddress).getBlueprintHash(blueprint);

        // Get the stored private key and sign
        uint256 privateKey = getPrivateKey(account);
        bytes memory signature = signBlueprint(blueprintHash, privateKey);

        // Create and return the requisition
        return
            IMockFBeanstalk.Requisition({
                blueprint: blueprint,
                blueprintHash: blueprintHash,
                signature: signature
            });
    }

    function publishAccountRequisition(
        address account,
        IMockFBeanstalk.Requisition memory req
    ) internal {
        vm.prank(account);
        bs.publishRequisition(req);
    }

    /**
     * @notice Create a requisition for ERC1271 contract publishers (no ECDSA signing)
     * @dev For ERC1271, the signature is validated by the contract itself via isValidSignature()
     */
    function createRequisitionWithPipeCallERC1271(
        address contractPublisher,
        bytes memory pipeCallData,
        address beanstalkAddress
    ) internal view returns (IMockFBeanstalk.Requisition memory) {
        // Create the blueprint
        IMockFBeanstalk.Blueprint memory blueprint = IMockFBeanstalk.Blueprint({
            publisher: contractPublisher,
            data: pipeCallData,
            operatorPasteInstrs: new bytes32[](0),
            maxNonce: type(uint256).max,
            startTime: block.timestamp,
            endTime: type(uint256).max
        });

        // Get the blueprint hash
        bytes32 blueprintHash = IMockFBeanstalk(beanstalkAddress).getBlueprintHash(blueprint);

        // For ERC1271, we provide a dummy signature
        // The actual validation happens in the contract's isValidSignature() method
        bytes memory dummySignature = new bytes(65);

        // Create and return the requisition
        return
            IMockFBeanstalk.Requisition({
                blueprint: blueprint,
                blueprintHash: blueprintHash,
                signature: dummySignature
            });
    }

    function executeRequisition(
        address user,
        IMockFBeanstalk.Requisition memory req,
        address beanstalkAddress
    ) internal {
        vm.prank(user);
        IMockFBeanstalk(beanstalkAddress).tractor(
            IMockFBeanstalk.Requisition(req.blueprint, req.blueprintHash, req.signature),
            ""
        );
    }

    /**
     * @notice Execute a requisition with dynamic contract data
     * @param user The operator executing the requisition
     * @param req The requisition to execute
     * @param beanstalkAddress The Beanstalk address
     * @param dynamicData Array of ContractData for transient storage
     */
    function executeRequisitionWithDynamicData(
        address user,
        IMockFBeanstalk.Requisition memory req,
        address beanstalkAddress,
        IMockFBeanstalk.ContractData[] memory dynamicData
    ) internal {
        vm.prank(user);
        IMockFBeanstalk(beanstalkAddress).tractorDynamicData(
            IMockFBeanstalk.Requisition(req.blueprint, req.blueprintHash, req.signature),
            "",
            dynamicData
        );
    }

    /**
     * @notice Create ContractData for harvest operations
     * @param account The account to query harvestable plots for
     * @param fieldIds Array of field IDs to create harvest data for
     * @return dynamicData Array of ContractData containing harvest information
     */
    function createHarvestDynamicData(
        address account,
        uint256[] memory fieldIds
    ) internal view returns (IMockFBeanstalk.ContractData[] memory dynamicData) {
        dynamicData = new IMockFBeanstalk.ContractData[](fieldIds.length);

        for (uint256 i = 0; i < fieldIds.length; i++) {
            uint256 fieldId = fieldIds[i];

            // Get harvestable plot indexes
            uint256[] memory harvestablePlotIndexes = _getHarvestablePlotIndexes(account, fieldId);

            // Create ContractData with key = HARVEST_DATA_KEY + fieldId
            uint256 key = automateClaimBlueprint.HARVEST_DATA_KEY() + fieldId;
            dynamicData[i] = IMockFBeanstalk.ContractData({
                key: key,
                value: abi.encode(harvestablePlotIndexes)
            });
        }
    }

    /**
     * @notice Calculate harvestable plots for a given account and field
     * @dev Simulates what operator would calculate off-chain
     * @return harvestablePlotIndexes Array of harvestable plot indexes
     */
    function _getHarvestablePlotIndexes(
        address account,
        uint256 fieldId
    ) internal view returns (uint256[] memory) {
        // Get plot indexes for the account
        uint256[] memory plotIndexes = bs.getPlotIndexesFromAccount(account, fieldId);
        uint256 harvestableIndex = bs.harvestableIndex(fieldId);

        if (plotIndexes.length == 0) {
            return new uint256[](0);
        }

        // Temporary array to collect harvestable plots
        uint256[] memory tempPlots = new uint256[](plotIndexes.length);
        uint256 harvestableCount = 0;

        for (uint256 i = 0; i < plotIndexes.length; i++) {
            uint256 plotIndex = plotIndexes[i];
            uint256 plotPods = bs.plot(account, fieldId, plotIndex);

            if (plotIndex + plotPods <= harvestableIndex) {
                // Fully harvestable
                tempPlots[harvestableCount] = plotIndex;
                harvestableCount++;
            } else if (plotIndex < harvestableIndex) {
                // Partially harvestable
                tempPlots[harvestableCount] = plotIndex;
                harvestableCount++;
            }
        }

        // Resize to actual count
        uint256[] memory harvestablePlots = new uint256[](harvestableCount);
        for (uint256 i = 0; i < harvestableCount; i++) {
            harvestablePlots[i] = tempPlots[i];
        }

        return harvestablePlots;
    }

    // Helper function to sign blueprints
    function signBlueprint(bytes32 hash, uint256 pk) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Helper function to setup a blueprint for withdrawing beans
     */
    function setupWithdrawBeansBlueprint(
        address account,
        uint256 withdrawAmount,
        uint8[] memory sourceTokenIndices,
        uint256 maxGrownStalkPerBdv,
        LibTransfer.To mode
    ) internal returns (IMockFBeanstalk.Requisition memory) {
        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams(
            maxGrownStalkPerBdv
        );
        LibSiloHelpers.WithdrawalPlan memory emptyPlan;
        // Create the withdrawBeansFromSources pipe call
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);
        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(siloHelpers),
            callData: abi.encodeWithSelector(
                SiloHelpers.withdrawBeansFromSources.selector,
                account,
                sourceTokenIndices,
                withdrawAmount,
                filterParams,
                0.01e18, // 1%
                uint8(mode),
                emptyPlan
            ),
            clipboard: hex"0000"
        });

        // Wrap the pipe calls in a farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        // Encode the advancedFarm call
        bytes memory data = abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);

        // Create the blueprint
        IMockFBeanstalk.Blueprint memory blueprint = IMockFBeanstalk.Blueprint({
            publisher: account,
            data: data,
            operatorPasteInstrs: new bytes32[](0),
            maxNonce: type(uint256).max,
            startTime: block.timestamp,
            endTime: type(uint256).max
        });

        // Get the blueprint hash
        bytes32 blueprintHash = bs.getBlueprintHash(blueprint);

        // Get the stored private key and sign
        uint256 privateKey = getPrivateKey(account);
        bytes memory signature = signBlueprint(blueprintHash, privateKey);

        // Create and return the requisition
        return
            IMockFBeanstalk.Requisition({
                blueprint: blueprint,
                blueprintHash: blueprintHash,
                signature: signature
            });
    }

    //////////////////////////// SowBlueprintv0 ////////////////////////////

    // Helper function that takes SowAmounts struct
    function setupSowBlueprintv0Blueprint(
        address account,
        SourceMode sourceMode,
        SowBlueprintBase.SowAmounts memory sowAmounts,
        uint256 minTemp,
        int256 operatorTipAmount,
        address tipAddress,
        uint256 maxPodlineLength,
        uint256 maxGrownStalkLimitPerBdv,
        uint256 runBlocksAfterSunrise
    )
        public
        returns (
            IMockFBeanstalk.Requisition memory,
            SowBlueprintBase.SowBlueprintStruct memory params
        )
    {
        // Create the SowBlueprintStruct using the helper function
        params = createSowBlueprintStruct(
            uint8(sourceMode),
            sowAmounts,
            minTemp,
            operatorTipAmount,
            tipAddress,
            maxPodlineLength,
            maxGrownStalkLimitPerBdv,
            runBlocksAfterSunrise,
            address(tractorHelpers),
            address(bs)
        );

        // Create the pipe call data
        bytes memory pipeCallData = createSowBlueprintv0CallData(params);

        // Create the requisition using the pipe call data
        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            account,
            pipeCallData,
            address(bs)
        );

        // Publish the requisition
        publishAccountRequisition(account, req);

        return (req, params);
    }

    // Helper function to create SowBlueprintStruct
    function createSowBlueprintStruct(
        uint8 sourceMode,
        SowBlueprintBase.SowAmounts memory sowAmounts,
        uint256 minTemp,
        int256 operatorTipAmount,
        address tipAddress,
        uint256 maxPodlineLength,
        uint256 maxGrownStalkLimitPerBdv,
        uint256 runBlocksAfterSunrise,
        address tractorHelpersAddress,
        address bsAddress
    ) internal view returns (SowBlueprintBase.SowBlueprintStruct memory) {
        // Create default whitelisted operators array with msg.sender
        address[] memory whitelistedOps = new address[](3);
        whitelistedOps[0] = msg.sender;
        whitelistedOps[1] = tipAddress;
        whitelistedOps[2] = address(this);

        // Create array with single index for the token based on source mode
        uint8[] memory sourceTokenIndices = new uint8[](1);
        if (sourceMode == uint8(SourceMode.PURE_PINTO)) {
            sourceTokenIndices[0] = TractorHelpers(tractorHelpersAddress).getTokenIndex(
                IMockFBeanstalk(bsAddress).getBeanToken()
            );
        } else if (sourceMode == uint8(SourceMode.LOWEST_PRICE)) {
            sourceTokenIndices[0] = type(uint8).max;
        } else {
            // LOWEST_SEED
            sourceTokenIndices[0] = type(uint8).max - 1;
        }

        // Create SowParams struct
        SowBlueprintBase.SowParams memory sowParams = SowBlueprintBase.SowParams({
            sourceTokenIndices: sourceTokenIndices,
            sowAmounts: sowAmounts,
            minTemp: minTemp,
            maxPodlineLength: maxPodlineLength,
            maxGrownStalkPerBdv: maxGrownStalkLimitPerBdv,
            runBlocksAfterSunrise: runBlocksAfterSunrise,
            slippageRatio: 0.01e18 // 1%
        });

        // Create OperatorParams struct
        BlueprintBase.OperatorParams memory opParams = BlueprintBase.OperatorParams({
            whitelistedOperators: whitelistedOps,
            tipAddress: tipAddress,
            operatorTipAmount: operatorTipAmount
        });

        return SowBlueprintBase.SowBlueprintStruct({sowParams: sowParams, opParams: opParams});
    }

    // Helper to create the calldata for sowBlueprint
    function createSowBlueprintv0CallData(
        SowBlueprintBase.SowBlueprintStruct memory params
    ) internal view returns (bytes memory) {
        // Create the sowBlueprint pipe call
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);

        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(sowBlueprint),
            callData: abi.encodeWithSelector(SowBlueprint.sowBlueprint.selector, params),
            clipboard: hex"0000"
        });

        // Wrap the pipe calls in a farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        // Return the encoded farm call
        return abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);
    }

    //////////////////////////// AutomateClaimBlueprint ////////////////////////////

    /**
     * @notice Helper struct to bundle automate claim setup parameters and avoid stack too deep
     */
    struct AutomateClaimSetupParams {
        address account;
        SourceMode sourceMode;
        uint256 minMowAmount;
        uint256 minTwaDeltaB;
        uint256 minPlantAmount;
        uint256 minHarvestAmount;
        uint256 minRinseAmount;
        uint256 minUnripeClaimAmount;
        address tipAddress;
        int256 mowTipAmount;
        int256 plantTipAmount;
        int256 harvestTipAmount;
        int256 rinseTipAmount;
        int256 unripeClaimTipAmount;
        uint256 maxGrownStalkPerBdv;
    }

    function setupAutomateClaimBlueprint(
        AutomateClaimSetupParams memory p
    )
        internal
        returns (
            IMockFBeanstalk.Requisition memory,
            AutomateClaimBlueprint.AutomateClaimBlueprintStruct memory params
        )
    {
        params = _createAutomateClaimBlueprintStructFromParams(p);

        bytes memory pipeCallData = createAutomateClaimBlueprintCallData(params);

        IMockFBeanstalk.Requisition memory req = createRequisitionWithPipeCall(
            p.account,
            pipeCallData,
            address(bs)
        );

        publishAccountRequisition(p.account, req);

        return (req, params);
    }

    function _createAutomateClaimBlueprintStructFromParams(
        AutomateClaimSetupParams memory p
    ) internal view returns (AutomateClaimBlueprint.AutomateClaimBlueprintStruct memory) {
        // Create default whitelisted operators array with msg.sender
        address[] memory whitelistedOps = new address[](3);
        whitelistedOps[0] = msg.sender;
        whitelistedOps[1] = p.tipAddress;
        whitelistedOps[2] = address(this);

        // Create array with single index for the token based on source mode
        uint8[] memory sourceTokenIndices = _getSourceTokenIndices(p.sourceMode);

        // create per-field-id harvest configs
        AutomateClaimBlueprint.FieldHarvestConfig[]
            memory fieldHarvestConfigs = createFieldHarvestConfigs(p.minHarvestAmount);

        // Create AutomateClaimParams struct
        AutomateClaimBlueprint.AutomateClaimParams
            memory automateClaimParams = AutomateClaimBlueprint.AutomateClaimParams({
                minMowAmount: p.minMowAmount,
                minTwaDeltaB: p.minTwaDeltaB,
                minPlantAmount: p.minPlantAmount,
                fieldHarvestConfigs: fieldHarvestConfigs,
                minRinseAmount: p.minRinseAmount,
                minUnripeClaimAmount: p.minUnripeClaimAmount,
                sourceTokenIndices: sourceTokenIndices,
                maxGrownStalkPerBdv: p.maxGrownStalkPerBdv,
                slippageRatio: 0.01e18 // 1%
            });

        // create OperatorParamsExtended struct
        AutomateClaimBlueprint.OperatorParamsExtended
            memory opParamsExtended = createOperatorParamsExtended(
                whitelistedOps,
                p.tipAddress,
                p.mowTipAmount,
                p.plantTipAmount,
                p.harvestTipAmount,
                p.rinseTipAmount,
                p.unripeClaimTipAmount
            );

        return
            AutomateClaimBlueprint.AutomateClaimBlueprintStruct({
                automateClaimParams: automateClaimParams,
                opParams: opParamsExtended
            });
    }

    function _getSourceTokenIndices(
        SourceMode sourceMode
    ) internal view returns (uint8[] memory sourceTokenIndices) {
        sourceTokenIndices = new uint8[](1);
        if (sourceMode == SourceMode.PURE_PINTO) {
            sourceTokenIndices[0] = tractorHelpers.getTokenIndex(
                IMockFBeanstalk(address(bs)).getBeanToken()
            );
        } else if (sourceMode == SourceMode.LOWEST_PRICE) {
            sourceTokenIndices[0] = type(uint8).max;
        } else {
            // LOWEST_SEED
            sourceTokenIndices[0] = type(uint8).max - 1;
        }
    }

    function createFieldHarvestConfigs(
        uint256 minHarvestAmount
    )
        internal
        view
        returns (AutomateClaimBlueprint.FieldHarvestConfig[] memory fieldHarvestConfigs)
    {
        fieldHarvestConfigs = new AutomateClaimBlueprint.FieldHarvestConfig[](2);
        // default field id
        fieldHarvestConfigs[0] = AutomateClaimBlueprint.FieldHarvestConfig({
            fieldId: DEFAULT_FIELD_ID,
            minHarvestAmount: minHarvestAmount
        });
        // expected payback field id
        fieldHarvestConfigs[1] = AutomateClaimBlueprint.FieldHarvestConfig({
            fieldId: PAYBACK_FIELD_ID,
            minHarvestAmount: minHarvestAmount
        });
        return fieldHarvestConfigs;
    }

    function createAutomateClaimBlueprintCallData(
        AutomateClaimBlueprint.AutomateClaimBlueprintStruct memory params
    ) internal view returns (bytes memory) {
        // create the automateClaimBlueprint pipe call
        IMockFBeanstalk.AdvancedPipeCall[] memory pipes = new IMockFBeanstalk.AdvancedPipeCall[](1);

        pipes[0] = IMockFBeanstalk.AdvancedPipeCall({
            target: address(automateClaimBlueprint),
            callData: abi.encodeWithSelector(
                AutomateClaimBlueprint.automateClaimBlueprint.selector,
                params
            ),
            clipboard: hex"0000"
        });

        // wrap the pipe calls in a farm call
        IMockFBeanstalk.AdvancedFarmCall[] memory calls = new IMockFBeanstalk.AdvancedFarmCall[](1);
        calls[0] = IMockFBeanstalk.AdvancedFarmCall({
            callData: abi.encodeWithSelector(IMockFBeanstalk.advancedPipe.selector, pipes, 0),
            clipboard: ""
        });

        // return the encoded farm call
        return abi.encodeWithSelector(IMockFBeanstalk.advancedFarm.selector, calls);
    }

    function createOperatorParamsExtended(
        address[] memory whitelistedOps,
        address tipAddress,
        int256 mowTipAmount,
        int256 plantTipAmount,
        int256 harvestTipAmount,
        int256 rinseTipAmount,
        int256 unripeClaimTipAmount
    ) internal view returns (AutomateClaimBlueprint.OperatorParamsExtended memory) {
        // create OperatorParams struct
        BlueprintBase.OperatorParams memory opParams = BlueprintBase.OperatorParams({
            whitelistedOperators: whitelistedOps,
            tipAddress: tipAddress,
            operatorTipAmount: 0 // plain operator tip amount is not used in this blueprint
        });

        // create OperatorParamsExtended struct
        AutomateClaimBlueprint.OperatorParamsExtended
            memory opParamsExtended = AutomateClaimBlueprint.OperatorParamsExtended({
                baseOpParams: opParams,
                mowTipAmount: mowTipAmount,
                plantTipAmount: plantTipAmount,
                harvestTipAmount: harvestTipAmount,
                rinseTipAmount: rinseTipAmount,
                unripeClaimTipAmount: unripeClaimTipAmount
            });

        return opParamsExtended;
    }

    /**
     * @notice Create ContractData for rinse operations
     * @param fertilizerIds Array of fertilizer IDs to include in rinse data
     * @return dynamicData Array of ContractData containing rinse information
     */
    function createRinseDynamicData(
        uint256[] memory fertilizerIds
    ) internal view returns (IMockFBeanstalk.ContractData[] memory dynamicData) {
        dynamicData = new IMockFBeanstalk.ContractData[](1);
        dynamicData[0] = IMockFBeanstalk.ContractData({
            key: automateClaimBlueprint.RINSE_DATA_KEY(),
            value: abi.encode(fertilizerIds)
        });
    }

    /**
     * @notice Merge harvest and rinse dynamic data arrays
     * @param harvestData Dynamic data for harvest operations
     * @param rinseData Dynamic data for rinse operations
     * @return merged Combined dynamic data array
     */
    function mergeHarvestAndRinseDynamicData(
        IMockFBeanstalk.ContractData[] memory harvestData,
        IMockFBeanstalk.ContractData[] memory rinseData
    ) internal pure returns (IMockFBeanstalk.ContractData[] memory merged) {
        merged = new IMockFBeanstalk.ContractData[](harvestData.length + rinseData.length);
        for (uint256 i = 0; i < harvestData.length; i++) {
            merged[i] = harvestData[i];
        }
        for (uint256 i = 0; i < rinseData.length; i++) {
            merged[harvestData.length + i] = rinseData[i];
        }
    }
}

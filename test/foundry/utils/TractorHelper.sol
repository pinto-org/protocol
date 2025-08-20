// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;
pragma abicoder v2;

import {TestHelper, LibTransfer, C, IMockFBeanstalk} from "test/foundry/utils/TestHelper.sol";
import {SowBlueprint} from "contracts/ecosystem/SowBlueprint.sol";
import {TractorHelpers} from "contracts/ecosystem/TractorHelpers.sol";
import {LibTractorHelpers} from "contracts/libraries/Silo/LibTractorHelpers.sol";
import {SiloHelpers} from "contracts/ecosystem/SiloHelpers.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";

contract TractorHelper is TestHelper {
    // Add this at the top of the contract
    TractorHelpers internal tractorHelpers;
    SowBlueprint internal sowBlueprint;
    SiloHelpers internal siloHelpers;

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
        LibSiloHelpers.FilterParams memory filterParams = LibSiloHelpers.getDefaultFilterParams();
        filterParams.maxGrownStalkPerBdv = maxGrownStalkPerBdv;
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

    // Helper function that takes SowAmounts struct
    function setupSowBlueprintv0Blueprint(
        address account,
        SourceMode sourceMode,
        SowBlueprint.SowAmounts memory sowAmounts,
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
            SowBlueprint.SowBlueprintStruct memory params
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
        vm.prank(account);
        bs.publishRequisition(req);

        return (req, params);
    }

    // Helper function to create SowBlueprintStruct
    function createSowBlueprintStruct(
        uint8 sourceMode,
        SowBlueprint.SowAmounts memory sowAmounts,
        uint256 minTemp,
        int256 operatorTipAmount,
        address tipAddress,
        uint256 maxPodlineLength,
        uint256 maxGrownStalkLimitPerBdv,
        uint256 runBlocksAfterSunrise,
        address tractorHelpersAddress,
        address bsAddress
    ) internal view returns (SowBlueprint.SowBlueprintStruct memory) {
        // Create default whitelisted operators array with msg.sender
        address[] memory whitelistedOps = new address[](3);
        whitelistedOps[0] = msg.sender;
        whitelistedOps[1] = tipAddress;
        whitelistedOps[2] = address(this);

        // Create array with single index for the token based on source mode
        uint8[] memory sourceTokenIndices = new uint8[](1);
        if (sourceMode == uint8(SourceMode.PURE_PINTO)) {
            sourceTokenIndices[0] = tractorHelpers.getTokenIndex(
                IMockFBeanstalk(bsAddress).getBeanToken()
            );
        } else if (sourceMode == uint8(SourceMode.LOWEST_PRICE)) {
            sourceTokenIndices[0] = type(uint8).max;
        } else {
            // LOWEST_SEED
            sourceTokenIndices[0] = type(uint8).max - 1;
        }

        // Create SowParams struct
        SowBlueprint.SowParams memory sowParams = SowBlueprint.SowParams({
            sourceTokenIndices: sourceTokenIndices,
            sowAmounts: sowAmounts,
            minTemp: minTemp,
            maxPodlineLength: maxPodlineLength,
            maxGrownStalkPerBdv: maxGrownStalkLimitPerBdv,
            runBlocksAfterSunrise: runBlocksAfterSunrise,
            slippageRatio: 0.01e18 // 1%
        });

        // Create OperatorParams struct
        SowBlueprint.OperatorParams memory opParams = SowBlueprint.OperatorParams({
            whitelistedOperators: whitelistedOps,
            tipAddress: tipAddress,
            operatorTipAmount: operatorTipAmount
        });

        return SowBlueprint.SowBlueprintStruct({sowParams: sowParams, opParams: opParams});
    }

    // Helper to create the calldata for sowBlueprint
    function createSowBlueprintv0CallData(
        SowBlueprint.SowBlueprintStruct memory params
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
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @title LibConvertData
 */
library LibConvertData {
    // In order to preserve backwards compatibility, make sure new kinds are added at the end of the enum.
    enum ConvertKind {
        LAMBDA_LAMBDA,
        BEANS_TO_WELL_LP,
        WELL_LP_TO_BEANS,
        ANTI_LAMBDA_LAMBDA
    }

    /// @notice Decoder for the Convert Enum
    function convertKind(bytes memory self) internal pure returns (ConvertKind) {
        return abi.decode(self, (ConvertKind));
    }

    /// @notice Decoder for the addLPInBeans Convert
    function basicConvert(
        bytes memory self
    ) internal pure returns (uint256 amountIn, uint256 minAmontOut) {
        (, amountIn, minAmontOut) = abi.decode(self, (ConvertKind, uint256, uint256));
    }

    /// @notice Decoder for the addLPInBeans Convert
    function convertWithAddress(
        bytes memory self
    ) internal pure returns (uint256 amountIn, uint256 minAmontOut, address token) {
        (, amountIn, minAmontOut, token) = abi.decode(
            self,
            (ConvertKind, uint256, uint256, address)
        );
    }

    /// @notice Decoder for the lambdaConvert
    function lambdaConvert(
        bytes memory self
    ) internal pure returns (uint256 amount, address token) {
        (, amount, token) = abi.decode(self, (ConvertKind, uint256, address));
    }

    /// @notice Decoder for the antiLambdaConvert
    /// @dev contains an additional address parameter for the account to update the deposit
    /// and a bool to indicate whether to decrease the bdv
    function antiLambdaConvert(
        bytes memory self
    ) internal pure returns (uint256 amount, address token, address account, bool decreaseBDV) {
        (, amount, token, account) = abi.decode(self, (ConvertKind, uint256, address, address));
        decreaseBDV = true;
    }
}

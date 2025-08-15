// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

library LibTransfer {
    type To is uint8;
}

library BeanstalkFertilizer {
    struct Balance {
        uint128 amount;
        uint128 lastBpf;
    }
}

interface IBarnPayback {
    struct AccountFertilizerData {
        address account;
        uint128 amount;
        uint128 lastBpf;
    }

    struct Fertilizers {
        uint128 fertilizerId;
        AccountFertilizerData[] accountData;
    }

    error AddressEmptyCode(address target);
    error AddressInsufficientBalance(address account);
    error ERC1155InsufficientBalance(
        address sender,
        uint256 balance,
        uint256 needed,
        uint256 tokenId
    );
    error ERC1155InvalidApprover(address approver);
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
    error ERC1155InvalidOperator(address operator);
    error ERC1155InvalidReceiver(address receiver);
    error ERC1155InvalidSender(address sender);
    error ERC1155MissingApprovalForAll(address operator, address owner);
    error FailedInnerCall();
    error InvalidInitialization();
    error NotInitializing();
    error OwnableInvalidOwner(address owner);
    error OwnableUnauthorizedAccount(address account);
    error ReentrancyGuardReentrantCall();
    error SafeCastOverflowedUintToInt(uint256 value);
    error SafeERC20FailedOperation(address token);

    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event BarnPaybackRewardsReceived(uint256 amount);
    event ClaimFertilizer(uint256[] ids, uint256 beans);
    event Initialized(uint64 version);
    event InternalBalanceChanged(address indexed account, address indexed token, int256 delta);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );
    event URI(string value, uint256 indexed id);

    function balanceOf(address account, uint256 id) external view returns (uint256);
    function balanceOfBatch(
        address[] memory accounts,
        uint256[] memory ids
    ) external view returns (uint256[] memory);
    function balanceOfFertilized(
        address account,
        uint256[] memory ids
    ) external view returns (uint256 beans);
    function balanceOfUnfertilized(
        address account,
        uint256[] memory ids
    ) external view returns (uint256 beans);
    function barnPaybackReceive(uint256 shipmentAmount) external;
    function barnRemaining() external view returns (uint256);
    function claimFertilized(uint256[] memory ids, LibTransfer.To mode) external;
    function fert()
        external
        view
        returns (
            uint256 activeFertilizer,
            uint256 fertilizedIndex,
            uint256 unfertilizedIndex,
            uint256 fertilizedPaidIndex,
            uint128 fertFirst,
            uint128 fertLast,
            uint128 bpf,
            uint256 leftoverBeans
        );
    function isApprovedForAll(address account, address operator) external view returns (bool);
    function lastBalanceOf(
        address account,
        uint256 id
    ) external view returns (BeanstalkFertilizer.Balance memory);
    function lastBalanceOfBatch(
        address[] memory accounts,
        uint256[] memory ids
    ) external view returns (BeanstalkFertilizer.Balance[] memory balances);
    function mintFertilizers(Fertilizers[] memory fertilizerIds) external;
    function name() external pure returns (string memory);
    function owner() external view returns (address);
    function pinto() external view returns (address);
    function pintoProtocol() external view returns (address);
    function renounceOwnership() external;
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external;
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external;
    function setApprovalForAll(address operator, bool approved) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function symbol() external pure returns (string memory);
    function totalUnfertilizedBeans() external view returns (uint256 beans);
    function transferOwnership(address newOwner) external;
    function uri(uint256) external view returns (string memory);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library LibTransfer {
    enum To {
        EXTERNAL,
        INTERNAL
    }
}

interface ISiloPayback {
    struct UnripeBdvTokenData {
        address receipient;
        uint256 bdv;
    }

    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidSpender(address spender);
    error InvalidInitialization();
    error NotInitializing();
    error OwnableInvalidOwner(address owner);
    error OwnableUnauthorizedAccount(address account);

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Claimed(address indexed user, uint256 amount, uint256 rewards);
    event Initialized(uint64 version);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SiloPaybackRewardsReceived(uint256 amount, uint256 newIndex);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function PRECISION() external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function batchMint(UnripeBdvTokenData[] memory unripeReceipts) external;
    function claim(address recipient, LibTransfer.To toMode) external;
    function decimals() external view returns (uint8);
    function earned(address account) external view returns (uint256);
    function initialize(address _pinto, address _pintoProtocol) external;
    function name() external view returns (string memory);
    function owner() external view returns (address);
    function pinto() external view returns (address);
    function pintoProtocol() external view returns (address);
    function renounceOwnership() external;
    function rewardPerTokenStored() external view returns (uint256);
    function rewards(address) external view returns (uint256);
    function siloPaybackReceive(uint256 shipmentAmount) external;
    function siloRemaining() external view returns (uint256);
    function symbol() external view returns (string memory);
    function totalDistributed() external view returns (uint256);
    function totalReceived() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transferOwnership(address newOwner) external;
    function userRewardPerTokenPaid(address) external view returns (uint256);
    function protocolUpdate(address from, address to, uint256 amount) external;
}

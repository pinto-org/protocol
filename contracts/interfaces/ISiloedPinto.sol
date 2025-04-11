// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

struct SiloDeposit {
    int96 stem;
    uint160 amount;
}

interface ISiloedPinto {
    type From is uint8;
    type To is uint8;

    error DepositNotInserted();
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidSpender(address spender);
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max);
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error InsufficientDepositAmount();
    error InvalidInitialization();
    error InvalidMode();
    error InvalidToken();
    error MinPdvViolation();
    error NotInitializing();
    error OwnableInvalidOwner(address owner);
    error OwnableUnauthorizedAccount(address account);
    error PdvDecrease();
    error ReentrancyGuardReentrantCall();
    error SafeERC20FailedOperation(address token);
    error StemsAmountMismatch();
    error ZeroAssets();
    error ZeroShares();

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Initialized(uint64 version);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Update(uint256 totalAssets, uint256 totalShares);
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function claim() external;
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function decimals() external view returns (uint8);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function depositAdvanced(
        uint256 assets,
        address receiver,
        From fromMode,
        To toMode
    ) external returns (uint256 shares);
    function depositFromSilo(
        int96[] memory stems,
        uint256[] memory amounts,
        address receiver,
        To toMode
    ) external returns (uint256 shares);
    function deposits(uint256) external view returns (int96 stem, uint160 amount);
    function floodAssetsPresent() external view returns (bool);
    function floodTranchRatio() external view returns (uint256);
    function germinatingDeposits(uint256) external view returns (SiloDeposit memory);
    function getDeposit(uint256 index) external view returns (SiloDeposit memory);
    function getDepositsLength() external view returns (uint256);
    function getGerminatingDepositsLength() external view returns (uint256);
    function getMaxRedeem(address owner, From fromMode) external view returns (uint256);
    function getMaxWithdraw(address owner, From fromMode) external view returns (uint256);
    function initialize(
        uint256 _maxTriggerPrice,
        uint256 _slippageRatio,
        uint256 _floodTranchRatio,
        uint256 _vestingPeriod,
        uint256 _minSize,
        uint256 _targetMinSize
    ) external;
    function lastEarnedTimestamp() external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxMint(address) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function maxTriggerPrice() external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function minSize() external view returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function mintAdvanced(
        uint256 shares,
        address receiver,
        From fromMode,
        To toMode
    ) external returns (uint256 assets);
    function name() external view returns (string memory);
    function owner() external view returns (address);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);
    function redeemAdvanced(
        uint256 shares,
        address receiver,
        address owner,
        From fromMode,
        To toMode
    ) external returns (uint256 assets);
    function redeemToSilo(
        uint256 shares,
        address receiver,
        address owner,
        From fromMode
    ) external returns (int96[] memory stems, uint256[] memory amounts);
    function renounceOwnership() external;
    function rescueTokens(address token, uint256 amount, address to) external;
    function setFloodTranchRatio(uint256 _floodTranchRatio) external;
    function setMaxTriggerPrice(uint256 _maxTriggerPrice) external;
    function setMinSize(uint256 _minSize) external;
    function setSlippageRatio(uint256 _slippageRatio) external;
    function setVestingPeriod(uint256 _vestingPeriod) external;
    function slippageRatio() external view returns (uint256);
    function symbol() external view returns (string memory);
    function totalAssets() external view returns (uint256 totalManagedAssets);
    function totalSupply() external view returns (uint256);
    function trancheSizes(address) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transferOwnership(address newOwner) external;
    function underlyingPdv() external view returns (uint256);
    function unvestedAssets() external view returns (uint256 assets);
    function version() external pure returns (string memory);
    function vestingPeriod() external view returns (uint256);
    function vestingPinto() external view returns (uint256);
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);
    function withdrawAdvanced(
        uint256 assets,
        address receiver,
        address owner,
        From fromMode,
        To toMode
    ) external returns (uint256 shares);
    function withdrawToSilo(
        uint256 assets,
        address receiver,
        address owner,
        From fromMode
    ) external returns (int96[] memory stems, uint256[] memory amounts);
}

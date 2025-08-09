/**
 * SPDX-License-Identifier: MIT
 *
 */
pragma solidity ^0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Decimal} from "contracts/libraries/Decimal.sol";
import {GaugeId, Gauge} from "contracts/beanstalk/storage/System.sol";
interface IMockFBeanstalk {
    enum CounterUpdateType {
        INCREASE,
        DECREASE
    }

    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    enum GerminationSide {
        ODD,
        EVEN,
        NOT_GERMINATING
    }

    enum ShipmentRecipient {
        NULL,
        SILO,
        FIELD,
        INTERNAL_BALANCE,
        EXTERNAL_BALANCE
    }

    struct AccountSeasonOfPlenty {
        uint32 lastRain;
        uint32 lastSop;
        uint256 roots;
        FarmerSops[] farmerSops;
    }

    struct AdvancedFarmCall {
        bytes callData;
        bytes clipboard;
    }

    struct AdvancedPipeCall {
        address target;
        bytes callData;
        bytes clipboard;
    }

    struct AssetSettings {
        bytes4 selector;
        uint40 stalkEarnedPerSeason;
        uint48 stalkIssuedPerBdv;
        uint32 milestoneSeason;
        int96 milestoneStem;
        bytes1 encodeType;
        int40 deltaStalkEarnedPerSeason;
        uint128 gaugePoints;
        uint64 optimalPercentDepositedBdv;
        Implementation gaugePointImplementation;
        Implementation liquidityWeightImplementation;
    }

    struct Balance {
        uint128 amount;
        uint128 lastBpf;
    }

    struct Blueprint {
        address publisher;
        bytes data;
        bytes32[] operatorPasteInstrs;
        uint256 maxNonce;
        uint256 startTime;
        uint256 endTime;
    }

    struct ClaimPlentyData {
        address token;
        uint256 plenty;
    }

    struct DeltaBStorage {
        int256 beforeInputTokenDeltaB;
        int256 afterInputTokenDeltaB;
        int256 beforeOutputTokenDeltaB;
        int256 afterOutputTokenDeltaB;
        int256 beforeOverallDeltaB;
        int256 afterOverallDeltaB;
    }

    struct Deposit {
        uint128 amount;
        uint128 bdv;
    }

    struct EvaluationParameters {
        uint256 maxBeanMaxLpGpPerBdvRatio;
        uint256 minBeanMaxLpGpPerBdvRatio;
        uint256 targetSeasonsToCatchUp;
        uint256 podRateLowerBound;
        uint256 podRateOptimal;
        uint256 podRateUpperBound;
        uint256 deltaPodDemandLowerBound;
        uint256 deltaPodDemandUpperBound;
        uint256 lpToSupplyRatioUpperBound;
        uint256 lpToSupplyRatioOptimal;
        uint256 lpToSupplyRatioLowerBound;
        uint256 excessivePriceThreshold;
        uint256 soilCoefficientHigh;
        uint256 soilCoefficientLow;
        uint256 baseReward;
        uint128 minAvgGsPerBdv;
        uint128 rainingMinBeanMaxLpGpPerBdvRatio;
    }

    struct ExtEvaluationParameters {
        uint256 belowPegSoilL2SRScalar;
        uint256 soilCoefficientRelativelyHigh;
        uint256 soilCoefficientRelativelyLow;
        uint256 abovePegDeltaBSoilScalar;
        uint256 soilDistributionPeriod;
        uint256 minSoilIssuance;
        uint256 minSoilSownDemand;
        bytes32[60] buffer;
    }

    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    struct FarmerSops {
        address well;
        PerWellPlenty wellsPlenty;
    }

    struct Implementation {
        address target;
        bytes4 selector;
        bytes1 encodeType;
        bytes data;
    }

    struct MowStatus {
        int96 lastStem;
        uint128 bdv;
    }

    struct PenaltyData {
        uint256 inputToken;
        uint256 outputToken;
        uint256 overall;
    }

    struct PerWellPlenty {
        uint256 plentyPerRoot;
        uint256 plenty;
        bytes32[4] _buffer;
    }

    struct PipeCall {
        address target;
        bytes data;
    }

    struct Plot {
        uint256 index;
        uint256 pods;
    }

    struct PodListing {
        address lister;
        uint256 fieldId;
        uint256 index;
        uint256 start;
        uint256 podAmount;
        uint24 pricePerPod;
        uint256 maxHarvestableIndex;
        uint256 minFillAmount;
        uint8 mode;
    }

    struct PodOrder {
        address orderer;
        uint256 fieldId;
        uint24 pricePerPod;
        uint256 maxPlaceInLine;
        uint256 minFillAmount;
    }

    struct Rain {
        uint256 pods;
        uint256 roots;
        bytes32[4] _buffer;
    }

    struct Requisition {
        Blueprint blueprint;
        bytes32 blueprintHash;
        bytes signature;
    }

    struct Season {
        uint32 current;
        uint32 lastSop;
        uint32 lastSopSeason;
        uint32 rainStart;
        bool raining;
        uint64 sunriseBlock;
        bool abovePeg;
        uint256 start;
        uint256 period;
        uint256 timestamp;
        uint256 standardMintedBeans;
        bytes32[8] _buffer;
    }

    struct SeedGauge {
        uint128 averageGrownStalkPerBdvPerSeason;
        uint128 beanToMaxLpGpPerBdvRatio;
        bytes32[4] _buffer;
    }

    struct ShipmentRoute {
        address planContract;
        bytes4 planSelector;
        ShipmentRecipient recipient;
        bytes data;
    }

    struct Supply {
        uint128 endBpf;
        uint256 supply;
    }

    struct TokenDepositId {
        address token;
        uint256[] depositIds;
        Deposit[] tokenDeposits;
    }

    struct Weather {
        uint128 lastDeltaSoil;
        uint32 lastSowTime;
        uint32 thisSowTime;
        uint32 temp;
        bytes32[4] _buffer;
    }

    struct WellDeltaB {
        address well;
        int256 deltaB;
    }

    struct WhitelistStatus {
        address token;
        bool isWhitelisted;
        bool isWhitelistedLp;
        bool isWhitelistedWell;
        bool isSoppable;
    }

    struct D256 {
        uint256 value;
    }

    struct BeanstalkState {
        D256 deltaPodDemand;
        D256 lpToSupplyRatio;
        D256 podRate;
        address largestLiqWell;
        bool oracleFailure;
    }

    error AddressEmptyCode(address target);
    error AddressInsufficientBalance(address account);
    error ECDSAInvalidSignature();
    error ECDSAInvalidSignatureLength(uint256 length);
    error ECDSAInvalidSignatureS(bytes32 s);
    error FailedInnerCall();
    error PRBMath__MulDivOverflow(uint256 prod1, uint256 denominator);
    error SafeCastOverflowedIntDowncast(uint8 bits, int256 value);
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);
    error SafeCastOverflowedUintToInt(uint256 value);
    error SafeERC20FailedOperation(address token);
    error StringsInsufficientHexLength(uint256 value, uint256 length);
    error T();

    event ActiveFieldSet(uint256 fieldId);
    event AddDeposit(
        address indexed account,
        address indexed token,
        int96 stem,
        uint256 amount,
        uint256 bdv
    );
    event AddWhitelistStatus(
        address token,
        uint256 index,
        bool isWhitelisted,
        bool isWhitelistedLp,
        bool isWhitelistedWell,
        bool isSoppable
    );
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event BeanToMaxLpGpPerBdvRatioChange(uint256 indexed season, uint256 caseId, int80 absChange);
    event CancelBlueprint(bytes32 blueprintHash);
    event ClaimPlenty(address indexed account, address token, uint256 plenty);
    event Convert(
        address indexed account,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount
    );
    event DeltaB(int256 deltaB);
    event DepositApproval(
        address indexed owner,
        address indexed spender,
        address token,
        uint256 amount
    );
    event DewhitelistToken(address indexed token);
    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
    event FarmerGerminatingStalkBalanceChanged(
        address indexed account,
        int256 delta,
        GerminationSide germ
    );
    event FieldAdded(uint256 fieldId);
    event GaugePointChange(uint256 indexed season, address indexed token, uint256 gaugePoints);
    event Harvest(address indexed account, uint256 fieldId, uint256[] plots, uint256 beans);
    event Incentivization(address indexed account, uint256 beans);
    event InternalBalanceChanged(address indexed account, address indexed token, int256 delta);
    event MockConvert(uint256 stalkRemoved, uint256 bdvRemoved);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Pause(uint256 timestamp);
    event Pick(address indexed account, address indexed token, uint256 amount);
    event Plant(address indexed account, uint256 beans);
    event PlotTransfer(
        address indexed from,
        address indexed to,
        uint256 fieldId,
        uint256 indexed index,
        uint256 amount
    );
    event PodApproval(
        address indexed owner,
        address indexed spender,
        uint256 fieldId,
        uint256 amount
    );
    event PodListingCancelled(address indexed lister, uint256 fieldId, uint256 index);
    event PodListingCreated(
        address indexed lister,
        uint256 fieldId,
        uint256 index,
        uint256 start,
        uint256 podAmount,
        uint24 pricePerPod,
        uint256 maxHarvestableIndex,
        uint256 minFillAmount,
        uint8 mode
    );
    event PodListingFilled(
        address indexed filler,
        address indexed lister,
        uint256 fieldId,
        uint256 index,
        uint256 start,
        uint256 podAmount,
        uint256 costInBeans
    );
    event PodOrderCancelled(address indexed orderer, bytes32 id);
    event PodOrderCreated(
        address indexed orderer,
        bytes32 id,
        uint256 beanAmount,
        uint256 fieldId,
        uint24 pricePerPod,
        uint256 maxPlaceInLine,
        uint256 minFillAmount
    );
    event PodOrderFilled(
        address indexed filler,
        address indexed orderer,
        bytes32 id,
        uint256 fieldId,
        uint256 index,
        uint256 start,
        uint256 podAmount,
        uint256 costInBeans
    );
    event PublishRequisition(Requisition requisition);
    event Receipt(ShipmentRecipient indexed recipient, uint256 receivedAmount, bytes data);
    event ReceiverApproved(address indexed owner, address receiver);
    event RemoveDeposit(
        address indexed account,
        address indexed token,
        int96 stem,
        uint256 amount,
        uint256 bdv
    );
    event RemoveDeposits(
        address indexed account,
        address indexed token,
        int96[] stems,
        uint256[] amounts,
        uint256 amount,
        uint256[] bdvs
    );
    event RetryableTicketCreated(uint256 indexed ticketId);
    event SeasonOfPlentyField(uint256 toField);
    event SeasonOfPlentyWell(
        uint256 indexed season,
        address well,
        address token,
        uint256 amount,
        uint256 beans
    );
    event ShipmentRoutesSet(ShipmentRoute[] newShipmentRoutes);
    event Soil(uint32 indexed season, uint256 soil);
    event Sow(address indexed account, uint256 fieldId, uint256 index, uint256 beans, uint256 pods);
    event StalkBalanceChanged(address indexed account, int256 delta, int256 deltaRoots);
    event Sunrise(uint256 indexed season);
    event TemperatureChange(
        uint256 indexed season,
        uint256 caseId,
        int32 absChange,
        uint256 fieldId
    );
    event TokenApproval(
        address indexed owner,
        address indexed spender,
        address token,
        uint256 amount
    );
    event TokenTransferred(
        address indexed token,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint8 fromMode,
        uint8 toMode
    );
    event TotalGerminatingBalanceChanged(
        uint256 germinationSeason,
        address indexed token,
        int256 deltaAmount,
        int256 deltaBdv
    );
    event TotalGerminatingStalkChanged(uint256 germinationSeason, int256 deltaGerminatingStalk);
    event TotalStalkChangedFromGermination(int256 deltaStalk, int256 deltaRoots);
    event Tractor(
        address indexed operator,
        address indexed publisher,
        bytes32 indexed blueprintHash,
        uint256 nonce,
        uint256 gasleft
    );
    event TractorExecutionBegan(
        address indexed operator,
        address indexed publisher,
        bytes32 indexed blueprintHash,
        uint256 nonce,
        uint256 gasleft
    );
    event TractorVersionSet(string version);
    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );
    event TransferSingle(
        address indexed operator,
        address indexed sender,
        address indexed recipient,
        uint256 depositId,
        uint256 amount
    );
    event URI(string _uri, uint256 indexed _id);
    event Unpause(uint256 timestamp, uint256 timePassed);
    event UpdateAverageStalkPerBdvPerSeason(uint256 newStalkPerBdvPerSeason);
    event UpdateGaugeSettings(
        address indexed token,
        bytes4 gpSelector,
        bytes4 lwSelector,
        uint64 optimalPercentDepositedBdv
    );
    event UpdateTWAPs(uint256[2] balances);
    event UpdateWhitelistStatus(
        address token,
        uint256 index,
        bool isWhitelisted,
        bool isWhitelistedLp,
        bool isWhitelistedWell,
        bool isSoppable
    );
    event UpdatedEvaluationParameters(EvaluationParameters);
    event UpdatedGaugePointImplementationForToken(
        address indexed token,
        Implementation gaugePointImplementation
    );
    event UpdatedLiquidityWeightImplementationForToken(
        address indexed token,
        Implementation liquidityWeightImplementation
    );
    event UpdatedOptimalPercentDepositedBdvForToken(
        address indexed token,
        uint64 optimalPercentDepositedBdv
    );
    event UpdatedOracleImplementationForToken(
        address indexed token,
        Implementation oracleImplementation
    );
    event UpdatedStalkPerBdvPerSeason(
        address indexed token,
        uint40 stalkEarnedPerSeason,
        uint32 season
    );
    event WellOracle(uint32 indexed season, address well, int256 deltaB, bytes cumulativeReserves);
    event WhitelistToken(
        address indexed token,
        bytes4 selector,
        uint40 stalkEarnedPerSeason,
        uint256 stalkIssuedPerBdv,
        uint128 gaugePoints,
        uint64 optimalPercentDepositedBdv
    );
    event WhitelistTokenImplementations(
        address indexed token,
        Implementation gpImplementation,
        Implementation lwImplementation
    );

    function abovePeg() external view returns (bool);

    function activeField() external view returns (uint256);

    function addField() external;

    function addWhitelistSelector(address token, bytes4 selector) external;

    function addWhitelistStatus(
        address token,
        bool isWhitelisted,
        bool isWhitelistedLp,
        bool isWhitelistedWell,
        bool isSoppable
    ) external;

    function advancedFarm(
        AdvancedFarmCall[] memory data
    ) external payable returns (bytes[] memory results);

    function advancedPipe(
        AdvancedPipeCall[] memory pipes,
        uint256 value
    ) external payable returns (bytes[] memory results);

    function allowancePods(
        address owner,
        address spender,
        uint256 fieldId
    ) external view returns (uint256);

    function approveDeposit(address spender, address token, uint256 amount) external payable;

    function approvePods(address spender, uint256 fieldId, uint256 amount) external payable;

    function approveReceiver(address owner, address receiver) external;

    function approveToken(address spender, address token, uint256 amount) external payable;

    function balanceOf(address account, uint256 depositId) external view returns (uint256 amount);

    function balanceOfBatch(
        address[] memory accounts,
        uint256[] memory depositIds
    ) external view returns (uint256[] memory);

    function balanceOfDepositedBdv(
        address account,
        address token
    ) external view returns (uint256 depositedBdv);

    function balanceOfEarnedBeans(address account) external view returns (uint256 beans);

    function balanceOfEarnedStalk(address account) external view returns (uint256);

    function balanceOfFinishedGerminatingStalkAndRoots(
        address account
    ) external view returns (uint256 gStalk, uint256 gRoots);

    function balanceOfGerminatingStalk(address account) external view returns (uint256);

    function balanceOfGrownStalk(address account, address token) external view returns (uint256);

    function balanceOfGrownStalkMultiple(
        address account,
        address[] memory tokens
    ) external view returns (uint256[] memory grownStalks);

    function balanceOfPlantableSeeds(address account) external view returns (uint256);

    function balanceOfPlenty(address account, address well) external view returns (uint256 plenty);

    function balanceOfPods(address account, uint256 fieldId) external view returns (uint256 pods);

    function balanceOfRainRoots(address account) external view returns (uint256);

    function balanceOfRevitalizedStalk(
        address account,
        address[] memory tokens,
        int96[] memory stems,
        uint256[] memory amounts
    ) external view returns (uint256 stalk);

    function balanceOfRoots(address account) external view returns (uint256);

    function balanceOfSop(address account) external view returns (AccountSeasonOfPlenty memory sop);

    function balanceOfStalk(address account) external view returns (uint256);

    function balanceOfYoungAndMatureGerminatingStalk(
        address account
    ) external view returns (uint256 matureGerminatingStalk, uint256 youngGerminatingStalk);

    function batchTransferERC1155(
        address token,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) external payable;

    function bdv(address token, uint256 amount) external view returns (uint256 _bdv);

    function bdvs(
        address[] memory tokens,
        uint256[] memory amounts
    ) external view returns (uint256 _bdv);

    function beanSown() external view returns (uint256);

    function beanToBDV(uint256 amount) external pure returns (uint256);

    function calcCaseIdE(int256 deltaB, uint128 endSoil) external;

    function calcCaseIdWithParams(
        uint256 pods,
        uint256 _lastDeltaSoil,
        uint128 beanSown,
        uint128 endSoil,
        int256 deltaB,
        bool raining,
        bool rainRoots,
        bool aboveQ,
        uint256 L2SRState
    ) external;

    function calcGaugePointsWithParams(
        address token,
        uint256 percentOfDepositedBdv
    ) external view returns (uint256);

    function calculateConvertCapacityPenaltyE(
        uint256 overallCappedDeltaB,
        uint256 overallAmountInDirectionOfPeg,
        address inputToken,
        uint256 inputTokenAmountInDirectionOfPeg,
        address outputToken,
        uint256 outputTokenAmountInDirectionOfPeg
    ) external view returns (uint256 cumulativePenalty, PenaltyData memory pdCapacity);

    function calculateDeltaBFromReserves(
        address well,
        uint256[] memory reserves,
        uint256 lookback
    ) external view returns (int256);

    function calculateStalkPenalty(
        DeltaBStorage memory dbs,
        uint256 bdvConverted,
        uint256 overallConvertCapacity,
        address inputToken,
        address outputToken
    )
        external
        view
        returns (
            uint256 stalkPenaltyBdv,
            uint256 overallConvertCapacityUsed,
            uint256 inputTokenAmountUsed,
            uint256 outputTokenAmountUsed
        );

    function calculateStemForTokenFromGrownStalk(
        address token,
        uint256 grownStalk,
        uint256 bdvOfDeposit
    ) external view returns (int96 stem, GerminationSide germ);

    function calculateCultivationFactorDeltaE(
        BeanstalkState memory bs
    ) external view returns (uint256);

    function getGauge(GaugeId gaugeId) external view returns (Gauge memory);

    function getGaugeValue(GaugeId gaugeId) external view returns (bytes memory);

    function getGaugeData(GaugeId gaugeId) external view returns (bytes memory);

    function cancelBlueprint(Requisition memory requisition) external;

    function cancelPodListing(uint256 fieldId, uint256 index) external payable;

    function cancelPodOrder(PodOrder memory podOrder, uint8 mode) external payable;

    function cappedReservesDeltaB(address well) external view returns (int256 deltaB);

    function captureE() external returns (int256 deltaB);

    function captureWellE(address well) external returns (int256 deltaB);

    function captureWellEInstantaneous(address well) external returns (int256 instDeltaB);

    function claimAllPlenty(
        uint8 toMode
    ) external payable returns (ClaimPlentyData[] memory allPlenty);

    function claimOwnership() external;

    function claimPlenty(address well, uint8 toMode) external payable;

    function convert(
        bytes memory convertData,
        int96[] memory stems,
        uint256[] memory amounts
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

    function convertInternalE(
        address tokenIn,
        uint256 amountIn,
        bytes memory convertData
    )
        external
        returns (
            address toToken,
            address fromToken,
            uint256 toAmount,
            uint256 fromAmount,
            address account,
            bool decreaseBDV
        );

    function createPodListing(PodListing memory podListing) external payable;

    function createPodOrder(
        PodOrder memory podOrder,
        uint256 beanAmount,
        uint8 mode
    ) external payable returns (bytes32 id);

    function cumulativeCurrentDeltaB(address[] memory pools) external view returns (int256 deltaB);

    function decreaseDepositAllowance(
        address spender,
        address token,
        uint256 subtractedValue
    ) external returns (bool);

    function decreaseTokenAllowance(
        address spender,
        address token,
        uint256 subtractedValue
    ) external returns (bool);

    function defaultGaugePoints(
        uint256 currentGaugePoints,
        uint256 optimalPercentDepositedBdv,
        uint256 percentOfDepositedBdv,
        bytes memory
    ) external pure returns (uint256 newGaugePoints);

    function deposit(
        address token,
        uint256 _amount,
        uint8 mode
    ) external payable returns (uint256 amount, uint256 _bdv, int96 stem);

    function depositAllowance(
        address owner,
        address spender,
        address token
    ) external view returns (uint256);

    function depositForConvertE(
        address token,
        uint256 amount,
        uint256 bdv,
        uint256 grownStalk,
        uint256 deltaRainRoots
    ) external;

    function determineReward(uint256 secondsLate) external view returns (uint256);

    function dewhitelistToken(address token) external payable;

    function diamondCut(
        FacetCut[] memory _diamondCut,
        address _init,
        bytes memory _calldata
    ) external;

    function droughtSiloSunrise(uint256 amount) external;

    function droughtSunrise() external;

    function etherPipe(
        PipeCall memory p,
        uint256 value
    ) external payable returns (bytes memory result);

    function exploitPodOrderBeans() external;

    function exploitSop() external;

    function exploitUserInternalTokenBalance() external;

    function exploitUserSendTokenInternal() external;

    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_);

    function facetAddresses() external view returns (address[] memory facetAddresses_);

    function facetFunctionSelectors(
        address _facet
    ) external view returns (bytes4[] memory facetFunctionSelectors_);

    function facets() external view returns (Facet[] memory facets_);

    function farm(bytes[] memory data) external payable returns (bytes[] memory results);

    function farmSunrise() external;

    function farmSunrises(uint256 number) external;

    function fastForward(uint32 _s) external;

    function fieldCount() external view returns (uint256);

    function fillPodListing(
        PodListing memory podListing,
        uint256 beanAmount,
        uint8 mode
    ) external payable;

    function fillPodOrder(
        PodOrder memory podOrder,
        uint256 index,
        uint256 start,
        uint256 amount,
        uint8 mode
    ) external payable;

    function floodHarvestablePods() external view returns (uint256);

    function forceSunrise() external;

    function gaugePointsNoChange(
        uint256 currentGaugePoints,
        uint256,
        uint256
    ) external pure returns (uint256);

    function getAbsBeanToMaxLpRatioChangeFromCaseId(
        uint256 caseId
    ) external view returns (uint80 ml);

    function getAbsTemperatureChangeFromCaseId(uint256 caseId) external view returns (int32 t);

    function getAddressAndStem(uint256 depositId) external pure returns (address token, int96 stem);

    function getAllBalance(address account, address token) external view returns (Balance memory b);

    function getAllBalances(
        address account,
        address[] memory tokens
    ) external view returns (Balance[] memory balances);

    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);

    function getAverageGrownStalkPerBdv() external view returns (uint256);

    function getAverageGrownStalkPerBdvPerSeason() external view returns (uint128);

    function getBalance(address account, address token) external view returns (uint256 balance);

    function getBalances(
        address account,
        address[] memory tokens
    ) external view returns (uint256[] memory balances);

    function getBeanGaugePointsPerBdv() external view returns (uint256);

    function getBeanToken() external view returns (address);

    function getBeanIndex(IERC20[] memory tokens) external view returns (uint256);

    function getBeanToMaxLpGpPerBdvRatio() external view returns (uint256);

    function getBeanToMaxLpGpPerBdvRatioScaled() external view returns (uint256);

    function getBlueprintHash(Blueprint memory blueprint) external view returns (bytes32);

    function getBlueprintNonce(bytes32 blueprintHash) external view returns (uint256);

    function getCaseData(uint256 caseId) external view returns (bytes32 casesData);

    function getCases() external view returns (bytes32[144] memory cases);

    function getChangeFromCaseId(
        uint256 caseId
    ) external view returns (uint32, int32, uint80, int80);

    function getCounter(address account, bytes32 counterId) external view returns (uint256 count);

    function getCurrentBlueprintHash() external view returns (bytes32);

    function getCurrentHumidity() external view returns (uint128 humidity);

    function getDeltaPodDemand() external view returns (uint256);

    function getDeltaPodDemandLowerBound() external view returns (uint256);

    function getDeltaPodDemandUpperBound() external view returns (uint256);

    function getDeposit(
        address account,
        address token,
        int96 stem
    ) external view returns (uint256, uint256);

    function getDepositId(address token, int96 stem) external pure returns (uint256);

    function getDepositMerkleRoot() external pure returns (bytes32);

    function getDepositsForAccount(
        address account
    ) external view returns (TokenDepositId[] memory deposits);

    function getEndBpf() external view returns (uint128 endBpf);

    function getEvenGerminating(address token) external view returns (uint256, uint256);

    function getExcessivePriceThreshold() external view returns (uint256);

    function getExternalBalance(
        address account,
        address token
    ) external view returns (uint256 balance);

    function getExternalBalances(
        address account,
        address[] memory tokens
    ) external view returns (uint256[] memory balances);

    function getExtremelyFarAbove(uint256 optimalPercentBdv) external pure returns (uint256);

    function getExtremelyFarBelow(uint256 optimalPercentBdv) external pure returns (uint256);

    function getFirst() external view returns (uint128);

    function getGaugePointImplementationForToken(
        address token
    ) external view returns (Implementation memory);

    function getGaugePoints(address token) external view returns (uint256);

    function getGaugePointsPerBdvForToken(address token) external view returns (uint256);

    function getGaugePointsPerBdvForWell(address well) external view returns (uint256);

    function getGaugePointsWithParams(address token) external view returns (uint256);

    function getGerminatingRootsForSeason(uint32 season) external view returns (uint256);

    function getGerminatingStalkAndRootsForSeason(
        uint32 season
    ) external view returns (uint256, uint256);

    function getGerminatingStalkForSeason(uint32 season) external view returns (uint256);

    function getGerminatingStem(address token) external view returns (int96 germinatingStem);

    function getHighestNonGerminatingStem(address token) external view returns (int96 stem);

    function getGerminatingStems(
        address[] memory tokens
    ) external view returns (int96[] memory germinatingStems);

    function getHighestNonGerminatingStems(
        address[] memory tokens
    ) external view returns (int96[] memory highestNonGerminatingStems);

    function getGerminatingTotalDeposited(address token) external view returns (uint256 amount);

    function getGerminatingTotalDepositedBdv(address token) external view returns (uint256 _bdv);

    function getGrownStalkIssuedPerGp() external view returns (uint256);

    function getGrownStalkIssuedPerSeason() external view returns (uint256);

    function getHumidity(uint128 _s) external pure returns (uint128 humidity);

    function getIndexForDepositId(
        address account,
        address token,
        uint256 depositId
    ) external view returns (uint256);

    function getInternalBalance(
        address account,
        address token
    ) external view returns (uint256 balance);

    function getInternalBalanceMerkleRoot() external pure returns (bytes32);

    function getInternalBalances(
        address account,
        address[] memory tokens
    ) external view returns (uint256[] memory balances);

    function getLargestGpPerBdv() external view returns (uint256);

    function getLargestLiqWell() external view returns (address);

    function getLast() external view returns (uint128);

    function getLastMowedStem(
        address account,
        address token
    ) external view returns (int96 lastStem);

    function getLiquidityToSupplyRatio() external view returns (uint256);

    function getLiquidityWeightImplementationForToken(
        address token
    ) external view returns (Implementation memory);

    function getLpToSupplyRatioLowerBound() external view returns (uint256);

    function getLpToSupplyRatioOptimal() external view returns (uint256);

    function getLpToSupplyRatioUpperBound() external view returns (uint256);

    function getMaxAmountIn(
        address tokenIn,
        address tokenOut
    ) external view returns (uint256 amountIn);

    function getMaxBeanMaxLpGpPerBdvRatio() external view returns (uint256);

    function getMinBeanMaxLpGpPerBdvRatio() external view returns (uint256);

    function getMowStatus(
        address account,
        address[] memory tokens
    ) external view returns (MowStatus[] memory mowStatuses);

    function getNext(uint128 id) external view returns (uint128);

    function getNextSeasonStart() external view returns (uint256);

    function getNonBeanTokenAndIndexFromWell(address well) external view returns (address, uint256);

    function getOddGerminating(address token) external view returns (uint256, uint256);

    function getOracleImplementationForToken(
        address token
    ) external view returns (Implementation memory);

    function getOrderId(PodOrder memory podOrder) external pure returns (bytes32 id);

    function getOverallConvertCapacity() external view returns (uint256);

    function getPlotIndexesFromAccount(
        address account,
        uint256 fieldId
    ) external view returns (uint256[] memory plotIndexes);

    function getPlotMerkleRoot() external pure returns (bytes32);

    function getPlotsFromAccount(
        address account,
        uint256 fieldId
    ) external view returns (Plot[] memory plots);

    function getPodListing(uint256 fieldId, uint256 index) external view returns (bytes32 id);

    function getPodOrder(bytes32 id) external view returns (uint256);

    function getPodRate(uint256 fieldId) external view returns (uint256);

    function getPodRateLowerBound() external view returns (uint256);

    function getPodRateOptimal() external view returns (uint256);

    function getPodRateUpperBound() external view returns (uint256);

    function getPoolDeltaBWithoutCap(address well) external view returns (int256 deltaB);

    function getPublisherCounter(bytes32 counterId) external view returns (uint256 count);

    function getReceiver(address owner) external view returns (address);

    function getRelBeanToMaxLpRatioChangeFromCaseId(uint256 caseId) external view returns (int80 l);

    function getRelTemperatureChangeFromCaseId(uint256 caseId) external view returns (uint32 mt);

    function getRelativelyFarAbove(uint256 optimalPercentBdv) external pure returns (uint256);

    function getRelativelyFarBelow(uint256 optimalPercentBdv) external pure returns (uint256);

    function getSeasonStart() external view returns (uint256);

    function getSeasonStruct() external view returns (Season memory);

    function getSeasonTimestamp() external view returns (uint256);

    function getSeedGauge() external view returns (SeedGauge memory);

    function getSeedGaugeSetting() external view returns (EvaluationParameters memory);

    function getEvaluationParameters() external view returns (EvaluationParameters memory);

    function getExtEvaluationParameters() external view returns (ExtEvaluationParameters memory);

    function getShipmentRoutes() external view returns (ShipmentRoute[] memory);

    function getSiloTokens() external view returns (address[] memory tokens);

    function getStemTips() external view returns (int96[] memory _stemTips);

    function getT() external view returns (uint256);

    function getTargetSeasonsToCatchUp() external view returns (uint256);

    function getTokenDepositIdsForAccount(
        address account,
        address token
    ) external view returns (uint256[] memory depositIds);

    function getTokenDepositsForAccount(
        address account,
        address token
    ) external view returns (TokenDepositId memory deposits);

    function getTokenUsdPrice(address token) external view returns (uint256);

    function getTokenUsdPriceFromExternal(
        address token,
        uint256 lookback
    ) external view returns (uint256 tokenUsd);

    function getTokenUsdTwap(address token, uint256 lookback) external view returns (uint256);

    function getTotalBdv() external view returns (uint256 totalBdv);

    function getTotalDeposited(address token) external view returns (uint256);

    function getTotalDepositedBdv(address token) external view returns (uint256);

    function getTotalGerminatingAmount(address token) external view returns (uint256);

    function getTotalGerminatingBdv(address token) external view returns (uint256);

    function getTotalGerminatingStalk() external view returns (uint256);

    function getTotalRecapDollarsNeeded() external view returns (uint256);

    function getTotalSiloDeposited() external view returns (uint256[] memory depositedAmounts);

    function getTotalSiloDepositedBdv() external view returns (uint256[] memory depositedBdvs);

    function getTotalUsdLiquidity() external view returns (uint256 totalLiquidity);

    function getTotalWeightedUsdLiquidity() external view returns (uint256 totalWeightedLiquidity);

    function getTractorVersion() external view returns (string memory);

    function getTwaLiquidityForWell(address well) external view returns (uint256);

    function getUsdTokenPrice(address token) external view returns (uint256);

    function getUsdTokenPriceFromExternal(
        address token,
        uint256 lookback
    ) external view returns (uint256 usdToken);

    function getUsdTokenTwap(address token, uint256 lookback) external view returns (uint256);

    function getWeightedTwaLiquidityForWell(address well) external view returns (uint256);

    function getWellConvertCapacity(address well) external view returns (uint256);

    function getWellsByDeltaB()
        external
        view
        returns (
            WellDeltaB[] memory wellDeltaBs,
            uint256 totalPositiveDeltaB,
            uint256 totalNegativeDeltaB,
            uint256 positiveDeltaBCount
        );

    function getWhitelistStatus(
        address token
    ) external view returns (WhitelistStatus memory _whitelistStatuses);

    function getWhitelistStatuses()
        external
        view
        returns (WhitelistStatus[] memory _whitelistStatuses);

    function getWhitelistedLpTokens() external view returns (address[] memory tokens);

    function getWhitelistedTokens() external view returns (address[] memory tokens);

    function getWhitelistedWellLpTokens() external view returns (address[] memory tokens);

    function getYoungAndMatureGerminatingTotalStalk()
        external
        view
        returns (uint256 matureGerminatingStalk, uint256 youngGerminatingStalk);

    function getCultivationFactor(uint256 fieldId) external view returns (uint256);

    function getCultivationFactorForActiveField() external view returns (uint256);

    function gm(address account, uint8 mode) external payable returns (uint256);

    function grownStalkForDeposit(
        address account,
        address token,
        int96 stem
    ) external view returns (uint256 grownStalk);

    function harvest(uint256 fieldId, uint256[] memory plots, uint8 mode) external payable;

    function harvestableIndex(uint256 fieldId) external view returns (uint256);

    function imageURI(
        address token,
        int96 stem,
        int96 stemTip
    ) external view returns (string memory);

    function increaseDepositAllowance(
        address spender,
        address token,
        uint256 addedValue
    ) external returns (bool);

    function increaseTokenAllowance(
        address spender,
        address token,
        uint256 addedValue
    ) external returns (bool);

    function incrementTotalHarvestableE(uint256 fieldId, uint256 amount) external;

    function incrementTotalPodsE(uint256 fieldId, uint256 amount) external;

    function incrementTotalSoilE(uint128 amount) external;

    function initialSoil() external view returns (uint256);

    function initOracleForAllWhitelistedWells() external;

    function isApprovedForAll(address _owner, address _operator) external view returns (bool);

    function isHarvesting(uint256 fieldId) external view returns (bool);

    function lastDeltaSoil() external view returns (uint256);

    function lastSeasonOfPlenty() external view returns (uint32);

    function lastSowTime() external view returns (uint256);

    function lastUpdate(address account) external view returns (uint32);

    function lightSunrise() external;

    function maxTemperature() external view returns (uint256);

    function maxWeight(bytes memory) external pure returns (uint256);

    function mintBeans(address to, uint256 amount) external;

    function mockBDV(uint256 amount) external pure returns (uint256);

    function mockBDVDecrease(uint256 amount) external pure returns (uint256);

    function mockBDVIncrease(uint256 amount) external pure returns (uint256);

    function mockcalcCaseIdAndHandleRain(
        int256 deltaB
    ) external returns (uint256 caseId, BeanstalkState memory bs);

    function mockChangeBDVSelector(address token, bytes4 selector) external;

    function mockEndTotalGerminationForToken(address token) external;

    function mockGetMorningTemp(
        uint256 initalTemp,
        uint256 delta
    ) external pure returns (uint256 scaledTemperature);

    function mockIncrementGermination(
        address account,
        address token,
        uint128 amount,
        uint128 bdv,
        GerminationSide side
    ) external;

    function mockInitState() external;

    function mockLiquidityWeight() external pure returns (uint256);

    function mockSetMilestoneStem(address token, int96 stem) external;

    function mockSetMilestoneSeason(address token, uint32 season) external;

    function mockSetAverageGrownStalkPerBdvPerSeason(
        uint128 _averageGrownStalkPerBdvPerSeason
    ) external;

    function mockSow(
        uint256 bean,
        uint256 _morningTemperature,
        uint32 maxTemperature,
        bool abovePeg
    ) external returns (uint256 pods);

    function mockStepGauge() external;

    function mockStepSeason() external returns (uint32 season);

    function mockStepSilo(uint256 amount) external;

    function mockUpdateAverageGrownStalkPerBdvPerSeason() external;

    function mockUpdateAverageStalkPerBdvPerSeason() external;

    function mockUpdateLiquidityWeight(
        address token,
        address newLiquidityWeightImplementation,
        bytes1 encodeType,
        bytes4 selector,
        bytes memory data
    ) external;

    function mockWhitelistToken(
        address token,
        bytes4 selector,
        uint48 stalkIssuedPerBdv,
        uint40 stalkEarnedPerSeason
    ) external;

    function mockWhitelistTokenWithGauge(
        address token,
        bytes4 selector,
        uint16 stalkIssuedPerBdv,
        uint40 stalkEarnedPerSeason,
        bytes1 encodeType,
        bytes4 gaugePointSelector,
        bytes4 liquidityWeightSelector,
        uint128 gaugePoints,
        uint64 optimalPercentDepositedBdv
    ) external;

    function mockinitializeGaugeForToken(
        address token,
        bytes4 gaugePointSelector,
        bytes4 liquidityWeightSelector,
        uint96 gaugePoints,
        uint64 optimalPercentDepositedBdv
    ) external;

    function mow(address account, address token) external payable;

    function mowMultiple(address account, address[] memory tokens) external payable;

    function multiPipe(PipeCall[] memory pipes) external payable returns (bytes[] memory results);

    function name() external pure returns (string memory);

    function newMockBDV() external pure returns (uint256);

    function newMockBDVDecrease() external pure returns (uint256);

    function newMockBDVIncrease() external pure returns (uint256);

    function noWeight(bytes memory) external pure returns (uint256);

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external pure returns (bytes4);

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) external pure returns (bytes4);

    function overallCappedDeltaB() external view returns (int256 deltaB);

    function overallCurrentDeltaB() external view returns (int256 deltaB);

    function owner() external view returns (address owner_);

    function ownerCandidate() external view returns (address ownerCandidate_);

    function pause() external payable;

    function paused() external view returns (bool);

    function pipe(PipeCall memory p) external payable returns (bytes memory result);

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

    function plant() external payable returns (uint256 beans, int96 stem);

    function plentyPerRoot(uint32 _season, address well) external view returns (uint256);

    function plot(address account, uint256 fieldId, uint256 index) external view returns (uint256);

    function podIndex(uint256 fieldId) external view returns (uint256);

    function poolCurrentDeltaB(address pool) external view returns (int256 deltaB);

    function poolCurrentDeltaBMock(address pool) external view returns (int256 deltaB);

    function poolDeltaB(address pool) external view returns (int256);

    function publishRequisition(Requisition memory requisition) external;

    function rain() external view returns (Rain memory);

    function rainSiloSunrise(uint256 amount) external;

    function rainSunrise() external;

    function rainSunrises(uint256 amount) external;

    function readPipe(PipeCall memory p) external view returns (bytes memory result);

    function recieveL1Beans(address receiver, uint256 amount, uint8 toMode) external;

    function reentrancyGuardTest() external;

    function remainingPods() external view returns (uint256);

    function remainingRecapitalization() external view returns (uint256);

    function removeWhitelistSelector(address token) external;

    function resetPools(address[] memory pools) external;

    function resetSeasonStart(uint256 amount) external;

    function resetState() external;

    function revert_netFlow() external;

    function revert_oneOutFlow() external;

    function revert_outFlow() external;

    function revert_supplyChange() external;

    function revert_supplyIncrease() external;

    function rewardSilo(uint256 amount) external;

    function rewardSunrise(uint256 amount) external;

    function ripen(uint256 amount) external;

    function safeBatchTransferFrom(
        address sender,
        address recipient,
        uint256[] memory depositIds,
        uint256[] memory amounts,
        bytes memory
    ) external;

    function safeTransferFrom(
        address sender,
        address recipient,
        uint256 depositId,
        uint256 amount,
        bytes memory
    ) external;

    function scaledDeltaB(
        uint256 beforeLpTokenSupply,
        uint256 afterLpTokenSupply,
        int256 deltaB
    ) external pure returns (int256);

    function season() external view returns (uint32);

    function seasonTime() external view returns (uint64);

    function seedGaugeSunSunrise(int256 deltaB, uint256 caseId, bool oracleFailure) external;

    function setAbovePegE(bool peg) external;

    function setActiveField(uint256 fieldId, uint32 _temperature) external;

    function setApprovalForAll(address spender, bool approved) external;

    function setBeanToMaxLpGpPerBdvRatio(uint128 percent) external;

    function setBeanstalkState(
        uint256 price,
        uint256 podRate,
        uint256 changeInSoilDemand,
        uint256 liquidityToSupplyRatio,
        address targetWell
    ) external returns (int256 deltaB);

    function setBpf(uint128 bpf) external;

    function setChangeInSoilDemand(uint256 changeInSoilDemand) external;

    function setCurrentSeasonE(uint32 _season) external;

    function setL2SR(uint256 liquidityToSupplyRatio, address targetWell) external;

    function setLastDSoilE(uint128 number) external;

    function setLastSowTimeE(uint32 number) external;

    function setMaxTemp(uint32 t) external;

    function setMaxTempE(uint32 number) external;

    function setNextSowTimeE(uint32 _time) external;

    function setPodRate(uint256 podRate) external;

    function setPrice(uint256 price, address targetWell) external returns (int256 deltaB);

    function setShipmentRoutes(ShipmentRoute[] memory shipmentRoutes) external;

    function setSoilE(uint256 amount) external;

    function setStalkAndRoots(address account, uint128 stalk, uint256 roots) external;

    function setSunriseBlock(uint256 _block) external;

    function setUnharvestable(uint256 amount) external;

    function setUsdEthPrice(uint256 price) external;

    function setYieldE(uint256 t) external;

    function setCultivationFactor(uint256 cultivationFactor) external;

    function siloSunrise(uint256 amount) external;

    function getGaugeResult(
        Gauge memory gauge,
        bytes memory systemData
    ) external returns (bytes memory);

    function getGaugeIdResult(
        GaugeId gaugeId,
        bytes memory systemData
    ) external returns (bytes memory);

    function sow(
        uint256 bean,
        uint256 minTemperature,
        uint8 mode
    ) external payable returns (uint256 pods);

    function sowWithMin(
        uint256 bean,
        uint256 minTemperature,
        uint256 minSoil,
        uint8 mode
    ) external payable returns (uint256 pods);

    function stalkEarnedPerSeason(
        address[] memory tokens
    ) external view returns (uint256[] memory stalkEarnedPerSeasons);

    function stealBeans(uint256 amount) external;

    function stemTipForToken(address token) external view returns (int96 _stemTip);

    function stepGauge() external;

    function sunSunrise(int256 deltaB, uint256 caseId, BeanstalkState memory bs) external;

    function sunTemperatureSunrise(int256 deltaB, uint256 caseId, uint32 t) external;

    function sunrise() external payable returns (uint256);

    function sunriseBlock() external view returns (uint64);

    function supportsInterface(bytes4 _interfaceId) external view returns (bool);

    function symbol() external pure returns (string memory);

    function teleportSunrise(uint32 _s) external;

    function temperature() external view returns (uint256);

    function thisSowTime() external view returns (uint256);

    function time() external view returns (Season memory);

    function tokenAllowance(
        address account,
        address spender,
        address token
    ) external view returns (uint256);

    function tokenSettings(address token) external view returns (AssetSettings memory);

    function totalDeltaB() external view returns (int256 deltaB);

    function totalInstantaneousDeltaB() external view returns (int256);

    function totalEarnedBeans() external view returns (uint256);

    function totalHarvestable(uint256 fieldId) external view returns (uint256);

    function totalHarvestableForActiveField() external view returns (uint256);

    function totalHarvested(uint256 fieldId) external view returns (uint256);

    function totalPods(uint256 fieldId) external view returns (uint256);

    function totalRainRoots() external view returns (uint256);

    function totalRealSoil() external view returns (uint256);

    function totalRoots() external view returns (uint256);

    function totalSoil() external view returns (uint256);

    function totalSoilAtMorningTemp(
        uint256 morningTemperature
    ) external view returns (uint256 totalSoil);

    function totalStalk() external view returns (uint256);

    function totalUnharvestable(uint256 fieldId) external view returns (uint256);

    function tractor(
        Requisition memory requisition,
        bytes memory operatorData
    ) external payable returns (bytes[] memory results);

    function transferDeposit(
        address sender,
        address recipient,
        address token,
        int96 stem,
        uint256 amount
    ) external payable returns (uint256 _bdv);

    function transferDeposits(
        address sender,
        address recipient,
        address token,
        int96[] memory stem,
        uint256[] memory amounts
    ) external payable returns (uint256[] memory bdvs);

    function transferERC1155(address token, address to, uint256 id, uint256 value) external payable;

    function transferERC721(address token, address to, uint256 id) external payable;

    function sendTokenToInternalBalance(
        address token,
        address recipient,
        uint256 amount
    ) external payable;

    function transferInternalTokenFrom(
        address token,
        address sender,
        address recipient,
        uint256 amount,
        uint8 toMode
    ) external payable;

    function transferOwnership(address _newOwner) external;

    function transferPlot(
        address sender,
        address recipient,
        uint256 fieldId,
        uint256 index,
        uint256 start,
        uint256 end
    ) external payable;

    function transferPlots(
        address sender,
        address recipient,
        uint256 fieldId,
        uint256[] memory ids,
        uint256[] memory starts,
        uint256[] memory ends
    ) external payable;

    function transferToken(
        address token,
        address recipient,
        uint256 amount,
        uint8 fromMode,
        uint8 toMode
    ) external payable;

    function unpause() external payable;

    function unwrapEth(uint256 amount, uint8 mode) external payable;

    function updateGaugeForToken(
        address token,
        uint64 optimalPercentDepositedBdv,
        Implementation memory gpImplementation,
        Implementation memory lwImplementation
    ) external payable;

    function updateGaugePointImplementationForToken(
        address token,
        Implementation memory impl
    ) external payable;

    function updateLiquidityWeightImplementationForToken(
        address token,
        Implementation memory impl
    ) external payable;

    function updateOracleImplementationForToken(
        address token,
        Implementation memory impl
    ) external payable;

    function updatePublisherCounter(
        bytes32 counterId,
        CounterUpdateType updateType,
        uint256 amount
    ) external returns (uint256 count);

    function updateSeedGaugeSettings(EvaluationParameters memory updatedSeedGaugeSettings) external;

    function updateSortedDepositIds(
        address account,
        address token,
        uint256[] calldata sortedDepositIds
    ) external payable;

    function updateStalkPerBdvPerSeasonForToken(
        address token,
        uint40 stalkEarnedPerSeason
    ) external payable;

    function updateStems() external;

    function updateTractorVersion(string memory version) external;

    function updateWhitelistStatus(
        address token,
        bool isWhitelisted,
        bool isWhitelistedLp,
        bool isWhitelistedWell,
        bool isSoppable
    ) external;

    function uri(uint256 depositId) external view returns (string memory);

    function weather() external view returns (Weather memory);

    function wellBdv(address token, uint256 amount) external view returns (uint256);

    function wellOracleSnapshot(address well) external view returns (bytes memory snapshot);

    function whitelistToken(
        address token,
        bytes4 selector,
        uint48 stalkIssuedPerBdv,
        uint40 stalkEarnedPerSeason,
        bytes1 encodeType,
        uint128 gaugePoints,
        uint64 optimalPercentDepositedBdv,
        Implementation memory oracleImplementation,
        Implementation memory gaugePointImplementation,
        Implementation memory liquidityWeightImplementation
    ) external payable;

    function withdrawDeposit(
        address token,
        int96 stem,
        uint256 amount,
        uint8 mode
    ) external payable;

    function withdrawDeposits(
        address token,
        int96[] memory stems,
        uint256[] memory amounts,
        uint8 mode
    ) external payable;
    function withdrawForConvertE(
        address token,
        int96[] memory stems,
        uint256[] memory amounts,
        uint256 maxTokens
    ) external;

    function woohoo() external pure returns (uint256);

    function wrapEth(uint256 amount, uint8 mode) external payable;

    function downPenalizedGrownStalk(
        address well,
        uint256 bdvToConvert,
        uint256 grownStalkToConvert,
        uint256 fromAmount
    ) external view returns (uint256 newGrownStalk, uint256 grownStalkLost);

    function setLastSeasonAndThisSeasonBeanSown(
        uint128 lastSeasonBeanSown,
        uint128 thisSeasonBeanSown
    ) external;

    function setMinSoilSownDemand(uint256 minSoilSownDemand) external;

    function setPrevSeasonAndCultivationTemp(uint256 prevSeasonTemp, uint256 soldOutTemp) external;

    function setConvertDownPenaltyRate(uint256 rate) external;

    function setBeansMintedAbovePeg(uint256 beansMintedAbovePeg) external;

    function setBeanMintedThreshold(uint256 beanMintedThreshold) external;

    function setThresholdSet(bool thresholdSet) external;

    function setRunningThreshold(uint256 runningThreshold) external;

    function getMaxAmountInAtRate(
        address tokenIn,
        address tokenOut,
        uint256 rate
    ) external view returns (uint256 amountIn);

    function setPenaltyRatio(uint256 penaltyRatio) external;
}

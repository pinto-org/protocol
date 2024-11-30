// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title System
 * @notice Stores system-level Beanstalk state.
 * @param paused True if Beanstalk is Paused.
 * @param pausedAt The timestamp at which Beanstalk was last paused.
 * @param reentrantStatus An intra-transaction state variable to protect against reentrance.
 * @param farmingStatus Stores whether the function call originated in a Farm-like transaction - Farm, Tractor, PipelineConvert, etc.
 * @param ownerCandidate Stores a candidate address to transfer ownership to. The owner must claim the ownership transfer.
 * @param plenty The amount of plenty token held by the contract.
 * @param soil The number of Soil currently available. Adjusted during {Sun.stepSun}.
 * @param beanSown The number of Bean sown within the current Season. Reset during {Weather.calcCaseId}.
 * @param activeField ID of the active Field.
 * @param fieldCount Number of Fields that have ever been initialized.
 * @param orderLockedBeans The number of Beans locked in Pod Orders.
 * @param _buffer_0 Reserved storage for future additions.
 * @param podListings A mapping from fieldId to index to hash of Listing.
 * @param podOrders A mapping from the hash of a Pod Order to the amount of Pods that the Pod Order is still willing to buy.
 * @param internalTokenBalanceTotal Sum of all users internalTokenBalance.
 * @param wellOracleSnapshots A mapping from Well Oracle address to the Well Oracle Snapshot.
 * @param twaReserves A mapping from well to its twaReserves. Stores twaReserves during the sunrise function. Returns 1 otherwise for each asset. Currently supports 2 token wells.
 * @param usdTokenPrice A mapping from token address to usd price.
 * @param sops A mapping from Season to Plenty Per Root (PPR) in that Season. Plenty Per Root is 0 if a Season of Plenty did not occur.
 * @param fields mapping of Field ID to Storage.Field.
 * @param convertCapacity A mapping from block number to the amount of Beans that can be converted towards peg in this block before stalk penalty becomes applied.
 * @param oracleImplementation A mapping from token to its oracle implementation.
 * @param shipmentRoutes Define the distribution of newly minted Beans.
 * @param _buffer_1 Reserved storage for future additions.
 * @param casesV2 Stores the 144 Weather and seedGauge cases.
 * @param silo See {Silo}.
 * @param season See {Season}.
 * @param weather See {Weather}.
 * @param seedGauge Stores the seedGauge.
 * @param rain See {Rain}.
 * @param evaluationParameters See {EvaluationParameters}.
 * @param sop See {SeasonOfPlenty}.
 */
struct System {
    address bean;
    bool paused;
    uint128 pausedAt;
    uint256 reentrantStatus;
    uint256 farmingStatus;
    address ownerCandidate;
    uint128 soil;
    uint128 beanSown;
    uint256 activeField;
    uint256 fieldCount;
    uint256 orderLockedBeans;
    bytes32[16] _buffer_0;
    mapping(uint256 => mapping(uint256 => bytes32)) podListings;
    mapping(bytes32 => uint256) podOrders;
    mapping(IERC20 => uint256) internalTokenBalanceTotal;
    mapping(address => bytes) wellOracleSnapshots;
    mapping(address => TwaReserves) twaReserves;
    mapping(address => uint256) usdTokenPrice;
    mapping(uint256 => Field) fields;
    mapping(uint256 => ConvertCapacity) convertCapacity;
    mapping(address => Implementation) oracleImplementation;
    ShipmentRoute[] shipmentRoutes;
    bytes32[16] _buffer_1;
    bytes32[144] casesV2;
    Silo silo;
    Season season;
    Weather weather;
    SeedGauge seedGauge;
    Rain rain;
    EvaluationParameters evaluationParameters;
    SeasonOfPlenty sop;
    // A buffer is not included here, bc current layout of AppStorage makes it unnecessary.
}

/**
 * @notice System-level Silo state variables.
 * @param stalk The total amount of active Stalk (including Earned Stalk, excluding Grown Stalk).
 * @param roots The total amount of Roots.
 * @param earnedBeans The number of Beans distributed to the Silo that have not yet been Deposited as a result of the Earn function being called.
 * @param balances A mapping from Token address to Silo Balance storage (amount deposited and withdrawn).
 * @param assetSettings A mapping from Token address to Silo Settings for each Whitelisted Token. If a non-zero storage exists, a Token is whitelisted.
 * @param whitelistStatuses Stores a list of Whitelist Statues for all tokens that have been Whitelisted and have not had their Whitelist Status manually removed.
 * @param germinating Mapping from odd/even to token to germinating deposits data.
 * @param unclaimedGerminating A mapping from season to object containing the stalk and roots that are germinating.
 * @param _buffer Reserved storage for future expansion.
 */
struct Silo {
    uint256 stalk;
    uint256 roots;
    uint256 earnedBeans;
    mapping(address => AssetSilo) balances;
    mapping(address => AssetSettings) assetSettings;
    WhitelistStatus[] whitelistStatuses;
    mapping(GerminationSide => mapping(address => Deposited)) germinating;
    mapping(uint32 => GerminatingSilo) unclaimedGerminating;
    bytes32[8] _buffer;
}

/**
 * @notice System-level Field state variables.
 * @param pods The pod index; the total number of Pods ever minted.
 * @param harvested The harvested index; the total number of Pods that have ever been Harvested.
 * @param harvestable The harvestable index; the total number of Pods that have ever been Harvestable. Included previously Harvested Beans.
 * @param _buffer Reserved storage for future expansion.
 */
struct Field {
    uint256 pods;
    uint256 harvested;
    uint256 harvestable;
    bytes32[8] _buffer;
}

/**
 * @notice System-level Season state variables.
 * @param current The current Season in Beanstalk.
 * @param lastSop The Season in which the most recent consecutive series of Seasons of Plenty started.
 * @param lastSopSeason The Season in which the most recent consecutive series of Seasons of Plenty ended.
 * @param rainStart Stores the most recent Season in which Rain started.
 * @param raining True if it is Raining (P > 1, Pod Rate Excessively Low).
 * @param sunriseBlock The block of the start of the current Season.
 * @param abovePeg Boolean indicating whether the previous Season was above or below peg.
 * @param start The timestamp of the Beanstalk deployment rounded down to the nearest hour.
 * @param period The length of each season in Beanstalk in seconds.
 * @param timestamp The timestamp of the start of the current Season.
 * @param standardMintedBeans The number of Beans minted this season, excluding flood.
 * @param _buffer Reserved storage for future expansion.
 */
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

/**
 * @notice System-level Weather state variables.
 * @param lastDeltaSoil Delta Soil; the number of Soil purchased last Season.
 * @param lastSowTime The number of seconds it took for Soil to sell out last Season.
 * @param thisSowTime The number of seconds it took for Soil to sell out this Season.
 * @param temp Temperature is max interest rate in current Season for sowing Beans in Soil. Adjusted each Season.
 * @param _buffer Reserved storage for future expansion.
 */
struct Weather {
    uint128 lastDeltaSoil; // ───┐ 16 (16)
    uint32 lastSowTime; //       │ 4  (20)
    uint32 thisSowTime; //       │ 4  (24)
    uint32 temp; // ─────────────┘ 4  (28/32)
    bytes32[4] _buffer;
}

/**
 * @notice System level variables used in the seed Gauge
 * @param averageGrownStalkPerBdvPerSeason The average Grown Stalk Per BDV
 * that beanstalk issues each season.
 * @param beanToMaxLpGpPerBdvRatio a scalar of the gauge points(GP) per bdv
 * issued to the largest LP share and Bean. 6 decimal precision.
 * @param avgGsPerBdvFlag update the average grown stalk per bdv per season, if true.
 * @param _buffer Reserved storage for future expansion.
 * @dev a beanToMaxLpGpPerBdvRatio of 0 means LP should be incentivized the most,
 * and that beans will have the minimum seeds ratio. see {LibGauge.getBeanToMaxLpGpPerBdvRatioScaled}
 */
struct SeedGauge {
    uint128 averageGrownStalkPerBdvPerSeason;
    uint128 beanToMaxLpGpPerBdvRatio;
    bool avgGsPerBdvFlag;
    bytes32[4] _buffer;
}

/**
 * @notice System-level Rain balances. Rain occurs when P > 1 and the Pod Rate Excessively Low.
 * @param pods The number of Pods when it last started Raining.
 * @param roots The number of Roots when it last started Raining.
 * @param _buffer Reserved storage for future expansion.
 */
struct Rain {
    uint256 pods;
    uint256 roots;
    bytes32[4] _buffer;
}

/**
 * @notice System-level Silo state; contains deposit and withdrawal data for a particular whitelisted Token.
 * @param deposited The total amount of this Token currently Deposited in the Silo.
 * @param depositedBdv The total bdv of this Token currently Deposited in the Silo.
 * @dev {State} contains a mapping from Token address => AssetSilo.
 * Currently, the bdv of deposits are asynchronous, and require an on-chain transaction to update.
 * Thus, the total bdv of deposits cannot be calculated, and must be stored and updated upon a bdv change.
 */
struct AssetSilo {
    uint128 deposited;
    uint128 depositedBdv;
}

/**
 * @notice Whitelist Status a token that has been Whitelisted before.
 * @param token the address of the token.
 * @param isWhitelisted whether the address is whitelisted.
 * @param isWhitelistedLp whether the address is a whitelisted LP token.
 * @param isWhitelistedWell whether the address is a whitelisted Well token.
 */

struct WhitelistStatus {
    address token;
    bool isWhitelisted;
    bool isWhitelistedLp;
    bool isWhitelistedWell;
    bool isSoppable;
}

/**
 * @notice Describes the settings for each Token that is Whitelisted in the Silo.
 * @param selector The encoded BDV function selector for the token that pertains to
 * an external view Beanstalk function with the following signature:
 * ```
 * function tokenToBdv(uint256 amount) external view returns (uint256);
 * ```
 * It is called by `LibTokenSilo` through the use of `delegatecall`
 * to calculate a token's BDV at the time of Deposit.
 * @param stalkEarnedPerSeason represents how much Stalk one BDV of the underlying deposited token
 * grows each season. In the past, this was represented by seeds. 6 decimal precision.
 * @param stalkIssuedPerBdv The Stalk Per BDV that the Silo grants in exchange for Depositing this Token.
 * previously called stalk.
 * @param milestoneSeason The last season in which the stalkEarnedPerSeason for this token was updated.
 * @param milestoneStem The cumulative amount of grown stalk per BDV for this token at the last stalkEarnedPerSeason update.
 * @param encodeType determine the encoding type of the selector.
 * a encodeType of 0x00 means the selector takes an input amount.
 * 0x01 means the selector takes an input amount and a token.
 * @param gpSelector The encoded gaugePoint function selector for the token that pertains to
 * an external view Beanstalk function with the following signature:
 * ```
 * function gaugePoints(
 *  uint256 currentGaugePoints,
 *  uint256 optimalPercentDepositedBdv,
 *  uint256 percentOfDepositedBdv
 *  bytes data
 *  ) external view returns (uint256);
 * ```
 * @param lwSelector The encoded liquidityWeight function selector for the token that pertains to
 * an external view Beanstalk function with the following signature `function liquidityWeight(bytes)`
 * @param gaugePoints the amount of Gauge points this LP token has in the LP Gauge. Only used for LP whitelisted assets.
 * GaugePoints has 18 decimal point precision (1 Gauge point = 1e18).
 * @param optimalPercentDepositedBdv The target percentage of the total LP deposited BDV for this token. 6 decimal precision.
 * @param gaugePointImplementation The implementation for the gauge points. Supports encodeType 0 and 1.
 * @param liquidityWeightImplementation The implementation for the liquidity weight.
 * @dev A Token is considered Whitelisted if there exists a non-zero {AssetSettings} selector.
 */
struct AssetSettings {
    bytes4 selector; // ────────────────────┐ 4
    uint40 stalkEarnedPerSeason; //         │ 5  (9)
    uint48 stalkIssuedPerBdv; //            │ 6  (15)
    uint32 milestoneSeason; //              │ 4  (19)
    int96 milestoneStem; //                 │ 12 (31)
    bytes1 encodeType; //                 ──┘ 1  (32)
    int40 deltaStalkEarnedPerSeason; // ────┐ 5
    uint128 gaugePoints; //                 │ 16 (21)
    uint64 optimalPercentDepositedBdv; //   │ 8  (29)
    // 3 bytes are left here.             ──┘ 3  (32)
    Implementation gaugePointImplementation;
    Implementation liquidityWeightImplementation;
}

/**
 * @notice Stores the twaReserves for each well during the sunrise function.
 */
struct TwaReserves {
    uint128 reserve0;
    uint128 reserve1;
}

/**
 * @notice Stores the total germination amounts for each whitelisted token.
 */
struct Deposited {
    uint128 amount;
    uint128 bdv;
}

/**
 * @notice Stores convert capacity data for a given block.
 * @param overallConvertCapacityUsed The amount of overall deltaB that can be converted towards peg within a block.
 * @param wellConvertCapacityUsed A mapping from well to the amount of deltaB
 * that can be converted in the given block.
 */
struct ConvertCapacity {
    uint256 overallConvertCapacityUsed;
    mapping(address => uint256) wellConvertCapacityUsed;
}

/**
 * @notice Stores the system level germination Silo data.
 */
struct GerminatingSilo {
    uint256 stalk;
    uint256 roots;
}

/**
 * @param planContract The address of the contract containing the plan getter view function.
 * @param planSelector The selector of the plan getter view function.
 * @param recipient The recipient enum of the shipment.
 * @param data The data to be passed to both the plan getter function and the receive function.
 */
struct ShipmentRoute {
    address planContract;
    bytes4 planSelector;
    ShipmentRecipient recipient;
    bytes data;
}

/**
 * @notice contains data in order for beanstalk to call a function with a specific selector.
 * @param target The address of the implementation.
 * @param selector The function selector that is used to call on the implementation.
 * @param encodeType The encode type that should be used to encode the function call.
 * The encodeType value depends on the context of each implementation.
 * @param data Any additional data, for example timeout
 * @dev assumes all future implementations will use the same parameters as the beanstalk
 * gaugePoint and liquidityWeight implementations.
 */
struct Implementation {
    address target; // 20 bytes
    bytes4 selector;
    bytes1 encodeType;
    bytes data;
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

/**
 * @param perWellPlenty A mapping from well amount of plenty (flooded tokens) per well
 * @param sops mapping of season to a mapping of wells to plentyPerRoot
 */
struct SeasonOfPlenty {
    mapping(address => uint256) plentyPerSopToken;
    mapping(uint32 => mapping(address => uint256)) sops;
}

/**
 * @notice Germinate determines what germination struct to use.
 * @dev "odd" and "even" refers to the value of the season counter.
 * "Odd" germinations are used when the season is odd, and vice versa.
 */
enum GerminationSide {
    ODD,
    EVEN,
    NOT_GERMINATING
}

/**
 * @notice Details which Beanstalk component receives the shipment.
 */
enum ShipmentRecipient {
    NULL,
    SILO,
    FIELD,
    INTERNAL_BALANCE,
    EXTERNAL_BALANCE
}

const fs = require("fs");
const { convertToBigNum } = require("../../../utils/read.js");
const { BigNumber } = require("ethers");
const { commentOutOracleTimeout } = require("./regex/updateOracleTimeout.js");
// const { updateConstantsInFiles } = require("./regex/updateConstants.js");

// Parse deployment parameters for system, whitelist, well, and token data
function parseDeploymentParameters(inputFilePath, updateConstantsAndTimeout) {
  const data = JSON.parse(fs.readFileSync(inputFilePath, "utf8"));

  // Parse SystemData (SeedGauge, EvaluationParameters, ShipmentRoute)
  const systemData = [
    // SeedGauge
    [
      convertToBigNum(data.seedGauge?.averageGrownStalkPerBdvPerSeason || "0"),
      convertToBigNum(data.seedGauge?.beanToMaxLpGpPerBdvRatio || "0"),
      convertToBigNum(data.seedGauge?.avgGsPerBdvFlag || "0"),
      [
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      ]
    ],
    // EvaluationParameters
    [
      convertToBigNum(data.evaluationParameters?.maxBeanMaxLpGpPerBdvRatio || "0"),
      convertToBigNum(data.evaluationParameters?.minBeanMaxLpGpPerBdvRatio || "0"),
      convertToBigNum(data.evaluationParameters?.targetSeasonsToCatchUp || "0"),
      convertToBigNum(data.evaluationParameters?.podRateLowerBound || "0"),
      convertToBigNum(data.evaluationParameters?.podRateOptimal || "0"),
      convertToBigNum(data.evaluationParameters?.podRateUpperBound || "0"),
      convertToBigNum(data.evaluationParameters?.deltaPodDemandLowerBound || "0"),
      convertToBigNum(data.evaluationParameters?.deltaPodDemandUpperBound || "0"),
      convertToBigNum(data.evaluationParameters?.lpToSupplyRatioUpperBound || "0"),
      convertToBigNum(data.evaluationParameters?.lpToSupplyRatioOptimal || "0"),
      convertToBigNum(data.evaluationParameters?.lpToSupplyRatioLowerBound || "0"),
      convertToBigNum(data.evaluationParameters?.excessivePriceThreshold || "0"),
      convertToBigNum(data.evaluationParameters?.soilCoefficientHigh || "0"),
      convertToBigNum(data.evaluationParameters?.soilCoefficientLow || "0"),
      convertToBigNum(data.evaluationParameters?.baseReward || "0"),
      convertToBigNum(data.evaluationParameters?.minAvgGsPerBdv || "2e12")
    ],
    // ShipmentRoutes
    data.shipmentRoutes?.map((route) => [
      route.planContract || "0x0000000000000000000000000000000000000000",
      route.planSelector || "0x00000000",
      convertToBigNum(route.recipient || "0"),
      route.data || "0x"
    ]) || []
  ];

  // Parse WhitelistData into array of objects
  const tokens = data.whitelistData?.tokens || [];
  const nonBeanTokens = data.whitelistData?.nonBeanTokens || [];

  // AssetSettings parsing with default values
  const defaultSettings = data.whitelistData?.defaultSettings || {};

  // Build array of AssetSettings (one per token)
  const assetsArray = Object.entries(data.whitelistData?.tokenAssetSettings || {}).map(
    ([token, tokenSettings]) => {
      const mergedSettings = {
        ...defaultSettings, // Default values applied first
        ...tokenSettings // Override with specific asset settings
      };

      return [
        mergedSettings.selector || "0x00000000",
        convertToBigNum(mergedSettings.stalkEarnedPerSeason || "1"),
        convertToBigNum(mergedSettings.stalkIssuedPerBdv || "10000000000"),
        convertToBigNum(mergedSettings.milestoneSeason || "1"),
        convertToBigNum(mergedSettings.milestoneStem || "0"),
        mergedSettings.encodeType || "0x00",
        convertToBigNum(mergedSettings.deltaStalkEarnedPerSeason || "0"),
        convertToBigNum(mergedSettings.gaugePoints || "0"),
        convertToBigNum(mergedSettings.optimalPercentDepositedBdv || "0"),
        [
          mergedSettings.gaugePointImplementation?.target ||
            "0x0000000000000000000000000000000000000000",
          mergedSettings.gaugePointImplementation?.selector || "0x00000000",
          mergedSettings.gaugePointImplementation?.encodeType || "0x00",
          mergedSettings.gaugePointImplementation?.data || "0x"
        ],
        [
          mergedSettings.liquidityWeightImplementation?.target ||
            "0x0000000000000000000000000000000000000000",
          mergedSettings.liquidityWeightImplementation?.selector || "0x2c5fa218",
          mergedSettings.liquidityWeightImplementation?.encodeType || "0x00",
          mergedSettings.liquidityWeightImplementation?.data || "0x"
        ]
      ];
    }
  );

  // Build array of oracle implementations (one per token)
  const oraclesArray =
    data.whitelistData?.oraclesImplementations?.map((oracle) => [
      oracle.implementation?.target || "0x0000000000000000000000000000000000000000",
      oracle.implementation?.selector || "0x00000000",
      oracle.implementation?.encodeType || "0x00",
      oracle.implementation?.data || "0x"
    ]) || [];

  // Format WhitelistData as array of objects (one per token)
  const whitelistData = tokens.map((token, index) => ({
    token: token,
    nonBeanToken: nonBeanTokens[index],
    asset: assetsArray[index],
    oracle: oraclesArray[index]
  }));

  // Parse WellData
  // We assume all wells have the same components for the implementation, aquifer, pump, and pumpData
  const wellData =
    data.wells?.map((well) => ({
      tokens: [
        "0x0000000000000000000000000000000000000000", // Bean placeholder, will be set in deployment
        well.nonBeanToken || "0x0000000000000000000000000000000000000000"
      ],
      wellImplementation:
        data.wellComponents.wellUpgradeableImplementation ||
        "0x0000000000000000000000000000000000000000",
      wellFunction: {
        target: well.wellFunctionTarget || "0x0000000000000000000000000000000000000000",
        data: well.wellFunctionData || "0x"
      },
      aquifer: data.wellComponents.aquifer || "0x0000000000000000000000000000000000000000",
      pumps: [
        {
          target: data.wellComponents.pump || "0x0000000000000000000000000000000000000000",
          data: data.wellComponents.pumpData || "0x"
        }
      ],
      wellSalt: well.wellSalt || "0x0000000000000000000000000000000000000000000000000000000000000010",
      proxySalt: well.proxySalt || well.salt || "0x0000000000000000000000000000000000000000000000000000000000000000",
      name: well.name || "",
      symbol: well.symbol || ""
    })) || [];

  // Parse TokenData
  const tokenData = [
    data.token?.name || "",
    data.token?.symbol || "",
    data.token?.receiver || "0",
    data.token?.salt || "0",
    convertToBigNum(data.token?.initSupply) || "1000000000"
  ];

  // get the well distributions
  const initWellDistributions = data.initWellDistributions || [];
  // get the initial supply with no decimals, assumes 6 decimals
  const initSupply =
    BigNumber.from(convertToBigNum(data.token?.initSupply)).div(1e6).toString() || "1000";

  if (updateConstantsAndTimeout) {
    // Parse parameters for c.sol
    // const constantsData = {
    //   wellMinimumBeanBalance: data.constants?.wellMinimumBeanBalance || "100e6",
    //   pipelineAddress:
    //     data.constants?.pipelineAddress || "0x0000000000000000000000000000000000000000",
    //   wethAddress: data.constants?.wethAddress || "0x0000000000000000000000000000000000000000"
    // };
    // Update the constants in the c.sol file
    // const constantsFilePath = "./contracts/C.sol";
    // const libWethFilePath = "./contracts/libraries/Token/LibWeth.sol";
    // updateConstantsInFiles(
    //   constantsFilePath,
    //   constantsData.wellMinimumBeanBalance,
    //   constantsData.pipelineAddress,
    //   libWethFilePath,
    //   constantsData.wethAddress
    // );

    // Comment out the oracle timeout checks in LibChainlinkOracle.sol
    const chainlinkPath = "./contracts/libraries/Oracle/LibChainlinkOracle.sol";
    console.log(`Commenting out the oracle timeout checks in ${chainlinkPath}`);
    commentOutOracleTimeout(chainlinkPath);
  }

  console.log("--------------------------------------------");
  console.log("\nSuccessfully parsed deployment parameters");
  return [systemData, whitelistData, wellData, tokenData, initWellDistributions, initSupply];
}

exports.parseDeploymentParameters = parseDeploymentParameters;

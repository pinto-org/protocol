const fs = require("fs");
const { ethers } = require("hardhat");
const { deployUpgradeableWells } = require("../utils/wellDeployment");

/**
 * Deploy Wells using configuration from JSON file or command line arguments
 *
 * Usage:
 *
 * 1. With JSON config file:
 *    npx hardhat run scripts/deployWell.js --network base
 *
 * 2. With environment variables:
 *    BEAN_ADDRESS=0x... WELL_CONFIG_PATH=./config.json npx hardhat run scripts/deployWell.js
 *
 * JSON config format should match deploymentParams.json structure:
 * {
 *   "wellComponents": {
 *     "wellUpgradeableImplementation": "0x...",
 *     "aquifer": "0x...",
 *     "pump": "0x...",
 *     "pumpData": "0x..."
 *   },
 *   "wells": [
 *     {
 *       "nonBeanToken": "0x...",
 *       "wellFunctionTarget": "0x...",
 *       "wellFunctionData": "0x...",
 *       "salt": "0x...",
 *       "name": "PINTO:WETH CP2 Well",
 *       "symbol": "U-PINTOWETHCP2w"
 *     }
 *   ]
 * }
 */
async function main() {
  console.log("========================================");
  console.log("Well Deployment Script");
  console.log("========================================\n");

  // Get deployer
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer address: ${deployer.address}`);
  console.log(`Network: ${network.name}`);

  // Check deployer balance
  const balance = await deployer.getBalance();
  console.log(`Deployer balance: ${ethers.utils.formatEther(balance)} ETH\n`);

  if (balance.eq(0)) {
    throw new Error("Deployer has no ETH balance");
  }

  // Load configuration
  const configPath =
    process.env.WELL_CONFIG_PATH || "./scripts/deployment/parameters/input/deploymentParams.json";
  const beanAddress = process.env.BEAN_ADDRESS;

  console.log(`Loading configuration from: ${configPath}\n`);

  if (!fs.existsSync(configPath)) {
    throw new Error(`Configuration file not found: ${configPath}`);
  }

  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));

  // Extract bean address from config or environment
  let bean = beanAddress;
  if (!bean && config.whitelistData && config.whitelistData.tokens) {
    // First token in whitelist is usually Bean
    bean = config.whitelistData.tokens[0];
  }

  if (!bean) {
    throw new Error(
      "Bean address not found. Set BEAN_ADDRESS environment variable or include in config"
    );
  }

  console.log(`Bean address: ${bean}`);

  // Validate well components
  if (!config.wellComponents) {
    throw new Error("wellComponents not found in configuration");
  }

  const { wellUpgradeableImplementation, aquifer, pump, pumpData } = config.wellComponents;

  if (!wellUpgradeableImplementation || !aquifer || !pump || !pumpData) {
    throw new Error("Missing required wellComponents in configuration");
  }

  console.log(`\nWell Components:`);
  console.log(`  Well Implementation: ${wellUpgradeableImplementation}`);
  console.log(`  Aquifer: ${aquifer}`);
  console.log(`  Pump: ${pump}`);
  console.log(`  Pump Data: ${pumpData.substring(0, 66)}...`);

  // Validate wells array
  if (!config.wells || config.wells.length === 0) {
    throw new Error("No wells found in configuration");
  }

  console.log(`\nWells to deploy: ${config.wells.length}`);

  // Transform config wells to deployment format
  const wellsData = config.wells.map((well) => ({
    nonBeanToken: well.nonBeanToken,
    wellImplementation: wellUpgradeableImplementation,
    wellFunctionTarget: well.wellFunctionTarget,
    wellFunctionData: well.wellFunctionData,
    aquifer: aquifer,
    pump: pump,
    pumpData: pumpData,
    salt: well.salt,
    name: well.name,
    symbol: well.symbol
  }));

  // Confirm deployment
  console.log(`\n========================================`);
  console.log(`Ready to deploy ${wellsData.length} well(s)`);
  console.log(`========================================`);

  for (let i = 0; i < wellsData.length; i++) {
    console.log(`\n${i + 1}. ${wellsData[i].name}`);
    console.log(`   Symbol: ${wellsData[i].symbol}`);
    console.log(`   Non-Bean Token: ${wellsData[i].nonBeanToken}`);
    console.log(`   Well Function: ${wellsData[i].wellFunctionTarget}`);
    console.log(`   Salt: ${wellsData[i].salt}`);
  }

  console.log(`\n========================================`);
  console.log(`Starting deployment...`);
  console.log(`========================================\n`);

  // Deploy wells
  const results = await deployUpgradeableWells(bean, wellsData, deployer, true);

  // Print summary
  console.log(`\n========================================`);
  console.log(`Deployment Complete!`);
  console.log(`========================================\n`);

  console.log(`Deployed Wells:\n`);
  for (let i = 0; i < results.length; i++) {
    const result = results[i];
    console.log(`${i + 1}. ${result.name} (${result.symbol})`);
    console.log(`   Proxy Address: ${result.proxyAddress}`);
    console.log(`   Implementation: ${result.implementationAddress}`);
    console.log(`   Non-Bean Token: ${result.nonBeanToken}`);
    console.log(``);
  }

  // Save deployment results
  const outputPath = `./deployments/wells-${network.name}-${Date.now()}.json`;
  const outputDir = "./deployments";

  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  const deploymentData = {
    network: network.name,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    beanAddress: bean,
    wellComponents: config.wellComponents,
    wells: results
  };

  fs.writeFileSync(outputPath, JSON.stringify(deploymentData, null, 2));
  console.log(`Deployment data saved to: ${outputPath}\n`);

  return results;
}

// Execute if running directly
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = { main };

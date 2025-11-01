const { task } = require("hardhat/config");
const { deployUpgradeableWells, deployStandardWell } = require("../utils/wellDeployment");
const fs = require("fs");

module.exports = function () {
  task("deployStandardWell", "Deploy a well using standard Base network infrastructure")
    .addParam("nonBeanToken", "Non-bean token address (e.g., WETH, USDC)")
    .addParam("wellFunction", "Well function type: CP2 (Constant Product) or S2 (Stable)")
    .addParam("name", "Well name")
    .addParam("symbol", "Well symbol")
    .addOptionalParam(
      "wellFunctionData",
      "Encoded well function data (auto-generated for S2 from token decimals)",
      "0x"
    )
    .addOptionalParam(
      "wellSalt",
      "CREATE2 salt for boreWell clone deployment (hex string)",
      undefined
    )
    .addOptionalParam(
      "proxySalt",
      "CREATE2 salt for ERC1967Proxy deployment (hex string)",
      "0x0000000000000000000000000000000000000000000000000000000000000002"
    )
    .setAction(async (taskArgs) => {
      const [deployer] = await ethers.getSigners();

      console.log(`\nDeploying standard well on ${network.name}`);
      console.log(`Deployer: ${deployer.address}\n`);

      // Deploy using standard infrastructure
      const result = await deployStandardWell({
        nonBeanToken: taskArgs.nonBeanToken,
        wellFunction: taskArgs.wellFunction,
        wellFunctionData: taskArgs.wellFunctionData,
        wellSalt: taskArgs.wellSalt,
        proxySalt: taskArgs.proxySalt,
        name: taskArgs.name,
        symbol: taskArgs.symbol,
        deployer,
        verbose: true
      });

      console.log(`\n✅ Standard well deployed successfully!`);
      console.log(`Proxy Address: ${result.proxyAddress}`);
      console.log(`Implementation: ${result.implementationAddress}\n`);

      return result;
    });

  task("deployWell", "Deploy an upgradeable well via Aquifer")
    .addParam("bean", "Bean token address")
    .addParam("nonBeanToken", "Non-bean token address (e.g., WETH, USDC)")
    .addParam("aquifer", "Aquifer factory address")
    .addParam("wellImplementation", "WellUpgradeable implementation address")
    .addParam("wellFunction", "Well function address (ConstantProduct2 or Stable2)")
    .addParam("pump", "Pump address (MultiFlowPump)")
    .addParam("pumpData", "Encoded pump data (hex string)")
    .addOptionalParam("wellFunctionData", "Encoded well function data (hex string)", "0x")
    .addOptionalParam(
      "salt",
      "CREATE2 salt for proxy deployment (hex string)",
      "0x0000000000000000000000000000000000000000000000000000000000000001"
    )
    .addOptionalParam("name", "Well name", "")
    .addOptionalParam("symbol", "Well symbol", "")
    .setAction(async (taskArgs) => {
      const [deployer] = await ethers.getSigners();

      console.log(`\nDeploying well from account: ${deployer.address}`);
      console.log(`Network: ${network.name}\n`);

      // Build well data
      const wellData = [
        {
          nonBeanToken: taskArgs.nonBeanToken,
          wellImplementation: taskArgs.wellImplementation,
          wellFunctionTarget: taskArgs.wellFunction,
          wellFunctionData: taskArgs.wellFunctionData,
          aquifer: taskArgs.aquifer,
          pump: taskArgs.pump,
          pumpData: taskArgs.pumpData,
          salt: taskArgs.salt,
          name: taskArgs.name || `Well ${taskArgs.bean}:${taskArgs.nonBeanToken}`,
          symbol: taskArgs.symbol || "WELL"
        }
      ];

      // Deploy
      const results = await deployUpgradeableWells(taskArgs.bean, wellData, deployer, true);

      console.log(`\n✅ Well deployed successfully!`);
      console.log(`Proxy Address: ${results[0].proxyAddress}`);
      console.log(`Implementation: ${results[0].implementationAddress}`);

      return results[0];
    });

  task("deployWellsFromConfig", "Deploy multiple wells from a JSON configuration file")
    .addParam("configFile", "Path to JSON configuration file")
    .addOptionalParam("bean", "Bean token address (overrides config)")
    .setAction(async (taskArgs) => {
      const [deployer] = await ethers.getSigners();

      console.log(`\nDeploying wells from config: ${taskArgs.configFile}`);
      console.log(`Deployer: ${deployer.address}`);
      console.log(`Network: ${network.name}\n`);

      // Load configuration
      if (!fs.existsSync(taskArgs.configFile)) {
        throw new Error(`Configuration file not found: ${taskArgs.configFile}`);
      }

      const config = JSON.parse(fs.readFileSync(taskArgs.configFile, "utf8"));

      // Get bean address
      let bean = taskArgs.bean;
      if (!bean && config.whitelistData && config.whitelistData.tokens) {
        bean = config.whitelistData.tokens[0];
      }

      if (!bean) {
        throw new Error("Bean address not found. Provide --bean parameter or include in config");
      }

      console.log(`Bean address: ${bean}`);

      // Validate configuration
      if (!config.wellComponents) {
        throw new Error("wellComponents not found in configuration");
      }

      if (!config.wells || config.wells.length === 0) {
        throw new Error("No wells found in configuration");
      }

      const { wellUpgradeableImplementation, aquifer, pump, pumpData } = config.wellComponents;

      // Transform wells
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

      console.log(`\nDeploying ${wellsData.length} well(s)...\n`);

      // Deploy wells
      const results = await deployUpgradeableWells(bean, wellsData, deployer, true);

      console.log(`\n✅ All wells deployed successfully!\n`);

      // Save results
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
    });

  task("verifyWellDeployment", "Verify a well deployment on block explorer")
    .addParam("proxy", "Well proxy address")
    .addParam("implementation", "Well implementation address")
    .addParam("name", "Well name")
    .addParam("symbol", "Well symbol")
    .setAction(async (taskArgs) => {
      console.log(`\nVerifying well deployment on ${network.name}...`);
      console.log(`Proxy: ${taskArgs.proxy}`);
      console.log(`Implementation: ${taskArgs.implementation}\n`);

      // Get WellUpgradeable interface
      const { getWellContractAt } = require("../utils/well");
      const wellUpgradeable = await getWellContractAt("WellUpgradeable", taskArgs.implementation);

      // Encode init call data
      const initCalldata = wellUpgradeable.interface.encodeFunctionData("init", [
        taskArgs.name,
        taskArgs.symbol
      ]);

      console.log(`Verifying ERC1967Proxy...`);

      try {
        await hre.run("verify:verify", {
          address: taskArgs.proxy,
          constructorArguments: [taskArgs.implementation, initCalldata]
        });
        console.log(`✅ Proxy verified successfully!`);
      } catch (error) {
        console.error(`Proxy verification failed: ${error.message}`);
      }

      console.log(`\nVerifying WellUpgradeable implementation...`);

      try {
        await hre.run("verify:verify", {
          address: taskArgs.implementation
        });
        console.log(`✅ Implementation verified successfully!`);
      } catch (error) {
        console.error(`Implementation verification failed: ${error.message}`);
      }
    });
};

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

      console.log("\n⚠️  DEPRECATION WARNING ⚠️");
      console.log("========================================");
      console.log("This task requires manual specification of all infrastructure addresses.");
      console.log("Consider using 'deployStandardWell' instead, which automatically uses");
      console.log("the standard Base network infrastructure and is much simpler to use.");
      console.log("========================================\n");

      console.log(`Deploying well from account: ${deployer.address}`);
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

  task("predictStandardWellAddress", "Predict well address using standard Base infrastructure")
    .addParam("nonBeanToken", "Non-bean token address (e.g., WETH, USDC)")
    .addParam("wellFunction", "Well function type: CP2 (Constant Product) or S2 (Stable)")
    .addParam("salt", "CREATE2 salt (32 bytes)")
    .addParam("sender", "Address that will deploy the well (msg.sender)")
    .addOptionalParam(
      "wellFunctionData",
      "Encoded well function data (auto-generated for S2 from token decimals)",
      "0x"
    )
    .setAction(async (taskArgs) => {
      const {
        encodeWellImmutableData,
        STANDARD_ADDRESSES_BASE
      } = require("../utils/wellDeployment");

      console.log("\n========================================");
      console.log("Predict Standard Well Address");
      console.log("========================================\n");

      // Map shorthand to full names
      const wellFunctionMap = {
        CP2: "constantProduct2",
        cp2: "constantProduct2",
        constantProduct2: "constantProduct2",
        S2: "stable2",
        s2: "stable2",
        stable2: "stable2"
      };

      const normalizedWellFunction = wellFunctionMap[taskArgs.wellFunction];
      if (!normalizedWellFunction) {
        throw new Error(
          `Invalid well function type: ${taskArgs.wellFunction}. Must be one of: CP2, constantProduct2, S2, or stable2`
        );
      }

      const wellFunctionTarget = STANDARD_ADDRESSES_BASE[normalizedWellFunction];
      const tokens = [STANDARD_ADDRESSES_BASE.bean, taskArgs.nonBeanToken];

      // Auto-generate wellFunctionData for S2 if not provided
      let finalWellFunctionData = taskArgs.wellFunctionData;
      if (normalizedWellFunction === "stable2" && taskArgs.wellFunctionData === "0x") {
        console.log(`Auto-generating well function data for Stable2...`);

        const beanToken = await ethers.getContractAt(
          "IERC20Metadata",
          STANDARD_ADDRESSES_BASE.bean
        );
        const nonBeanTokenContract = await ethers.getContractAt(
          "IERC20Metadata",
          taskArgs.nonBeanToken
        );

        const beanDecimals = await beanToken.decimals();
        const nonBeanDecimals = await nonBeanTokenContract.decimals();

        console.log(`  Bean decimals: ${beanDecimals}`);
        console.log(`  Non-Bean token decimals: ${nonBeanDecimals}`);

        finalWellFunctionData = ethers.utils.defaultAbiCoder.encode(
          ["uint256", "uint256"],
          [beanDecimals, nonBeanDecimals]
        );
        console.log(`  Encoded: ${finalWellFunctionData}\n`);
      }

      const wellFunction = {
        target: wellFunctionTarget,
        data: finalWellFunctionData
      };

      const pumps = [
        {
          target: STANDARD_ADDRESSES_BASE.pump,
          data: STANDARD_ADDRESSES_BASE.pumpData
        }
      ];

      // Encode immutable data
      const immutableData = encodeWellImmutableData(
        STANDARD_ADDRESSES_BASE.aquifer,
        tokens,
        wellFunction,
        pumps
      );

      console.log("Configuration:");
      console.log(`  Deployer (msg.sender): ${taskArgs.sender}`);
      console.log(`  Bean: ${STANDARD_ADDRESSES_BASE.bean}`);
      console.log(`  Non-Bean Token: ${taskArgs.nonBeanToken}`);
      console.log(`  Well Function (${normalizedWellFunction}): ${wellFunctionTarget}`);
      console.log(`  Aquifer: ${STANDARD_ADDRESSES_BASE.aquifer}`);
      console.log(`  Implementation: ${STANDARD_ADDRESSES_BASE.wellImplementation}`);
      console.log(`  Pump: ${STANDARD_ADDRESSES_BASE.pump}`);
      console.log(`  Salt: ${taskArgs.salt}\n`);

      console.log("Predicting well address...\n");

      try {
        // Impersonate the sender to call predictWellAddress as them
        await hre.network.provider.request({
          method: "hardhat_impersonateAccount",
          params: [taskArgs.sender]
        });

        const impersonatedSigner = await ethers.getSigner(taskArgs.sender);
        const aquifer = await ethers.getContractAt(
          "IAquifer",
          STANDARD_ADDRESSES_BASE.aquifer,
          impersonatedSigner
        );

        console.log("immutableData", immutableData);

        const predictedAddress = await aquifer.callStatic.predictWellAddress(
          STANDARD_ADDRESSES_BASE.wellImplementation,
          immutableData,
          taskArgs.salt
        );

        // Stop impersonating
        await hre.network.provider.request({
          method: "hardhat_stopImpersonatingAccount",
          params: [taskArgs.sender]
        });

        console.log("✅ Predicted Well Implementation Address:");
        console.log(`   ${predictedAddress}\n`);

        console.log("⚠️  Note: Aquifer hashes salt with msg.sender to prevent frontrunning");
        console.log(
          `   Actual salt used = keccak256(abi.encode(${taskArgs.sender}, ${taskArgs.salt}))`
        );
        console.log(`   Different deployer = different address\n`);

        return predictedAddress;
      } catch (error) {
        console.error("❌ Failed to predict address:", error.message);
        throw error;
      }
    });

  task("predictWellAddress", "Predict the well implementation address for a given salt")
    .addParam("implementation", "WellUpgradeable implementation address")
    .addParam("bean", "Bean token address")
    .addParam("nonBeanToken", "Non-bean token address")
    .addParam("wellFunction", "Well function address (ConstantProduct2 or Stable2)")
    .addParam("pump", "Pump address (MultiFlowPump)")
    .addParam("pumpData", "Encoded pump data (hex string)")
    .addParam("aquifer", "Aquifer factory address")
    .addParam("salt", "CREATE2 salt (32 bytes)")
    .addParam("sender", "Address that will deploy the well (msg.sender)")
    .addOptionalParam("wellFunctionData", "Encoded well function data (hex string)", "0x")
    .setAction(async (taskArgs) => {
      const { encodeWellImmutableData } = require("../utils/wellDeployment");

      console.log("\n========================================");
      console.log("Predict Well Implementation Address");
      console.log("========================================\n");

      const tokens = [taskArgs.bean, taskArgs.nonBeanToken];
      const wellFunction = {
        target: taskArgs.wellFunction,
        data: taskArgs.wellFunctionData
      };
      const pumps = [
        {
          target: taskArgs.pump,
          data: taskArgs.pumpData
        }
      ];

      // Encode immutable data
      const immutableData = encodeWellImmutableData(taskArgs.aquifer, tokens, wellFunction, pumps);

      console.log("Configuration:");
      console.log(`  Deployer (msg.sender): ${taskArgs.sender}`);
      console.log(`  Aquifer: ${taskArgs.aquifer}`);
      console.log(`  Implementation: ${taskArgs.implementation}`);
      console.log(`  Bean: ${taskArgs.bean}`);
      console.log(`  Non-Bean Token: ${taskArgs.nonBeanToken}`);
      console.log(`  Well Function: ${taskArgs.wellFunction}`);
      console.log(`  Pump: ${taskArgs.pump}`);
      console.log(`  Salt: ${taskArgs.salt}\n`);

      // Predict address
      console.log("Predicting well address...\n");

      try {
        // Impersonate the sender to call predictWellAddress as them
        await hre.network.provider.request({
          method: "hardhat_impersonateAccount",
          params: [taskArgs.sender]
        });

        const impersonatedSigner = await ethers.getSigner(taskArgs.sender);
        const aquifer = await ethers.getContractAt(
          "IAquifer",
          taskArgs.aquifer,
          impersonatedSigner
        );

        const predictedAddress = await aquifer.callStatic.predictWellAddress(
          taskArgs.implementation,
          immutableData,
          taskArgs.salt
        );

        // Stop impersonating
        await hre.network.provider.request({
          method: "hardhat_stopImpersonatingAccount",
          params: [taskArgs.sender]
        });

        console.log("✅ Predicted Well Implementation Address:");
        console.log(`   ${predictedAddress}\n`);

        console.log("📋 This is the address that will be deployed when calling:");
        console.log(`   aquifer.boreWell(`);
        console.log(`     ${taskArgs.implementation},`);
        console.log(`     immutableData,`);
        console.log(`     initData,`);
        console.log(`     ${taskArgs.salt}`);
        console.log(`   )\n`);

        console.log("⚠️  Note: Aquifer hashes salt with msg.sender to prevent frontrunning");
        console.log(
          `   Actual salt used = keccak256(abi.encode(${taskArgs.sender}, ${taskArgs.salt}))\n`
        );

        return predictedAddress;
      } catch (error) {
        console.error("❌ Failed to predict address:", error.message);
        throw error;
      }
    });

  task("mineProxySalt", "Mine a CREATE2 salt for a vanity well proxy address")
    .addParam("prefix", "Desired address prefix (hex, without 0x)")
    .addParam("implementation", "Well implementation address")
    .addParam("name", "Well name for init call")
    .addParam("symbol", "Well symbol for init call")
    .addOptionalParam(
      "deployer",
      "Address that will deploy the proxy (InitDeployAndWhitelistWell contract or CreateX)",
      undefined
    )
    .addOptionalParam(
      "createx",
      "CreateX factory address (deprecated, use --deployer)",
      "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed"
    )
    .addFlag("caseSensitive", "Enable case-sensitive matching")
    .addFlag("estimateOnly", "Only show difficulty estimate, don't mine")
    .setAction(async (taskArgs) => {
      const { mineProxySalt, estimateDifficulty } = require("../utils/mineProxySalt");

      console.log("========================================");
      console.log("CREATE2 Proxy Salt Miner");
      console.log("========================================\n");

      const {
        prefix,
        implementation: implementationAddress,
        name: wellName,
        symbol: wellSymbol,
        deployer: deployerAddress,
        createx: createXAddress,
        caseSensitive,
        estimateOnly
      } = taskArgs;

      // Use deployer if provided, otherwise fall back to createx
      const deployer = deployerAddress || createXAddress;

      // Show difficulty estimate
      console.log("📊 Difficulty Analysis");
      console.log("========================================");
      const estimate = estimateDifficulty(prefix, caseSensitive);
      console.log(`Prefix: 0x${prefix}`);
      console.log(`Length: ${estimate.prefixLength} characters`);
      console.log(`Difficulty: ${estimate.difficulty}`);
      console.log(`Probability: ${estimate.probability} per attempt`);
      console.log(`Expected attempts: ${estimate.expectedAttempts}`);
      console.log(`Expected time: ${estimate.expectedTime}`);
      console.log(`(at ~100k attempts/sec per core)\n`);

      if (estimateOnly) {
        console.log("ℹ️  Estimate only mode - exiting without mining\n");
        return;
      }

      // Prepare init calldata
      const initCalldata = new ethers.utils.Interface([
        "function init(string name, string symbol)"
      ]).encodeFunctionData("init", [wellName, wellSymbol]);

      console.log("⚙️  Mining Configuration");
      console.log("========================================");
      console.log(`Implementation: ${implementationAddress}`);
      console.log(`Well name: ${wellName}`);
      console.log(`Well symbol: ${wellSymbol}`);
      console.log(`Deployer: ${deployer}`);
      console.log(`Case sensitive: ${caseSensitive}\n`);

      // Progress callback
      let lastUpdate = Date.now();
      const onProgress = ({ iterations, elapsed, rate }) => {
        const now = Date.now();
        if (now - lastUpdate > 2000) {
          console.log(
            `   ${iterations.toLocaleString()} attempts | ${elapsed.toFixed(1)}s | ${rate.toLocaleString()}/sec`
          );
          lastUpdate = now;
        }
      };

      // Mine the salt
      console.log("⛏️  Mining...");
      console.log("========================================");

      const result = await mineProxySalt({
        implementationAddress,
        initCalldata,
        deployerAddress: deployer,
        prefix,
        caseSensitive,
        onProgress
      });

      if (result) {
        console.log("💾 Result");
        console.log("========================================");
        console.log(`Salt (bytes32): ${result.salt}`);
        console.log(`Address: ${result.address}`);
        console.log("\n📋 To use this salt in deployment:");
        console.log(`proxySalt: "${result.salt}",\n`);

        console.log("🔍 Verification:");
        console.log(`Implementation: ${implementationAddress}`);
        console.log(`Name: ${wellName}`);
        console.log(`Symbol: ${wellSymbol}`);
        console.log("\n⚠️  You MUST use these exact values when deploying!\n");

        return result;
      } else {
        // Mining was interrupted or no match found
        // Error message already printed by mineProxySalt
        process.exit(0);
      }
    });

  task("mineWellSalt", "Mine a CREATE2 salt for a vanity well implementation address")
    .addParam("prefix", "Desired address prefix (hex, without 0x)")
    .addParam("implementation", "Well implementation address")
    .addParam("bean", "Bean token address")
    .addParam("nonBeanToken", "Non-bean token address")
    .addParam("wellFunction", "Well function type: CP2 or S2")
    .addParam("sender", "Address that will deploy the well (msg.sender)")
    .addOptionalParam("aquifer", "Aquifer factory address")
    .addOptionalParam("pump", "Pump address")
    .addOptionalParam("batchSize", "Number of iterations per batch (default: 20)", 20, types.int)
    .addFlag("caseSensitive", "Enable case-sensitive matching")
    .addFlag("estimateOnly", "Only show difficulty estimate, don't mine")
    .setAction(async (taskArgs) => {
      const { mineWellSalt, estimateDifficulty } = require("../utils/mineWellSalt");
      const { STANDARD_ADDRESSES_BASE } = require("../utils/wellDeployment");

      console.log("\n========================================");
      console.log("Well Implementation Salt Miner");
      console.log("========================================\n");

      const {
        prefix,
        implementation,
        bean,
        nonBeanToken,
        wellFunction: wellFunctionType,
        sender,
        aquifer: aquiferParam,
        pump: pumpParam,
        batchSize,
        caseSensitive,
        estimateOnly
      } = taskArgs;

      // Use standard addresses if not specified
      const aquiferAddress = aquiferParam || STANDARD_ADDRESSES_BASE.aquifer;
      const pumpAddress = pumpParam || STANDARD_ADDRESSES_BASE.pump;

      // Normalize well function type
      const normalizedWellFunction = wellFunctionType.toUpperCase();
      if (!["CP2", "S2"].includes(normalizedWellFunction)) {
        throw new Error('Well function must be "CP2" or "S2"');
      }

      // Get well function address
      const wellFunctionTarget =
        normalizedWellFunction === "CP2"
          ? STANDARD_ADDRESSES_BASE.constantProduct2
          : STANDARD_ADDRESSES_BASE.stable2;

      // For S2, we need to get token decimals to generate well function data
      let wellFunctionData = "0x";
      if (normalizedWellFunction === "S2") {
        const ERC20 = await ethers.getContractAt("ERC20", nonBeanToken);
        const decimals = await ERC20.decimals();
        wellFunctionData = ethers.utils.defaultAbiCoder.encode(
          ["uint256", "uint256"],
          [ethers.BigNumber.from(10).pow(6), ethers.BigNumber.from(10).pow(decimals)]
        );
      }

      const wellFunction = {
        target: wellFunctionTarget,
        data: wellFunctionData
      };

      // Show configuration
      console.log("Configuration:");
      console.log(`  Deployer (msg.sender): ${sender}`);
      console.log(`  Bean: ${bean}`);
      console.log(`  Non-Bean Token: ${nonBeanToken}`);
      console.log(`  Well Function (${normalizedWellFunction}): ${wellFunctionTarget}`);
      console.log(`  Aquifer: ${aquiferAddress}`);
      console.log(`  Implementation: ${implementation}`);
      console.log(`  Pump: ${pumpAddress}\n`);

      // Show difficulty estimate
      console.log("📊 Difficulty Analysis");
      console.log("========================================");
      const estimate = estimateDifficulty(prefix, caseSensitive);
      console.log(`Prefix: 0x${prefix}`);
      console.log(`Length: ${estimate.prefixLength} characters`);
      console.log(`Difficulty: ${estimate.difficulty}`);
      console.log(`Probability: ${estimate.probability} per attempt`);
      console.log(`Expected attempts: ${estimate.expectedAttempts}`);
      console.log(`Expected time: ${estimate.expectedTime}`);
      console.log(`(at ~100k attempts/sec per core)\n`);

      if (estimateOnly) {
        console.log("ℹ️  Estimate only mode - exiting without mining\n");
        return;
      }

      console.log("⚙️  Mining Configuration");
      console.log("========================================");
      console.log(`Case sensitive: ${caseSensitive}\n`);

      // Progress callback
      let lastUpdate = Date.now();
      const onProgress = ({ iterations, elapsed, rate }) => {
        const now = Date.now();
        if (now - lastUpdate > 2000) {
          console.log(
            `   ${iterations.toLocaleString()} attempts | ${elapsed.toFixed(1)}s | ${rate.toLocaleString()}/sec`
          );
          lastUpdate = now;
        }
      };

      // Mine the salt
      console.log("⛏️  Mining...");
      console.log("========================================");

      const result = await mineWellSalt({
        aquifer: aquiferAddress,
        implementation,
        bean,
        nonBeanToken,
        wellFunctionTarget,
        wellFunctionData,
        pumpTarget: pumpAddress,
        pumpData: STANDARD_ADDRESSES_BASE.pumpData,
        sender,
        prefix,
        caseSensitive,
        batchSize,
        onProgress
      });

      if (result) {
        console.log("💾 Result");
        console.log("========================================");
        console.log(`Salt (bytes32): ${result.salt}`);
        console.log(`Address: ${result.address}`);
        console.log("\n📋 To use this salt in deployment:");
        console.log(`salt: "${result.salt}",\n`);

        console.log("🔍 Verification:");
        console.log(`Deployer: ${sender}`);
        console.log(`Implementation: ${implementation}`);
        console.log(`Bean: ${bean}`);
        console.log(`Non-Bean Token: ${nonBeanToken}`);
        console.log(`Well Function: ${normalizedWellFunction}`);
        console.log("\n⚠️  You MUST deploy from ${sender} with these exact parameters!\n");

        console.log("✅ Verify with:");
        console.log(
          `npx hardhat predictStandardWellAddress --non-bean-token ${nonBeanToken} --well-function ${normalizedWellFunction} --salt ${result.salt} --sender ${sender} --network base\n`
        );

        return result;
      } else {
        // Mining was interrupted or no match found
        // Error message already printed by mineWellSalt
        process.exit(0);
      }
    });
};

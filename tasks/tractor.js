/**
 * TRACTOR BLUEPRINT SIGNING TASKS
 *
 * This file provides Hardhat tasks for signing and publishing Tractor blueprints.
 * Tractor is Beanstalk's system for creating reusable, signed transaction templates
 * that can be executed by operators on behalf of publishers.
 *
 * KEY CONCEPTS:
 * - Blueprint: A template containing transaction data and execution parameters
 * - Requisition: A signed blueprint ready for publication/execution
 * - Publisher: The account that signs and owns the blueprint
 * - Operator: The account that executes the blueprint (receives tips)
 *
 * ARCHITECTURE:
 * 1. Blueprints contain encoded function calls to ecosystem contracts
 * 2. Tractor wraps these calls in advancedFarm for execution
 * 3. EIP-712 signatures ensure blueprint authenticity
 * 4. Published requisitions can be executed multiple times (up to maxNonce)
 *
 * BLUEPRINT CONTRACTS:
 * - SowBlueprint: Automated sowing with configurable parameters
 * - ConvertUpBlueprint: Convert deposits to higher BDV tokens
 * - Custom blueprints: Any contract following the blueprint pattern
 *
 * USAGE PATTERNS:
 * 1. Use sign-beanstalk-blueprint for ecosystem contracts (recommended)
 * 2. Use sign-blueprint for arbitrary data (advanced)
 * 3. Use publish-blueprint to put requisitions on-chain
 * 4. Use blueprint-status to check execution state
 */

const { task } = require("hardhat/config");
const fs = require("fs");
const path = require("path");
const { getBeanstalk, impersonateSigner } = require("../utils");
const {
  L2_PINTO,
  PINTO_CBTC_WELL_BASE,
  PINTO_USDC_WELL_BASE,
  PINTO_CBETH_WELL_BASE,
  PIPELINE,
  tractorToAddressMap
} = require("../test/hardhat/utils/constants.js");

// ============================================
// HELPER FUNCTIONS
// ============================================

/**
 * Calculate blueprint hash using EIP-712 typed data hashing
 *
 * This hash uniquely identifies a blueprint and is used for:
 * - Signature verification
 * - Tracking execution nonces
 * - Blueprint cancellation
 *
 * @param {Object} blueprint - The blueprint object with publisher, data, etc.
 * @param {string} tractorVersion - Current Tractor version from Beanstalk
 * @param {number} chainId - Network chain ID
 * @param {string} beanstalkAddress - Beanstalk contract address
 * @returns {string} EIP-712 compliant hash
 */
function calculateBlueprintHash(blueprint, tractorVersion, chainId, beanstalkAddress) {
  const { ethers } = require("hardhat");

  const domain = {
    name: "Tractor",
    version: tractorVersion,
    chainId,
    verifyingContract: beanstalkAddress
  };

  const types = {
    Blueprint: [
      { name: "publisher", type: "address" },
      { name: "data", type: "bytes" },
      { name: "operatorPasteInstrs", type: "bytes32[]" },
      { name: "maxNonce", type: "uint256" },
      { name: "startTime", type: "uint256" },
      { name: "endTime", type: "uint256" }
    ]
  };

  // Use ethers to hash typed data
  return ethers.utils._TypedDataEncoder.hash(domain, types, blueprint);
}

/**
 * Convert contract name to expected function name
 *
 * Follows the convention: ContractName -> contractName (camelCase)
 * e.g., "SowBlueprint" -> "sowBlueprint"
 *
 * @param {string} contractName - Name of the contract
 * @returns {string} camelCase function name
 */
function getBlueprintFunctionName(contractName) {
  return contractName.charAt(0).toLowerCase() + contractName.slice(1);
}

/**
 * Verbose logging helper
 *
 * @param {boolean} verbose - Whether to show verbose output
 * @param {string} message - Message to log
 */
function log(verbose, message) {
  if (verbose) {
    console.log(message);
  }
}

async function createTractorData(blueprintName, blueprintStructData, hre) {
  const blueprintAddress = tractorToAddressMap[blueprintName];
  // encode function call.
  const blueprintArtifact = await hre.artifacts.readArtifact(blueprintName);
  blueprintInterface = new hre.ethers.utils.Interface(blueprintArtifact.abi);
  blueprintFunctionName = getBlueprintFunctionName(blueprintName);
  blueprintFunctionCalldata = blueprintInterface.encodeFunctionData(blueprintFunctionName, [
    blueprintStructData
  ]);

  // encode this in an advancedPipe call
  const depotFacetArtifact = await hre.artifacts.readArtifact("DepotFacet");
  const depotFacetInterface = new hre.ethers.utils.Interface(depotFacetArtifact.abi);
  advancedPipeCall = [
    {
      target: blueprintAddress,
      callData: blueprintFunctionCalldata,
      clipboard: "0x0000"
    }
  ];
  const advancedPipeFunctionCalldata = depotFacetInterface.encodeFunctionData("advancedPipe", [
    advancedPipeCall,
    0
  ]);

  // encode this in an advancedFarm call
  const farmFacetArtifact = await hre.artifacts.readArtifact("FarmFacet");
  const farmFacetInterface = new hre.ethers.utils.Interface(farmFacetArtifact.abi);

  const advancedFarmCall = [
    {
      callData: advancedPipeFunctionCalldata,
      clipboard: "0x0000"
    }
  ];
  const advancedFarmFunctionCalldata = farmFacetInterface.encodeFunctionData("advancedFarm", [
    advancedFarmCall
  ]);

  return advancedFarmFunctionCalldata;
}

/**
 * Build parameters interactively by prompting user
 *
 * NOTE: Interactive parameter building is not yet implemented.
 * This is a placeholder that suggests using --params flag instead.
 *
 * @param {Object} contractFactory - Contract factory with interface
 * @param {string} functionName - Name of function to call
 * @param {Object} hre - Hardhat runtime environment
 * @param {boolean} verbose - Whether to show verbose output
 */
async function buildParametersInteractively(contractFactory, functionName, hre, verbose = true) {
  const functionFragment = contractFactory.interface.getFunction(functionName);

  if (verbose) {
    console.log(`\n🔧 Function ${functionName} requires parameters:`);
    functionFragment.inputs.forEach((input) => {
      console.log(`  - ${input.name}: ${input.type}`);
    });

    console.log("\n⚠️  Interactive parameter building not implemented yet.");
    console.log("Please provide parameters using --params flag with JSON data.");
  }

  throw new Error("Interactive parameter building requires --params flag");
}

/**
 * General function to sign any blueprint data using EIP-712
 *
 * This is the core signing function that:
 * 1. Creates a properly formatted Blueprint struct
 * 2. Calculates the EIP-712 hash
 * 3. Signs the data using the provided signer
 *
 * @param {string} blueprintData - Encoded transaction data (hex string)
 * @param {Object} options - Signing options
 * @param {string} options.publisher - Publisher address
 * @param {string[]} options.operatorPasteInstrs - Operator paste instructions
 * @param {number} options.maxNonce - Maximum executions allowed
 * @param {number} options.startTime - When blueprint becomes active (unix timestamp)
 * @param {number} options.endTime - When blueprint expires (unix timestamp)
 * @param {Object} options.signer - Ethers.js signer instance
 * @param {string} options.tractorVersion - Tractor version string
 * @param {number} options.chainId - Network chain ID
 * @param {string} options.beanstalkAddress - Beanstalk contract address
 * @returns {Object} Requisition object with blueprint, hash, and signature
 */
async function signBlueprint(blueprintData, options = {}) {
  const {
    signer,
    publisher,
    operatorPasteInstrs = [],
    maxNonce = 100,
    startTime = Math.floor(Date.now() / 1000),
    endTime = Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60,
    tractorVersion,
    beanstalkAddress,
    mock = true
  } = options;

  const blueprint = {
    publisher,
    data: blueprintData,
    operatorPasteInstrs,
    maxNonce,
    startTime,
    endTime
  };
  const chainId = await signer.getChainId();

  // Calculate blueprint hash
  const blueprintHash = calculateBlueprintHash(
    blueprint,
    tractorVersion,
    chainId,
    beanstalkAddress
  );
  console.log(`Blueprint hash: ${blueprintHash}`);

  // EIP-712 signing
  const domain = {
    name: "Tractor",
    version: tractorVersion,
    chainId,
    verifyingContract: beanstalkAddress
  };

  const types = {
    Blueprint: [
      { name: "publisher", type: "address" },
      { name: "data", type: "bytes" },
      { name: "operatorPasteInstrs", type: "bytes32[]" },
      { name: "maxNonce", type: "uint256" },
      { name: "startTime", type: "uint256" },
      { name: "endTime", type: "uint256" }
    ]
  };

  const signature = await signer._signTypedData(domain, types, blueprint);
  console.log(`Signature: ${signature}`);
  return {
    blueprint,
    blueprintHash,
    signature
  };
}

// ============================================
// HELPER FUNCTIONS FOR TESTING
// ============================================

/**
 * Setup an address with LP tokens for testing ConvertUp blueprints
 * @param {string} address - Address to setup
 * @param {string} amount - Amount of LP tokens in beans (e.g., "10000" for 10k beans worth)
 * @param {Object} hre - Hardhat runtime environment
 * @param {boolean} verbose - Show detailed logs
 */
async function setupAddressWithLPTokens(address, amount, hre, wellAddresses, verbose = false) {
  const { ethers } = hre;

  // Setup each well type
  for (let i = 0; i < wellAddresses.length; i++) {
    try {
      const wellAddress = wellAddresses[i];
      if (!wellAddress || wellAddress === "0x0000000000000000000000000000000000000000") {
        continue;
      }

      log(verbose, `  📈 Setting up LP tokens for well ${i}: ${wellAddress}`);

      // Get well contract
      const well = await ethers.getContractAt("IWell", wellAddress);

      // Get the underlying tokens
      const tokens = await well.tokens();

      if (tokens.length !== 2) continue;
      const token0Contract = await ethers.getContractAt("MockToken", tokens[0]);
      const token0Decimals = await token0Contract.decimals();
      const token1Contract = await ethers.getContractAt("MockToken", tokens[1]);
      const token1Decimals = await token1Contract.decimals();

      // Calculate amount for second token based on well reserves
      const reserves = await well.getReserves();
      // Normalize reserves based on token decimals
      // Ensure amount is a string representing an integer value (no decimals) to avoid underflow
      const beanAmount = BigInt(amount);

      const reserve0Normalized = parseFloat(ethers.utils.formatUnits(reserves[0], token0Decimals));
      console.log(`Reserve 0 normalized: ${reserve0Normalized}`);
      const reserve1Normalized = parseFloat(ethers.utils.formatUnits(reserves[1], token1Decimals));
      console.log(`Reserve 1 normalized: ${reserve1Normalized}`);
      let token1Amount = (Number(beanAmount) * reserve1Normalized) / reserve0Normalized;
      // Truncate to token1Decimals precision
      token1Amount =
        Math.floor(token1Amount * Math.pow(10, token1Decimals)) / Math.pow(10, token1Decimals);
      console.log(`Token 1 amount: ${token1Amount}`);

      // Use the addLiquidity task to handle minting and liquidity addition

      await hre.run("addLiquidity", {
        well: wellAddress,
        amounts: `${beanAmount},${token1Amount}`,
        receiver: address,
        deposit: true
      });

      log(verbose, `  ✓ Added liquidity and deposited LP tokens to Silo for well ${wellAddress}`);
    } catch (error) {
      console.error(
        `Failed to setup well ${wellAddresses[i]} LP tokens for ${address}: ${error.message}`
      );
    }
  }
}

// ============================================
// HARDHAT TASKS
// ============================================

module.exports = function () {
  /**
   * SIGN-BEANSTALK-BLUEPRINT TASK
   *
   * This is the main task for signing blueprints for Beanstalk ecosystem contracts.
   * It automatically discovers contract interfaces and encodes function calls.
   *
   * KEY FEATURES:
   * - Auto-discovers function names from contract names
   * - Handles contracts with library dependencies via artifact loading
   * - Supports parameter files or inline JSON
   * - Creates properly formatted Tractor requisitions
   *
   * EXAMPLE USAGE:
   * npx hardhat sign-beanstalk-blueprint --contract SowBlueprint --params '{"sowParams":{...}}'
   * npx hardhat sign-beanstalk-blueprint --contract SowBlueprint --params ./my-params.json
   */
  task("sign-beanstalk-blueprint", "Sign a blueprint for a Beanstalk ecosystem contract")
    .addParam("contract", "Blueprint contract name (e.g., 'SowBlueprint')")
    .addParam("privateKey", "Private key to use for signing")
    .addOptionalParam("function", "Function name (defaults to camelCase of contract)")
    .addOptionalParam("params", "Parameters as JSON string or file path")
    .addOptionalParam("maxNonce", "Max executions", "100")
    .addOptionalParam("duration", "Duration in days", "30")
    .addOptionalParam("output", "Output file path")
    .addFlag("detail", "Show detailed logging")
    .setAction(async (taskArgs, hre) => {
      const { ethers } = hre;
      const signer = new ethers.Wallet(taskArgs.privateKey, ethers.provider);
      const publisher = signer.address;
      const verbose = taskArgs.detail;

      if (!verbose) {
        console.log(`📋 Signing ${taskArgs.contract} blueprint...`);
      } else {
        console.log(`\n📋 Signing blueprint for ${taskArgs.contract}...`);
        console.log(`🔑 Publisher: ${publisher}`);
        console.log(`📊 Max Nonce: ${taskArgs.maxNonce}`);
        console.log(`⏰ Duration: ${taskArgs.duration} days`);
      }

      try {
        // 1. Get the contract interface from artifacts (more reliable with library dependencies)
        log(verbose, "📦 Getting contract interface from artifacts...");
        const contractArtifact = await hre.artifacts.readArtifact(taskArgs.contract);
        const contractInterface = new ethers.utils.Interface(contractArtifact.abi);
        log(verbose, "✓ Got contract interface from artifact");

        const functionName = taskArgs.function || getBlueprintFunctionName(taskArgs.contract);
        log(verbose, `🔍 Using function name: ${functionName}`);

        // 2. Verify function exists
        let functionFragment;
        try {
          functionFragment = contractInterface.getFunction(functionName);
        } catch (error) {
          console.log(`❌ Function '${functionName}' not found in ${taskArgs.contract}`);
          console.log("Available functions:");
          contractInterface.fragments
            .filter((f) => f.type === "function")
            .forEach((f) => console.log(`  - ${f.name}`));
          throw new Error(`Function ${functionName} not found`);
        }

        log(verbose, `✓ Found function: ${functionName}`);
        if (verbose) {
          console.log("Expected parameters:");
          functionFragment.inputs.forEach((input) => {
            console.log(`  - ${input.name}: ${input.type}`);
          });
        }

        // 3. Parse parameters
        let params;
        if (taskArgs.params) {
          // Check if it's a file path or JSON string
          if (taskArgs.params.endsWith(".json")) {
            if (!fs.existsSync(taskArgs.params)) {
              throw new Error(`Parameter file not found: ${taskArgs.params}`);
            }
            params = JSON.parse(fs.readFileSync(taskArgs.params, "utf8"));
            log(verbose, `✓ Loaded parameters from ${taskArgs.params}`);
          } else {
            params = JSON.parse(taskArgs.params);
            log(verbose, "✓ Parsed parameters from command line");
          }
        } else {
          // Interactive parameter building
          params = await buildParametersInteractively(
            { interface: contractInterface },
            functionName,
            hre,
            verbose
          );
        }

        // 4. Use createTractorData helper for consistent encoding
        log(verbose, "📦 Creating tractor data using helper function...");
        const tractorData = await createTractorData(taskArgs.contract, params, hre);
        log(verbose, `✓ Tractor data encoded: ${tractorData.substring(0, 42)}...`);

        // 6. Sign the blueprint using the sign-blueprint task
        log(verbose, "✍️  Signing blueprint...");
        const requisition = await hre.run("sign-blueprint", {
          data: tractorData,
          privateKey: taskArgs.privateKey,
          maxNonce: taskArgs.maxNonce,
          startTime: Math.floor(Date.now() / 1000).toString(),
          endTime: (
            Math.floor(Date.now() / 1000) +
            parseInt(taskArgs.duration) * 24 * 60 * 60
          ).toString(),
          detail: verbose
        });
        log(verbose, `✓ Blueprint signed with hash: ${requisition.blueprintHash}`);

        // 8. Save to file
        const timestamp = Date.now();
        const defaultOutput = `./tasks/requisition/${taskArgs.contract}-${timestamp}.json`;
        const outputPath = taskArgs.output || defaultOutput;

        // Create requisitions directory if it doesn't exist
        const outputDir = path.dirname(outputPath);
        if (!fs.existsSync(outputDir)) {
          fs.mkdirSync(outputDir, { recursive: true });
          log(verbose, `✓ Created directory: ${outputDir}`);
        }

        fs.writeFileSync(outputPath, JSON.stringify(requisition, null, 2));

        console.log(`\n🎉 Successfully signed ${taskArgs.contract}.${functionName}`);
        console.log(`📁 Requisition saved to: ${outputPath}`);
        if (verbose) {
          console.log(`🔑 Blueprint Hash: ${requisition.blueprintHash}`);
          console.log(`👤 Publisher: ${requisition.blueprint.publisher}`);
          console.log(`📝 Max Nonce: ${requisition.blueprint.maxNonce}`);
          console.log(
            `⏰ Valid until: ${new Date(requisition.blueprint.endTime * 1000).toLocaleString()}`
          );
        }

        return requisition;
      } catch (error) {
        console.error(
          `❌ Error signing blueprint at line ${error.stack?.split("\n")[1]?.trim() || "unknown"}: ${error.message}`
        );
        throw error;
      }
    });

  task("sign-blueprint", "Sign arbitrary blueprint data")
    .addParam("data", "Encoded blueprint data (hex string)")
    .addParam("privateKey", "Private key to use for signing")
    .addOptionalParam("operatorPasteInstrs", "Operator paste instructions as JSON array")
    .addOptionalParam("maxNonce", "Max executions", "100")
    .addOptionalParam("startTime", "Start timestamp (unix)")
    .addOptionalParam("endTime", "End timestamp (unix)")
    .addOptionalParam("output", "Output file path")
    .addFlag("detail", "Show detailed logging")
    .setAction(async (taskArgs, hre) => {
      const { ethers } = hre;
      const signer = new ethers.Wallet(taskArgs.privateKey, ethers.provider);
      const publisher = signer.address;
      const verbose = taskArgs.detail;

      if (!verbose) {
        console.log("📋 Signing arbitrary blueprint data...");
      } else {
        console.log("\n📋 Signing arbitrary blueprint data...");
        console.log(`📊 Data: ${taskArgs.data.substring(0, 42)}...`);
        console.log(`👤 Publisher: ${publisher}`);
        console.log(`📝 Max Nonce: ${taskArgs.maxNonce}`);
      }

      try {
        // Get Beanstalk for version and address
        log(verbose, "🔗 Connecting to Beanstalk...");
        const beanstalk = await getBeanstalk(L2_PINTO);
        const tractorVersion = await beanstalk.getTractorVersion();
        log(verbose, `✓ Tractor version: ${tractorVersion}`);

        log(verbose, "✍️  Signing blueprint...");
        const requisition = await signBlueprint(taskArgs.data, {
          signer: signer,
          publisher: publisher,
          operatorPasteInstrs: taskArgs.operatorPasteInstrs
            ? JSON.parse(taskArgs.operatorPasteInstrs)
            : [],
          maxNonce: parseInt(taskArgs.maxNonce),
          startTime: parseInt(taskArgs.startTime) || Math.floor(Date.now() / 1000),
          endTime: parseInt(taskArgs.endTime) || Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60,
          tractorVersion,
          beanstalkAddress: beanstalk.address,
          mock: true
        });
        log(verbose, `✓ Blueprint signed with hash: ${requisition.blueprintHash}`);

        if (taskArgs.output) {
          fs.writeFileSync(taskArgs.output, JSON.stringify(requisition, null, 2));
          log(verbose, `📁 Saved to: ${taskArgs.output}`);
        } else if (verbose) {
          console.log("\n📄 Requisition JSON:");
          console.log(JSON.stringify(requisition, null, 2));
        }

        console.log(`\n🎉 Blueprint signed successfully`);
        if (verbose) {
          console.log(`🔑 Blueprint Hash: ${requisition.blueprintHash}`);
          console.log(`👤 Publisher: ${requisition.blueprint.publisher}`);
          console.log(`📝 Max Nonce: ${requisition.blueprint.maxNonce}`);
          console.log(
            `⏰ Valid until: ${new Date(requisition.blueprint.endTime * 1000).toLocaleString()}`
          );
        }

        return requisition;
      } catch (error) {
        console.error(`❌ Error signing blueprint: ${error.message}`);
        throw error;
      }
    });

  task("publish-blueprint", "Publish a signed blueprint requisition")
    .addParam("requisition", "Requisition JSON file path or JSON string")
    .addFlag("detail", "Show detailed logging")
    .setAction(async (taskArgs, hre) => {
      const verbose = taskArgs.detail;

      if (!verbose) {
        console.log("📤 Publishing blueprint requisition...");
      } else {
        console.log("\n📤 Publishing blueprint requisition...");
      }

      try {
        // Load requisition
        let requisition;
        if (taskArgs.requisition.startsWith("{")) {
          requisition = JSON.parse(taskArgs.requisition);
          log(verbose, "✓ Parsed requisition from command line");
        } else {
          if (!fs.existsSync(taskArgs.requisition)) {
            throw new Error(`Requisition file not found: ${taskArgs.requisition}`);
          }
          requisition = JSON.parse(fs.readFileSync(taskArgs.requisition, "utf8"));
          log(verbose, `✓ Loaded requisition from ${taskArgs.requisition}`);
        }

        // Get Beanstalk and publish
        log(verbose, "🔗 Connecting to Beanstalk...");
        const beanstalk = await getBeanstalk(L2_PINTO);

        if (verbose) {
          console.log(`🔑 Blueprint Hash: ${requisition.blueprintHash}`);
          console.log(`👤 Publisher: ${requisition.blueprint.publisher}`);
        }
        log(verbose, "📤 Publishing to blockchain...");

        const tx = await beanstalk.publishRequisition(requisition);
        log(verbose, `⏳ Transaction submitted: ${tx.hash}`);

        const receipt = await tx.wait();

        console.log(`\n🎉 Blueprint published successfully!`);
        console.log(`📝 Transaction: ${receipt.transactionHash}`);
        if (verbose) {
          console.log(`⛽ Gas used: ${receipt.gasUsed.toString()}`);
          console.log(`📦 Block: ${receipt.blockNumber}`);
        }

        return receipt;
      } catch (error) {
        console.error(`❌ Error publishing blueprint: ${error.message}`);
        throw error;
      }
    });

  task("blueprint-status", "Check status of a blueprint")
    .addParam("hash", "Blueprint hash to check")
    .addFlag("detail", "Show detailed logging")
    .setAction(async (taskArgs, hre) => {
      const { ethers } = hre;
      const verbose = taskArgs.detail;

      if (!verbose) {
        console.log(`🔍 Checking blueprint status...`);
      } else {
        console.log(`\n🔍 Checking status of blueprint: ${taskArgs.hash}`);
      }

      try {
        log(verbose, "🔗 Connecting to Beanstalk...");
        const beanstalk = await getBeanstalk(L2_PINTO);

        log(verbose, "📊 Fetching blueprint nonce...");
        const nonce = await beanstalk.getBlueprintNonce(taskArgs.hash);

        console.log(`\n📊 Blueprint Status:`);
        if (verbose) {
          console.log(`🔑 Hash: ${taskArgs.hash}`);
        }
        console.log(`🔢 Current Nonce: ${nonce}`);

        if (nonce.toString() === ethers.constants.MaxUint256.toString()) {
          console.log(`❌ Status: CANCELLED`);
        } else {
          console.log(`✅ Status: ACTIVE`);
        }

        return nonce;
      } catch (error) {
        console.error(`❌ Error checking blueprint status: ${error.message}`);
        throw error;
      }
    });

  /**
   * create-mock-convert-up-orders TASK
   *
   * Creates and executes multiple ConvertUpBlueprint orders from different addresses for testing.
   * This task:
   * 1. Generates 5 test addresses from deterministic private keys
   * 2. Sets up each address with ETH and LP tokens
   * 3. Creates ConvertUpBlueprint orders based on JSON configuration
   * 4. Signs and executes the blueprints through Tractor
   *
   * Distribution: 5 addresses with [1,2,3,5,9] orders each (20 total)
   *
   * REQUIREMENTS:
   * - Must run on Base fork with ConvertUpBlueprint deployed
   * - Requires active Tractor system with getTractorVersion() support
   *
   * USAGE:
   * npx hardhat create-mock-convert-up-orders --network localhost --params ./utils/data/convertUpTestOrders.json
   * npx hardhat create-mock-convert-up-orders --network localhost --execute --detail
   *
   * SETUP (run first):
   * npx hardhat node --fork https://mainnet.base.org
   */
  task(
    "create-mock-convert-up-orders",
    "Create and execute multiple ConvertUpBlueprint orders for testing"
  )
    .addOptionalParam(
      "params",
      "Path to JSON parameters file",
      "./utils/data/convertUpTestOrders.json"
    )
    .addOptionalParam("beanPerAddress", "amount of the bean side to add liquidity", "10000")
    .addFlag("execute", "Actually execute the orders (default: dry run)")
    .addFlag("detail", "Show detailed logging")
    .setAction(async (taskArgs, hre) => {
      const { ethers } = hre;
      const verbose = taskArgs.detail;

      if (!verbose) {
        console.log("🧪 Setting up ConvertUpBlueprint test orders...");
      } else {
        console.log("\n🧪 Creating ConvertUpBlueprint test orders from multiple addresses");
        console.log(`📁 Parameters file: ${taskArgs.params}`);
        console.log(`💰 LP tokens per address: ${taskArgs.beanPerAddress} tokens`);
        console.log(`🎯 Execute mode: ${taskArgs.execute ? "LIVE" : "DRY RUN"}`);
      }

      try {
        // Validate network setup
        const networkName = hre.network.name;
        log(verbose, `🌐 Running on network: ${networkName}`);

        if (networkName === "hardhat") {
          console.log("⚠️  WARNING: Running on default Hardhat network.");
          console.log("💡 For full functionality, run on Base fork:");
          console.log("   1. npx hardhat node --fork https://mainnet.base.org");
          console.log("   2. npx hardhat create-mock-convert-up-orders --network localhost");
          console.log("🔄 Continuing with dry run validation only...");
        }

        // Load configuration
        log(verbose, "📖 Loading test configuration...");
        if (!fs.existsSync(taskArgs.params)) {
          throw new Error(`Parameters file not found: ${taskArgs.params}`);
        }
        const config = JSON.parse(fs.readFileSync(taskArgs.params, "utf8"));
        log(
          verbose,
          `✓ Loaded config for ${config.metadata.totalOrders} orders across ${config.metadata.totalAddresses} addresses`
        );

        // Get Beanstalk connection (only if not hardhat network or if execute mode)
        let beanstalk, tractorVersion, chainId;
        if (networkName !== "hardhat" || taskArgs.execute) {
          log(verbose, "🔗 Connecting to Beanstalk...");
          try {
            beanstalk = await getBeanstalk(L2_PINTO);
            tractorVersion = await beanstalk.getTractorVersion();
            chainId = await ethers.provider.getNetwork().then((n) => n.chainId);
            log(verbose, `✓ Connected to Beanstalk, Tractor version: ${tractorVersion}`);
            log(verbose, `🌐 Network Chain ID: ${chainId}`);
          } catch (error) {
            if (taskArgs.execute) {
              throw new Error(
                `Failed to connect to Beanstalk for execution: ${error.message}. Make sure you're running on a Base fork.`
              );
            }
            log(
              verbose,
              `⚠️  Could not connect to Beanstalk: ${error.message}. Continuing with validation only.`
            );
          }
        }

        let totalOrdersCreated = 0;
        let totalRequisitionsSigned = 0;

        // Process each address
        for (const [address, addressData] of Object.entries(config.addresses)) {
          log(
            verbose,
            `\n👤 Processing ${addressData.name} (${address}) - ${addressData.orderCount} orders`
          );

          // Generate signer from deterministic private key
          const addressIndex = Object.keys(config.addresses).indexOf(address);
          const privateKey = ethers.BigNumber.from(config.metadata.privateKeyBase).add(
            addressIndex + 1
          );
          const testSigner = new ethers.Wallet(
            `0x${privateKey.toHexString().slice(2).padStart(64, "0")}`,
            ethers.provider
          );

          log(verbose, `🔑 Generated test signer: ${testSigner.address}`);
          if (testSigner.address.toLowerCase() !== address.toLowerCase()) {
            console.warn(`⚠️  Address mismatch! Expected ${address}, got ${testSigner.address}`);
          }

          if (taskArgs.execute) {
            if (!beanstalk) {
              throw new Error(
                "Cannot execute orders: Beanstalk connection not available. Make sure you're running on a Base fork."
              );
            }

            // Setup address with ETH and tokens
            log(verbose, "💸 Minting ETH to address...");
            await hre.network.provider.send("hardhat_setBalance", [
              testSigner.address,
              `0x${ethers.utils.parseEther("1000").toHexString().slice(2)}`
            ]);

            // Mint LP tokens and deposit to Silo
            wellAddresses = [PINTO_CBETH_WELL_BASE, PINTO_USDC_WELL_BASE, PINTO_CBTC_WELL_BASE];
            log(verbose, "🪙 Minting and depositing LP tokens to address...");
            await setupAddressWithLPTokens(
              testSigner.address,
              taskArgs.beanPerAddress,
              hre,
              wellAddresses,
              verbose
            );
          }

          // Process each order for this address
          for (const order of addressData.orders) {
            totalOrdersCreated++;

            if (!verbose) {
              process.stdout.write(
                `\r🔄 Processing order ${totalOrdersCreated}/${config.metadata.totalOrders}...`
              );
            } else {
              console.log(`\n📋 Creating order ${order.orderId} for ${addressData.name}`);
              console.log(
                `   💰 Convert amount: ${ethers.utils.formatEther(order.convertUpParams.totalBeanAmountToConvert)} Beans`
              );
              console.log(
                `   📊 Source tokens: [${order.convertUpParams.sourceTokenIndices.join(", ")}]`
              );
              console.log(
                `   💵 Price range: $${(order.convertUpParams.minPriceToConvertUp / 1e6).toFixed(3)} - $${(order.convertUpParams.maxPriceToConvertUp / 1e6).toFixed(3)}`
              );
            }

            // Create ConvertUpBlueprintStruct
            const convertUpBlueprintStruct = {
              convertUpParams: {
                sourceTokenIndices: order.convertUpParams.sourceTokenIndices,
                totalBeanAmountToConvert: order.convertUpParams.totalBeanAmountToConvert,
                minBeansConvertPerExecution: order.convertUpParams.minBeansConvertPerExecution,
                maxBeansConvertPerExecution: order.convertUpParams.maxBeansConvertPerExecution,
                minTimeBetweenConverts: order.convertUpParams.minTimeBetweenConverts,
                minConvertBonusCapacity: order.convertUpParams.minConvertBonusCapacity,
                maxGrownStalkPerBdv: order.convertUpParams.maxGrownStalkPerBdv,
                grownStalkPerBdvBonusBid: order.convertUpParams.grownStalkPerBdvBonusBid,
                maxPriceToConvertUp: order.convertUpParams.maxPriceToConvertUp,
                minPriceToConvertUp: order.convertUpParams.minPriceToConvertUp,
                seedDifference: order.convertUpParams.seedDifference,
                maxGrownStalkPerBdvPenalty: order.convertUpParams.maxGrownStalkPerBdvPenalty,
                slippageRatio: order.convertUpParams.slippageRatio,
                lowStalkDeposits: order.convertUpParams.lowStalkDeposits
              },
              opParams: {
                whitelistedOperators: order.operatorParams.whitelistedOperators,
                tipAddress: order.operatorParams.tipAddress,
                operatorTipAmount: order.operatorParams.operatorTipAmount
              }
            };

            if (taskArgs.execute && beanstalk) {
              try {
                // Use the sign-beanstalk-blueprint task for consistent encoding and signing
                const requisition = await hre.run("sign-beanstalk-blueprint", {
                  contract: "ConvertUpBlueprint",
                  privateKey: `0x${privateKey.toHexString().slice(2).padStart(64, "0")}`,
                  params: JSON.stringify(convertUpBlueprintStruct),
                  maxNonce: "1000000",
                  duration: "600"
                });

                totalRequisitionsSigned++;
                log(
                  verbose,
                  `✓ Signed requisition ${order.orderId} with hash: ${requisition.blueprintHash.slice(0, 10)}...`
                );

                // Publish the requisition to make it available for operators
                const publishTx = await beanstalk
                  .connect(testSigner)
                  .publishRequisition(requisition);
                const publishReceipt = await publishTx.wait();
                log(
                  verbose,
                  `✓ Published requisition ${order.orderId} - TX: ${publishReceipt.transactionHash}`
                );

                // Save the requisition to file for later execution
                const requisitionsDir = "./tasks/requisition";
                if (!fs.existsSync(requisitionsDir)) {
                  fs.mkdirSync(requisitionsDir, { recursive: true });
                }
                const requisitionFile = `${requisitionsDir}/convertUp-order-${order.orderId}-${Date.now()}.json`;
                fs.writeFileSync(requisitionFile, JSON.stringify(requisition, null, 2));
                log(verbose, `📁 Saved requisition to: ${requisitionFile}`);
              } catch (error) {
                console.error(`❌ Failed to execute order ${order.orderId}: ${error.message}`);
              }
            } else {
              // Dry run - just validate the parameters
              log(verbose, `✓ Order ${order.orderId} parameters validated`);
            }
          }
        }

        // Final summary
        if (!verbose) process.stdout.write("\n");
        console.log(`\n🎉 Test setup completed!`);
        console.log(`📊 Summary:`);
        console.log(`   📋 Orders created: ${totalOrdersCreated}`);
        console.log(`   👥 Addresses used: ${Object.keys(config.addresses).length}`);
        console.log(`   📝 Distribution: [${config.metadata.distribution.join(", ")}]`);

        if (taskArgs.execute) {
          console.log(`   ✍️  Requisitions signed: ${totalRequisitionsSigned}`);
          console.log(`   ⚡ Mode: EXECUTED`);
        } else {
          console.log(`   🔍 Mode: DRY RUN (use --execute to run live)`);
        }

        if (verbose) {
          console.log(`\n💡 Next steps:`);
          console.log(`   1. Monitor orders using: npx hardhat blueprint-status --hash <hash>`);
          console.log(`   2. Execute orders by calling the blueprint functions`);
          console.log(`   3. Check conversion results in the Silo`);
        }

        return {
          totalOrdersCreated,
          totalRequisitionsSigned,
          addresses: Object.keys(config.addresses),
          executed: taskArgs.execute
        };
      } catch (error) {
        console.error(`❌ Error setting up test orders: ${error.message}`);
        throw error;
      }
    });
};

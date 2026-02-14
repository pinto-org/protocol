const { distributeBarnPaybackTokens } = require("./deployPaybackContracts.js");
const { getContractAddress, verifyDeployedAddresses } = require("./utils/addressCache.js");

/**
 * Initialize BarnPayback contract with fertilizer data
 * This is Step 1.6 of the Beanstalk Shipments deployment
 * Reads deployed BarnPayback address from cache or production and mints fertilizers
 *
 * @param {Object} params - Initialization parameters
 * @param {Object} params.account - Account to use for transactions
 * @param {boolean} params.verbose - Enable verbose logging
 * @param {number} params.startFromChunk - Resume from chunk number (0-indexed)
 * @param {number} params.targetEntriesPerChunk - Entries per chunk (default: 300)
 * @param {boolean} params.useDeployed - Use production addresses instead of dev addresses
 */
async function initializeBarnPayback({
  account,
  verbose = true,
  startFromChunk = 0,
  targetEntriesPerChunk = 300,
  useDeployed = false
}) {
  if (verbose) {
    console.log("\n📦 STEP 1.6: INITIALIZING BARN PAYBACK CONTRACT");
    console.log("-".repeat(50));
    if (useDeployed) {
      console.log("🏭 Using production addresses (--use-deployed)");
    }
  }

  // Verify deployed addresses exist
  if (!verifyDeployedAddresses(useDeployed)) {
    if (useDeployed) {
      throw new Error("Production addresses not found. Check productionAddresses.json.");
    } else {
      throw new Error("Deployed addresses not found. Run deployPaybackContracts first.");
    }
  }

  // Get BarnPayback address from cache or production
  const barnPaybackAddress = getContractAddress("barnPayback", useDeployed);
  if (!barnPaybackAddress) {
    throw new Error("BarnPayback address not found");
  }

  if (verbose) {
    console.log(`📍 BarnPayback address: ${barnPaybackAddress}`);
  }

  // Get contract instance
  const barnPaybackContract = await ethers.getContractAt("BarnPayback", barnPaybackAddress);

  // Distribute barn payback tokens (fertilizers)
  await distributeBarnPaybackTokens({
    barnPaybackContract,
    account,
    dataPath: "./scripts/beanstalkShipments/data/beanstalkAccountFertilizer.json",
    verbose,
    targetEntriesPerChunk,
    startFromChunk
  });

  if (verbose) {
    console.log("\n✅ BarnPayback initialization completed");
  }
}

module.exports = {
  initializeBarnPayback
};

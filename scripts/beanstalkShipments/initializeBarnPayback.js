const { distributeBarnPaybackTokens } = require("./deployPaybackContracts.js");
const { getContractAddress, verifyDeployedAddresses } = require("./utils/addressCache.js");

/**
 * Initialize BarnPayback contract with fertilizer data
 * This is Step 1.6 of the Beanstalk Shipments deployment
 * Reads deployed BarnPayback address from cache and mints fertilizers
 *
 * @param {Object} params - Initialization parameters
 * @param {Object} params.account - Account to use for transactions
 * @param {boolean} params.verbose - Enable verbose logging
 * @param {number} params.startFromChunk - Resume from chunk number (0-indexed)
 * @param {number} params.targetEntriesPerChunk - Entries per chunk (default: 300)
 */
async function initializeBarnPayback({
  account,
  verbose = true,
  startFromChunk = 0,
  targetEntriesPerChunk = 300
}) {
  if (verbose) {
    console.log("\n📦 STEP 1.6: INITIALIZING BARN PAYBACK CONTRACT");
    console.log("-".repeat(50));
  }

  // Verify deployed addresses exist
  if (!verifyDeployedAddresses()) {
    throw new Error("Deployed addresses not found. Run deployPaybackContracts first.");
  }

  // Get BarnPayback address from cache
  const barnPaybackAddress = getContractAddress("barnPayback");
  if (!barnPaybackAddress) {
    throw new Error("BarnPayback address not found in cache");
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

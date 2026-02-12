const { distributeUnripeBdvTokens } = require("./deployPaybackContracts.js");
const { getContractAddress, verifyDeployedAddresses } = require("./utils/addressCache.js");

/**
 * Initialize SiloPayback contract with unripe BDV data
 * This is Step 1.5 of the Beanstalk Shipments deployment
 * Reads deployed SiloPayback address from cache and batch mints unripe BDV tokens
 *
 * @param {Object} params - Initialization parameters
 * @param {Object} params.account - Account to use for transactions
 * @param {boolean} params.verbose - Enable verbose logging
 * @param {number} params.startFromChunk - Resume from chunk number (0-indexed)
 * @param {number} params.targetEntriesPerChunk - Entries per chunk (default: 300)
 */
async function initializeSiloPayback({
  account,
  verbose = true,
  startFromChunk = 0,
  targetEntriesPerChunk = 300
}) {
  if (verbose) {
    console.log("\n📦 STEP 1.5: INITIALIZING SILO PAYBACK CONTRACT");
    console.log("-".repeat(50));
  }

  // Verify deployed addresses exist
  if (!verifyDeployedAddresses()) {
    throw new Error("Deployed addresses not found. Run deployPaybackContracts first.");
  }

  // Get SiloPayback address from cache
  const siloPaybackAddress = getContractAddress("siloPayback");
  if (!siloPaybackAddress) {
    throw new Error("SiloPayback address not found in cache");
  }

  if (verbose) {
    console.log(`📍 SiloPayback address: ${siloPaybackAddress}`);
  }

  // Get contract instance
  const siloPaybackContract = await ethers.getContractAt("SiloPayback", siloPaybackAddress);

  // Distribute unripe BDV tokens
  await distributeUnripeBdvTokens({
    siloPaybackContract,
    account,
    dataPath: "./scripts/beanstalkShipments/data/unripeBdvTokens.json",
    verbose,
    useChunking: true,
    targetEntriesPerChunk,
    startFromChunk
  });

  if (verbose) {
    console.log("\n✅ SiloPayback initialization completed");
  }
}

module.exports = {
  initializeSiloPayback
};

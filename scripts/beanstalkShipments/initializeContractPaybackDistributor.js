const { distributeContractAccountData } = require("./deployPaybackContracts.js");
const { getContractAddress, verifyDeployedAddresses } = require("./utils/addressCache.js");

/**
 * Initialize ContractPaybackDistributor contract with account data
 * This is Step 1.7 of the Beanstalk Shipments deployment
 * Reads deployed ContractPaybackDistributor address from cache and initializes account data
 *
 * @param {Object} params - Initialization parameters
 * @param {Object} params.account - Account to use for transactions
 * @param {boolean} params.verbose - Enable verbose logging
 * @param {number} params.startFromChunk - Resume from chunk number (0-indexed)
 * @param {number} params.targetEntriesPerChunk - Entries per chunk (default: 25)
 */
async function initializeContractPaybackDistributor({
  account,
  verbose = true,
  startFromChunk = 0,
  targetEntriesPerChunk = 25
}) {
  if (verbose) {
    console.log("\n📦 STEP 1.7: INITIALIZING CONTRACT PAYBACK DISTRIBUTOR");
    console.log("-".repeat(50));
  }

  // Verify deployed addresses exist
  if (!verifyDeployedAddresses()) {
    throw new Error("Deployed addresses not found. Run deployPaybackContracts first.");
  }

  // Get ContractPaybackDistributor address from cache
  const contractPaybackDistributorAddress = getContractAddress("contractPaybackDistributor");
  if (!contractPaybackDistributorAddress) {
    throw new Error("ContractPaybackDistributor address not found in cache");
  }

  if (verbose) {
    console.log(`📍 ContractPaybackDistributor address: ${contractPaybackDistributorAddress}`);
  }

  // Get contract instance
  const contractPaybackDistributorContract = await ethers.getContractAt(
    "ContractPaybackDistributor",
    contractPaybackDistributorAddress
  );

  // Distribute contract account data
  await distributeContractAccountData({
    contractPaybackDistributorContract,
    account,
    verbose,
    targetEntriesPerChunk,
    startFromChunk
  });

  if (verbose) {
    console.log("\n✅ ContractPaybackDistributor initialization completed");
  }
}

module.exports = {
  initializeContractPaybackDistributor
};

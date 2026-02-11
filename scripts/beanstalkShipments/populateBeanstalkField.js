const fs = require("fs");
const {
  splitEntriesIntoChunksOptimized,
  splitWhaleAccounts,
  updateProgress,
  retryOperation,
  verifyTransaction
} = require("../../utils/read.js");

// EIP-7987 tx gas limit is 16,777,216 (2^24)
// ~70,600 gas per plot, with 65% safety margin: floor(16,777,216 * 0.65 / 70,600) = ~150
const MAX_PLOTS_PER_ACCOUNT_PER_TX = 150;

/**
 * Populates the beanstalk field by reading data from beanstalkPlots.json
 * and calling initializeRepaymentPlots directly on the L2_PINTO contract
 * @param {Object} options - Configuration options
 * @param {string} options.diamondAddress - The diamond contract address
 * @param {Object} options.account - The signer account
 * @param {boolean} options.verbose - Whether to log verbose output
 * @param {number} options.startFromChunk - Chunk index to resume from (0-indexed)
 */
async function populateBeanstalkField({ diamondAddress, account, verbose, startFromChunk = 0 }) {
  console.log("populateBeanstalkField: Re-initialize the field with Beanstalk plots.");

  // Read and parse the JSON file
  const plotsPath = "./scripts/beanstalkShipments/data/beanstalkPlots.json";
  const rawPlotData = JSON.parse(fs.readFileSync(plotsPath));

  // Split whale accounts to fit within EIP-7987 gas limit
  const splitData = splitWhaleAccounts(rawPlotData, MAX_PLOTS_PER_ACCOUNT_PER_TX);
  if (splitData.length !== rawPlotData.length) {
    console.log(`Split ${rawPlotData.length} accounts into ${splitData.length} entries (whale accounts divided)`);
  }

  // Split into chunks for processing
  const targetEntriesPerChunk = 300;
  const plotChunks = splitEntriesIntoChunksOptimized(splitData, targetEntriesPerChunk);
  console.log(`Starting to process ${plotChunks.length} chunks...`);

  if (startFromChunk > 0) {
    console.log(`⏩ Resuming from chunk ${startFromChunk + 1}/${plotChunks.length}`);
  }

  // Get contract instance for TempRepaymentFieldFacet
  const pintoDiamond = await ethers.getContractAt(
    "TempRepaymentFieldFacet",
    diamondAddress,
    account
  );

  for (let i = startFromChunk; i < plotChunks.length; i++) {
    await updateProgress(i + 1, plotChunks.length);
    if (verbose) {
      console.log(`\n🔄 Processing chunk ${i + 1}/${plotChunks.length}`);
      console.log(`Chunk contains ${plotChunks[i].length} accounts`);
      console.log("-----------------------------------");
    }

    try {
      await retryOperation(
        async () => {
          const tx = await pintoDiamond.initializeRepaymentPlots(plotChunks[i]);
          const receipt = await verifyTransaction(tx, `Repayment plots chunk ${i + 1}`);
          if (verbose) {
            console.log(`⛽ Gas used: ${receipt.gasUsed.toString()}`);
            console.log(`📋 Transaction hash: ${receipt.transactionHash}`);
          }
        },
        { context: `Chunk ${i + 1}/${plotChunks.length}` }
      );
    } catch (error) {
      console.error(`\n❌ FAILED AT CHUNK ${i + 1}/${plotChunks.length}`);
      console.error(`To resume, use: --field-start-chunk ${i}`);
      throw error;
    }

    if (verbose) {
      console.log(`Completed chunk ${i + 1}/${plotChunks.length}`);
    }
  }

  console.log("✅ Successfully populated Beanstalk field with all plots!");
}

module.exports = {
  populateBeanstalkField
};

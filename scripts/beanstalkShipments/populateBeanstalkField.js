const fs = require("fs");
const {
  splitEntriesIntoChunksOptimized,
  updateProgress,
  retryOperation
} = require("../../utils/read.js");

/**
 * Populates the beanstalk field by reading data from beanstalkPlots.json
 * and calling initializeReplaymentPlots directly on the L2_PINTO contract
 */
async function populateBeanstalkField({ diamondAddress, account, verbose }) {
  console.log("populateBeanstalkField: Re-initialize the field with Beanstalk plots.");

  // Read and parse the JSON file
  const plotsPath = "./scripts/beanstalkShipments/data/beanstalkPlots.json";
  const rawPlotData = JSON.parse(fs.readFileSync(plotsPath));

  // Split into chunks for processing
  const targetEntriesPerChunk = 300;
  const plotChunks = splitEntriesIntoChunksOptimized(rawPlotData, targetEntriesPerChunk);
  console.log(`Starting to process ${plotChunks.length} chunks...`);

  // Get contract instance for TempRepaymentFieldFacet
  const pintoDiamond = await ethers.getContractAt(
    "TempRepaymentFieldFacet",
    diamondAddress,
    account
  );

  for (let i = 0; i < plotChunks.length; i++) {
    await updateProgress(i + 1, plotChunks.length);
    if (verbose) {
      console.log(`\n🔄 Processing chunk ${i + 1}/${plotChunks.length}`);
      console.log(`Chunk contains ${plotChunks[i].length} accounts`);
      console.log("-----------------------------------");
    }
    await retryOperation(async () => {
      const tx = await pintoDiamond.initializeReplaymentPlots(plotChunks[i]);
      const receipt = await tx.wait();
      if (verbose) {
        console.log(`⛽ Gas used: ${receipt.gasUsed.toString()}`);
        console.log(`📋 Transaction hash: ${receipt.transactionHash}`);
      }
    });
    if (verbose) {
      console.log(`Completed chunk ${i + 1}/${plotChunks.length}`);
    }
  }

  console.log("✅ Successfully populated Beanstalk field with all plots!");
}

module.exports = {
  populateBeanstalkField
};

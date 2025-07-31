const { upgradeWithNewFacets } = require("../diamond.js");
const fs = require("fs");
const { splitEntriesIntoChunksOptimized, updateProgress, retryOperation } = require("../../utils/read.js");

/**
 * Populates the beanstalk field by reading data from beanstalkPlots.json
 * and calling diamond upgrade with InitReplaymentField init script
 * @param diamondAddress - The address of the diamond contract
 * @param account - The account to use for the transaction
 * @param verbose - Whether to log verbose output
 */
async function populateBeanstalkField(diamondAddress, account, verbose = false) {
  console.log("-----------------------------------");
  console.log("populateBeanstalkField: Re-initialize the field with Beanstalk plots.\n");

  // Read and parse the JSON file
  const plotsPath = "./scripts/beanstalkShipments/data/beanstalkPlots.json";
  const rawPlotData = JSON.parse(fs.readFileSync(plotsPath));

  // Split into chunks for processing
  const targetEntriesPerChunk = 300;
  const plotChunks = splitEntriesIntoChunksOptimized(rawPlotData, targetEntriesPerChunk);
  console.log(`Starting to process ${plotChunks.length} chunks...`);

  for (let i = 0; i < plotChunks.length; i++) {
    await updateProgress(i + 1, plotChunks.length);
    if (verbose) {
      console.log(`Processing chunk ${i + 1}/${plotChunks.length}`);
      console.log(`Chunk contains ${plotChunks[i].length} accounts`);
      console.log("-----------------------------------");
    }

    await retryOperation(async () => {
      await upgradeWithNewFacets({
        diamondAddress: diamondAddress,
        facetNames: [], // No new facets to deploy
        initFacetName: "InitReplaymentField",
        initArgs: [plotChunks[i]], // Pass the chunk as ReplaymentPlotData[]
        verbose: verbose,
        account: account
      });
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
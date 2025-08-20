const { upgradeWithNewFacets } = require("../diamond.js");
const fs = require("fs");
const {
  splitEntriesIntoChunksOptimized,
  updateProgress,
  retryOperation
} = require("../../utils/read.js");

/**
 * Populates the beanstalk field by reading data from beanstalkPlots.json
 * and calling diamond upgrade with InitReplaymentField init script
 * @param {string} diamondAddress - The address of the diamond contract
 * @param {Object} account - The account to use for the transaction
 * @param {boolean} verbose - Whether to log verbose output
 */
async function populateBeanstalkField(diamondAddress, account, verbose = false, mockData = false) {
  console.log("populateBeanstalkField: Re-initialize the field with Beanstalk plots.");

  // Read and parse the JSON file
  const plotsPath = mockData
    ? "./scripts/beanstalkShipments/data/mocks/mockBeanstalkPlots.json"
    : "./scripts/beanstalkShipments/data/beanstalkPlots.json";
  const rawPlotData = JSON.parse(fs.readFileSync(plotsPath));

  // Split into chunks for processing
  const targetEntriesPerChunk = 800;
  const plotChunks = splitEntriesIntoChunksOptimized(rawPlotData, targetEntriesPerChunk);
  console.log(`Starting to process ${plotChunks.length} chunks...`);

  // Deploy the standalone InitReplaymentField contract using ethers
  const initReplaymentFieldFactory = await ethers.getContractFactory("InitReplaymentField", account);
  const initReplaymentField = await initReplaymentFieldFactory.deploy();
  await initReplaymentField.deployed();
  console.log("✅ InitReplaymentField deployed to:", initReplaymentField.address);

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
        initFacetAddress: initReplaymentField.address, // Re-use the same contract for all chunks
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

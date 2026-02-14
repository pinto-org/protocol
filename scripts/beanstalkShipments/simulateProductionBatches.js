const fs = require("fs");
const { ethers } = require("hardhat");
const { splitEntriesIntoChunksOptimized, splitWhaleAccounts } = require("../../utils/read.js");

/**
 * Production Batch Gas Simulation
 *
 * Simulates gas usage for TempRepaymentFieldFacet.initializeRepaymentPlots()
 * using real production data from beanstalkPlots.json.
 *
 * Validates that all chunks fit within EIP-7987 transaction gas limit (2^24).
 *
 * Run: npx hardhat run scripts/beanstalkShipments/simulateProductionBatches.js
 */

const CONFIG = {
  EIP_7987_TX_GAS_LIMIT: 16_777_216, // 2^24
  SAFE_GAS_MARGIN: 0.65,
  MAX_PLOTS_PER_ACCOUNT_PER_TX: 150, // ~10.6M gas, safely under EIP-7987 limit
  TARGET_ENTRIES_PER_CHUNK: 300,
  PLOTS_DATA_PATH: "./scripts/beanstalkShipments/data/beanstalkPlots.json"
};

async function main() {
  console.log("=".repeat(80));
  console.log("PRODUCTION BATCH GAS SIMULATION");
  console.log("=".repeat(80));
  console.log();

  console.log("1. Loading data...");
  const rawPlotData = JSON.parse(fs.readFileSync(CONFIG.PLOTS_DATA_PATH));
  const totalAccounts = rawPlotData.length;
  const totalPlots = rawPlotData.reduce((sum, u) => sum + u[1].length, 0);
  console.log(`   Total accounts: ${totalAccounts}`);
  console.log(`   Total plots: ${totalPlots}`);
  console.log();

  console.log("2. Splitting whale accounts...");
  const splitData = splitWhaleAccounts(rawPlotData, CONFIG.MAX_PLOTS_PER_ACCOUNT_PER_TX);
  console.log(`   Entries after split: ${splitData.length}`);
  if (splitData.length !== totalAccounts) {
    console.log(`   Whale accounts split: ${splitData.length - totalAccounts} additional entries`);
  }
  console.log();

  console.log("3. Creating chunks...");
  const chunks = splitEntriesIntoChunksOptimized(splitData, CONFIG.TARGET_ENTRIES_PER_CHUNK);
  console.log(`   Chunks created: ${chunks.length}`);
  console.log();

  console.log("4. Deploying contract...");
  const REPAYMENT_FIELD_POPULATOR = "0xc4c66c8b199443a8deA5939ce175C3592e349791";
  const Contract = await ethers.getContractFactory("TempRepaymentFieldFacet");
  const deployedContract = await Contract.deploy();
  await deployedContract.deployed();

  // Impersonate the populator address and fund it for gas
  await ethers.provider.send("hardhat_impersonateAccount", [REPAYMENT_FIELD_POPULATOR]);
  await ethers.provider.send("hardhat_setBalance", [REPAYMENT_FIELD_POPULATOR, "0x56BC75E2D63100000"]); // 100 ETH
  const populatorSigner = await ethers.getSigner(REPAYMENT_FIELD_POPULATOR);
  const testContract = deployedContract.connect(populatorSigner);

  console.log(`   Contract: ${deployedContract.address}`);
  console.log(`   Populator: ${REPAYMENT_FIELD_POPULATOR}`);
  console.log();

  console.log("5. Running chunk simulations...");
  console.log("-".repeat(80));
  console.log(`${"Chunk".padEnd(8)} ${"Accounts".padEnd(10)} ${"Plots".padEnd(8)} ${"Est. Gas".padEnd(15)} ${"Status"}`);
  console.log("-".repeat(80));

  const results = [];
  const failedChunks = [];
  const warningChunks = [];
  const safeLimit = Math.floor(CONFIG.EIP_7987_TX_GAS_LIMIT * CONFIG.SAFE_GAS_MARGIN);

  for (let i = 0; i < chunks.length; i++) {
    const chunk = chunks[i];
    const chunkAccounts = chunk.length;
    const chunkPlots = chunk.reduce((sum, u) => sum + u[1].length, 0);

    let estimatedGas;
    let status;
    let error = null;

    try {
      estimatedGas = await testContract.estimateGas.initializeRepaymentPlots(chunk);
      estimatedGas = estimatedGas.toNumber();

      if (estimatedGas > CONFIG.EIP_7987_TX_GAS_LIMIT) {
        status = "FAIL";
        failedChunks.push({ chunk: i + 1, accounts: chunkAccounts, plots: chunkPlots, gas: estimatedGas });
      } else if (estimatedGas > safeLimit) {
        status = "WARN";
        warningChunks.push({ chunk: i + 1, accounts: chunkAccounts, plots: chunkPlots, gas: estimatedGas });
      } else {
        status = "OK";
      }
    } catch (err) {
      estimatedGas = -1;
      status = "ERROR";
      error = err.message;
      failedChunks.push({ chunk: i + 1, accounts: chunkAccounts, plots: chunkPlots, gas: -1, error: err.message });
    }

    let statusStr;
    if (status === "FAIL") statusStr = "EXCEEDS LIMIT";
    else if (status === "WARN") statusStr = "NEAR LIMIT";
    else if (status === "ERROR") statusStr = "ERROR";
    else statusStr = "OK";

    const gasStr = estimatedGas > 0 ? estimatedGas.toLocaleString() : "N/A";
    console.log(
      `${(i + 1).toString().padEnd(8)} ` +
      `${chunkAccounts.toString().padEnd(10)} ` +
      `${chunkPlots.toString().padEnd(8)} ` +
      `${gasStr.padEnd(15)} ` +
      `${statusStr}`
    );

    results.push({
      chunk: i + 1,
      accounts: chunkAccounts,
      plots: chunkPlots,
      estimatedGas,
      status,
      error,
      users: chunk.map(u => ({ address: u[0], plots: u[1].length }))
    });
  }

  console.log("-".repeat(80));
  console.log();

  console.log("=".repeat(80));
  console.log("SUMMARY");
  console.log("=".repeat(80));
  console.log();

  const totalGas = results.reduce((sum, r) => sum + (r.estimatedGas > 0 ? r.estimatedGas : 0), 0);
  const okChunks = results.filter(r => r.status === "OK").length;

  console.log(`Total chunks: ${chunks.length}`);
  console.log(`Total estimated gas: ${totalGas.toLocaleString()}`);
  console.log();
  console.log(`EIP-7987 Limit: ${CONFIG.EIP_7987_TX_GAS_LIMIT.toLocaleString()} gas`);
  console.log(`Safe Limit (95%): ${safeLimit.toLocaleString()} gas`);
  console.log();
  console.log(`Passing: ${okChunks}`);
  console.log(`Near limit: ${warningChunks.length}`);
  console.log(`Failed: ${failedChunks.length}`);
  console.log();

  if (failedChunks.length > 0) {
    console.log("FAILED CHUNKS:");
    console.log("-".repeat(60));
    for (const c of failedChunks) {
      console.log(`\nChunk ${c.chunk}:`);
      console.log(`  Accounts: ${c.accounts}, Plots: ${c.plots}`);
      if (c.gas > 0) {
        console.log(`  Gas: ${c.gas.toLocaleString()}`);
      }
      if (c.error) {
        console.log(`  Error: ${c.error}`);
      }
      const chunkData = results.find(r => r.chunk === c.chunk);
      if (chunkData && chunkData.users) {
        console.log(`  Addresses:`);
        for (const user of chunkData.users) {
          console.log(`    ${user.address}: ${user.plots} plots`);
        }
      }
    }
  }

  if (warningChunks.length > 0) {
    console.log();
    console.log("CHUNKS NEAR LIMIT:");
    console.log("-".repeat(60));
    for (const c of warningChunks) {
      const pct = ((c.gas / CONFIG.EIP_7987_TX_GAS_LIMIT) * 100).toFixed(1);
      console.log(`Chunk ${c.chunk}: ${c.accounts} accounts, ${c.plots} plots, ${c.gas.toLocaleString()} gas (${pct}%)`);
    }
  }

  console.log();
  console.log("Done.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

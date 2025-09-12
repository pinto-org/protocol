const { BigNumber } = require("ethers");
const { ethers } = require("ethers");

async function readPrune() {
  // function initially read from C.sol to find INITIAL_HAIRCUT.
  // This function is not used in the protocol anymore, and is hard coded here
  // instead of reading from the contract.
  return BigNumber.from("185564685220298701");
}

function convertToBigNum(value) {
  // if the value is in scientific notation and not hex
  if (value.includes("e") && !value.startsWith("0x")) {
    // if the value is a decimal in scientific notation
    if (value.includes(".")) {
      const [base, exponent] = value.split("e");
      const bigNumNotation = ethers.utils.parseUnits(base, exponent);
      return bigNumNotation.toString();
    }
    // if the value is an integer in scientific notation
    const [base, exponent] = value.split("e");
    const bigNumNotation = BigNumber.from(base).mul(BigNumber.from(10).pow(exponent));
    return bigNumNotation.toString();
  }
  return BigNumber.from(value).toString();
}

function splitEntriesIntoChunks(data, targetEntriesPerChunk) {
  const chunks = [];
  let currentChunk = [];
  let currentChunkEntries = 0;

  for (const item of data) {
    const itemEntries = countEntries(item);

    if (currentChunkEntries + itemEntries > targetEntriesPerChunk && currentChunk.length > 0) {
      // This item would exceed the target, so start a new chunk
      chunks.push(currentChunk);
      currentChunk = [];
      currentChunkEntries = 0;
    }

    currentChunk.push(item);
    currentChunkEntries += itemEntries;
  }

  // Add any remaining entries to the last chunk
  if (currentChunk.length > 0) {
    chunks.push(currentChunk);
  }

  return chunks;
}

function splitIntoExactChunks(data, numberOfChunks) {
  if (numberOfChunks <= 0) {
    throw new Error("Number of chunks must be greater than 0");
  }

  if (numberOfChunks >= data.length) {
    // If we want more chunks than items, return each item as its own chunk
    return data.map((item) => [item]);
  }

  const chunks = [];
  const itemsPerChunk = Math.ceil(data.length / numberOfChunks);

  for (let i = 0; i < data.length; i += itemsPerChunk) {
    chunks.push(data.slice(i, i + itemsPerChunk));
  }

  return chunks;
}

// Count entries recursively
function countEntries(item) {
  if (Array.isArray(item)) {
    return item.reduce((sum, subItem) => sum + countEntries(subItem), 0);
  } else {
    return 1;
  }
}

// in the EVM, setting a zero value to a non-zero value costs 20,000 gas.
// assuming a transaction gas target of 20m, this means that we can fit
// 1000 storage changes in a single transaction. In practice, we aim for a conservative
// 800 storage slots to account for logic.
function splitEntriesIntoChunksOptimized(data, targetEntriesPerChunk) {
  const chunks = [];
  let currentChunk = [];
  let currentChunkEntries = 0;

  for (const item of data) {
    const itemEntries = countEntries(item);

    if (currentChunkEntries + itemEntries > targetEntriesPerChunk && currentChunk.length > 0) {
      // This item would exceed the target, so start a new chunk
      chunks.push(currentChunk);
      currentChunk = [];
      currentChunkEntries = 0;
    }

    currentChunk.push(item);
    currentChunkEntries += itemEntries;
  }

  // Add any remaining entries to the last chunk
  if (currentChunk.length > 0) {
    chunks.push(currentChunk);
  }

  return chunks;
}

async function updateProgress(current, total) {
  const percentage = Math.round((current / total) * 100);
  const progressBarLength = 30;
  let filledLength = Math.round((progressBarLength * current) / total);
  if (filledLength > progressBarLength) filledLength = progressBarLength;
  const progressBar = "█".repeat(filledLength) + "░".repeat(progressBarLength - filledLength);

  console.log(`Processing: [${progressBar}] ${percentage}% | Chunk ${current}/${total}`);
}

const MAX_RETRIES = 20;
const RETRY_DELAY = 500; // 0.5 seconds

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function retryOperation(operation, retries = MAX_RETRIES) {
  try {
    return await operation();
  } catch (error) {
    if (retries > 0 && error.message.includes("Internal server error")) {
      console.log(
        `RPC error encountered. Retrying in ${RETRY_DELAY / 1000} seconds... (${retries} attempts left)`
      );
      await sleep(RETRY_DELAY);
      return retryOperation(operation, retries - 1);
    }
    throw error;
  }
}

exports.readPrune = readPrune;
exports.splitEntriesIntoChunks = splitEntriesIntoChunks;
exports.splitIntoExactChunks = splitIntoExactChunks;
exports.splitEntriesIntoChunksOptimized = splitEntriesIntoChunksOptimized;
exports.updateProgress = updateProgress;
exports.convertToBigNum = convertToBigNum;
exports.retryOperation = retryOperation;

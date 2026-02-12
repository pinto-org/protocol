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

/**
 * Splits accounts with too many plots into multiple entries.
 * This allows whale accounts to be processed across multiple transactions.
 * @param {Array} plotData - Array of [address, [[plotId, amount], ...]]
 * @param {number} maxPlotsPerEntry - Maximum plots per entry (default: 200)
 * @returns {Array} - Flattened array with whale accounts split
 */
function splitWhaleAccounts(plotData, maxPlotsPerEntry = 200) {
  const result = [];

  for (const [address, plots] of plotData) {
    if (plots.length <= maxPlotsPerEntry) {
      result.push([address, plots]);
    } else {
      // Split into chunks of maxPlotsPerEntry
      for (let i = 0; i < plots.length; i += maxPlotsPerEntry) {
        const plotChunk = plots.slice(i, i + maxPlotsPerEntry);
        result.push([address, plotChunk]);
      }
    }
  }

  return result;
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
const BASE_RETRY_DELAY = 500; // 0.5 seconds base delay
const MAX_RETRY_DELAY = 30000; // 30 seconds max delay
const CHUNK_DELAY = 100; // 100ms delay between chunks to avoid rate limiting

// Common RPC error patterns that warrant a retry
const RETRYABLE_ERRORS = [
  "Internal server error",
  "429",
  "too many requests",
  "rate limit",
  "timeout",
  "ETIMEDOUT",
  "ESOCKETTIMEDOUT",
  "ECONNRESET",
  "ECONNREFUSED",
  "network error",
  "header not found",
  "missing trie node",
  "request failed",
  "transaction underpriced",
  "replacement transaction underpriced",
  "nonce too low",
  "already known"
];

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Checks if an error message contains any retryable error patterns
 * @param {string} errorMessage - The error message to check
 * @returns {boolean} - True if the error is retryable
 */
function isRetryableError(errorMessage) {
  const lowerMessage = errorMessage.toLowerCase();
  return RETRYABLE_ERRORS.some((pattern) => lowerMessage.includes(pattern.toLowerCase()));
}

/**
 * Calculates exponential backoff delay with jitter
 * @param {number} attempt - Current attempt number (0-indexed)
 * @returns {number} - Delay in milliseconds
 */
function calculateBackoffDelay(attempt) {
  // Exponential backoff: base * 2^attempt
  const exponentialDelay = BASE_RETRY_DELAY * Math.pow(2, attempt);
  // Add random jitter (0-25% of delay)
  const jitter = Math.random() * exponentialDelay * 0.25;
  // Cap at max delay
  return Math.min(exponentialDelay + jitter, MAX_RETRY_DELAY);
}

/**
 * Retries an operation with exponential backoff on RPC errors
 * @param {Function} operation - Async function to execute
 * @param {Object} options - Options object
 * @param {number} options.retries - Maximum number of retries (default: MAX_RETRIES)
 * @param {string} options.context - Context string for error messages (e.g., "Chunk 5/10")
 * @returns {Promise<any>} - Result of the operation
 */
async function retryOperation(operation, options = {}) {
  const { retries = MAX_RETRIES, context = "" } = options;
  const maxAttempts = retries + 1;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await operation();
    } catch (error) {
      const isLastAttempt = attempt === maxAttempts - 1;
      const isRetryable = isRetryableError(error.message);

      if (isLastAttempt || !isRetryable) {
        // Final attempt or non-retryable error - throw with context
        const contextPrefix = context ? `${context}: ` : "";
        error.message = `${contextPrefix}${error.message}`;
        throw error;
      }

      // Calculate delay with exponential backoff
      const delay = calculateBackoffDelay(attempt);
      const retriesLeft = maxAttempts - attempt - 1;

      console.log(
        `⚠️  RPC error encountered${context ? ` (${context})` : ""}. ` +
          `Retrying in ${(delay / 1000).toFixed(1)}s... (${retriesLeft} attempts left)`
      );
      console.log(`   Error: ${error.message.substring(0, 100)}${error.message.length > 100 ? "..." : ""}`);

      await sleep(delay);
    }
  }
}

/**
 * Verifies a transaction completed successfully by checking receipt status
 * @param {Object} tx - Transaction object from contract call
 * @param {string} description - Description for error messages (e.g., "Barn payback chunk 5")
 * @returns {Promise<Object>} - Transaction receipt
 * @throws {Error} - If transaction reverted (status !== 1)
 */
async function verifyTransaction(tx, description = "Transaction") {
  const receipt = await tx.wait();
  if (receipt.status !== 1) {
    throw new Error(`${description} reverted. Hash: ${receipt.transactionHash}`);
  }
  return receipt;
}

exports.readPrune = readPrune;
exports.splitEntriesIntoChunks = splitEntriesIntoChunks;
exports.splitIntoExactChunks = splitIntoExactChunks;
exports.splitEntriesIntoChunksOptimized = splitEntriesIntoChunksOptimized;
exports.splitWhaleAccounts = splitWhaleAccounts;
exports.updateProgress = updateProgress;
exports.convertToBigNum = convertToBigNum;
exports.retryOperation = retryOperation;
exports.verifyTransaction = verifyTransaction;
exports.sleep = sleep;
exports.CHUNK_DELAY = CHUNK_DELAY;

const { ethers } = require("ethers");
const { Worker } = require("worker_threads");
const os = require("os");
const path = require("path");

/**
 * Mine a CREATE2 salt for a vanity proxy address using worker threads
 *
 * @param {Object} params - Mining parameters
 * @param {string} params.implementationAddress - Address of the well implementation
 * @param {string} params.initCalldata - Encoded initialization call (e.g., init(name, symbol))
 * @param {string} params.createXAddress - CreateX factory address
 * @param {string} params.prefix - Desired address prefix (without 0x, e.g., "BEEF" or "dead")
 * @param {number} [params.numWorkers] - Number of worker threads (default: CPU cores)
 * @param {boolean} [params.caseSensitive=false] - Whether prefix matching is case-sensitive
 * @param {Function} [params.onProgress] - Callback for progress updates
 * @returns {Promise<Object>} {salt: string, address: string, iterations: number} or null if not found
 */
async function mineProxySaltMultiThreaded({
  implementationAddress,
  initCalldata,
  createXAddress,
  prefix,
  numWorkers = os.cpus().length,
  caseSensitive = false,
  onProgress = null
}) {
  // Validate inputs
  if (!ethers.utils.isAddress(implementationAddress)) {
    throw new Error("Invalid implementation address");
  }
  if (!ethers.utils.isAddress(createXAddress)) {
    throw new Error("Invalid CreateX address");
  }
  if (!prefix || prefix.length === 0) {
    throw new Error("Prefix cannot be empty");
  }

  // Remove 0x prefix if present
  const prefixWithoutOx = prefix.replace(/^0x/, "");

  // Validate hex prefix
  if (!/^[0-9a-f]+$/i.test(prefixWithoutOx)) {
    throw new Error("Prefix must be valid hex characters");
  }

  // Get ERC1967Proxy bytecode
  const ERC1967ProxyArtifact = require("../artifacts/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol/ERC1967Proxy.json");
  const proxyBytecode = ERC1967ProxyArtifact.bytecode;

  // Encode constructor arguments
  const constructorArgs = ethers.utils.defaultAbiCoder.encode(
    ["address", "bytes"],
    [implementationAddress, initCalldata]
  );

  // Build init code
  const initCode = ethers.utils.solidityPack(["bytes", "bytes"], [proxyBytecode, constructorArgs]);
  const initCodeHash = ethers.utils.keccak256(initCode);

  console.log(`\n🔍 Mining for CREATE2 proxy address with prefix: 0x${prefixWithoutOx}`);
  console.log(`   Implementation: ${implementationAddress}`);
  console.log(`   CreateX: ${createXAddress}`);
  console.log(`   Workers: ${numWorkers} threads`);
  console.log(`   Case sensitive: ${caseSensitive}`);
  console.log(`   Press Ctrl+C to exit cleanly\n`);

  const startTime = Date.now();
  const workers = [];
  let found = false;
  let result = null;
  let totalIterations = 0;
  const workerStats = new Map();

  // Create workers
  const workerPath = path.join(__dirname, "mineProxySaltWorker.js");
  for (let i = 0; i < numWorkers; i++) {
    const worker = new Worker(workerPath, {
      workerData: {
        createXAddress,
        initCodeHash,
        prefix: prefixWithoutOx,
        caseSensitive,
        workerId: i
      }
    });

    workerStats.set(i, { iterations: 0, rate: 0 });

    worker.on("message", (msg) => {
      if (msg.type === "found" && !found) {
        found = true;
        result = {
          salt: msg.salt,
          address: msg.address,
          iterations: totalIterations + msg.iterations,
          workerId: msg.workerId
        };

        // Stop all workers
        workers.forEach((w) => w.postMessage("stop"));
      } else if (msg.type === "progress") {
        workerStats.set(msg.workerId, {
          iterations: msg.iterations,
          rate: msg.rate
        });

        // Aggregate and report progress
        if (onProgress) {
          totalIterations = Array.from(workerStats.values()).reduce(
            (sum, stat) => sum + stat.iterations,
            0
          );
          const totalRate = Array.from(workerStats.values()).reduce((sum, stat) => sum + stat.rate, 0);
          const elapsed = (Date.now() - startTime) / 1000;
          onProgress({
            iterations: totalIterations,
            elapsed,
            rate: totalRate
          });
        }
      } else if (msg.type === "stopped") {
        workerStats.set(msg.workerId, {
          iterations: msg.iterations,
          rate: 0
        });
      }
    });

    worker.on("error", (err) => {
      console.error(`Worker ${i} error:`, err);
    });

    workers.push(worker);
  }

  // Handle Ctrl+C
  let interrupted = false;
  const handleInterrupt = () => {
    if (!interrupted) {
      interrupted = true;
      console.log("\n\n⏸️  Mining interrupted by user...");
      workers.forEach((w) => w.postMessage("stop"));
    }
  };
  process.on("SIGINT", handleInterrupt);

  // Wait for all workers to finish
  await Promise.all(workers.map((w) => new Promise((resolve) => w.on("exit", resolve))));

  // Remove interrupt handler
  process.off("SIGINT", handleInterrupt);

  const endTime = Date.now();
  const totalTime = (endTime - startTime) / 1000;

  // Calculate final stats
  totalIterations = Array.from(workerStats.values()).reduce((sum, stat) => sum + stat.iterations, 0);

  if (found && result) {
    console.log(`\n✅ Found matching address!`);
    console.log(`   Salt: ${result.salt}`);
    console.log(`   Address: ${result.address}`);
    console.log(`   Found by: Worker ${result.workerId}`);
    console.log(`   Total iterations: ${totalIterations.toLocaleString()}`);
    console.log(`   Time: ${totalTime.toFixed(2)}s`);
    console.log(`   Rate: ${Math.round(totalIterations / totalTime).toLocaleString()} attempts/sec\n`);

    return {
      salt: result.salt,
      address: result.address,
      iterations: totalIterations
    };
  } else if (interrupted) {
    console.log(`\n⏸️  Mining stopped after ${totalIterations.toLocaleString()} iterations`);
    console.log(`   Time: ${totalTime.toFixed(2)}s`);
    console.log(`   Rate: ${Math.round(totalIterations / totalTime).toLocaleString()} attempts/sec`);
    console.log(`\n💡 To continue mining:`);
    console.log(`   - Run again (workers try random salts)`);
    console.log(`   - Try a shorter prefix`);
    console.log(`   - Use case-insensitive matching\n`);

    return null;
  } else {
    console.log(`\n❌ This shouldn't happen - workers stopped without finding or interruption`);
    return null;
  }
}

/**
 * Mine a CREATE2 salt for a vanity proxy address (single-threaded)
 *
 * @param {Object} params - Mining parameters
 * @param {string} params.implementationAddress - Address of the well implementation
 * @param {string} params.initCalldata - Encoded initialization call (e.g., init(name, symbol))
 * @param {string} params.createXAddress - CreateX factory address
 * @param {string} params.prefix - Desired address prefix (without 0x, e.g., "BEEF" or "dead")
 * @param {number} [params.maxIterations=1000000] - Maximum attempts before giving up
 * @param {boolean} [params.caseSensitive=false] - Whether prefix matching is case-sensitive
 * @param {Function} [params.onProgress] - Callback for progress updates (called every 10000 iterations)
 * @returns {Object} {salt: string, address: string, iterations: number} or null if not found
 */
function mineProxySaltSingleThreaded({
  implementationAddress,
  initCalldata,
  createXAddress,
  prefix,
  maxIterations = 1000000,
  caseSensitive = false,
  onProgress = null
}) {
  // Validate inputs
  if (!ethers.utils.isAddress(implementationAddress)) {
    throw new Error("Invalid implementation address");
  }
  if (!ethers.utils.isAddress(createXAddress)) {
    throw new Error("Invalid CreateX address");
  }
  if (!prefix || prefix.length === 0) {
    throw new Error("Prefix cannot be empty");
  }

  // Remove 0x prefix if present and normalize for validation
  const prefixWithoutOx = prefix.replace(/^0x/, "");
  const cleanPrefix = caseSensitive ? prefixWithoutOx : prefixWithoutOx.toLowerCase();

  // Validate hex prefix
  if (!/^[0-9a-f]+$/i.test(prefixWithoutOx)) {
    throw new Error("Prefix must be valid hex characters");
  }

  // Get ERC1967Proxy bytecode
  // This would normally come from artifacts, but we'll construct it
  const ERC1967ProxyArtifact = require("../artifacts/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol/ERC1967Proxy.json");
  const proxyBytecode = ERC1967ProxyArtifact.bytecode;

  // Encode constructor arguments
  const constructorArgs = ethers.utils.defaultAbiCoder.encode(
    ["address", "bytes"],
    [implementationAddress, initCalldata]
  );

  // Build init code
  const initCode = ethers.utils.solidityPack(["bytes", "bytes"], [proxyBytecode, constructorArgs]);
  const initCodeHash = ethers.utils.keccak256(initCode);

  console.log(`\n🔍 Mining for CREATE2 proxy address with prefix: 0x${prefixWithoutOx}`);
  console.log(`   Implementation: ${implementationAddress}`);
  console.log(`   CreateX: ${createXAddress}`);
  console.log(`   Max iterations: ${maxIterations.toLocaleString()}`);
  console.log(`   Case sensitive: ${caseSensitive}`);
  console.log(`   Press Ctrl+C to exit cleanly\n`);

  const startTime = Date.now();
  let found = false;
  let resultSalt = null;
  let resultAddress = null;
  let interrupted = false;
  let finalIterations = 0;

  // Handle Ctrl+C for clean exit
  const handleInterrupt = () => {
    interrupted = true;
    console.log("\n\n⏸️  Mining interrupted by user...");
  };
  process.on("SIGINT", handleInterrupt);

  for (let i = 0; i < maxIterations; i++) {
    finalIterations = i + 1;

    // Check if interrupted
    if (interrupted) {
      break;
    }

    // Generate random salt (32 bytes)
    const salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));

    // Calculate CREATE2 address
    // address = keccak256(0xff ++ deployerAddress ++ salt ++ keccak256(initCode))
    const rawAddress = ethers.utils.getCreate2Address(createXAddress, salt, initCodeHash);

    // Get checksummed address for case-sensitive matching
    const create2Address = ethers.utils.getAddress(rawAddress);

    // Check if address matches prefix (after 0x)
    let matches = false;
    if (caseSensitive) {
      // Case-sensitive: match exact case with checksummed address
      const addressPrefix = create2Address.slice(2);
      matches = addressPrefix.startsWith(cleanPrefix);
    } else {
      // Case-insensitive: convert both to lowercase
      const addressPrefix = create2Address.slice(2).toLowerCase();
      matches = addressPrefix.startsWith(cleanPrefix);
    }

    if (matches) {
      found = true;
      resultSalt = salt;
      resultAddress = create2Address;
      break;
    }

    // Progress callback every 10000 iterations
    if (onProgress && i > 0 && i % 10000 === 0) {
      const elapsed = (Date.now() - startTime) / 1000;
      const rate = i / elapsed;
      onProgress({
        iterations: i,
        elapsed,
        rate: Math.round(rate)
      });
    }
  }

  // Remove interrupt handler
  process.off("SIGINT", handleInterrupt);

  const endTime = Date.now();
  const totalTime = (endTime - startTime) / 1000;

  if (found) {
    console.log(`\n✅ Found matching address!`);
    console.log(`   Salt: ${resultSalt}`);
    console.log(`   Address: ${resultAddress}`);
    console.log(`   Iterations: ${finalIterations.toLocaleString()}`);
    console.log(`   Time: ${totalTime.toFixed(2)}s`);
    console.log(`   Rate: ${Math.round(finalIterations / totalTime).toLocaleString()} attempts/sec\n`);

    return {
      salt: resultSalt,
      address: resultAddress,
      iterations: finalIterations
    };
  } else if (interrupted) {
    console.log(`\n⏸️  Mining stopped after ${finalIterations.toLocaleString()} iterations`);
    console.log(`   Time: ${totalTime.toFixed(2)}s`);
    console.log(`   Rate: ${Math.round(finalIterations / totalTime).toLocaleString()} attempts/sec`);
    console.log(`\n💡 To continue mining:`);
    console.log(`   - Increase --max-iterations`);
    console.log(`   - Try a shorter prefix`);
    console.log(`   - Use case-insensitive matching\n`);

    return null;
  } else {
    console.log(`\n❌ No match found after ${finalIterations.toLocaleString()} iterations`);
    console.log(`   Time: ${totalTime.toFixed(2)}s`);
    console.log(`   Rate: ${Math.round(finalIterations / totalTime).toLocaleString()} attempts/sec`);
    console.log(`\n💡 Try:`);
    console.log(`   - Shorter prefix`);
    console.log(`   - More iterations: --max-iterations ${(maxIterations * 10).toLocaleString()}`);
    console.log(`   - Case insensitive matching\n`);

    return null;
  }
}

/**
 * Mine a CREATE2 salt for a vanity proxy address
 * Automatically chooses multi-threaded or single-threaded based on parameters
 *
 * @param {Object} params - Mining parameters
 * @param {string} params.implementationAddress - Address of the well implementation
 * @param {string} params.initCalldata - Encoded initialization call
 * @param {string} params.createXAddress - CreateX factory address
 * @param {string} params.prefix - Desired address prefix (without 0x)
 * @param {number} [params.maxIterations] - Max attempts for single-threaded (default: 1000000)
 * @param {number} [params.numWorkers] - Number of worker threads for multi-threaded (default: auto-detect CPUs)
 * @param {boolean} [params.caseSensitive=false] - Whether prefix matching is case-sensitive
 * @param {Function} [params.onProgress] - Callback for progress updates
 * @returns {Promise<Object>|Object} Result object with salt and address, or null if not found
 */
function mineProxySalt(params) {
  // If numWorkers is specified or maxIterations is not specified, use multi-threaded
  // Multi-threaded is now the default
  const useMultiThreaded = params.numWorkers !== undefined || params.maxIterations === undefined;

  if (useMultiThreaded) {
    // Multi-threaded (async)
    return mineProxySaltMultiThreaded(params);
  } else {
    // Single-threaded (sync)
    return mineProxySaltSingleThreaded(params);
  }
}

/**
 * Estimate difficulty and expected time for a given prefix
 *
 * @param {string} prefix - Desired address prefix (without 0x)
 * @param {boolean} [caseSensitive=false] - Whether matching is case-sensitive
 * @param {number} [attemptsPerSecond=100000] - Estimated mining rate
 * @returns {Object} Difficulty estimates
 */
function estimateDifficulty(prefix, caseSensitive = false, attemptsPerSecond = 100000) {
  const cleanPrefix = prefix.toLowerCase().replace(/^0x/, "");
  const length = cleanPrefix.length;

  // Calculate probability
  // For each hex character, there are 16 possibilities (0-f)
  // For case-sensitive, there are effectively 22 possibilities per char (0-9, a-f, A-F where applicable)
  const possibilities = caseSensitive ? 22 : 16;
  const probability = 1 / Math.pow(possibilities, length);
  const expectedAttempts = Math.pow(possibilities, length);
  const expectedSeconds = expectedAttempts / attemptsPerSecond;

  let timeEstimate = "";
  if (expectedSeconds < 60) {
    timeEstimate = `${expectedSeconds.toFixed(1)} seconds`;
  } else if (expectedSeconds < 3600) {
    timeEstimate = `${(expectedSeconds / 60).toFixed(1)} minutes`;
  } else if (expectedSeconds < 86400) {
    timeEstimate = `${(expectedSeconds / 3600).toFixed(1)} hours`;
  } else if (expectedSeconds < 2592000) {
    timeEstimate = `${(expectedSeconds / 86400).toFixed(1)} days`;
  } else {
    timeEstimate = `${(expectedSeconds / 2592000).toFixed(1)} months`;
  }

  return {
    prefixLength: length,
    probability: probability.toExponential(2),
    expectedAttempts: expectedAttempts.toLocaleString(),
    expectedTime: timeEstimate,
    difficulty:
      length <= 3 ? "Easy" : length <= 4 ? "Medium" : length <= 5 ? "Hard" : "Very Hard"
  };
}

module.exports = {
  mineProxySalt,
  estimateDifficulty
};

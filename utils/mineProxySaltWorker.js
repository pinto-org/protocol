const { parentPort, workerData } = require("worker_threads");
const { ethers } = require("ethers");

/**
 * Worker thread for mining CREATE2 salts in parallel
 * Each worker tries random salts until a match is found or told to stop
 */

const { createXAddress, initCodeHash, prefix, caseSensitive, workerId } = workerData;

let shouldStop = false;
let iterations = 0;

// Handle stop message from parent
parentPort.on("message", (msg) => {
  if (msg === "stop") {
    shouldStop = true;
  }
});

// Clean prefix for matching
const cleanPrefix = caseSensitive ? prefix : prefix.toLowerCase();

// Mining loop
const startTime = Date.now();

// Use batched mining to allow checking shouldStop more frequently
async function mine() {
  while (!shouldStop) {
    // Process in batches to allow event loop to check messages
    const batchSize = 1000;
    for (let i = 0; i < batchSize && !shouldStop; i++) {
      iterations++;

      // Generate random salt (32 bytes)
      const salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));

      // Calculate CREATE2 address
      const rawAddress = ethers.utils.getCreate2Address(createXAddress, salt, initCodeHash);
      const create2Address = ethers.utils.getAddress(rawAddress);

      // Check if address matches prefix
      let matches = false;
      if (caseSensitive) {
        const addressPrefix = create2Address.slice(2);
        matches = addressPrefix.startsWith(cleanPrefix);
      } else {
        const addressPrefix = create2Address.slice(2).toLowerCase();
        matches = addressPrefix.startsWith(cleanPrefix);
      }

      if (matches) {
        // Found a match! Send to parent and exit immediately
        const elapsed = (Date.now() - startTime) / 1000;
        parentPort.postMessage({
          type: "found",
          salt,
          address: create2Address,
          iterations,
          workerId,
          elapsed
        });
        process.exit(0);
      }

      // Send progress every 10000 iterations
      if (iterations % 10000 === 0) {
        const elapsed = (Date.now() - startTime) / 1000;
        parentPort.postMessage({
          type: "progress",
          iterations,
          workerId,
          elapsed,
          rate: Math.round(iterations / elapsed)
        });
      }
    }

    // Yield to event loop to check for stop messages
    await new Promise((resolve) => setImmediate(resolve));
  }

  // Stopped without finding
  const elapsed = (Date.now() - startTime) / 1000;
  parentPort.postMessage({
    type: "stopped",
    iterations,
    workerId,
    elapsed
  });
  process.exit(0);
}

mine();

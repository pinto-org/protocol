const hre = require("hardhat");

/**
 * Mine a CREATE2 salt for a vanity well address by calling predictWellAddress on-chain
 *
 * @param {Object} params - Mining parameters
 * @param {string} params.aquifer - Aquifer factory address
 * @param {string} params.implementation - Well implementation address
 * @param {string} [params.immutableData] - Encoded immutable data (hex string) - if not provided, will encode from individual params
 * @param {string} [params.bean] - Bean token address (defaults to Base Bean)
 * @param {string} [params.nonBeanToken] - Non-bean token address
 * @param {string} [params.wellFunctionTarget] - Well function address
 * @param {string} [params.wellFunctionData="0x"] - Encoded well function data
 * @param {string} [params.pumpTarget] - Pump address (defaults to Base pump)
 * @param {string} [params.pumpData] - Encoded pump data (defaults to Base pump data)
 * @param {string} params.sender - Address that will deploy (msg.sender)
 * @param {string} params.prefix - Desired address prefix (without 0x)
 * @param {boolean} [params.caseSensitive=false] - Whether prefix matching is case-sensitive
 * @param {number} [params.batchSize=20] - Number of iterations per batch (default: 20)
 * @param {Function} [params.onProgress] - Callback for progress updates
 * @returns {Promise<Object>} {salt: string, address: string, iterations: number} or null if not found
 */
async function mineWellSalt({
  aquifer,
  implementation,
  immutableData,
  bean,
  nonBeanToken,
  wellFunctionTarget,
  wellFunctionData = "",
  pumpTarget,
  pumpData,
  sender,
  prefix,
  caseSensitive = false,
  batchSize = 40,
  onProgress = null
}) {
  const { ethers } = hre;
  const { encodeWellImmutableData, STANDARD_ADDRESSES_BASE } = require("./wellDeployment");

  // If immutableData not provided, encode from individual parameters
  let finalImmutableData = immutableData;
  if (!finalImmutableData) {
    // Apply defaults from STANDARD_ADDRESSES_BASE
    const finalBean = bean || STANDARD_ADDRESSES_BASE.bean;
    const finalPumpTarget = pumpTarget || STANDARD_ADDRESSES_BASE.pump;
    const finalPumpData = pumpData || STANDARD_ADDRESSES_BASE.pumpData;

    // Validate required parameters
    if (!nonBeanToken) {
      throw new Error("nonBeanToken is required when immutableData is not provided");
    }
    if (!wellFunctionTarget) {
      throw new Error("wellFunctionTarget is required when immutableData is not provided");
    }

    // Build the immutable data structure
    const tokens = [finalBean, nonBeanToken];
    const wellFunction = {
      target: wellFunctionTarget,
      data: wellFunctionData
    };
    const pumps = [
      {
        target: finalPumpTarget,
        data: finalPumpData
      }
    ];

    // Encode immutable data
    finalImmutableData = encodeWellImmutableData(aquifer, tokens, wellFunction, pumps);
  }

  // Validate inputs
  if (!ethers.utils.isAddress(aquifer)) {
    throw new Error("Invalid aquifer address");
  }
  if (!ethers.utils.isAddress(implementation)) {
    throw new Error("Invalid implementation address");
  }
  if (!ethers.utils.isAddress(sender)) {
    throw new Error("Invalid sender address");
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

  // Clean prefix for matching
  const cleanPrefix = caseSensitive ? prefixWithoutOx : prefixWithoutOx.toLowerCase();

  console.log(`\n🔍 Mining for well address with prefix: 0x${prefixWithoutOx}`);
  console.log(`   Aquifer: ${aquifer}`);
  console.log(`   Implementation: ${implementation}`);
  console.log(`   Sender: ${sender}`);
  console.log(`   Batch size: ${batchSize}`);
  if (!immutableData) {
    console.log(`   Bean: ${bean || STANDARD_ADDRESSES_BASE.bean}`);
    console.log(`   Non-Bean Token: ${nonBeanToken}`);
    console.log(`   Well Function: ${wellFunctionTarget}`);
    console.log(`   Pump: ${pumpTarget || STANDARD_ADDRESSES_BASE.pump}`);
  }
  console.log(`   Case sensitive: ${caseSensitive}`);
  console.log(`   Press Ctrl+C to exit cleanly\n`);

  // Deploy WellAddressMiner helper contract to get bytecode
  console.log("📦 Deploying WellAddressMiner helper contract...");
  const WellAddressMiner = await ethers.getContractFactory("WellAddressMiner");
  const tempMiner = await WellAddressMiner.deploy();
  await tempMiner.deployed();
  console.log(`   Temporary deployment: ${tempMiner.address}`);

  // Get the deployed bytecode
  const deployedBytecode = await ethers.provider.getCode(tempMiner.address);
  console.log(`   Bytecode length: ${deployedBytecode.length} chars`);

  // Overwrite sender address with helper contract bytecode
  console.log(`   Overwriting ${sender} with helper contract bytecode...`);
  await hre.network.provider.send("hardhat_setCode", [sender, deployedBytecode]);

  // Now the sender address IS the helper contract
  const minerAsSender = await ethers.getContractAt("WellAddressMiner", sender);
  console.log(`   ✅ Sender address is now the helper contract\n`);

  // Convert prefix to bytes for case-insensitive matching
  const prefixBytes = ethers.utils.arrayify("0x" + cleanPrefix);

  const startTime = Date.now();
  let totalIterations = 0;
  let batchCount = 0;
  let interrupted = false;

  // Handle Ctrl+C
  const handleInterrupt = () => {
    interrupted = true;
    console.log("\n\n⏸️  Mining interrupted by user...");
  };
  process.on("SIGINT", handleInterrupt);

  try {
    while (!interrupted) {
      batchCount++;

      // Generate random starting salt (32 bytes)
      const startSalt = ethers.utils.hexlify(ethers.utils.randomBytes(32));

      try {
        // Call batch miner with case-insensitive matching
        const result = await minerAsSender.callStatic.batchMineAddressCaseInsensitive(
          aquifer,
          implementation,
          finalImmutableData,
          startSalt,
          prefixBytes,
          batchSize
        );

        // Found a match!
        totalIterations += result.iterations.toNumber();
        const elapsed = (Date.now() - startTime) / 1000;

        console.log(`\n✅ Found matching address!`);
        console.log(`   Salt: ${result.salt}`);
        console.log(`   Address: ${result.wellAddress}`);
        console.log(`   Total iterations: ${totalIterations.toLocaleString()}`);
        console.log(`   Total batches: ${batchCount.toLocaleString()}`);
        console.log(`   Time: ${elapsed.toFixed(2)}s`);
        console.log(
          `   Rate: ${Math.round(totalIterations / elapsed).toLocaleString()} attempts/sec\n`
        );

        // Remove interrupt handler
        process.off("SIGINT", handleInterrupt);

        return {
          salt: result.salt,
          address: result.wellAddress,
          iterations: totalIterations
        };
      } catch (error) {
        // No match in this batch, continue with next batch
        totalIterations += batchSize;

        // Send progress every batch
        const elapsed = (Date.now() - startTime) / 1000;
        const rate = Math.round(totalIterations / elapsed);

        if (onProgress) {
          onProgress({ iterations: totalIterations, elapsed, rate, batchCount });
        } else if (batchCount % 5 === 0) {
          // Report every 5 batches
          console.log(
            `   ${totalIterations.toLocaleString()} attempts | ${batchCount} batches | ${elapsed.toFixed(1)}s | ${rate.toLocaleString()}/sec`
          );
        }
      }
    }

    // Interrupted
    const elapsed = (Date.now() - startTime) / 1000;
    console.log(`\n⏸️  Mining stopped after ${totalIterations.toLocaleString()} iterations`);
    console.log(`   Batches processed: ${batchCount.toLocaleString()}`);
    console.log(`   Time: ${elapsed.toFixed(2)}s`);
    console.log(`   Rate: ${Math.round(totalIterations / elapsed).toLocaleString()} attempts/sec`);
    console.log(`\n💡 To continue mining:`);
    console.log(`   - Run again`);
    console.log(`   - Try a shorter prefix`);
    console.log(`   - Use case-insensitive matching`);
    console.log(`   - Increase batch size (--batch-size)\n`);

    // Remove interrupt handler
    process.off("SIGINT", handleInterrupt);

    return null;
  } catch (error) {
    // Remove interrupt handler
    process.off("SIGINT", handleInterrupt);
    throw error;
  }
}

/**
 * Estimate difficulty and expected time for a given prefix
 *
 * @param {string} prefix - Desired address prefix (without 0x)
 * @param {boolean} [caseSensitive=false] - Whether matching is case-sensitive
 * @param {number} [attemptsPerSecond=100] - Estimated mining rate (batching makes this much faster)
 * @returns {Object} Difficulty estimates
 */
function estimateDifficulty(prefix, caseSensitive = false, attemptsPerSecond = 100) {
  const cleanPrefix = prefix.toLowerCase().replace(/^0x/, "");
  const length = cleanPrefix.length;

  // Calculate probability
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
    difficulty: length <= 3 ? "Easy" : length <= 4 ? "Medium" : length <= 5 ? "Hard" : "Very Hard"
  };
}

module.exports = {
  mineWellSalt,
  estimateDifficulty
};

const { ethers } = require("ethers");
const { execSync } = require("child_process");

/**
 * Mine a CREATE2 salt for a vanity proxy address using Foundry's cast create2
 *
 * @param {Object} params - Mining parameters
 * @param {string} params.implementationAddress - Address of the well implementation
 * @param {string} params.initCalldata - Encoded initialization call (e.g., init(name, symbol))
 * @param {string} params.deployerAddress - Address that will deploy the proxy (CreateX or InitDeployAndWhitelistWell)
 * @param {string} params.prefix - Desired address prefix (without 0x, e.g., "BEEF" or "dead")
 * @param {boolean} [params.caseSensitive=false] - Whether prefix matching is case-sensitive
 * @returns {Promise<Object>} {salt: string, address: string} or null if not found
 */
async function mineProxySalt({
  implementationAddress,
  initCalldata,
  deployerAddress,
  prefix,
  caseSensitive = false
}) {
  const deployer = deployerAddress;

  // Validate inputs
  if (!ethers.utils.isAddress(implementationAddress)) {
    throw new Error("Invalid implementation address");
  }
  if (!ethers.utils.isAddress(deployer)) {
    throw new Error("Invalid deployer address");
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

  // Get ERC1967Proxy bytecode (creation code)
  const ERC1967ProxyArtifact = require("../artifacts/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol/ERC1967Proxy.json");
  const proxyBytecode = ERC1967ProxyArtifact.bytecode;
  // console.log("proxyBytecode", proxyBytecode);

  // Encode constructor arguments for ERC1967Proxy(address _logic, bytes memory _data)
  const constructorArgs = ethers.utils.defaultAbiCoder.encode(
    ["address", "bytes"],
    [implementationAddress, initCalldata]
  );

  // Build init code: creationCode + abi.encode(constructorArgs)
  const initCode = ethers.utils.solidityPack(["bytes", "bytes"], [proxyBytecode, constructorArgs]);
  // Calculate init code hash
  const initCodeHash = ethers.utils.keccak256(initCode);

  console.log(`\n🔍 Mining for CREATE2 proxy address with prefix: 0x${prefixWithoutOx}`);
  // console.log(`   Implementation: ${implementationAddress}`);
  // console.log(`   Deployer: ${deployer}`);
  // console.log(`   Init code hash: ${initCodeHash}`);
  // console.log(`   Case sensitive: ${caseSensitive}`);

  const startTime = Date.now();

  try {
    // Build cast create2 command
    const castCommand = [
      "cast",
      "create2",
      "--init-code-hash",
      initCodeHash,
      "--starts-with",
      `0x${prefixWithoutOx}`,
      "-d",
      deployer
    ];

    // Add case-sensitive flag if needed
    if (caseSensitive) {
      castCommand.push("--case-sensitive");
    }

    console.log(`⛏️  Mining with command: ${castCommand.join(" ")}\n`);

    // Execute cast create2 command
    // Note: cast create2 handles the mining and outputs results
    const output = execSync(castCommand.join(" "), {
      encoding: "utf8",
      stdio: ["inherit", "pipe", "inherit"], // Inherit stdin and stderr, capture stdout
      maxBuffer: 10 * 1024 * 1024 // 10MB buffer
    });

    const endTime = Date.now();
    const totalTime = (endTime - startTime) / 1000;

    // Parse cast output
    // Expected format:
    // Address: 0x...
    // Salt: ...
    const addressMatch = output.match(/Address:\s*(0x[a-fA-F0-9]{40})/);
    const saltMatch = output.match(/Salt:\s*(0x[a-fA-F0-9]{64}|[0-9]+)/);

    if (!addressMatch || !saltMatch) {
      throw new Error("Failed to parse cast create2 output");
    }

    const address = addressMatch[1];
    const salt = saltMatch[1];

    // Ensure salt is in hex format with 0x prefix
    let formattedSalt = salt;
    if (!salt.startsWith("0x")) {
      // Convert decimal to hex
      formattedSalt = ethers.BigNumber.from(salt).toHexString();
    }
    // Pad to 32 bytes (66 characters including 0x)
    formattedSalt = ethers.utils.hexZeroPad(formattedSalt, 32);

    console.log(`\n✅ Found matching address!`);
    console.log(`   Salt: ${formattedSalt}`);
    console.log(`   Address: ${address}`);
    console.log(`   Time: ${totalTime.toFixed(2)}s\n`);

    return {
      salt: formattedSalt,
      address: address
    };
  } catch (error) {
    const endTime = Date.now();
    const totalTime = (endTime - startTime) / 1000;

    if (error.signal === "SIGINT") {
      console.log(`\n⏸️  Mining interrupted by user`);
      console.log(`   Time: ${totalTime.toFixed(2)}s`);
      console.log(`\n💡 To continue mining:`);
      console.log(`   - Run again`);
      console.log(`   - Try a shorter prefix`);
      console.log(`   - Use case-insensitive matching\n`);
      return null;
    }

    if (error.message.includes("command not found") || error.message.includes("cast")) {
      throw new Error(
        "Foundry's 'cast' command not found. Please install Foundry: https://getfoundry.sh"
      );
    }

    throw error;
  }
}

/**
 * Estimate difficulty and expected time for a given prefix
 *
 * @param {string} prefix - Desired address prefix (without 0x)
 * @param {boolean} [caseSensitive=false] - Whether matching is case-sensitive
 * @param {number} [attemptsPerSecond=1000000] - Estimated mining rate (cast create2 is much faster)
 * @returns {Object} Difficulty estimates
 */
function estimateDifficulty(prefix, caseSensitive = false, attemptsPerSecond = 1000000) {
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
    difficulty: length <= 3 ? "Easy" : length <= 4 ? "Medium" : length <= 5 ? "Hard" : "Very Hard"
  };
}

module.exports = {
  mineProxySalt,
  estimateDifficulty
};

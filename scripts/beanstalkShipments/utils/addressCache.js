const fs = require("fs");
const path = require("path");

const DATA_DIR = path.join(__dirname, "../data");
const FILE_PREFIX = "deployedAddresses_";
const FILE_EXTENSION = ".json";
const PRODUCTION_FILE = "productionAddresses.json";

const NUM_CONTRACTS = 2;
/**
 * Gets all existing deployed address files and returns them sorted by counter
 * @returns {Array<{path: string, counter: number}>} Sorted array of file info
 */
function getExistingFiles() {
  if (!fs.existsSync(DATA_DIR)) {
    return [];
  }

  const files = fs.readdirSync(DATA_DIR);
  const addressFiles = files
    .filter((f) => f.startsWith(FILE_PREFIX) && f.endsWith(FILE_EXTENSION))
    .map((f) => {
      const counterStr = f.slice(FILE_PREFIX.length, -FILE_EXTENSION.length);
      const counter = parseInt(counterStr, 10);
      return { path: path.join(DATA_DIR, f), counter };
    })
    .filter((f) => !isNaN(f.counter))
    .sort((a, b) => a.counter - b.counter);

  return addressFiles;
}

/**
 * Gets the path for the next available counter
 * @returns {string} Path for the next file
 */
function getNextFilePath() {
  const existing = getExistingFiles();
  const nextCounter = existing.length > 0 ? existing[existing.length - 1].counter + 1 : 1;
  return path.join(DATA_DIR, `${FILE_PREFIX}${nextCounter}${FILE_EXTENSION}`);
}

/**
 * Gets the path of the latest (highest counter) file
 * @returns {string|null} Path to latest file or null if none exist
 */
function getLatestFilePath() {
  const existing = getExistingFiles();
  return existing.length > 0 ? existing[existing.length - 1].path : null;
}

/**
 * Saves deployed contract addresses to cache file with auto-incrementing counter
 * @param {Object} addresses - Object containing contract addresses
 * @param {string} addresses.siloPayback - SiloPayback contract address
 * @param {string} addresses.barnPayback - BarnPayback contract address
 * @param {string} addresses.contractPaybackDistributor - ContractPaybackDistributor contract address
 * @param {string} network - Network name (e.g., "base", "localhost")
 */
function saveDeployedAddresses(addresses, network = "unknown") {
  const data = {
    siloPayback: addresses.siloPayback,
    barnPayback: addresses.barnPayback,
    contractPaybackDistributor: addresses.contractPaybackDistributor,
    deployedAt: new Date().toISOString(),
    network: network
  };

  const filePath = getNextFilePath();
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
  console.log(`📝 Deployed addresses saved to ${filePath}`);
}

/**
 * Gets deployed contract addresses from the latest cache file
 * @returns {Object|null} Object containing contract addresses or null if not found
 */
function getDeployedAddresses() {
  const latestFile = getLatestFilePath();
  if (!latestFile) {
    return null;
  }

  try {
    const data = JSON.parse(fs.readFileSync(latestFile));
    return data;
  } catch (error) {
    console.error("Error reading deployed addresses cache:", error);
    return null;
  }
}

/**
 * Verifies that all required contract addresses are present in the cache or production file
 * @param {boolean} useDeployed - If true, verify production addresses; if false, verify dev addresses
 * @returns {boolean} True if all addresses are present, false otherwise
 */
function verifyDeployedAddresses(useDeployed = false) {
  const addresses = getAddresses(useDeployed);
  if (!addresses) {
    if (useDeployed) {
      console.error("❌ No production addresses found. Check productionAddresses.json.");
    } else {
      console.error("❌ No deployed addresses found. Run deployPaybackContracts first.");
    }
    return false;
  }

  const required = ["siloPayback", "barnPayback", "contractPaybackDistributor"];
  const missing = required.filter((key) => !addresses[key]);

  if (missing.length > 0) {
    console.error(`❌ Missing deployed addresses: ${missing.join(", ")}`);
    return false;
  }

  return true;
}

/**
 * Gets production (mainnet) addresses from the canonical production file.
 * These addresses are never auto-incremented and represent deployed mainnet contracts.
 * @returns {Object|null} Object containing production contract addresses or null if not found
 */
function getProductionAddresses() {
  const productionFilePath = path.join(DATA_DIR, PRODUCTION_FILE);
  if (!fs.existsSync(productionFilePath)) {
    console.error("❌ Production addresses file not found:", productionFilePath);
    return null;
  }

  try {
    const data = JSON.parse(fs.readFileSync(productionFilePath));
    return data;
  } catch (error) {
    console.error("Error reading production addresses:", error);
    return null;
  }
}

/**
 * Router function that returns either production addresses or latest dev addresses
 * based on the useDeployed flag.
 * @param {boolean} useDeployed - If true, return production addresses; if false, return latest dev addresses
 * @returns {Object|null} Object containing contract addresses or null if not found
 */
function getAddresses(useDeployed = false) {
  if (useDeployed) {
    const productionAddresses = getProductionAddresses();
    if (productionAddresses) {
      console.log("📍 Using production addresses from productionAddresses.json");
    }
    return productionAddresses;
  }
  return getDeployedAddresses();
}

/**
 * Gets a specific contract address from cache or production
 * @param {string} contractName - Name of contract ("siloPayback", "barnPayback", or "contractPaybackDistributor")
 * @param {boolean} useDeployed - If true, use production addresses; if false, use latest dev addresses
 * @returns {string|null} Contract address or null if not found
 */
function getContractAddress(contractName, useDeployed = false) {
  const addresses = getAddresses(useDeployed);
  if (!addresses) {
    return null;
  }
  return addresses[contractName] || null;
}

/**
 * Pre-computes the ContractPaybackDistributor proxy address based on deployer nonce.
 * Nonce consumption for transparent proxies:
 * - First proxy (SiloPayback): Implementation + ProxyAdmin + Proxy = 3 nonces
 * - Second proxy (BarnPayback): Implementation + Proxy = 2 nonces (reuses ProxyAdmin)
 * - Third proxy (ContractPaybackDistributor): Implementation + Proxy = 2 nonces (reuses ProxyAdmin)
 *
 * This function is called AFTER SiloPayback deployment, so currentNonce already includes
 * SiloPayback's 3 nonces. We need to add:
 * - BarnPayback: 2 nonces
 * - ContractPaybackDistributor implementation: 1 nonce (NUM_CONTRACTS accounts for this offset)
 * The proxy address is at currentNonce + NUM_CONTRACTS after BarnPayback deployment.
 *
 * @param {Object} deployer - Ethers signer object
 * @returns {Promise<{distributorAddress: string, startingNonce: number}>}
 */
async function computeDistributorAddress(deployer) {
  const ethers = require("ethers");
  const currentNonce = await deployer.getTransactionCount();
  const distributorAddress = ethers.utils.getContractAddress({
    from: deployer.address,
    nonce: currentNonce + NUM_CONTRACTS
  });
  return { distributorAddress, startingNonce: currentNonce };
}

module.exports = {
  saveDeployedAddresses,
  getDeployedAddresses,
  getProductionAddresses,
  getAddresses,
  verifyDeployedAddresses,
  getContractAddress,
  getLatestFilePath,
  getExistingFiles,
  computeDistributorAddress
};

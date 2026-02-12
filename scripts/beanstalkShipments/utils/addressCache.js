const fs = require("fs");
const path = require("path");

const DATA_DIR = path.join(__dirname, "../data");
const FILE_PREFIX = "deployedAddresses_";
const FILE_EXTENSION = ".json";

const NUM_CONTRACTS = 1;
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
 * Verifies that all required contract addresses are present in the cache
 * @returns {boolean} True if all addresses are present, false otherwise
 */
function verifyDeployedAddresses() {
  const addresses = getDeployedAddresses();
  if (!addresses) {
    console.error("❌ No deployed addresses found. Run deployPaybackContracts first.");
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
 * Gets a specific contract address from cache
 * @param {string} contractName - Name of contract ("siloPayback", "barnPayback", or "contractPaybackDistributor")
 * @returns {string|null} Contract address or null if not found
 */
function getContractAddress(contractName) {
  const addresses = getDeployedAddresses();
  if (!addresses) {
    return null;
  }
  return addresses[contractName] || null;
}

/**
 * Pre-computes the ContractPaybackDistributor address based on deployer nonce.
 * Nonce consumption for transparent proxies:
 * - First proxy (SiloPayback): Implementation + ProxyAdmin + Proxy = 3 nonces
 * - Second proxy (BarnPayback): Implementation + Proxy = 2 nonces (reuses ProxyAdmin)
 * - ContractPaybackDistributor: 1 nonce (regular deployment)
 * Total offset from starting nonce: 5
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
  verifyDeployedAddresses,
  getContractAddress,
  getLatestFilePath,
  getExistingFiles,
  computeDistributorAddress
};

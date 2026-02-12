const fs = require("fs");
const path = require("path");

const CACHE_FILE_PATH = path.join(__dirname, "../data/deployedAddresses.json");

/**
 * Saves deployed contract addresses to cache file
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

  fs.writeFileSync(CACHE_FILE_PATH, JSON.stringify(data, null, 2));
  console.log(`📝 Deployed addresses saved to ${CACHE_FILE_PATH}`);
}

/**
 * Gets deployed contract addresses from cache file
 * @returns {Object|null} Object containing contract addresses or null if not found
 */
function getDeployedAddresses() {
  if (!fs.existsSync(CACHE_FILE_PATH)) {
    return null;
  }

  try {
    const data = JSON.parse(fs.readFileSync(CACHE_FILE_PATH));
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

module.exports = {
  saveDeployedAddresses,
  getDeployedAddresses,
  verifyDeployedAddresses,
  getContractAddress,
  CACHE_FILE_PATH
};

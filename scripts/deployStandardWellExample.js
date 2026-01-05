const { ethers } = require("hardhat");
const { deployStandardWell, STANDARD_ADDRESSES_BASE } = require("../utils/wellDeployment");

/**
 * Example script showing how to deploy a standard well on Base
 *
 * Usage:
 *   npx hardhat run scripts/deployStandardWellExample.js --network base
 */
async function main() {
  console.log("========================================");
  console.log("Standard Well Deployment Example");
  console.log("========================================\n");

  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Network: ${network.name}\n`);

  // Example: Deploy a PINTO:WETH ConstantProduct2 well
  const wethWell = await deployStandardWell({
    nonBeanToken: "0x4200000000000000000000000000000000000006", // WETH on Base
    wellFunction: "CP2", // Shorthand for ConstantProduct2 (can also use "constantProduct2")
    wellFunctionData: "0x", // No data needed for CP2
    wellSalt: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PINTO:WETH-Well-Clone")), // For boreWell
    proxySalt: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PINTO:WETH-Proxy")), // For ERC1967Proxy
    name: "PINTO:WETH Constant Product 2 Well",
    symbol: "U-PINTOWETHCP2w",
    deployer,
    verbose: true
  });

  console.log(`\n✅ WETH Well deployed at: ${wethWell.proxyAddress}\n`);

  // Example: Deploy a PINTO:USDC Stable2 well
  // For S2 (stable2), wellFunctionData is automatically generated from token decimals!
  const usdcWell = await deployStandardWell({
    nonBeanToken: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", // USDC on Base
    wellFunction: "S2", // Shorthand for Stable2 (can also use "stable2")
    // wellFunctionData not needed - auto-fetches token decimals and encodes them
    wellSalt: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PINTO:USDC-Well-Clone")), // For boreWell
    proxySalt: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PINTO:USDC-Proxy")), // For ERC1967Proxy
    name: "PINTO:USDC Stable 2 Well",
    symbol: "U-PINTOUSDCS2w",
    deployer,
    verbose: true
  });

  console.log(`\n✅ USDC Well deployed at: ${usdcWell.proxyAddress}\n`);

  // Show standard addresses being used
  console.log("========================================");
  console.log("Standard Addresses Used:");
  console.log("========================================");
  console.log(`Bean: ${STANDARD_ADDRESSES_BASE.bean}`);
  console.log(`Aquifer: ${STANDARD_ADDRESSES_BASE.aquifer}`);
  console.log(`Well Implementation: ${STANDARD_ADDRESSES_BASE.wellImplementation}`);
  console.log(`Pump: ${STANDARD_ADDRESSES_BASE.pump}`);
  console.log(`ConstantProduct2: ${STANDARD_ADDRESSES_BASE.constantProduct2}`);
  console.log(`Stable2: ${STANDARD_ADDRESSES_BASE.stable2}\n`);

  return { wethWell, usdcWell };
}

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = { main };

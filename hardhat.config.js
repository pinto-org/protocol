require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers");
require("hardhat-contract-sizer");
require("hardhat-gas-reporter");
require("hardhat-tracer");
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();
require("@nomiclabs/hardhat-etherscan");

//////////////////////// TASKS ////////////////////////
// Import task modules
require("./tasks")();

// used in the UI to run the latest upgrade
task("runLatestUpgrade", "Compiles the contracts").setAction(async function () {
  const order = true;
  // compile contracts.
  await hre.run("compile");
  // deploy PI-13
  await hre.run("PI-13");

  // Setup LP tokens for test addresses BEFORE running many sunrises
  if (order) {
    console.log("Setting up LP tokens for test addresses...");
    await hre.run("setup-convert-up-addresses");
    // increase the seeds, call sunrise.
    await hre.run("mock-seeds");
    await hre.run("callSunrise");
  }

  // deploy convert up blueprint
  // dev: should be deployed to : 0x53B7cF2a4A18062aFF4fA71Bb300F6eA2d3702E2 for testing purposes.
  await hre.run("deployConvertUpBlueprint");

  // Now sign and publish the convert up blueprints with grown stalk available
  if (order) {
    console.log("Signing and publishing convert up blueprints...");
    await hre.run("create-mock-convert-up-orders", {
      execute: true,
      skipSetup: true // Skip LP token setup since we already did it
    });
    await hre.run("callSunrise");
  }
});

//////////////////////// CONFIGURATION ////////////////////////

module.exports = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      chainId: 1337,
      forking: process.env.FORKING_RPC
        ? {
            url: process.env.FORKING_RPC,
            blockNumber: parseInt(process.env.BLOCK_NUMBER) || undefined
          }
        : undefined,
      allowUnlimitedContractSize: true
    },
    localhost: {
      chainId: 1337,
      url: "http://127.0.0.1:8545/",
      timeout: 100000000000000000,
      accounts: "remote"
    },
    mainnet: {
      chainId: 1,
      url: process.env.MAINNET_RPC || "",
      timeout: 1000000000
    },
    arbitrum: {
      chainId: 42161,
      url: process.env.ARBITRUM_RPC || "",
      timeout: 1000000000
    },
    base: {
      chainId: 8453,
      url: process.env.BASE_RPC || "",
      timeout: 100000000,
      accounts: []
    },
    custom: {
      chainId: 41337,
      url: process.env.CUSTOM_RPC || "",
      timeout: 100000
    }
  },
  etherscan: {
    apiKey: {
      base: process.env.ETHERSCAN_API_KEY
    },
    customChains: [
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=8453",
          browserURL: "https://basescan.org"
        }
      }
    ]
  },
  solidity: {
    compilers: [
      {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100
          }
        }
      }
    ]
  }
};

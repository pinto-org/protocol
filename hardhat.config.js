require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers");
require("hardhat-contract-sizer");
require("hardhat-gas-reporter");
require("hardhat-tracer");
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();
require("@nomiclabs/hardhat-etherscan");
require("@nomicfoundation/hardhat-foundry");
const { getBeanstalk } = require("./utils");
const { L2_PINTO } = require("./test/hardhat/utils/constants.js");

//////////////////////// TASKS ////////////////////////
// Import task modules
require("./tasks")();

// used in the UI to run the latest upgrade
task("runLatestUpgrade", "Compiles the contracts").setAction(async function () {
  // compile contracts.
  await hre.run("compile");

  const { fetchAllSowData } = require("./scripts/deployment/fetchSowFarmers.js");
  await fetchAllSowData();

  await hre.run("PI-X-migration-referral");

  console.log("Diamond Upgraded.");

  await hre.run("addLiquidityToWstethWell", { deposit: true });
  console.log("Liquidity added to WSTETH well.");

  // deploy the new pod referral contracts:
  await hre.run("deployPodReferralContracts");
  console.log("Pod referral contracts deployed.");

  // update the oracle timeouts
  await hre.run("updateOracleTimeouts");
  console.log("Oracle timeouts updated.");
});

task("callSunriseAndTestMigration", "Calls the sunrise function and tests the migration").setAction(
  async function () {
    for (let i = 0; i < 50; i++) {
      await hre.run("callSunrise");
      console.log("Sunrise called.");

      const beanstalk = await getBeanstalk(L2_PINTO);
      const cbethWellData = await beanstalk.tokenSettings(
        "0x3e111115A82dF6190e36ADf0d552880663A4dBF1"
      );
      const wstethWellData = await beanstalk.tokenSettings(
        "0x3e1155245FF9a6a019Bc35827e801c6ED2CE91b9"
      );
      console.log(
        "CBETH optimal percent deposited bdv: ",
        cbethWellData.optimalPercentDepositedBdv.toString()
      );
      console.log(
        "WSTETH optimal percent deposited bdv: ",
        wstethWellData.optimalPercentDepositedBdv.toString()
      );
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
);

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
      timeout: 1000000000,
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
          },
          evmVersion: "cancun"
        }
      }
    ]
  }
};

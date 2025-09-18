const { task } = require("hardhat/config");
const { impersonateSigner, mintEth, getBeanstalk } = require("../utils");
const {
  L2_PINTO,
  L2_PCM,
  PINTO,
  PINTO_CBTC_WELL_BASE,
  addressToNameMap
} = require("../test/hardhat/utils/constants.js");

module.exports = function() {
  task("getPrice", async () => {
    const priceContract = await ethers.getContractAt(
      "BeanstalkPrice",
      "0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E"
    );
    const price = await priceContract.price();
    console.log(price);
  });

  task("getGerminatingStem", async () => {
    const beanstalk = await getBeanstalk(L2_PINTO);
    const stem = await beanstalk.getGerminatingStem(PINTO);
    console.log("pinto stem:", stem);

    const depositIds = await beanstalk.getTokenDepositIdsForAccount(
      "0x00001d167c31a30fca4ccc0fd56df74f1c606524",
      PINTO
    );
    for (let i = 0; i < depositIds.length; i++) {
      const [token, stem] = await beanstalk.getAddressAndStem(depositIds[i]);
      console.log("token:", token, "stem:", stem);
    }
  });

  task("getWhitelistedWells", "Lists all whitelisted wells and their non-pinto tokens").setAction(
    async () => {
      console.log("-----------------------------------");
      console.log("Whitelisted Wells and Their Non-Pinto Tokens:");
      console.log("-----------------------------------");

      const beanstalk = await getBeanstalk(L2_PINTO);
      const wells = await beanstalk.getWhitelistedWellLpTokens();

      for (let i = 0; i < wells.length; i++) {
        const well = await ethers.getContractAt("IWell", wells[i]);
        const tokens = await well.tokens();
        const nonBeanToken = await ethers.getContractAt("MockToken", tokens[1]);

        // Get token details
        const tokenName = addressToNameMap[tokens[1]] || tokens[1];
        const tokenSymbol = await nonBeanToken.symbol();
        const tokenDecimals = await nonBeanToken.decimals();

        // Get well reserves
        const reserves = await well.getReserves();
        const pintoReserve = ethers.utils.formatUnits(reserves[0], 6); // Pinto has 6 decimals
        const tokenReserve = ethers.utils.formatUnits(reserves[1], tokenDecimals);

        console.log(`\nWell Address: ${wells[i]}`);
        console.log(`Non-Pinto Token:`);
        console.log(`  - Address: ${tokens[1]}`);
        console.log(`  - Name: ${tokenName}`);
        console.log(`  - Symbol: ${tokenSymbol}`);
        console.log(`  - Decimals: ${tokenDecimals}`);
        console.log(`Current Reserves:`);
        console.log(`  - Pinto: ${pintoReserve}`);
        console.log(`  - ${tokenSymbol}: ${tokenReserve}`);
      }
    }
  );

  task("wellOracleSnapshot", "Gets the well oracle snapshot for a given well", async function () {
    const beanstalk = await getBeanstalk(L2_PINTO);
    const tokens = await beanstalk.getWhitelistedWellLpTokens();
    for (let i = 0; i < tokens.length; i++) {
      const snapshot = await beanstalk.wellOracleSnapshot(tokens[i]);
      console.log(snapshot);
    }
  });

  task("price", "Gets the price of a given token", async function () {
    const beanstalkPrice = await ethers.getContractAt(
      "BeanstalkPrice",
      "0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E"
    );
    const price = await beanstalkPrice.price();
    for (let i = 0; i < 5; i++) {
      console.log(price[3][i]);
    }
  });

  task("pumps", async function () {
    const well = await ethers.getContractAt("IWell", PINTO_CBTC_WELL_BASE);
    const pumps = await well.pumps();
    console.log(pumps);
  });

  task("updateOracleTimeouts", "Updates oracle timeouts for all whitelisted LP tokens").setAction(
    async () => {
      console.log("Updating oracle timeouts for all whitelisted LP tokens");

      const beanstalk = await getBeanstalk(L2_PINTO);
      const account = await impersonateSigner(L2_PCM);
      await mintEth(account.address);

      // Get all whitelisted LP tokens
      const wells = await beanstalk.getWhitelistedWellLpTokens();

      for (let i = 0; i < wells.length; i++) {
        const well = await ethers.getContractAt("IWell", wells[i]);
        const tokens = await well.tokens();
        // tokens[0] is pinto/bean, tokens[1] is the non-bean token
        const nonPintoToken = tokens[1];
        const tokenName = addressToNameMap[nonPintoToken] || nonPintoToken;

        console.log(`\nProcessing well: ${wells[i]}`);
        console.log(`Non-pinto token: ${tokenName} (${nonPintoToken})`);

        try {
          // Get current oracle implementation for the non-pinto token
          const currentImpl = await beanstalk.getOracleImplementationForToken(nonPintoToken);
          console.log("Current implementation:");
          console.log("- Target:", currentImpl.target);
          console.log("- Selector:", currentImpl.selector);
          console.log("- Encode Type:", currentImpl.encodeType);
          console.log("- Current Data:", currentImpl.data);

          const newImpl = {
            target: currentImpl.target,
            selector: currentImpl.selector,
            encodeType: currentImpl.encodeType,
            data: ethers.utils.hexZeroPad(ethers.utils.hexlify(86400 * 365), 32) // 365 day oracle timeout
          };

          console.log("\nNew implementation:");
          console.log("- Target:", newImpl.target);
          console.log("- Selector:", newImpl.selector);
          console.log("- Encode Type:", newImpl.encodeType);
          console.log("- New Data:", newImpl.data);

          // Update the oracle implementation for token
          await beanstalk
            .connect(account)
            .updateOracleImplementationForToken(nonPintoToken, newImpl, { gasLimit: 10000000 });
          console.log(`Successfully updated oracle timeout for token: ${tokenName}`);
        } catch (error) {
          console.error(`Failed to update oracle timeout for token ${tokenName}:`, error.message);
        }
      }

      console.log("Finished oracle updates");
    }
  );

  task("facetAddresses", "Displays current addresses of specified facets on Base mainnet")
    .addParam(
      "facets",
      "Comma-separated list of facet names to look up (ex: 'FieldFacet,SiloFacet,SeasonFacet')"
    )
    .addFlag("urls", "Show BaseScan URLs for the facets")
    .setAction(async (taskArgs) => {
      const BASESCAN_API_KEY = process.env.ETHERSCAN_KEY_BASE;
      if (!BASESCAN_API_KEY) {
        console.error("❌ Please set ETHERSCAN_KEY_BASE in your environment variables");
        return;
      }

      const diamond = await ethers.getContractAt("IDiamondLoupe", L2_PINTO);

      // Get all facets from the diamond
      const allFacets = await diamond.facets();

      // Get the requested facet names
      const requestedFacets = taskArgs.facets.split(",").map((f) => f.trim());

      console.log("\n🔍 Looking up facet addresses on Base mainnet...");
      console.log("-----------------------------------");

      // Create a map of addresses to their contract names
      const addressToName = new Map();

      // Fetch contract names from BaseScan for each unique address
      const uniqueAddresses = [...new Set(allFacets.map((f) => f.facetAddress))];

      for (const address of uniqueAddresses) {
        try {
          let data;
          let attempts = 0;
          const maxAttempts = 3;

          do {
            const response = await fetch(
              `https://api.basescan.org/api?module=contract&action=getsourcecode&address=${address}&apikey=${BASESCAN_API_KEY}`
            );
            data = await response.json();
            attempts++;

            if (data.status === "1" && data.result[0]) {
              const contractName = data.result[0].ContractName;
              addressToName.set(address, contractName);
              break;
            }

            // Wait 1 second before retrying
            if (data.status === "0" && attempts < maxAttempts) {
              await new Promise((resolve) => setTimeout(resolve, 1000));
            }
          } while (data.status === "0" && attempts < maxAttempts);
        } catch (e) {
          console.log(`⚠️  Error fetching contract name for ${address}: ${e.message}`);
        }
      }

      // For each requested facet, find its address
      for (const facetName of requestedFacets) {
        let found = false;

        for (const facet of allFacets) {
          const contractName = addressToName.get(facet.facetAddress);
          if (contractName && contractName.toLowerCase() === facetName.toLowerCase()) {
            console.log(`📦 ${facetName}: ${facet.facetAddress}`);
            if (taskArgs.urls) {
              console.log(`   🔗 https://basescan.org/address/${facet.facetAddress}`);
            }
            found = true;
            break;
          }
        }

        if (!found) {
          console.log(`❌ ${facetName}: Not found on diamond`);
        }
      }

      console.log("-----------------------------------");
    });
};
const { task } = require("hardhat/config");
const path = require("path");
const fs = require("fs");
const glob = require("glob");

function generateDiamondABI(outputFileName, includeMocks = false) {
  const modulesDir = path.join("contracts", "beanstalk", "facets");
  const modules = ["diamond", "farm", "field", "market", "silo", "sun", "metadata"];

  const getFacetName = (file) => {
    return file.split("/").pop().split(".")[0];
  };

  let abi = [];

  // Process facet modules
  modules.forEach((module) => {
    const pattern = path.join(".", modulesDir, module, "**", "*Facet.sol");
    const files = glob.sync(pattern);

    if (module === "silo") {
      // Manually add in libraries that emit events
      files.push("contracts/libraries/LibIncentive.sol");
      files.push("contracts/libraries/Silo/LibGerminate.sol");
      files.push("contracts/libraries/Minting/LibWellMinting.sol");
      files.push("contracts/libraries/Silo/LibWhitelistedTokens.sol");
      files.push("contracts/libraries/Silo/LibWhitelist.sol");
      files.push("contracts/libraries/Silo/LibTokenSilo.sol");
      files.push("contracts/libraries/LibGauge.sol");
      files.push("contracts/libraries/LibShipping.sol");
      files.push("contracts/libraries/Token/LibTransfer.sol");
      files.push("contracts/libraries/LibEvaluate.sol");
      files.push("contracts/libraries/Silo/LibFlood.sol");
      files.push("contracts/libraries/Sun/LibWeather.sol");
    }

    files.forEach((file) => {
      const facetName = getFacetName(file);
      const jsonFileName = `${facetName}.json`;
      const jsonFileLoc = path.join(".", "artifacts", file, jsonFileName);

      const json = JSON.parse(fs.readFileSync(jsonFileLoc));

      console.log(`${module}:`.padEnd(10), file);
      json.abi.forEach((item) => console.log(``.padEnd(10), item.type, item.name));
      console.log("");

      abi.push(...json.abi);
    });
  });

  // Process mock facets if requested
  if (includeMocks) {
    const mockModulesDir = path.join("contracts", "mocks", "mockFacets");
    const filesInModule = fs.readdirSync(path.join(".", mockModulesDir));

    console.log("Mock Facets:");
    console.log(filesInModule);

    filesInModule.forEach((module) => {
      const file = path.join(".", mockModulesDir, module);
      const facetName = getFacetName(file);
      const jsonFileName = `${facetName}.json`;
      const jsonFileLoc = path.join(".", "artifacts", file, jsonFileName);
      const json = JSON.parse(fs.readFileSync(jsonFileLoc));

      console.log(`${module}:`.padEnd(10), file);
      json.abi.forEach((item) => console.log(``.padEnd(10), item.type, item.name));
      console.log("");

      abi.push(...json.abi);
    });
  }

  // Remove duplicates and write file
  const names = abi.map((a) => a.name);
  const filteredAbi = abi.filter((item, pos) => names.indexOf(item.name) === pos);

  fs.writeFileSync(`./abi/${outputFileName}`, JSON.stringify(filteredAbi, null, 2));

  console.log(`ABI written to abi/${outputFileName}`);
}

async function generateEcosystemABIs(contracts, outputDir = "./abi/ecosystem") {
  try {
    console.log("Generating ABIs for ecosystem contracts...");

    // Create output directory if it doesn't exist
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }

    // Generate ABI for each contract
    for (const contractName of contracts) {
      const artifact = await hre.artifacts.readArtifact(contractName);
      fs.writeFileSync(`${outputDir}/${contractName}.json`, JSON.stringify(artifact.abi, null, 2));
      console.log(`Generated ABI for ${contractName}`);
    }

    console.log("ABIs generated successfully in", outputDir);
  } catch (error) {
    console.error("Error generating ABIs:", error);
    process.exit(1);
  }
}

module.exports = function () {
  task("diamondABI", "Generates ABI file for diamond, includes all ABIs of facets", async () => {
    generateDiamondABI("Beanstalk.json", false);
  });

  task("mockDiamondABI", "Generates ABI file for mock contracts", async () => {
    generateDiamondABI("MockBeanstalk.json", true);
  });

  task("ecosystemABI", "Generates ABI files for ecosystem contracts").setAction(async () => {
    const ecosystemContracts = ["SiloHelpers", "SowBlueprintv0"];
    await generateEcosystemABIs(ecosystemContracts);
  });
};

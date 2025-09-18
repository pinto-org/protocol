const { task } = require("hardhat/config");
const path = require("path");
const fs = require("fs");
const glob = require("glob");

module.exports = function () {
  task("diamondABI", "Generates ABI file for diamond, includes all ABIs of facets", async () => {
    // The path (relative to the root of `protocol` directory) where all modules sit.
    const modulesDir = path.join("contracts", "beanstalk", "facets");

    // The list of modules to combine into a single ABI. All facets (and facet dependencies) will be aggregated.
    const modules = ["diamond", "farm", "field", "market", "silo", "sun", "metadata"];

    // The glob returns the full file path like this:
    // contracts/beanstalk/facets/silo/SiloFacet.sol
    // We want the "SiloFacet" part.
    const getFacetName = (file) => {
      return file.split("/").pop().split(".")[0];
    };

    // Load files across all modules
    const paths = [];
    modules.forEach((module) => {
      const filesInModule = fs.readdirSync(path.join(".", modulesDir, module));
      paths.push(...filesInModule.map((f) => [module, f]));
    });

    // Build ABI
    let abi = [];
    modules.forEach((module) => {
      const pattern = path.join(".", modulesDir, module, "**", "*Facet.sol");
      const files = glob.sync(pattern);
      if (module == "silo") {
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

        // Log what's being included
        console.log(`${module}:`.padEnd(10), file);
        json.abi.forEach((item) => console.log(``.padEnd(10), item.type, item.name));
        console.log("");

        abi.push(...json.abi);
      });
    });

    const names = abi.map((a) => a.name);
    fs.writeFileSync(
      "./abi/Beanstalk.json",
      JSON.stringify(
        abi.filter((item, pos) => names.indexOf(item.name) == pos),
        null,
        2
      )
    );

    console.log("ABI written to abi/Beanstalk.json");
  });

  task("mockDiamondABI", "Generates ABI file for mock contracts", async () => {
    //////////////////////// FACETS ////////////////////////

    // The path (relative to the root of `protocol` directory) where all modules sit.
    const modulesDir = path.join("contracts", "beanstalk", "facets");

    // The list of modules to combine into a single ABI. All facets (and facet dependencies) will be aggregated.
    const modules = ["diamond", "farm", "field", "market", "silo", "sun", "metadata"];

    // The glob returns the full file path like this:
    // contracts/beanstalk/facets/silo/SiloFacet.sol
    // We want the "SiloFacet" part.
    const getFacetName = (file) => {
      return file.split("/").pop().split(".")[0];
    };

    // Load files across all modules
    let paths = [];
    modules.forEach((module) => {
      const filesInModule = fs.readdirSync(path.join(".", modulesDir, module));
      paths.push(...filesInModule.map((f) => [module, f]));
    });

    // Build ABI
    let abi = [];
    modules.forEach((module) => {
      const pattern = path.join(".", modulesDir, module, "**", "*Facet.sol");
      const files = glob.sync(pattern);
      if (module == "silo") {
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

        // Log what's being included
        console.log(`${module}:`.padEnd(10), file);
        json.abi.forEach((item) => console.log(``.padEnd(10), item.type, item.name));
        console.log("");

        abi.push(...json.abi);
      });
    });

    ////////////////////////// MOCK ////////////////////////
    // The path (relative to the root of `protocol` directory) where all modules sit.
    const mockModulesDir = path.join("contracts", "mocks", "mockFacets");

    // Load files across all mock modules.
    const filesInModule = fs.readdirSync(path.join(".", mockModulesDir));
    console.log("Mock Facets:");
    console.log(filesInModule);

    // Build ABI
    filesInModule.forEach((module) => {
      const file = path.join(".", mockModulesDir, module);
      const facetName = getFacetName(file);
      const jsonFileName = `${facetName}.json`;
      const jsonFileLoc = path.join(".", "artifacts", file, jsonFileName);
      const json = JSON.parse(fs.readFileSync(jsonFileLoc));

      // Log what's being included
      console.log(`${module}:`.padEnd(10), file);
      json.abi.forEach((item) => console.log(``.padEnd(10), item.type, item.name));
      console.log("");

      abi.push(...json.abi);
    });

    const names = abi.map((a) => a.name);
    fs.writeFileSync(
      "./abi/MockBeanstalk.json",
      JSON.stringify(
        abi.filter((item, pos) => names.indexOf(item.name) == pos),
        null,
        2
      )
    );
  });

  task("ecosystemABI", "Generates ABI files for ecosystem contracts").setAction(async () => {
    try {
      console.log("Generating ABIs for ecosystem contracts...");

      // Create output directory if it doesn't exist
      const outputDir = "./abi/ecosystem";
      if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
      }

      // Generate SiloHelpers ABI
      const siloHelpersArtifact = await hre.artifacts.readArtifact("SiloHelpers");
      fs.writeFileSync(
        `${outputDir}/SiloHelpers.json`,
        JSON.stringify(siloHelpersArtifact.abi, null, 2)
      );

      // Generate SowBlueprintv0 ABI
      const sowBlueprintArtifact = await hre.artifacts.readArtifact("SowBlueprintv0");
      fs.writeFileSync(
        `${outputDir}/SowBlueprintv0.json`,
        JSON.stringify(sowBlueprintArtifact.abi, null, 2)
      );

      console.log("ABIs generated successfully in", outputDir);
    } catch (error) {
      console.error("Error generating ABIs:", error);
      process.exit(1);
    }
  });
};

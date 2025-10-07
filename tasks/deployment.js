const { task } = require("hardhat/config");
const { parseDeploymentParameters } = require("../scripts/deployment/parameters/parseParams.js");
const { upgradeWithNewFacets } = require("../scripts/diamond.js");
const { megaInit } = require("../scripts/deployment/megaInit");
const { impersonateSigner, mintEth } = require("../utils");
const { L2_PINTO, L2_PCM, PINTO_DIAMOND_DEPLOYER } = require("../test/hardhat/utils/constants.js");

module.exports = function () {
  task("epi0", async () => {
    const mock = true;
    let deployer;
    if (mock) {
      deployer = (await ethers.getSigners())[0];
      console.log("Deployer address: ", await deployer.getAddress());
    } else {
      deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
    }
    deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);

    // Deployment parameters path
    const inputFilePath = "./scripts/deployment/parameters/input/deploymentParams.json";
    let [systemData, whitelistData, wellData, tokenData, initWellDistributions, initSupply] =
      await parseDeploymentParameters(inputFilePath, false);

    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: ["MetadataFacet"],
      initFacetName: "InitZeroWell",
      initArgs: [wellData],
      bip: false,
      object: !mock,
      verbose: true,
      account: deployer,
      verify: false
    });
  });

  task("megaDeploy", "Deploys the Pinto Diamond", async function () {
    const mock = true;
    let deployer;
    let owner;
    if (mock) {
      deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
      owner = L2_PCM;
      await mintEth(owner);
      await mintEth(deployer.address);
    } else {
      deployer = (await ethers.getSigners())[0];
      console.log("Deployer address: ", await deployer.getAddress());
      owner = L2_PCM;
    }

    await megaInit({
      deployer: deployer,
      deployerAddress: PINTO_DIAMOND_DEPLOYER,
      ownerAddress: owner,
      diamondName: "PintoDiamond",
      updateOracleTimeout: true,
      addLiquidity: true,
      skipInitialAmountPrompts: true,
      verbose: true,
      mock: mock
    });
  });

  task("TractorHelpers", "Deploys TractorHelpers").setAction(async function () {
    const mock = true;
    let owner;
    if (mock) {
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
    }

    // Deploy contracts in correct order
    const priceManipulation = await ethers.getContractFactory("PriceManipulation");
    const priceManipulationContract = await priceManipulation.deploy(L2_PINTO);
    await priceManipulationContract.deployed();
    console.log("PriceManipulation deployed to:", priceManipulationContract.address);

    // Deploy SiloHelpers
    const siloHelpers = await ethers.getContractFactory("SiloHelpers");
    const siloHelpersContract = await siloHelpers.deploy(
      L2_PINTO,
      "0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E", // price contract
      await owner.getAddress(), // owner address
      priceManipulationContract.address // price manipulation contract address
    );
    await siloHelpersContract.deployed();
    console.log("SiloHelpers deployed to:", siloHelpersContract.address);

    // Deploy SowBlueprintv0 and connect it to the existing SiloHelpers
    const sowBlueprint = await ethers.getContractFactory("SowBlueprintv0");
    const sowBlueprintContract = await sowBlueprint.deploy(
      L2_PINTO,
      "0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E", // price contract
      await owner.getAddress(), // owner address
      siloHelpersContract.address // siloHelpers contract address
    );
    await sowBlueprintContract.deployed();
    console.log("SowBlueprintv0 deployed to:", sowBlueprintContract.address);

    // Rest of the facet upgrades...
    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: [
        "TokenFacet",
        "TractorFacet",
        "FieldFacet",
        "SiloFacet",
        "SiloGettersFacet",
        "TokenSupportFacet",
        "MarketplaceFacet",
        "ApprovalFacet",
        "ClaimFacet",
        "ConvertFacet",
        "PipelineConvertFacet",
        "SeasonFacet"
      ],
      libraryNames: [
        "LibSilo",
        "LibTokenSilo",
        "LibConvert",
        "LibPipelineConvert",
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      facetLibraries: {
        SiloFacet: ["LibSilo", "LibTokenSilo"],
        ClaimFacet: ["LibSilo", "LibTokenSilo"],
        ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        SeasonFacet: [
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate"
        ]
      },
      object: !mock,
      verbose: true,
      account: owner
    });
  });

  task("deploySiloHelpers", "Deploys the SiloHelpers contract").setAction(
    async (args, { network, ethers }) => {
      try {
        console.log("-----------------------------------");
        console.log("Deploying SiloHelpers...");

        // Get deployer
        const deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
        await mintEth(deployer.address);

        const BEANSTALK_PRICE = "0xd0fd333f7b30c7925debd81b7b7a4dfe106c3a5e";

        // Deploy contract
        const SiloHelpers = await ethers.getContractFactory("SiloHelpers");
        const siloHelpers = await SiloHelpers.connect(deployer).deploy(L2_PINTO, BEANSTALK_PRICE);
        await siloHelpers.deployed();

        console.log("\nSiloHelpers deployed to:", siloHelpers.address);
        console.log("-----------------------------------");
      } catch (error) {
        console.error("\x1b[31mError during deployment:\x1b[0m", error);
        process.exit(1);
      }
    }
  );

  task("deployHelperStorage", async () => {
    mock = false;
    let deployer;
    if (mock) {
      deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
    } else {
      deployer = (await ethers.getSigners())[0];
      console.log("Deployer address: ", await deployer.getAddress());

      // add a enter key:
      
    }

    const HelperStorage = await ethers.getContractFactory("HelperStorage");
    const helperStorage = await HelperStorage.connect(deployer).deploy();
    await helperStorage.deployed();

    console.log("\helperStorage deployed to:", helperStorage.address);
  });
};

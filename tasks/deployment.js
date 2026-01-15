const { task, types } = require("hardhat/config");
const { parseDeploymentParameters } = require("../scripts/deployment/parameters/parseParams.js");
const { upgradeWithNewFacets } = require("../scripts/diamond.js");
const { megaInit } = require("../scripts/deployment/megaInit");
const { impersonateSigner, mintEth } = require("../utils");
const {
  L2_PINTO,
  L2_PCM,
  PINTO_DIAMOND_DEPLOYER,
  PINTO_PRICE_CONTRACT,
  LIB_SILO_HELPERS,
  PRICE_MANIPULATION,
  TRACTOR_HELPERS,
  SILO_HELPERS
} = require("../test/hardhat/utils/constants.js");

module.exports = function () {
  // new diamond deployment
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

  // tractor blueprints deployment
  task("deployConvertUpBlueprint", "Deploys the ConvertUpBlueprint contract").setAction(
    async (args, { ethers }) => {
      mock = true;
      try {
        console.log("-----------------------------------");
        console.log("Deploying ConvertUpBlueprint and dependencies...");

        // Get deployer
        let deployer;
        if (mock) {
          deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
          await mintEth(deployer.address);
        } else {
          deployer = await ethers.getSigners()[0];
        }

        // Deploy LibSiloHelpers library first
        const libSiloHelpers = await hre.run("deployLibSiloHelpers", { mock });

        // Deploy PriceManipulation
        const priceManipulationContract = await hre.run("deployPriceManipulation", { mock });

        // Deploy TractorHelpers first (SiloHelpers depends on it)
        const tractorHelpersContract = await hre.run("deployTractorHelpers", {
          mock,
          libSiloHelpersAddress: libSiloHelpers.address
        });

        // Deploy SiloHelpers with linked library (depends on TractorHelpers and PriceManipulation)
        const siloHelpersContract = await hre.run("deploySiloHelpers", {
          mock,
          libSiloHelpersAddress: libSiloHelpers.address,
          tractorHelpersAddress: tractorHelpersContract.address,
          priceManipulationAddress: priceManipulationContract.address
        });

        // Deploy ConvertUpBlueprint with linked library and actual helper addresses
        console.log("Deploying ConvertUpBlueprint with linked libraries...");
        const ConvertUpBlueprint = await ethers.getContractFactory("ConvertUpBlueprint", {
          libraries: {
            "contracts/libraries/Silo/LibSiloHelpers.sol:LibSiloHelpers": libSiloHelpers.address
          },
          signer: deployer
        });
        const convertUpBlueprint = await ConvertUpBlueprint.deploy(
          L2_PINTO,
          await deployer.getAddress(), // owner address
          tractorHelpersContract.address, // tractorHelpers address
          siloHelpersContract.address, // siloHelpers address
          PINTO_PRICE_CONTRACT
        );
        await convertUpBlueprint.deployed();

        console.log("\n=== Deployment Summary ===");
        console.log("BeanstalkPrice:", PINTO_PRICE_CONTRACT);
        console.log("PriceManipulation:", priceManipulationContract.address);
        console.log("SiloHelpers:", siloHelpersContract.address);
        console.log("TractorHelpers:", tractorHelpersContract.address);
        console.log("LibSiloHelpers:", libSiloHelpers.address);
        console.log("ConvertUpBlueprint:", convertUpBlueprint.address);
        console.log("-----------------------------------");
      } catch (error) {
        console.error("\x1b[31mError during deployment:\x1b[0m", error);
        process.exit(1);
      }
    }
  );

  task("deployPodReferralContracts", "Deploys the Pod referral contracts").setAction(
    async (args, { ethers }) => {
      const mock = false;
      const useExistingContracts = true;
      try {
        console.log("-----------------------------------");
        console.log("Deploying Pod referral contracts...");

        // Get deployer
        let deployer;
        if (mock) {
          deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
          await mintEth(deployer.address);
        } else {
          deployer = (await ethers.getSigners())[0];
        }

        // Deploy LibSiloHelpers library first
        let libSiloHelpers;
        if (useExistingContracts) {
          libSiloHelpers = await ethers.getContractAt("LibSiloHelpers", LIB_SILO_HELPERS);
        } else {
          libSiloHelpers = await hre.run("deployLibSiloHelpers", { mock });
        }

        // Deploy PriceManipulation
        let priceManipulationContract;
        if (useExistingContracts) {
          priceManipulationContract = await ethers.getContractAt(
            "PriceManipulation",
            PRICE_MANIPULATION
          );
        } else {
          priceManipulationContract = await hre.run("deployPriceManipulation", { mock });
        }

        // Deploy TractorHelpers first (SiloHelpers depends on it)
        let tractorHelpersContract;
        if (useExistingContracts) {
          tractorHelpersContract = await ethers.getContractAt("TractorHelpers", TRACTOR_HELPERS);
        } else {
          tractorHelpersContract = await hre.run("deployTractorHelpers", {
            mock,
            libSiloHelpersAddress: libSiloHelpers.address
          });
        }

        // Deploy SiloHelpers with linked library (depends on TractorHelpers and PriceManipulation)
        let siloHelpersContract;
        if (useExistingContracts) {
          siloHelpersContract = await ethers.getContractAt("SiloHelpers", SILO_HELPERS);
        } else {
          siloHelpersContract = await hre.run("deploySiloHelpers", {
            mock,
            libSiloHelpersAddress: libSiloHelpers.address,
            tractorHelpersAddress: tractorHelpersContract.address,
            priceManipulationAddress: priceManipulationContract.address
          });
        }

        // Deploy PodReferral with linked library and actual helper addresses
        console.log("Deploying SowBlueprintReferralBlueprint");
        const SowBlueprintReferralBlueprint = await ethers.getContractFactory(
          "SowBlueprintReferral",
          {
            libraries: {
              "contracts/libraries/Silo/LibSiloHelpers.sol:LibSiloHelpers": libSiloHelpers.address
            },
            signer: deployer
          }
        );
        const sowBlueprintReferralBlueprint = await SowBlueprintReferralBlueprint.deploy(
          L2_PINTO,
          await deployer.address, // owner address
          tractorHelpersContract.address, // tractorHelpers address
          siloHelpersContract.address // siloHelpers address
        );
        await sowBlueprintReferralBlueprint.deployed();

        console.log("\n=== Deployment Summary ===");
        console.log("BeanstalkPrice:", PINTO_PRICE_CONTRACT);
        console.log("PriceManipulation:", priceManipulationContract.address);
        console.log("SiloHelpers:", siloHelpersContract.address);
        console.log("TractorHelpers:", tractorHelpersContract.address);
        console.log("LibSiloHelpers:", libSiloHelpers.address);
        console.log("SowBlueprintReferral:", sowBlueprintReferralBlueprint.address);
        console.log("-----------------------------------");
      } catch (error) {
        console.error("\x1b[31mError during deployment:\x1b[0m", error);
        process.exit(1);
      }
    }
  );

  // Emergency deployment tasks

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

  // misc

  task("deployHelperStorage", async () => {
    mock = false;
    let deployer;
    if (mock) {
      deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
    } else {
      deployer = (await ethers.getSigners())[0];
      console.log("Deployer address: ", await deployer.getAddress());
    }

    const HelperStorage = await ethers.getContractFactory("HelperStorage");
    const helperStorage = await HelperStorage.connect(deployer).deploy();
    await helperStorage.deployed();

    console.log("\helperStorage deployed to:", helperStorage.address);
  });

  // tractor blueprint components

  task("deployBeanstalkPrice", "Deploys the BeanstalkPrice contract").setAction(
    async (args, { network, ethers }) => {
      mock = true;
      let deployer;
      if (mock) {
        deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = await ethers.getSigners()[0];
      }
      const beanstalkPrice = await ethers.getContractFactory("BeanstalkPrice");
      const beanstalkPriceContract = await beanstalkPrice.deploy(L2_PINTO);
      await beanstalkPriceContract.deployed();
      console.log("BeanstalkPrice deployed to:", beanstalkPriceContract.address);
      return beanstalkPriceContract.address;
    }
  );

  task("deployLibSiloHelpers", "Deploys the LibSiloHelpers contract").setAction(
    async (args, { ethers }) => {
      const { mock } = args;
      let deployer;
      if (mock) {
        deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }
      console.log("Deploying LibSiloHelpers library...");
      const LibSiloHelpers = await ethers.getContractFactory("LibSiloHelpers", deployer);
      const libSiloHelpers = await LibSiloHelpers.deploy();
      await libSiloHelpers.deployed();
      console.log("LibSiloHelpers deployed to:", libSiloHelpers.address);
      return libSiloHelpers;
    }
  );

  task("deployPriceManipulation", "Deploys the PriceManipulation contract")
    .addParam("mock", "Whether to use mock deployment", false, types.boolean)
    .setAction(async (taskArgs, { ethers }) => {
      const { mock } = taskArgs;
      let deployer;
      if (mock) {
        deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }
      console.log("Deploying PriceManipulation...");
      const PriceManipulation = await ethers.getContractFactory("PriceManipulation", deployer);
      const priceManipulation = await PriceManipulation.deploy(L2_PINTO);
      await priceManipulation.deployed();
      console.log("PriceManipulation deployed to:", priceManipulation.address);
      return priceManipulation;
    });

  task("deployTractorHelpers", "Deploys the TractorHelpers contract")
    .addParam("mock", "Whether to use mock deployment", false, types.boolean)
    .addOptionalParam(
      "libSiloHelpersAddress",
      "Address of LibSiloHelpers library",
      undefined,
      types.string
    )
    .setAction(async (taskArgs, { ethers, hre }) => {
      const { mock, libSiloHelpersAddress } = taskArgs;
      let deployer;
      if (mock) {
        deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }

      // Deploy or get LibSiloHelpers address
      let libSiloHelpersAddr = libSiloHelpersAddress;
      if (!libSiloHelpersAddr) {
        const libSiloHelpers = await hre.run("deployLibSiloHelpers", { mock });
        libSiloHelpersAddr = libSiloHelpers.address;
      }

      console.log("Deploying TractorHelpers...");
      const tractorHelpers = await ethers.getContractFactory("TractorHelpers", {
        libraries: {
          "contracts/libraries/Silo/LibSiloHelpers.sol:LibSiloHelpers": libSiloHelpersAddr
        },
        signer: deployer
      });
      const tractorHelpersContract = await tractorHelpers.deploy(L2_PINTO, PINTO_PRICE_CONTRACT);
      await tractorHelpersContract.deployed();
      console.log("TractorHelpers deployed to:", tractorHelpersContract.address);
      return tractorHelpersContract;
    });

  task("deploySiloHelpers", "Deploys the SiloHelpers contract")
    .addParam("mock", "Whether to use mock deployment", false, types.boolean)
    .addOptionalParam(
      "libSiloHelpersAddress",
      "Address of LibSiloHelpers library",
      undefined,
      types.string
    )
    .addOptionalParam(
      "tractorHelpersAddress",
      "Address of TractorHelpers contract",
      undefined,
      types.string
    )
    .addOptionalParam(
      "priceManipulationAddress",
      "Address of PriceManipulation contract",
      undefined,
      types.string
    )
    .setAction(async (taskArgs, { ethers, hre }) => {
      const { mock, libSiloHelpersAddress, tractorHelpersAddress, priceManipulationAddress } =
        taskArgs;
      let deployer;
      if (mock) {
        deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }

      // Deploy or get LibSiloHelpers address
      let libSiloHelpersAddr = libSiloHelpersAddress;
      if (!libSiloHelpersAddr) {
        const libSiloHelpers = await hre.run("deployLibSiloHelpers", { mock });
        libSiloHelpersAddr = libSiloHelpers.address;
      }

      // Deploy or get TractorHelpers address
      let tractorHelpersAddr = tractorHelpersAddress;
      if (!tractorHelpersAddr) {
        const tractorHelpers = await hre.run("deployTractorHelpers", {
          mock,
          libSiloHelpersAddress: libSiloHelpersAddr
        });
        tractorHelpersAddr = tractorHelpers.address;
      }

      // Deploy or get PriceManipulation address
      let priceManipulationAddr = priceManipulationAddress;
      if (!priceManipulationAddr) {
        const priceManipulation = await hre.run("deployPriceManipulation", { mock });
        priceManipulationAddr = priceManipulation.address;
      }

      console.log("Deploying SiloHelpers...");
      const siloHelpers = await ethers.getContractFactory("SiloHelpers", {
        libraries: {
          "contracts/libraries/Silo/LibSiloHelpers.sol:LibSiloHelpers": libSiloHelpersAddr
        },
        signer: deployer
      });
      const siloHelpersContract = await siloHelpers.deploy(
        L2_PINTO,
        tractorHelpersAddr,
        priceManipulationAddr
      );
      await siloHelpersContract.deployed();
      console.log("SiloHelpers deployed to:", siloHelpersContract.address);
      return siloHelpersContract;
    });

  task("deployLSDChainlinkOracle", "Deploys the LSDChainlinkOracle contract").setAction(
    async (args, { ethers }) => {
      const mock = false;
      let deployer;
      if (mock) {
        deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }

      const LSDChainlinkOracle = await ethers.getContractFactory("LSDChainlinkOracle");
      const lsdChainlinkOracle = await LSDChainlinkOracle.deploy();
      await lsdChainlinkOracle.deployed();
      console.log("LSDChainlinkOracle deployed to:", lsdChainlinkOracle.address);
      return lsdChainlinkOracle;
    }
  );
};

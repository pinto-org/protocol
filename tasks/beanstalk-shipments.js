module.exports = function () {
  const fs = require("fs");
  const { task } = require("hardhat/config");
  const { impersonateSigner, mintEth, getBeanstalk } = require("../utils");
  const {
    L2_PINTO,
    L2_PCM,
    PINTO,
    L1_CONTRACT_MESSENGER_DEPLOYER,
    BEANSTALK_CONTRACT_PAYBACK_DISTRIBUTOR,
    BEANSTALK_SHIPMENTS_DEPLOYER,
    BEANSTALK_SHIPMENTS_REPAYMENT_FIELD_POPULATOR,
    BEANSTALK_SILO_PAYBACK,
    BEANSTALK_BARN_PAYBACK
  } = require("../test/hardhat/utils/constants.js");
  const { upgradeWithNewFacets } = require("../scripts/diamond.js");
  const {
    populateBeanstalkField
  } = require("../scripts/beanstalkShipments/populateBeanstalkField.js");
  const {
    deployAndSetupContracts,
    transferContractOwnership
  } = require("../scripts/beanstalkShipments/deployPaybackContracts.js");
  const { parseAllExportData } = require("../scripts/beanstalkShipments/parsers");

  //////////////////////// BEANSTALK SHIPMENTS ////////////////////////

  ////// PRE-DEPLOYMENT: ANALYZE SHIPMENT CONTRACTS //////
  // Analyzes all addresses with Beanstalk assets to determine claimability on Base.
  // Detects Safe wallets, EIP-7702 delegations, EIP-1167 proxies, and Ambire wallets.
  // Outputs: shipmentContractAnalysis.json, eip7702Addresses.json, unclaimableContractAddresses.json
  // Requires MAINNET_RPC, ARBITRUM_RPC and BASE_RPC in .env
  //  - npx hardhat analyzeShipmentContracts
  task(
    "analyzeShipmentContracts",
    "analyzes contract addresses for cross-chain claimability"
  ).setAction(async () => {
    const { main } = require("../scripts/beanstalkShipments/analyzeShipmentContracts");
    await main();
  });

  ////// PRE-DEPLOYMENT: DEPLOY L1 CONTRACT MESSENGER //////
  // As a backup solution, ethAccounts will be able to send a message on the L1 to claim their assets on the L2
  // from the L2 ContractPaybackDistributor contract. We deploy the L1ContractMessenger contract on the L1
  // and whitelist the ethAccounts that are eligible to claim their assets.
  // Requires: analyzeShipmentContracts (generates unclaimableContractAddresses.json)
  // Make sure account[0] in the hardhat config for mainnet is the L1_CONTRACT_MESSENGER_DEPLOYER at 0xbfb5d09ffcbe67fbed9970b893293f21778be0a6
  //  - npx hardhat deployL1ContractMessenger --network mainnet
  task("deployL1ContractMessenger", "deploys the L1ContractMessenger contract").setAction(
    async (taskArgs) => {
      const mock = true;
      let deployer;
      if (mock) {
        deployer = await impersonateSigner(L1_CONTRACT_MESSENGER_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }

      // log deployer address
      console.log("Deployer address:", deployer.address);

      // read the unclaimable contract addresses from the json file
      const contractAccounts = JSON.parse(
        fs.readFileSync("./scripts/beanstalkShipments/data/unclaimableContractAddresses.json")
      );

      const L1Messenger = await ethers.getContractFactory("L1ContractMessenger");
      const l1Messenger = await L1Messenger.deploy(
        BEANSTALK_CONTRACT_PAYBACK_DISTRIBUTOR,
        contractAccounts
      );
      await l1Messenger.deployed();

      console.log("L1ContractMessenger deployed to:", l1Messenger.address);
    }
  );

  ////// STEP 0: PARSE EXPORT DATA //////
  // Run this task prior to deploying the contracts on a local fork at the latest base block to
  // dynamically identify EOAs that have contract code due to contract code delegation.
  // Spin up a local anvil node:
  //  - anvil --fork-url <url> --chain-id 1337 --no-rate-limit --threads 0
  // Run the parseExportData task:
  //  - npx hardhat parseExportData --network localhost
  task("parseExportData", "parses the export data and checks for contract addresses").setAction(
    async (taskArgs) => {
      const parseContracts = true;
      // Step 0: Parse export data into required format
      console.log("\n=� STEP 0: PARSING EXPORT DATA");
      console.log("-".repeat(50));
      try {
        await parseAllExportData(parseContracts);
        console.log(" Export data parsing completed");
      } catch (error) {
        console.error("L Failed to parse export data:", error);
        throw error;
      }
    }
  );

  ////// STEP 1: DEPLOY PAYBACK CONTRACTS //////
  // Deploy and initialize the payback contracts and the ContractPaybackDistributor contract
  // Make sure account[1] in the hardhat config for base is the BEANSTALK_SHIPMENTS_DEPLOYER at 0x47c365cc9ef51052651c2be22f274470ad6afc53
  // Set mock to false to deploy the payback contracts on base.
  //  - npx hardhat deployPaybackContracts --network base
  task(
    "deployPaybackContracts",
    "performs all actions to initialize the beanstalk shipments"
  ).setAction(async (taskArgs) => {
    // params
    const verbose = true;
    const populateData = true;
    const mock = true;

    // Use the shipments deployer to get correct addresses
    let deployer;
    if (mock) {
      deployer = await impersonateSigner(BEANSTALK_SHIPMENTS_DEPLOYER);
      await mintEth(deployer.address);
    } else {
      deployer = (await ethers.getSigners())[1];
    }

    // Step 1: Deploy and setup payback contracts, distribute assets to users and distributor contract
    console.log("STEP 1: DEPLOYING AND INITIALIZING PAYBACK CONTRACTS");
    console.log("-".repeat(50));
    await deployAndSetupContracts({
      PINTO,
      L2_PINTO,
      L2_PCM,
      account: deployer,
      verbose,
      populateData: populateData,
      useChunking: true
    });
    console.log(" Payback contracts deployed and configured\n");
  });

  ////// STEP 2: DEPLOY TEMP_FIELD_FACET AND TOKEN_HOOK_FACET //////
  // To minimize the number of transaction the PCM multisig has to sign, we deploy the TempFieldFacet
  // that allows an EOA to add plots to the repayment field.
  // Set mock to false to deploy the TempFieldFacet
  //  - npx hardhat deployTempFieldFacet --network base
  // Grab the diamond cut, queue it in the multisig and wait for execution before proceeding to the next step.
  task("deployTempFieldFacet", "deploys the TempFieldFacet").setAction(async (taskArgs) => {
    // params
    const mock = true;

    // Step 2: Create the new TempRepaymentFieldFacet via diamond cut and populate the repayment field
    console.log(
      "STEP 2: ADDING NEW TEMP_REPAYMENT_FIELD_FACET AND THE TOKEN_HOOK_FACET TO THE PINTO DIAMOND"
    );
    console.log("-".repeat(50));

    let deployer;
    if (mock) {
      deployer = await impersonateSigner(L2_PCM);
      await mintEth(deployer.address);
    } else {
      deployer = (await ethers.getSigners())[0];
    }

    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: ["TempRepaymentFieldFacet"],
      libraryNames: [],
      facetLibraries: {},
      initArgs: [],
      verbose: true,
      object: !mock,
      account: deployer
    });
  });

  ////// STEP 3: POPULATE THE BEANSTALK FIELD WITH DATA //////
  // After the initialization of the repayment field is done and the shipments have been deployed
  // The PCM will need to remove the TempRepaymentFieldFacet from the diamond since it is no longer needed
  // Set mock to false to populate the repayment field on base.
  //  - npx hardhat populateRepaymentField --network base
  task("populateRepaymentField", "populates the repayment field with data").setAction(
    async (taskArgs) => {
      // params
      const mock = true;
      const verbose = true;

      let repaymentFieldPopulator;
      if (mock) {
        repaymentFieldPopulator = await impersonateSigner(
          BEANSTALK_SHIPMENTS_REPAYMENT_FIELD_POPULATOR
        );
        await mintEth(repaymentFieldPopulator.address);
      } else {
        repaymentFieldPopulator = (await ethers.getSigners())[2];
      }

      // Populate the repayment field with data
      console.log("STEP 3: POPULATING THE BEANSTALK FIELD WITH DATA");
      console.log("-".repeat(50));
      await populateBeanstalkField({
        diamondAddress: L2_PINTO,
        account: repaymentFieldPopulator,
        verbose: verbose
      });
      console.log(" Beanstalk field initialized\n");
    }
  );

  ////// STEP 4: FINALIZE THE BEANSTALK SHIPMENTS //////
  // The PCM will need to remove the TempRepaymentFieldFacet from the diamond since it is no longer needed
  // At the same time, the new shipment routes that include the payback contracts will need to be set.
  // Set mock to false to finalize the beanstalk shipments on base.
  //  - npx hardhat finalizeBeanstalkShipments --network base
  task("finalizeBeanstalkShipments", "finalizes the beanstalk shipments").setAction(
    async (taskArgs) => {
      // params
      const mock = true;

      // Use any account for diamond cuts
      let owner;
      if (mock) {
        owner = await impersonateSigner(L2_PCM);
        await mintEth(owner.address);
      } else {
        owner = (await ethers.getSigners())[0];
      }

      // Step 4: Update shipment routes, create new field and remove the TempRepaymentFieldFacet
      // The SeasonFacet will also need to be updated since LibReceiving was modified.
      // Selectors removed:
      // 0x31f2cd56: REPAYMENT_FIELD_ID()
      // 0x49e40d6c: REPAYMENT_FIELD_POPULATOR()
      // 0x1fd620f9: initializeRepaymentPlots()
      console.log("\nSTEP 4: UPDATING SHIPMENT ROUTES, CREATING NEW FIELD AND REMOVING TEMP FACET");
      const routesPath = "./scripts/beanstalkShipments/data/updatedShipmentRoutes.json";
      const routes = JSON.parse(fs.readFileSync(routesPath));

      await upgradeWithNewFacets({
        diamondAddress: L2_PINTO,
        facetNames: ["SeasonFacet", "TokenHookFacet", "ShipmentPlannerFacet"],
        libraryNames: [
          "LibEvaluate",
          "LibSeedGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate",
          "LibWeather"
        ],
        facetLibraries: {
          SeasonFacet: [
            "LibEvaluate",
            "LibSeedGauge",
            "LibIncentive",
            "LibShipping",
            "LibWellMinting",
            "LibFlood",
            "LibGerminate",
            "LibWeather"
          ]
        },
        initFacetName: "InitBeanstalkShipments",
        initArgs: [routes, BEANSTALK_SILO_PAYBACK],
        selectorsToRemove: ["0x31f2cd56", "0x49e40d6c", "0x1fd620f9"],
        verbose: true,
        object: !mock,
        account: owner
      });
      console.log(" Shipment routes updated and new field created\n");
    }
  );

  ////// STEP 5: TRANSFER OWNERSHIP OF PAYBACK CONTRACTS TO THE PCM //////
  // The deployer will need to transfer ownership of the payback contracts to the PCM
  //  - npx hardhat transferContractOwnership --network base
  // Set mock to false to transfer ownership of the payback contracts to the PCM on base.
  // The owner is the deployer account at 0x47c365cc9ef51052651c2be22f274470ad6afc53
  task(
    "transferPaybackContractOwnership",
    "transfers ownership of the payback contracts to the PCM"
  ).setAction(async (taskArgs) => {
    const mock = true;
    const verbose = true;

    let deployer;
    if (mock) {
      deployer = await impersonateSigner(BEANSTALK_SHIPMENTS_DEPLOYER);
      await mintEth(deployer.address);
    } else {
      deployer = (await ethers.getSigners())[0];
    }

    const siloPaybackContract = await ethers.getContractAt("SiloPayback", BEANSTALK_SILO_PAYBACK);
    const barnPaybackContract = await ethers.getContractAt("BarnPayback", BEANSTALK_BARN_PAYBACK);
    const contractPaybackDistributorContract = await ethers.getContractAt(
      "ContractPaybackDistributor",
      BEANSTALK_CONTRACT_PAYBACK_DISTRIBUTOR
    );

    await transferContractOwnership({
      siloPaybackContract: siloPaybackContract,
      barnPaybackContract: barnPaybackContract,
      contractPaybackDistributorContract: contractPaybackDistributorContract,
      deployer: deployer,
      newOwner: L2_PCM,
      verbose: verbose
    });
  });

  ////// SEQUENTIAL ORCHESTRATION TASK //////
  // Runs all beanstalk shipment tasks in the correct sequential order
  // Note: deployL1ContractMessenger should be run separately on mainnet before this
  //  - npx hardhat runBeanstalkShipments --network base
  task("runBeanstalkShipments", "Runs all beanstalk shipment deployment steps in sequential order")
    .addOptionalParam("skipPause", "Set to true to skip pauses between steps", false, types.boolean)
    .addOptionalParam(
      "runStep0",
      "Set to true to run Step 0: Parse Export Data",
      false,
      types.boolean
    )
    .setAction(async (taskArgs) => {
      console.log("\n🚀 STARTING BEANSTALK SHIPMENTS DEPLOYMENT");
      console.log("=".repeat(60));

      // Helper function for pausing, only if !skipPause
      async function pauseIfNeeded(message = "Press Enter to continue...") {
        if (taskArgs.skipPause) {
          return;
        }
        console.log(message);
        await new Promise((resolve) => {
          process.stdin.resume();
          process.stdin.once("data", () => {
            process.stdin.pause();
            resolve();
          });
        });
      }

      try {
        // Step 0: Parse Export Data (optional)
        if (taskArgs.runStep0) {
          console.log("\n📊 Running Step 0: Parse Export Data");
          await hre.run("parseExportData");
        }

        // Step 1: Deploy Payback Contracts
        console.log("\n📦 Running Step 1: Deploy Payback Contracts");
        await hre.run("deployPaybackContracts");

        // Step 2: Deploy Temp Field Facet
        console.log("\n🔧 Running Step 2: Deploy Temp Field Facet");
        await hre.run("deployTempFieldFacet");
        console.log("\n⚠️  PAUSE: Queue the diamond cut in the multisig and wait for execution");
        await pauseIfNeeded(
          "Press Ctrl+C to stop, or press Enter to continue after multisig execution..."
        );

        // Step 3: Populate Repayment Field
        console.log("\n🌾 Running Step 3: Populate Repayment Field");
        await hre.run("populateRepaymentField");
        console.log(
          "\n⚠️  PAUSE: Proceed with the multisig as needed before moving to the next step"
        );
        await pauseIfNeeded(
          "Press Ctrl+C to stop, or press Enter to continue after necessary approvals..."
        );

        // Step 4: Finalize Beanstalk Shipments
        console.log("\n🎯 Running Step 4: Finalize Beanstalk Shipments");
        await hre.run("finalizeBeanstalkShipments");
        console.log("\n⚠️  PAUSE: Queue the diamond cut in the multisig and wait for execution");
        await pauseIfNeeded(
          "Press Ctrl+C to stop, or press Enter to continue after multisig execution..."
        );

        // Step 5: Transfer Contract Ownership
        console.log("\n🔐 Running Step 5: Transfer Contract Ownership");
        await hre.run("transferPaybackContractOwnership");
        console.log(
          "\n⚠️  PAUSE: Ownership transfer completed. Proceed with validations as required."
        );
        await pauseIfNeeded("Press Ctrl+C to stop, or press Enter to finish...");

        console.log("\n" + "=".repeat(60));
        console.log("✅ BEANSTALK SHIPMENTS DEPLOYMENT COMPLETED SUCCESSFULLY!");
        console.log("=".repeat(60) + "\n");
      } catch (error) {
        console.error("\n❌ ERROR: Beanstalk Shipments deployment failed:", error.message);
        throw error;
      }
    });
};

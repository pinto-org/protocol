module.exports = function () {
  const fs = require("fs");
  const { task } = require("hardhat/config");
  const { impersonateSigner, mintEth, getBeanstalk } = require("../utils");
  const {
    L2_PINTO,
    L2_PCM,
    PINTO,
    L1_CONTRACT_MESSENGER_DEPLOYER,
    BEANSTALK_SHIPMENTS_DEPLOYER,
    BEANSTALK_SHIPMENTS_REPAYMENT_FIELD_POPULATOR,
    BEANSTALK_SILO_PAYBACK
  } = require("../test/hardhat/utils/constants.js");
  const { upgradeWithNewFacets } = require("../scripts/diamond.js");
  const {
    populateBeanstalkField
  } = require("../scripts/beanstalkShipments/populateBeanstalkField.js");
  const {
    deployAndSetupContracts,
    transferContractOwnership
  } = require("../scripts/beanstalkShipments/deployPaybackContracts.js");
  const {
    initializeSiloPayback
  } = require("../scripts/beanstalkShipments/initializeSiloPayback.js");
  const {
    initializeBarnPayback
  } = require("../scripts/beanstalkShipments/initializeBarnPayback.js");
  const {
    initializeContractPaybackDistributor
  } = require("../scripts/beanstalkShipments/initializeContractPaybackDistributor.js");
  const { getDeployedAddresses } = require("../scripts/beanstalkShipments/utils/addressCache.js");
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

      // Get distributor address from cache
      const cachedAddresses = getDeployedAddresses();
      if (!cachedAddresses || !cachedAddresses.contractPaybackDistributor) {
        throw new Error(
          "ContractPaybackDistributor address not found in cache. Run 'npx hardhat precomputeDistributorAddress' first."
        );
      }
      const distributorAddress = cachedAddresses.contractPaybackDistributor;
      console.log(`Using distributor address from cache: ${distributorAddress}`);

      // read the unclaimable contract addresses from the json file
      const contractAccounts = JSON.parse(
        fs.readFileSync("./scripts/beanstalkShipments/data/unclaimableContractAddresses.json")
      );

      const L1Messenger = await ethers.getContractFactory("L1ContractMessenger");
      const l1Messenger = await L1Messenger.deploy(distributorAddress, contractAccounts);
      await l1Messenger.deployed();

      console.log("L1ContractMessenger deployed to:", l1Messenger.address);
    }
  );

  ////// STEP 0: PARSE EXPORT DATA //////
  // Parses the export data and detects contract addresses using direct RPC calls
  // to Ethereum and Arbitrum. Requires MAINNET_RPC and ARBITRUM_RPC in .env
  //  - npx hardhat parseExportData
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
  // Deploy the payback contracts and the ContractPaybackDistributor contract (no initialization)
  // Data initialization is now handled by separate tasks (Steps 1.5, 1.6, 1.7)
  // Make sure account[1] in the hardhat config for base is the BEANSTALK_SHIPMENTS_DEPLOYER
  // Set mock to false to deploy the payback contracts on base.
  //  - npx hardhat deployPaybackContracts --network base
  task("deployPaybackContracts", "deploys the payback contracts (no initialization)").setAction(
    async (taskArgs, hre) => {
      // params
      const verbose = true;
      const mock = false;

      // Use the shipments deployer to get correct addresses
      let deployer;
      if (mock) {
        deployer = await impersonateSigner(BEANSTALK_SHIPMENTS_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }

      // Step 1: Deploy payback contracts only (initialization is now separate)
      console.log("-".repeat(50));

      const contracts = await deployAndSetupContracts({
        PINTO,
        L2_PINTO,
        L2_PCM,
        account: deployer,
        verbose,
        network: hre.network.name
      });
      console.log(" Payback contracts deployed\n");
      console.log("📝 Next steps:");
      console.log("   Run initializeSiloPayback (Step 1.5)");
      console.log("   Run initializeBarnPayback (Step 1.6)");
      console.log("   Run initializeContractPaybackDistributor (Step 1.7)");

      // Step 1b: Update the shipment routes JSON with deployed contract addresses
      console.log("STEP 1b: UPDATING SHIPMENT ROUTES WITH DEPLOYED ADDRESSES");
      console.log("-".repeat(50));

      const routesPath = "./scripts/beanstalkShipments/data/updatedShipmentRoutes.json";
      const routes = JSON.parse(fs.readFileSync(routesPath));

      const siloPaybackAddress = contracts.siloPaybackContract.address;
      const barnPaybackAddress = contracts.barnPaybackContract.address;
      const contractPaybackDistributorAddress =
        contracts.contractPaybackDistributorContract.address;

      // Helper to encode addresses into padded hex data
      const encodeAddress = (addr) => addr.toLowerCase().replace("0x", "").padStart(64, "0");
      const encodeUint256 = (num) => num.toString(16).padStart(64, "0");

      // Route 4 (index 3): getPaybackFieldPlan - data = (siloPayback, barnPayback, fieldId)
      // fieldId = 1 for the repayment field
      routes[3].data =
        "0x" +
        encodeAddress(siloPaybackAddress) +
        encodeAddress(barnPaybackAddress) +
        encodeUint256(1);

      // Route 5 (index 4): getPaybackSiloPlan - data = (siloPayback, barnPayback)
      routes[4].data = "0x" + encodeAddress(siloPaybackAddress) + encodeAddress(barnPaybackAddress);

      // Route 6 (index 5): getPaybackBarnPlan - data = (siloPayback, barnPayback)
      // Note: Order must be (siloPayback, barnPayback) to match paybacksRemaining() decoding
      routes[5].data = "0x" + encodeAddress(siloPaybackAddress) + encodeAddress(barnPaybackAddress);

      fs.writeFileSync(routesPath, JSON.stringify(routes, null, 4));
      console.log("Updated updatedShipmentRoutes.json with deployed contract addresses:");
      console.log(`   - SiloPayback: ${siloPaybackAddress}`);
      console.log(`   - BarnPayback: ${barnPaybackAddress}`);
      console.log(`   - ContractPaybackDistributor: ${contractPaybackDistributorAddress}`);
    }
  );

  ////// STEP 1.5: INITIALIZE SILO PAYBACK //////
  // Initialize the SiloPayback contract with unripe BDV data
  // Must be run after deployPaybackContracts (Step 1) or with --use-deployed for production addresses
  //  - npx hardhat initializeSiloPayback --network base
  //  - npx hardhat initializeSiloPayback --use-deployed --network base (use production addresses)
  // Resume parameters:
  //  - npx hardhat initializeSiloPayback --start-chunk 5 --network base
  task("initializeSiloPayback", "Initialize SiloPayback with unripe BDV data")
    .addOptionalParam("startChunk", "Resume from chunk number (0-indexed)", 0, types.int)
    .addOptionalParam(
      "useDeployed",
      "Use production addresses from productionAddresses.json instead of latest dev deployment",
      false,
      types.boolean
    )
    .setAction(async (taskArgs) => {
      const mock = true;
      const verbose = true;

      let deployer;
      if (mock) {
        deployer = await impersonateSigner(BEANSTALK_SHIPMENTS_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }

      await initializeSiloPayback({
        account: deployer,
        verbose,
        startFromChunk: taskArgs.startChunk,
        useDeployed: taskArgs.useDeployed
      });
    });

  ////// STEP 1.6: INITIALIZE BARN PAYBACK //////
  // Initialize the BarnPayback contract with fertilizer data
  // Must be run after deployPaybackContracts (Step 1) or with --use-deployed for production addresses
  //  - npx hardhat initializeBarnPayback --network base
  //  - npx hardhat initializeBarnPayback --use-deployed --network base (use production addresses)
  // Resume parameters:
  //  - npx hardhat initializeBarnPayback --start-chunk 10 --network base
  task("initializeBarnPayback", "Initialize BarnPayback with fertilizer data")
    .addOptionalParam("startChunk", "Resume from chunk number (0-indexed)", 0, types.int)
    .addOptionalParam(
      "useDeployed",
      "Use production addresses from productionAddresses.json instead of latest dev deployment",
      false,
      types.boolean
    )
    .setAction(async (taskArgs) => {
      const mock = true;
      const verbose = true;

      let deployer;
      if (mock) {
        deployer = await impersonateSigner(BEANSTALK_SHIPMENTS_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }

      await initializeBarnPayback({
        account: deployer,
        verbose,
        startFromChunk: taskArgs.startChunk,
        useDeployed: taskArgs.useDeployed
      });
    });

  ////// STEP 1.7: INITIALIZE CONTRACT PAYBACK DISTRIBUTOR //////
  // Initialize the ContractPaybackDistributor contract with account data
  // Must be run after deployPaybackContracts (Step 1) or with --use-deployed for production addresses
  //  - npx hardhat initializeContractPaybackDistributor --network base
  //  - npx hardhat initializeContractPaybackDistributor --use-deployed --network base (use production addresses)
  // Resume parameters:
  //  - npx hardhat initializeContractPaybackDistributor --start-chunk 3 --network base
  task(
    "initializeContractPaybackDistributor",
    "Initialize ContractPaybackDistributor with account data"
  )
    .addOptionalParam("startChunk", "Resume from chunk number (0-indexed)", 0, types.int)
    .addOptionalParam(
      "useDeployed",
      "Use production addresses from productionAddresses.json instead of latest dev deployment",
      false,
      types.boolean
    )
    .setAction(async (taskArgs) => {
      const mock = true;
      const verbose = true;

      let deployer;
      if (mock) {
        deployer = await impersonateSigner(BEANSTALK_SHIPMENTS_DEPLOYER);
        await mintEth(deployer.address);
      } else {
        deployer = (await ethers.getSigners())[0];
      }

      await initializeContractPaybackDistributor({
        account: deployer,
        verbose,
        startFromChunk: taskArgs.startChunk,
        useDeployed: taskArgs.useDeployed
      });
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
  // Resume parameters:
  //  - npx hardhat populateRepaymentField --field-start-chunk 15 --network base
  task("populateRepaymentField", "populates the repayment field with data")
    .addOptionalParam(
      "fieldStartChunk",
      "Chunk index to resume field population from (0-indexed)",
      0,
      types.int
    )
    .setAction(async (taskArgs) => {
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

      if (taskArgs.fieldStartChunk > 0) {
        console.log(`⏩ Resume mode: starting from chunk ${taskArgs.fieldStartChunk}`);
      }

      await populateBeanstalkField({
        diamondAddress: L2_PINTO,
        account: repaymentFieldPopulator,
        verbose: verbose,
        startFromChunk: taskArgs.fieldStartChunk
      });
      console.log(" Beanstalk field initialized\n");
    });

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
  // The owner is the deployer account.
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

    // Get addresses from cache
    const cachedAddresses = getDeployedAddresses();
    if (
      !cachedAddresses ||
      !cachedAddresses.siloPayback ||
      !cachedAddresses.barnPayback ||
      !cachedAddresses.contractPaybackDistributor
    ) {
      throw new Error(
        "Contract addresses not found in cache. Run 'npx hardhat deployPaybackContracts' first."
      );
    }

    const siloPaybackContract = await ethers.getContractAt(
      "SiloPayback",
      cachedAddresses.siloPayback
    );
    const barnPaybackContract = await ethers.getContractAt(
      "BarnPayback",
      cachedAddresses.barnPayback
    );
    const contractPaybackDistributorContract = await ethers.getContractAt(
      "ContractPaybackDistributor",
      cachedAddresses.contractPaybackDistributor
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
  //  - npx hardhat runBeanstalkShipments --step 1.5 --network base (run specific step)
  //  - npx hardhat runBeanstalkShipments --step all --network base (run all steps)
  //  - npx hardhat runBeanstalkShipments --step deploy --network base (deploy all payback contracts)
  //  - npx hardhat runBeanstalkShipments --step init --network base (initialize all payback contracts)
  //  - npx hardhat runBeanstalkShipments --step init --use-deployed --network base (init with production addresses)
  // Available steps: 0, 1, 1.5, 1.6, 1.7, 2, 3, 4, 5, all, deploy, init
  task("runBeanstalkShipments", "Runs all beanstalk shipment deployment steps in sequential order")
    .addOptionalParam("skipPause", "Set to true to skip pauses between steps", false, types.boolean)
    .addOptionalParam(
      "step",
      "Step to run (0, 1, 1.5, 1.6, 1.7, 2, 3, 4, 5, 'all', 'deploy', or 'init')",
      "all",
      types.string
    )
    .addOptionalParam(
      "useDeployed",
      "Use production addresses from productionAddresses.json for init steps",
      false,
      types.boolean
    )
    .setAction(async (taskArgs, hre) => {
      const step = taskArgs.step;
      const validSteps = [
        "0",
        "1",
        "1.5",
        "1.6",
        "1.7",
        "2",
        "3",
        "4",
        "5",
        "all",
        "deploy",
        "init"
      ];

      // Step group definitions
      const stepGroups = {
        deploy: ["1"], // Deploy all payback contracts
        init: ["1.5", "1.6", "1.7"] // Initialize all payback contracts
      };

      if (!validSteps.includes(step)) {
        console.error(`❌ Invalid step: ${step}`);
        console.error(`Valid steps: ${validSteps.join(", ")}`);
        console.error(`\nKeywords:`);
        console.error(`  deploy - Deploy payback contracts (Step 1)`);
        console.error(`  init   - Initialize all payback contracts (Steps 1.5, 1.6, 1.7)`);
        return;
      }

      console.log("\n🚀 STARTING BEANSTALK SHIPMENTS DEPLOYMENT");
      console.log("=".repeat(60));

      if (step === "deploy") {
        console.log(`📍 Running: Deploy payback contracts (Step 1)`);
      } else if (step === "init") {
        console.log(`📍 Running: Initialize all payback contracts (Steps 1.5, 1.6, 1.7)`);
      } else if (step !== "all") {
        console.log(`📍 Running only Step ${step}`);
      }

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

      // Helper to check if a step should run
      // Note: Step 0 is excluded from "all" - it must be run explicitly
      const shouldRun = (s) => {
        // Direct match
        if (step === s) return true;
        // "all" includes everything except Step 0
        if (step === "all" && s !== "0") return true;
        // Check if step is a group keyword and s is in that group
        if (stepGroups[step] && stepGroups[step].includes(s)) return true;
        return false;
      };

      try {
        // Step 0: Parse Export Data (must be run explicitly, not included in "all")
        if (step === "0") {
          console.log("\n📊 Running Step 0: Parse Export Data");
          await hre.run("parseExportData");
        }

        // Step 1: Deploy Payback Contracts
        if (shouldRun("1")) {
          console.log("\n📦 Running Step 1: Deploy Payback Contracts");
          await hre.run("deployPaybackContracts");
        }

        // Step 1.5: Initialize Silo Payback
        if (shouldRun("1.5")) {
          console.log("\n🌱 Running Step 1.5: Initialize Silo Payback");
          if (taskArgs.useDeployed) {
            console.log("   Using production addresses (--use-deployed)");
          }
          await hre.run("initializeSiloPayback", { useDeployed: taskArgs.useDeployed });
        }

        // Step 1.6: Initialize Barn Payback
        if (shouldRun("1.6")) {
          console.log("\n🏚️ Running Step 1.6: Initialize Barn Payback");
          if (taskArgs.useDeployed) {
            console.log("   Using production addresses (--use-deployed)");
          }
          await hre.run("initializeBarnPayback", { useDeployed: taskArgs.useDeployed });
        }

        // Step 1.7: Initialize Contract Payback Distributor
        if (shouldRun("1.7")) {
          console.log("\n📋 Running Step 1.7: Initialize Contract Payback Distributor");
          if (taskArgs.useDeployed) {
            console.log("   Using production addresses (--use-deployed)");
          }
          await hre.run("initializeContractPaybackDistributor", {
            useDeployed: taskArgs.useDeployed
          });
        }

        // Step 2: Deploy Temp Field Facet
        if (shouldRun("2")) {
          console.log("\n🔧 Running Step 2: Deploy Temp Field Facet");
          await hre.run("deployTempFieldFacet");
          if (step === "all") {
            console.log(
              "\n⚠️  PAUSE: Queue the diamond cut in the multisig and wait for execution"
            );
            await pauseIfNeeded(
              "Press Ctrl+C to stop, or press Enter to continue after multisig execution..."
            );
          }
        }

        // Step 3: Populate Repayment Field
        if (shouldRun("3")) {
          console.log("\n🌾 Running Step 3: Populate Repayment Field");
          await hre.run("populateRepaymentField");
          if (step === "all") {
            console.log(
              "\n⚠️  PAUSE: Proceed with the multisig as needed before moving to the next step"
            );
            await pauseIfNeeded(
              "Press Ctrl+C to stop, or press Enter to continue after necessary approvals..."
            );
          }
        }

        // Step 4: Finalize Beanstalk Shipments
        if (shouldRun("4")) {
          console.log("\n🎯 Running Step 4: Finalize Beanstalk Shipments");
          await hre.run("finalizeBeanstalkShipments");
          if (step === "all") {
            console.log(
              "\n⚠️  PAUSE: Queue the diamond cut in the multisig and wait for execution"
            );
            await pauseIfNeeded(
              "Press Ctrl+C to stop, or press Enter to continue after multisig execution..."
            );
          }
        }

        // Step 5: Transfer Contract Ownership
        if (shouldRun("5")) {
          console.log("\n🔐 Running Step 5: Transfer Contract Ownership");
          await hre.run("transferPaybackContractOwnership");
          if (step === "all") {
            console.log(
              "\n⚠️  PAUSE: Ownership transfer completed. Proceed with validations as required."
            );
            await pauseIfNeeded("Press Ctrl+C to stop, or press Enter to finish...");
          }
        }

        console.log("\n" + "=".repeat(60));
        if (step === "all") {
          console.log("✅ BEANSTALK SHIPMENTS DEPLOYMENT COMPLETED SUCCESSFULLY!");
        } else {
          console.log(`✅ STEP ${step} COMPLETED SUCCESSFULLY!`);
        }
        console.log("=".repeat(60) + "\n");
      } catch (error) {
        console.error("\n❌ ERROR: Beanstalk Shipments deployment failed:", error.message);
        throw error;
      }
    });
};

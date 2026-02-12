const fs = require("fs");
const {
  splitEntriesIntoChunks,
  updateProgress,
  retryOperation,
  verifyTransaction,
  sleep,
  CHUNK_DELAY
} = require("../../utils/read.js");
const { saveDeployedAddresses, computeDistributorAddress } = require("./utils/addressCache.js");
const DELAY = 2000; // 2000ms delay between contracts

// Deploys SiloPayback, BarnPayback, and ContractPaybackDistributor contracts
async function deployShipmentContracts({ PINTO, L2_PINTO, account, verbose = true }) {
  if (verbose) {
    console.log("🚀 Deploying Beanstalk shipment contracts...");
  }

  //////////////////////////// Silo Payback ////////////////////////////
  console.log("\n📦 Deploying SiloPayback...");
  const siloPaybackFactory = await ethers.getContractFactory("SiloPayback", account);
  // factory, args, proxy options
  const siloPaybackContract = await upgrades.deployProxy(siloPaybackFactory, [PINTO, L2_PINTO], {
    initializer: "initialize",
    kind: "transparent"
  });
  await siloPaybackContract.deployed();
  await printContractAddresses(siloPaybackContract.address, "SiloPayback");

  //////////////////////////// Barn Payback ////////////////////////////
  console.log("\n📦 Deploying BarnPayback...");
  const barnPaybackFactory = await ethers.getContractFactory("BarnPayback", account);
  // get the initialization args from the json file
  const barnPaybackArgsPath = "./scripts/beanstalkShipments/data/beanstalkGlobalFertilizer.json";
  const barnPaybackArgs = JSON.parse(fs.readFileSync(barnPaybackArgsPath));
  const distributorAddress = (await computeDistributorAddress(account)).distributorAddress;
  console.log(`\n📍 Using pre-computed ContractPaybackDistributor address: ${distributorAddress}`);
  const barnPaybackContract = await upgrades.deployProxy(
    barnPaybackFactory,
    [PINTO, L2_PINTO, distributorAddress, barnPaybackArgs],
    {
      initializer: "initialize",
      kind: "transparent"
    }
  );
  await barnPaybackContract.deployed();
  await printContractAddresses(barnPaybackContract.address, "BarnPayback");

  //////////////////////////// Contract Payback Distributor ////////////////////////////
  console.log("\n📦 Deploying ContractPaybackDistributor...");
  const contractPaybackDistributorFactory = await ethers.getContractFactory(
    "ContractPaybackDistributor",
    account
  );

  const contractPaybackDistributorContract = await contractPaybackDistributorFactory.deploy(
    L2_PINTO, // address _pintoProtocol
    siloPaybackContract.address, // address _siloPayback
    barnPaybackContract.address // address _barnPayback
  );
  await contractPaybackDistributorContract.deployed();
  await printContractAddresses(
    contractPaybackDistributorContract.address,
    "ContractPaybackDistributor",
    false
  );

  return {
    siloPaybackContract,
    barnPaybackContract,
    contractPaybackDistributorContract
  };
}

// Distributes unripe BDV tokens from JSON file to contract recipients
async function distributeUnripeBdvTokens({
  siloPaybackContract,
  account,
  dataPath,
  verbose = true,
  useChunking = true,
  targetEntriesPerChunk = 300,
  startFromChunk = 0
}) {
  if (verbose) console.log("🌱 Distributing unripe BDV tokens...");

  try {
    const unripeAccountBdvTokens = JSON.parse(fs.readFileSync(dataPath));
    console.log("📊 Unripe BDV Accounts to be distributed:", unripeAccountBdvTokens.length);

    if (!useChunking) {
      // Process all tokens in a single transaction
      console.log("Processing all tokens in a single transaction...");

      // log the address of the payback contract
      console.log("SiloPayback address:", siloPaybackContract.address);

      await retryOperation(
        async () => {
          const tx = await siloPaybackContract.connect(account).batchMint(unripeAccountBdvTokens);
          const receipt = await verifyTransaction(tx, "Unripe BDV batch mint");
          if (verbose) console.log(`⛽ Gas used: ${receipt.gasUsed.toString()}`);
        },
        { context: "Unripe BDV single transaction" }
      );
    } else {
      // Split into chunks for processing
      const chunks = splitEntriesIntoChunks(unripeAccountBdvTokens, targetEntriesPerChunk);
      console.log(`Starting to process ${chunks.length} chunks...`);

      if (startFromChunk > 0) {
        console.log(`⏩ Resuming from chunk ${startFromChunk + 1}/${chunks.length}`);
      }

      let totalGasUsed = ethers.BigNumber.from(0);

      for (let i = startFromChunk; i < chunks.length; i++) {
        if (verbose) {
          console.log(`\n\nProcessing chunk ${i + 1}/${chunks.length}`);
          console.log(`Chunk contains ${chunks[i].length} accounts`);
          console.log("-----------------------------------");
        }

        try {
          await retryOperation(
            async () => {
              // mint tokens to users in chunks
              const tx = await siloPaybackContract.connect(account).batchMint(chunks[i]);
              const receipt = await verifyTransaction(tx, `Unripe BDV chunk ${i + 1}`);
              totalGasUsed = totalGasUsed.add(receipt.gasUsed);
              if (verbose) console.log(`⛽ Chunk gas used: ${receipt.gasUsed.toString()}`);
            },
            { context: `Chunk ${i + 1}/${chunks.length}` }
          );
        } catch (error) {
          console.error(`\n❌ FAILED AT CHUNK ${i + 1}/${chunks.length}`);
          console.error(`To resume, use: --start-chunk ${i}`);
          throw error;
        }

        await updateProgress(i + 1, chunks.length);

        // Small delay between chunks to avoid rate limiting
        if (i < chunks.length - 1) {
          await sleep(CHUNK_DELAY);
        }
      }

      if (verbose) {
        console.log("\n📊 Total Gas Summary:");
        console.log(`⛽ Total gas used: ${totalGasUsed.toString()}`);
      }
    }

    if (verbose) console.log("✅ Unripe BDV tokens distributed to old Beanstalk participants");
  } catch (error) {
    console.error("Error distributing unripe BDV tokens:", error);
    throw error;
  }
}

// Distributes barn payback tokens from JSON file to contract recipients
async function distributeBarnPaybackTokens({
  barnPaybackContract,
  account,
  dataPath,
  verbose = true,
  targetEntriesPerChunk = 300,
  startFromChunk = 0
}) {
  if (verbose) console.log("🌱 Distributing barn payback tokens...");

  try {
    const accountFertilizers = JSON.parse(fs.readFileSync(dataPath));
    console.log("📊 Fertilizer Ids to be distributed:", accountFertilizers.length);

    // Split into chunks for processing
    const chunks = splitEntriesIntoChunks(accountFertilizers, targetEntriesPerChunk);
    console.log(`Starting to process ${chunks.length} chunks...`);

    if (startFromChunk > 0) {
      console.log(`⏩ Resuming from chunk ${startFromChunk + 1}/${chunks.length}`);
    }

    let totalGasUsed = ethers.BigNumber.from(0);

    for (let i = startFromChunk; i < chunks.length; i++) {
      if (verbose) {
        console.log(`\n\nProcessing chunk ${i + 1}/${chunks.length}`);
        console.log(`Chunk contains ${chunks[i].length} fertilizers`);
        console.log("-----------------------------------");
      }

      try {
        await retryOperation(
          async () => {
            const tx = await barnPaybackContract.connect(account).mintFertilizers(chunks[i]);
            const receipt = await verifyTransaction(tx, `Barn payback chunk ${i + 1}`);
            totalGasUsed = totalGasUsed.add(receipt.gasUsed);
            if (verbose) console.log(`⛽ Chunk gas used: ${receipt.gasUsed.toString()}`);
          },
          { context: `Chunk ${i + 1}/${chunks.length}` }
        );
      } catch (error) {
        console.error(`\n❌ FAILED AT CHUNK ${i + 1}/${chunks.length}`);
        console.error(`To resume, use: --start-chunk ${i}`);
        throw error;
      }

      await updateProgress(i + 1, chunks.length);

      // Small delay between chunks to avoid rate limiting
      if (i < chunks.length - 1) {
        await sleep(CHUNK_DELAY);
      }
    }
    if (verbose) {
      console.log("\n📊 Total Gas Summary:");
      console.log(`⛽ Total gas used: ${totalGasUsed.toString()}`);
    }
    if (verbose) console.log("✅ Barn payback tokens distributed to old Beanstalk participants");
  } catch (error) {
    console.error("Error distributing barn payback tokens:", error);
    throw error;
  }
}

// Distributes contract account data from JSON files to contract distributor
async function distributeContractAccountData({
  contractPaybackDistributorContract,
  account,
  verbose = true,
  targetEntriesPerChunk = 25,
  startFromChunk = 0
}) {
  if (verbose) console.log("🌱 Distributing contract account data...");

  try {
    // Load contract accounts and initialization data
    const contractAccountsPath = "./scripts/beanstalkShipments/data/contractAccounts.json";
    const initDataPath = "./scripts/beanstalkShipments/data/contractAccountDistributorInit.json";

    let contractAccounts = [];
    let initData = [];

    contractAccounts = JSON.parse(fs.readFileSync(contractAccountsPath));
    initData = JSON.parse(fs.readFileSync(initDataPath));
    console.log(`📊 Loaded ${contractAccounts.length} contract accounts for initialization`);

    if (contractAccounts.length === 0 || initData.length === 0) {
      console.log("ℹ️  No contract accounts to distribute");
      return;
    }

    // Verify data consistency
    if (contractAccounts.length !== initData.length) {
      throw new Error(
        `Data mismatch: ${contractAccounts.length} addresses but ${initData.length} data entries`
      );
    }

    // Split into chunks for processing
    const chunks = [];
    for (let i = 0; i < contractAccounts.length; i += targetEntriesPerChunk) {
      const accountChunk = contractAccounts.slice(i, i + targetEntriesPerChunk);
      const dataChunk = initData.slice(i, i + targetEntriesPerChunk);
      chunks.push({ accounts: accountChunk, data: dataChunk });
    }

    console.log(`Starting to process ${chunks.length} chunks...`);

    if (startFromChunk > 0) {
      console.log(`⏩ Resuming from chunk ${startFromChunk + 1}/${chunks.length}`);
    }

    let totalGasUsed = ethers.BigNumber.from(0);

    for (let i = startFromChunk; i < chunks.length; i++) {
      if (verbose) {
        console.log(`\n\nProcessing chunk ${i + 1}/${chunks.length}`);
        console.log(`Chunk contains ${chunks[i].accounts.length} contract accounts`);
        console.log("-----------------------------------");
      }

      try {
        await retryOperation(
          async () => {
            // Remove address field from data before contract call (contract doesn't expect this field)
            const dataForContract = chunks[i].data.map((accountData) => {
              const { address, ...dataWithoutAddress } = accountData;
              return dataWithoutAddress;
            });

            // Initialize contract account data in chunks
            const tx = await contractPaybackDistributorContract
              .connect(account)
              .initializeAccountData(chunks[i].accounts, dataForContract);
            const receipt = await verifyTransaction(tx, `Contract account data chunk ${i + 1}`);
            totalGasUsed = totalGasUsed.add(receipt.gasUsed);
            if (verbose) console.log(`⛽ Chunk gas used: ${receipt.gasUsed.toString()}`);
          },
          { context: `Chunk ${i + 1}/${chunks.length}` }
        );
      } catch (error) {
        console.error(`\n❌ FAILED AT CHUNK ${i + 1}/${chunks.length}`);
        console.error(`To resume, use: --start-chunk ${i}`);
        throw error;
      }

      await updateProgress(i + 1, chunks.length);

      // Small delay between chunks to avoid rate limiting
      if (i < chunks.length - 1) {
        await sleep(CHUNK_DELAY);
      }
    }

    if (verbose) {
      console.log("\n📊 Total Gas Summary:");
      console.log(`⛽ Total gas used: ${totalGasUsed.toString()}`);
    }

    if (verbose) console.log("✅ Contract account data distributed to ContractPaybackDistributor");
  } catch (error) {
    console.error("Error distributing contract account data:", error);
    throw error;
  }
}

// Transfers ownership of payback contracts to PCM
async function transferContractOwnership({
  siloPaybackContract,
  barnPaybackContract,
  contractPaybackDistributorContract,
  newOwner,
  deployer,
  verbose = true
}) {
  if (verbose) console.log("🔄 Transferring ownership to PCM...");

  await siloPaybackContract.connect(deployer).transferOwnership(newOwner);
  if (verbose) console.log("✅ SiloPayback ownership transferred to PCM");

  await barnPaybackContract.connect(deployer).transferOwnership(newOwner);
  if (verbose) console.log("✅ BarnPayback ownership transferred to PCM");

  await contractPaybackDistributorContract.connect(deployer).transferOwnership(newOwner);
  if (verbose) console.log("✅ ContractPaybackDistributor ownership transferred to PCM");
}

// Main function that deploys contracts (no initialization)
// Initialization is now handled by separate tasks (Steps 1.5, 1.6, 1.7)
async function deployAndSetupContracts(params) {
  const contracts = await deployShipmentContracts(params);

  // Save deployed addresses to cache for use by initialization tasks
  const network = params.network || "unknown";
  saveDeployedAddresses(
    {
      siloPayback: contracts.siloPaybackContract.address,
      barnPayback: contracts.barnPaybackContract.address,
      contractPaybackDistributor: contracts.contractPaybackDistributorContract.address
    },
    network
  );

  return contracts;
}

async function printContractAddresses(contractAddress, contractName, isUpgradeable = true) {
  console.log(`✅ ${contractName} deployed to:`, contractAddress);
  if (isUpgradeable) {
    await sleep(DELAY);
    console.log(
      "   Implementation:",
      await upgrades.erc1967.getImplementationAddress(contractAddress)
    );
    await sleep(DELAY);
    console.log("   ProxyAdmin:", await upgrades.erc1967.getAdminAddress(contractAddress));
    await sleep(DELAY);
    const contract = await ethers.getContractAt("OwnableUpgradeable", contractAddress);
    console.log(`👤 ${contractName} owner:`, await contract.owner());
  }
}

module.exports = {
  deployShipmentContracts,
  distributeUnripeBdvTokens,
  distributeBarnPaybackTokens,
  distributeContractAccountData,
  transferContractOwnership,
  deployAndSetupContracts
};

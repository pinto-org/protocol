const fs = require("fs");
const { splitEntriesIntoChunks, updateProgress, retryOperation } = require("../../utils/read.js");

// Deploys SiloPayback, BarnPayback, and ShipmentPlanner contracts
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
  console.log("✅ SiloPayback deployed to:", siloPaybackContract.address);
  console.log("👤 SiloPayback owner:", await siloPaybackContract.owner());

  //////////////////////////// Barn Payback ////////////////////////////
  console.log("\n📦 Deploying BarnPayback...");
  const barnPaybackFactory = await ethers.getContractFactory("BarnPayback", account);
  // get the initialization args from the json file
  const barnPaybackArgsPath = "./scripts/beanstalkShipments/data/beanstalkGlobalFertilizer.json";
  const barnPaybackArgs = JSON.parse(fs.readFileSync(barnPaybackArgsPath));
  // factory, args, proxy options
  const barnPaybackContract = await upgrades.deployProxy(
    barnPaybackFactory,
    [PINTO, L2_PINTO, barnPaybackArgs],
    {
      initializer: "initialize",
      kind: "transparent"
    }
  );
  await barnPaybackContract.deployed();
  console.log("✅ BarnPayback deployed to:", barnPaybackContract.address);
  console.log("👤 BarnPayback owner:", await barnPaybackContract.owner());

  //////////////////////////// Shipment Planner ////////////////////////////
  console.log("\n📦 Deploying ShipmentPlanner...");
  const shipmentPlannerFactory = await ethers.getContractFactory("ShipmentPlanner", account);
  const shipmentPlannerContract = await shipmentPlannerFactory.deploy(L2_PINTO, PINTO);
  await shipmentPlannerContract.deployed();
  console.log("✅ ShipmentPlanner deployed to:", shipmentPlannerContract.address);

  //////////////////////////// Contract Payback Distributor ////////////////////////////
  // console.log("\n📦 Deploying ContractPaybackDistributor...");
  // const contractPaybackDistributorFactory = await ethers.getContractFactory("ContractPaybackDistributor", account);
  // const contractPaybackDistributorContract = await contractPaybackDistributorFactory.deploy();
  // await contractPaybackDistributorContract.deployed();
  // console.log("✅ ContractPaybackDistributor deployed to:", contractPaybackDistributorContract.address);

  return {
    siloPaybackContract,
    barnPaybackContract,
    shipmentPlannerContract
  };
}

// Distributes unripe BDV tokens from JSON file to contract recipients
async function distributeUnripeBdvTokens({
  siloPaybackContract,
  account,
  dataPath,
  verbose = true,
  useChunking = true,
  targetEntriesPerChunk = 300
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

      const tx = await siloPaybackContract.connect(account).batchMint(unripeAccountBdvTokens);
      const receipt = await tx.wait();

      if (verbose) console.log(`⛽ Gas used: ${receipt.gasUsed.toString()}`);
    } else {
      // Split into chunks for processing
      const chunks = splitEntriesIntoChunks(unripeAccountBdvTokens, targetEntriesPerChunk);
      console.log(`Starting to process ${chunks.length} chunks...`);

      let totalGasUsed = ethers.BigNumber.from(0);

      for (let i = 0; i < chunks.length; i++) {
        if (verbose) {
          console.log(`\n\nProcessing chunk ${i + 1}/${chunks.length}`);
          console.log(`Chunk contains ${chunks[i].length} accounts`);
          console.log("-----------------------------------");
        }

        await retryOperation(async () => {
          // mint tokens to users in chunks
          const tx = await siloPaybackContract.connect(account).batchMint(chunks[i]);
          const receipt = await tx.wait();
          totalGasUsed = totalGasUsed.add(receipt.gasUsed);
          if (verbose) console.log(`⛽ Chunk gas used: ${receipt.gasUsed.toString()}`);
        });

        await updateProgress(i + 1, chunks.length);
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
  targetEntriesPerChunk = 300
}) {
  if (verbose) console.log("🌱 Distributing barn payback tokens...");

  try {
    const accountFertilizers = JSON.parse(fs.readFileSync(dataPath));
    console.log("📊 Fertilizer Ids to be distributed:", accountFertilizers.length);

    // Split into chunks for processing
    const chunks = splitEntriesIntoChunks(accountFertilizers, targetEntriesPerChunk);
    console.log(`Starting to process ${chunks.length} chunks...`);

    let totalGasUsed = ethers.BigNumber.from(0);

    for (let i = 0; i < chunks.length; i++) {
      if (verbose) {
        console.log(`\n\nProcessing chunk ${i + 1}/${chunks.length}`);
        console.log(`Chunk contains ${chunks[i].length} fertilizers`);
        console.log("-----------------------------------");
      }
      const tx = await barnPaybackContract.connect(account).mintFertilizers(chunks[i]);
      const receipt = await tx.wait();

      totalGasUsed = totalGasUsed.add(receipt.gasUsed);
      if (verbose) console.log(`⛽ Chunk gas used: ${receipt.gasUsed.toString()}`);

      await updateProgress(i + 1, chunks.length);
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


// Transfers ownership of both payback contracts to PCM
async function transferContractOwnership({
  siloPaybackContract,
  barnPaybackContract,
  L2_PCM,
  verbose = true
}) {
  if (verbose) console.log("🔄 Transferring ownership to PCM...");

  await siloPaybackContract.transferOwnership(L2_PCM);
  if (verbose) console.log("✅ SiloPayback ownership transferred to PCM");

  await barnPaybackContract.transferOwnership(L2_PCM);
  if (verbose) console.log("✅ BarnPayback ownership transferred to PCM");
}

// Main function that orchestrates all deployment steps
async function deployAndSetupContracts(params) {
  const contracts = await deployShipmentContracts(params);

  if (params.populateData) {
    await distributeUnripeBdvTokens({
      siloPaybackContract: contracts.siloPaybackContract,
      account: params.account,
      dataPath: "./scripts/beanstalkShipments/data/unripeBdvTokens.json",
      verbose: true
    });

    await distributeBarnPaybackTokens({
      barnPaybackContract: contracts.barnPaybackContract,
      account: params.account,
      dataPath: "./scripts/beanstalkShipments/data/beanstalkAccountFertilizer.json",
      verbose: true
    });

  }

  await transferContractOwnership({
    siloPaybackContract: contracts.siloPaybackContract,
    barnPaybackContract: contracts.barnPaybackContract,
    L2_PCM: params.L2_PCM,
    verbose: true
  });

  return contracts;
}

module.exports = {
  deployShipmentContracts,
  distributeUnripeBdvTokens,
  distributeBarnPaybackTokens,
  transferContractOwnership,
  deployAndSetupContracts
};

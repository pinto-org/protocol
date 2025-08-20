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
  console.log("\n📦 Deploying ContractPaybackDistributor...");
  const contractPaybackDistributorFactory = await ethers.getContractFactory("ContractPaybackDistributor", account);
  
  // Load constructor data
  const contractDataPath = "./scripts/beanstalkShipments/data/contractDistributorData.json";
  const contractData = JSON.parse(fs.readFileSync(contractDataPath));
  
  const contractPaybackDistributorContract = await contractPaybackDistributorFactory.deploy(
    contractData.contractAccounts,
    contractData.siloPaybackTokensOwed,
    contractData.fertilizerClaims,
    contractData.plotClaims,
    L2_PINTO,
    siloPaybackContract.address,
    barnPaybackContract.address
  );
  await contractPaybackDistributorContract.deployed();
  console.log("✅ ContractPaybackDistributor deployed to:", contractPaybackDistributorContract.address);
  console.log(`📊 Managing ${contractData.contractAccounts.length} contract accounts`);
  // log total gas used from deployment
  const receipt = await contractPaybackDistributorContract.deployTransaction.wait();
  console.log("⛽ Gas used:", receipt.gasUsed.toString());

  return {
    siloPaybackContract,
    barnPaybackContract,
    shipmentPlannerContract,
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

// Distributes silo payback tokens to ContractPaybackDistributor for ethContracts
async function distributeSiloTokensToDistributor({
  siloPaybackContract,
  contractPaybackDistributorContract,
  account,
  verbose = true
}) {
  if (verbose) console.log("🏭 Distributing silo payback tokens to ContractPaybackDistributor...");

  try {
    const contractDataPath = "./scripts/beanstalkShipments/data/contractDistributorData.json";
    const contractData = JSON.parse(fs.readFileSync(contractDataPath));
    
    // Calculate total silo tokens owed to all contract accounts
    const totalSiloOwed = contractData.siloPaybackTokensOwed.reduce((sum, amount) => {
      return sum.add(ethers.BigNumber.from(amount));
    }, ethers.BigNumber.from(0));
    
    console.log(`📊 Total silo tokens to distribute to ContractPaybackDistributor: ${totalSiloOwed.toString()}`);
    
    if (totalSiloOwed.gt(0)) {
      // Mint the total amount to the ContractPaybackDistributor
      const tx = await siloPaybackContract.connect(account).mint(
        contractPaybackDistributorContract.address, 
        totalSiloOwed
      );
      const receipt = await tx.wait();
      
      if (verbose) {
        console.log(`⛽ Gas used: ${receipt.gasUsed.toString()}`);
        console.log("✅ Silo payback tokens distributed to ContractPaybackDistributor");
      }
    } else {
      console.log("ℹ️  No silo tokens to distribute to ContractPaybackDistributor");
    }
  } catch (error) {
    console.error("Error distributing silo tokens to ContractPaybackDistributor:", error);
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

// Distributes fertilizer tokens to ContractPaybackDistributor for ethContracts
async function distributeFertilizerTokensToDistributor({
  barnPaybackContract,
  contractPaybackDistributorContract,
  account,
  verbose = true
}) {
  if (verbose) console.log("🏭 Distributing fertilizer tokens to ContractPaybackDistributor...");

  try {
    const contractDataPath = "./scripts/beanstalkShipments/data/contractDistributorData.json";
    const contractData = JSON.parse(fs.readFileSync(contractDataPath));
    
    // Build fertilizer data for minting to ContractPaybackDistributor
    const contractFertilizers = [];
    
    for (const fertilizerClaim of contractData.fertilizerClaims) {
      if (fertilizerClaim.fertilizerIds.length > 0) {
        // For each fertilizer ID, create account data pointing to ContractPaybackDistributor
        for (let i = 0; i < fertilizerClaim.fertilizerIds.length; i++) {
          const fertId = fertilizerClaim.fertilizerIds[i];
          const amount = fertilizerClaim.fertilizerAmounts[i];
          
          // Find or create entry for this fertilizer ID
          let fertilizerEntry = contractFertilizers.find(entry => entry[0] === fertId);
          if (!fertilizerEntry) {
            fertilizerEntry = [fertId, []];
            contractFertilizers.push(fertilizerEntry);
          }
          
          // Add the amount to the ContractPaybackDistributor
          fertilizerEntry[1].push([
            contractPaybackDistributorContract.address,
            amount,
            "340802" // Using the global beanBpf value
          ]);
        }
      }
    }
    
    console.log(`📊 Fertilizer IDs to mint to ContractPaybackDistributor: ${contractFertilizers.length}`);
    
    if (contractFertilizers.length > 0) {
      const tx = await barnPaybackContract.connect(account).mintFertilizers(contractFertilizers);
      const receipt = await tx.wait();
      
      if (verbose) {
        console.log(`⛽ Gas used: ${receipt.gasUsed.toString()}`);
        console.log("✅ Fertilizer tokens distributed to ContractPaybackDistributor");
      }
    } else {
      console.log("ℹ️  No fertilizer tokens to distribute to ContractPaybackDistributor");
    }
  } catch (error) {
    console.error("Error distributing fertilizer tokens to ContractPaybackDistributor:", error);
    throw error;
  }
}

// Pre-sows plots for ContractPaybackDistributor using protocol sow function  
async function sowPlotsForDistributor({
  pintoProtocol,
  contractPaybackDistributorContract,
  account,
  verbose = true
}) {
  if (verbose) console.log("🌾 Pre-sowing plots for ContractPaybackDistributor...");

  try {
    const contractDataPath = "./scripts/beanstalkShipments/data/contractDistributorData.json";
    const contractData = JSON.parse(fs.readFileSync(contractDataPath));
    
    // Calculate total pods needed for all plots
    let totalPodsNeeded = ethers.BigNumber.from(0);
    let totalPlotsCount = 0;
    
    for (const plotClaim of contractData.plotClaims) {
      for (let i = 0; i < plotClaim.ids.length; i++) {
        const podAmount = ethers.BigNumber.from(plotClaim.ends[i]);
        totalPodsNeeded = totalPodsNeeded.add(podAmount);
        totalPlotsCount++;
      }
    }
    
    console.log(`📊 Total pods to sow for ContractPaybackDistributor: ${totalPodsNeeded.toString()}`);
    console.log(`📊 Total plots to create: ${totalPlotsCount}`);
    
    if (totalPodsNeeded.gt(0)) {
      // Note: This assumes we have beans available to sow and current soil/temperature conditions allow it
      // In practice, this might need to be done during protocol initialization or through a special admin function
      console.log("⚠️  WARNING: Plot sowing requires special protocol initialization");
      console.log("⚠️  This would typically be done through protocol admin functions during deployment");
      console.log(`⚠️  ContractPaybackDistributor address: ${contractPaybackDistributorContract.address}`);
      console.log(`⚠️  Total beans needed for sowing: ${totalPodsNeeded.toString()}`);
      
      // For now, we'll log what needs to be done rather than attempt the sow operation
      // since it requires specific protocol state and bean balance
      if (verbose) {
        console.log("📝 Plot sowing will need to be handled through protocol initialization");
      }
    } else {
      console.log("ℹ️  No plots to sow for ContractPaybackDistributor");
    }
  } catch (error) {
    console.error("Error preparing plots for ContractPaybackDistributor:", error);
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

    // Distribute tokens to ContractPaybackDistributor for ethContracts
    await distributeSiloTokensToDistributor({
      siloPaybackContract: contracts.siloPaybackContract,
      contractPaybackDistributorContract: contracts.contractPaybackDistributorContract,
      account: params.account,
      verbose: true
    });

    await distributeFertilizerTokensToDistributor({
      barnPaybackContract: contracts.barnPaybackContract,
      contractPaybackDistributorContract: contracts.contractPaybackDistributorContract,
      account: params.account,
      verbose: true
    });

    // Handle plot pre-sowing for ContractPaybackDistributor
    await sowPlotsForDistributor({
      pintoProtocol: params.L2_PINTO,
      contractPaybackDistributorContract: contracts.contractPaybackDistributorContract,
      account: params.account,
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
  distributeSiloTokensToDistributor,
  distributeFertilizerTokensToDistributor,
  sowPlotsForDistributor,
  transferContractOwnership,
  deployAndSetupContracts
};

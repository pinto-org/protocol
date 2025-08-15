const fs = require("fs");

// Deploys SiloPayback, BarnPayback, and ShipmentPlanner contracts
async function deployShipmentContracts({ PINTO, L2_PINTO, L2_PCM, account, verbose = true }) {
  if (verbose) {
    console.log("Deploying Beanstalk shipment contracts...");
  }

  //////////////////////////// Silo Payback ////////////////////////////
  console.log("\nDeploying SiloPayback...");
  const siloPaybackFactory = await ethers.getContractFactory("SiloPayback", account);
  // factory, args, proxy options
  const siloPaybackContract = await upgrades.deployProxy(siloPaybackFactory, [PINTO, L2_PINTO], {
    initializer: "initialize",
    kind: "transparent"
  });
  await siloPaybackContract.deployed();
  if (verbose) console.log("SiloPayback deployed to:", siloPaybackContract.address);
  if (verbose) console.log("SiloPayback owner:", await siloPaybackContract.owner());

  //////////////////////////// Barn Payback ////////////////////////////
  console.log("--------------------------------");
  console.log("Deploying BarnPayback...");
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
  if (verbose) console.log("BarnPayback deployed to:", barnPaybackContract.address);
  if (verbose) console.log("BarnPayback owner:", await barnPaybackContract.owner());

  //////////////////////////// Shipment Planner ////////////////////////////
  console.log("--------------------------------");
  console.log("Deploying ShipmentPlanner...");
  const shipmentPlannerFactory = await ethers.getContractFactory("ShipmentPlanner", account);
  const shipmentPlannerContract = await shipmentPlannerFactory.deploy(L2_PINTO, PINTO);
  await shipmentPlannerContract.deployed();
  if (verbose) console.log("ShipmentPlanner deployed to:", shipmentPlannerContract.address);
  console.log("--------------------------------");

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
  verbose = true
}) {
  if (verbose) console.log("Distributing unripe BDV tokens...");

  try {
    const unripeAccountBdvTokens = JSON.parse(fs.readFileSync(dataPath));
    // mint all in one transaction
    await siloPaybackContract.connect(account).batchMint(unripeAccountBdvTokens);

    if (verbose) console.log("Unripe BDV tokens distributed to old Beanstalk participants");
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
  verbose = true
}) {
  if (verbose) console.log("Distributing barn payback tokens...");

  try {
    const accountFertilizers = JSON.parse(fs.readFileSync(dataPath));
    // mint all in one transaction
    await barnPaybackContract.connect(account).mintFertilizers(accountFertilizers);
  } catch (error) {
    console.error("Error distributing barn payback tokens:", error);
    throw error;
  }
  if (verbose) console.log("Barn payback tokens distributed to old Beanstalk participants");
}

// Transfers ownership of both payback contracts to PCM
async function transferContractOwnership({
  siloPaybackContract,
  barnPaybackContract,
  L2_PCM,
  verbose = true
}) {
  if (verbose) console.log("Transferring ownership to PCM...");

  await siloPaybackContract.transferOwnership(L2_PCM);
  if (verbose) console.log("SiloPayback ownership transferred to PCM");

  await barnPaybackContract.transferOwnership(L2_PCM);
  if (verbose) console.log("BarnPayback ownership transferred to PCM");
}

// Main function that orchestrates all deployment steps
async function deployAndSetupContracts(params) {
  const { verbose = true } = params;

  const contracts = await deployShipmentContracts(params);

  await distributeUnripeBdvTokens({
    siloPaybackContract: contracts.siloPaybackContract,
    account: params.account,
    dataPath: "./scripts/beanstalkShipments/data/unripeBdvTokens.json",
    verbose
  });

  await distributeBarnPaybackTokens({
    barnPaybackContract: contracts.barnPaybackContract,
    account: params.account,
    dataPath: "./scripts/beanstalkShipments/data/beanstalkAccountFertilizer.json",
    verbose
  });

  await transferContractOwnership({
    siloPaybackContract: contracts.siloPaybackContract,
    barnPaybackContract: contracts.barnPaybackContract,
    L2_PCM: params.L2_PCM,
    verbose
  });

  return contracts;
}

module.exports = {
  deployShipmentContracts,
  distributeUnripeBdvTokens,
  transferContractOwnership,
  deployAndSetupContracts
};

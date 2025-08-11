const fs = require("fs");

// Deploys SiloPayback, BarnPayback, and ShipmentPlanner contracts
async function deployShipmentContracts({ PINTO, L2_PINTO, L2_PCM, owner, verbose = true }) {
  if (verbose) {
    console.log("Deploying Beanstalk shipment contracts...");
  }

  //////////////////////////// Silo Payback ////////////////////////////
  const siloPaybackFactory = await ethers.getContractFactory("SiloPayback");
  // factory, args, proxy options
  const siloPaybackContract = await upgrades.deployProxy(siloPaybackFactory, [PINTO, L2_PINTO], {
    initializer: "initialize",
    kind: "transparent"
  });
  await siloPaybackContract.deployed();
  if (verbose) console.log("SiloPayback deployed to:", siloPaybackContract.address);

  //////////////////////////// Barn Payback ////////////////////////////
  const barnPaybackFactory = await ethers.getContractFactory("BarnPayback");
  // get the initialization args from the json file
  const barnPaybackArgsPath = "./scripts/beanstalkShipments/data/beanstalkGlobalFertilizer.json";
  const barnPaybackArgs = JSON.parse(fs.readFileSync(barnPaybackArgsPath));
  // factory, args, proxy options
  const barnPaybackContract = await upgrades.deployProxy(barnPaybackFactory, barnPaybackArgs, {
    initializer: "initialize",
    kind: "transparent"
  });
  await barnPaybackContract.deployed();
  if (verbose) console.log("BarnPayback deployed to:", barnPaybackContract.address);

  //////////////////////////// Shipment Planner ////////////////////////////
  const shipmentPlannerFactory = await ethers.getContractFactory("ShipmentPlanner");
  const shipmentPlannerContract = await shipmentPlannerFactory.deploy(L2_PINTO, PINTO);
  await shipmentPlannerContract.deployed();
  if (verbose) console.log("ShipmentPlanner deployed to:", shipmentPlannerContract.address);

  return {
    siloPaybackContract,
    barnPaybackContract,
    shipmentPlannerContract
  };
}

// Distributes unripe BDV tokens from JSON file to contract recipients
async function distributeUnripeBdvTokens({
  siloPaybackContract,
  owner,
  dataPath = "./scripts/beanstalkShipments/data/unripeBdvTokens.json",
  verbose = true
}) {
  if (verbose) console.log("Distributing unripe BDV tokens...");

  try {
    const unripeAccountBdvTokens = JSON.parse(fs.readFileSync(dataPath));

    await siloPaybackContract.connect(owner).batchMint(unripeAccountBdvTokens);

    if (verbose) console.log("Unripe BDV tokens distributed to old Beanstalk participants");
  } catch (error) {
    console.error("Error distributing unripe BDV tokens:", error);
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
  if (verbose) console.log("Transferring ownership to PCM...");

  await siloPaybackContract.transferOwnership(L2_PCM);
  if (verbose) console.log("SiloPayback ownership transferred to PCM");

  await barnPaybackContract.transferOwnership(L2_PCM);
  if (verbose) console.log("BarnPayback ownership transferred to PCM");
}

// Distributes barn payback tokens from JSON file to contract recipients
async function distributeBarnPaybackTokens({
  barnPaybackContract,
  owner,
  dataPath = "./scripts/beanstalkShipments/data/beanstalkAccountFertilizer.json",
  verbose = true
}) {
  if (verbose) console.log("Distributing barn payback tokens...");

  try {
    const accountFertilizers = JSON.parse(fs.readFileSync(dataPath));

    // call the mintFertilizers function
    await barnPaybackContract.connect(owner).mintFertilizers(accountFertilizers);

    if (verbose) console.log("Barn payback tokens distributed to old Beanstalk participants");
  } catch (error) {
    console.error("Error distributing barn payback tokens:", error);
    throw error;
  }

  if (verbose) console.log("Barn payback tokens distributed to old Beanstalk participants");
}

// Logs deployed contract addresses
function logDeployedAddresses({
  siloPaybackContract,
  barnPaybackContract,
  shipmentPlannerContract
}) {
  console.log("\nDeployed Contract Addresses:");
  console.log("- SiloPayback:", siloPaybackContract.address);
  console.log("- BarnPayback:", barnPaybackContract.address);
  console.log("- ShipmentPlanner:", shipmentPlannerContract.address);
}

// Main function that orchestrates all deployment steps
async function deployAndSetupContracts(params) {
  const { verbose = true } = params;

  const contracts = await deployShipmentContracts(params);

  await distributeUnripeBdvTokens({
    siloPaybackContract: contracts.siloPaybackContract,
    owner: params.owner,
    verbose
  });

  await distributeBarnPaybackTokens({
    barnPaybackContract: contracts.barnPaybackContract,
    owner: params.owner,
    verbose
  });

  await transferContractOwnership({
    siloPaybackContract: contracts.siloPaybackContract,
    barnPaybackContract: contracts.barnPaybackContract,
    L2_PCM: params.L2_PCM,
    verbose
  });

  if (verbose) {
    logDeployedAddresses(contracts);
  }

  return contracts;
}

module.exports = {
  deployShipmentContracts,
  distributeUnripeBdvTokens,
  transferContractOwnership,
  logDeployedAddresses,
  deployAndSetupContracts
};

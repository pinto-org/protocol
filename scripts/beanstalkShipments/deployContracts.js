const fs = require("fs");
const { upgrades } = require("hardhat");

// Deploys SiloPayback, BarnPayback, and ShipmentPlanner contracts
async function deployShipmentContracts({ PINTO, L2_PINTO, L2_PCM, owner, verbose = true }) {
  if (verbose) {
    console.log("Deploying Beanstalk shipment contracts...");
  }

  const siloPaybackFactory = await ethers.getContractFactory("SiloPayback");
  const siloPaybackContract = await upgrades.deployProxy(siloPaybackFactory, [PINTO, L2_PINTO], {
    initializer: "initialize",
    kind: "transparent"
  });
  await siloPaybackContract.deployed();
  if (verbose) console.log("SiloPayback deployed to:", siloPaybackContract.address);

  const barnPaybackFactory = await ethers.getContractFactory("BarnPayback");
  const barnPaybackContract = await upgrades.deployProxy(barnPaybackFactory, [0], {
    initializer: "initialize",
    kind: "transparent"
  });
  await barnPaybackContract.deployed();
  if (verbose) console.log("BarnPayback deployed to:", barnPaybackContract.address);

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
    const unripeBdvTokens = JSON.parse(fs.readFileSync(dataPath));

    const unripeReceipts = unripeBdvTokens.map(([recipient, bdv]) => ({
      receipient: recipient,
      bdv: bdv
    }));

    await siloPaybackContract.connect(owner).batchMint(unripeReceipts);

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

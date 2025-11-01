const { getWellContractAt } = require("./well.js");

// Note: ethers is accessed from global scope at runtime (provided by Hardhat)

// Default well salt to prevent front-running (matches InitWells.sol)
const DEFAULT_WELL_SALT = "0x0000000000000000000000000000000000000000000000000000000000000010";

// Standard Base network addresses
const STANDARD_ADDRESSES_BASE = {
  bean: "0xb170000aeeFa790fa61D6e837d1035906839a3c8",
  aquifer: "0xBA51AA60B3b8d9A36cc748a62Aa56801060183f8",
  wellImplementation: "0xBA510990a720725Ab1F9a0D231F045fc906909f4",
  pump: "0xBA51AAaA66DaB6c236B356ad713f759c206DcB93",
  pumpData:
    "0x3ffefd29d6deab9ccdef2300d0c1c903000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000603ffd0000000000000000000000000000000000000000000000000000000000003ffd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003ffd00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000023ffd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  constantProduct2: "0xBA510C289fD067EBbA41335afa11F0591940d6fe",
  stable2: "0xBA51055a97b40d7f41f3F64b57469b5D45B67c87",
  createX: "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed" // CREATE2 factory
};

/**
 * Encodes Well immutable data matching LibWellDeployer.sol:44-67
 * @param {string} aquifer - Aquifer factory address
 * @param {string[]} tokens - Array of token addresses (IERC20[])
 * @param {Object} wellFunction - {target: address, data: bytes}
 * @param {Object[]} pumps - Array of {target: address, data: bytes}
 * @returns {string} Encoded immutable data
 */
function encodeWellImmutableData(aquifer, tokens, wellFunction, pumps) {
  // Initial encoding: aquifer, tokens.length, wellFunction.target, wellFunction.data.length, pumps.length
  let immutableData = ethers.utils.solidityPack(
    ["address", "uint256", "address", "uint256", "uint256"],
    [aquifer, tokens.length, wellFunction.target, wellFunction.data.length, pumps.length]
  );

  // Append tokens array
  immutableData = ethers.utils.solidityPack(["bytes", "address[]"], [immutableData, tokens]);

  // Append well function data
  immutableData = ethers.utils.solidityPack(["bytes", "bytes"], [immutableData, wellFunction.data]);

  // Append each pump (target, data.length, data)
  for (let i = 0; i < pumps.length; i++) {
    immutableData = ethers.utils.solidityPack(
      ["bytes", "address", "uint256", "bytes"],
      [immutableData, pumps[i].target, pumps[i].data.length, pumps[i].data]
    );
  }

  return immutableData;
}

/**
 * Encodes Well deployment data for upgradeable wells
 * Matches LibWellDeployer.sol:17-25
 * @param {string} aquifer - Aquifer factory address
 * @param {string[]} tokens - Array of token addresses
 * @param {Object} wellFunction - {target: address, data: bytes}
 * @param {Object[]} pumps - Array of {target: address, data: bytes}
 * @returns {Object} {immutableData: bytes, initData: bytes}
 */
function encodeUpgradeableWellDeploymentData(aquifer, tokens, wellFunction, pumps) {
  const immutableData = encodeWellImmutableData(aquifer, tokens, wellFunction, pumps);

  // Get the initNoWellToken selector from IWellUpgradeable
  // initNoWellToken() selector = 0x4bfe9943
  const initData = "0xa46b6179";

  return { immutableData, initData };
}

/**
 * Deploys an upgradeable well matching InitWells.sol:70-102
 * @param {Object} params - Deployment parameters
 * @param {string[]} params.tokens - Array of token addresses [Bean, NonBeanToken]
 * @param {Object} params.wellFunction - {target: address, data: bytes}
 * @param {Object[]} params.pumps - Array of {target: address, data: bytes}
 * @param {string} params.aquifer - Aquifer factory address
 * @param {string} params.wellImplementation - WellUpgradeable implementation address
 * @param {string} params.wellSalt - CREATE2 salt for boreWell clone
 * @param {string} params.proxySalt - CREATE2 salt for ERC1967Proxy
 * @param {string} [params.createX] - CreateX factory address (defaults to Base address)
 * @param {string} params.name - Well name
 * @param {string} params.symbol - Well symbol
 * @param {Object} params.deployer - Signer account
 * @param {boolean} params.verbose - Enable verbose logging
 * @returns {Object} {proxyAddress: string, implementationAddress: string}
 */
async function deployUpgradeableWell({
  tokens,
  wellFunction,
  pumps,
  aquifer,
  wellImplementation,
  wellSalt = DEFAULT_WELL_SALT,
  proxySalt,
  createX = STANDARD_ADDRESSES_BASE.createX,
  name,
  symbol,
  deployer,
  verbose = false
}) {
  // Encode well data
  const { immutableData, initData } = encodeUpgradeableWellDeploymentData(
    aquifer,
    tokens,
    wellFunction,
    pumps
  );

  console.log("immutableData", immutableData);
  console.log("initData", initData);

  if (verbose) {
    console.log(`\nDeploying upgradeable well: ${name}`);
    console.log(`Tokens: ${tokens.join(", ")}`);
    console.log(`Well Function: ${wellFunction.target}`);
    console.log(`Aquifer: ${aquifer}`);
    console.log(`Well Implementation: ${wellImplementation}`);
  }

  // Get Aquifer contract
  const aquiferContract = await ethers.getContractAt("IAquifer", aquifer);

  // Bore upgradeable well with wellSalt for CREATE2 deployment
  const tx = await aquiferContract
    .connect(deployer)
    .boreWell(wellImplementation, immutableData, initData, wellSalt);

  const receipt = await tx.wait();
  const wellAddress = receipt.events.find(e => e.event === "BoreWell").args.well;

  if (verbose) {
    console.log(`Base well deployed at: ${wellAddress}`);
  }

  // Get WellUpgradeable interface to encode init call
  const wellUpgradeable = await getWellContractAt("WellUpgradeable", wellAddress);
  const initCalldata = wellUpgradeable.interface.encodeFunctionData("init", [name, symbol]);

  // Deploy ERC1967Proxy using CreateX for CREATE2 deployment
  const ERC1967Proxy = await ethers.getContractFactory("ERC1967Proxy", deployer);

  // Build initCode: bytecode + encoded constructor args
  const constructorArgs = ethers.utils.defaultAbiCoder.encode(
    ["address", "bytes"],
    [wellAddress, initCalldata]
  );
  const initCode = ethers.utils.solidityPack(
    ["bytes", "bytes"],
    [ERC1967Proxy.bytecode, constructorArgs]
  );

  // Calculate expected proxy address
  const proxyAddress = ethers.utils.getCreate2Address(
    createX,
    proxySalt,
    ethers.utils.keccak256(initCode)
  );

  if (verbose) {
    console.log(`Deploying proxy via CreateX at: ${proxyAddress}`);
  }

  // Deploy via CreateX
  const createXContract = await ethers.getContractAt(
    [
      "function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address)"
    ],
    createX,
    deployer
  );

  const proxyTx = await createXContract.deployCreate2(proxySalt, initCode);
  await proxyTx.wait();

  if (verbose) {
    console.log(`✅ Proxy deployed at: ${proxyAddress}`);
    console.log(`Well Name: ${name}`);
    console.log(`Well Symbol: ${symbol}`);
  }

  return {
    proxyAddress: proxyAddress,
    implementationAddress: wellAddress
  };
}

/**
 * Deploys multiple upgradeable wells
 * @param {string} beanAddress - Bean token address
 * @param {Object[]} wellsData - Array of well configuration objects
 * @param {Object} deployer - Signer account
 * @param {boolean} verbose - Enable verbose logging
 * @returns {Object[]} Array of deployment results
 */
async function deployUpgradeableWells(beanAddress, wellsData, deployer, verbose = false) {
  const results = [];

  for (let i = 0; i < wellsData.length; i++) {
    const wellData = wellsData[i];

    // Build tokens array [Bean, NonBeanToken]
    const tokens = [beanAddress, wellData.nonBeanToken];

    // Build well function call
    const wellFunction = {
      target: wellData.wellFunctionTarget,
      data: wellData.wellFunctionData
    };

    // Build pumps array
    const pumps = [
      {
        target: wellData.pump,
        data: wellData.pumpData
      }
    ];

    if (verbose) {
      console.log(`\n========================================`);
      console.log(`Deploying Well ${i + 1}/${wellsData.length}`);
      console.log(`========================================`);
    }

    const result = await deployUpgradeableWell({
      tokens,
      wellFunction,
      pumps,
      aquifer: wellData.aquifer,
      wellImplementation: wellData.wellImplementation,
      wellSalt: wellData.wellSalt,
      proxySalt: wellData.proxySalt,
      name: wellData.name,
      symbol: wellData.symbol,
      deployer,
      verbose
    });

    results.push({
      ...result,
      name: wellData.name,
      symbol: wellData.symbol,
      nonBeanToken: wellData.nonBeanToken
    });
  }

  return results;
}

/**
 * Deploy a standard well with default Base network infrastructure
 * @param {Object} params - Deployment parameters
 * @param {string} params.nonBeanToken - Non-bean token address (WETH, USDC, etc.)
 * @param {string} params.wellFunction - Well function type: "CP2", "constantProduct2", "S2", or "stable2"
 * @param {string} [params.wellFunctionData="0x"] - Encoded well function data (auto-generated for S2)
 * @param {string} [params.wellSalt] - CREATE2 salt for boreWell clone (defaults to DEFAULT_WELL_SALT)
 * @param {string} params.proxySalt - CREATE2 salt for ERC1967Proxy
 * @param {string} params.name - Well name
 * @param {string} params.symbol - Well symbol
 * @param {Object} params.deployer - Signer account
 * @param {boolean} [params.verbose=false] - Enable verbose logging
 * @returns {Object} {proxyAddress: string, implementationAddress: string}
 */
async function deployStandardWell({
  nonBeanToken,
  wellFunction,
  wellFunctionData = "0x",
  wellSalt,
  proxySalt,
  name,
  symbol,
  deployer,
  verbose = false
}) {
  // Map shorthand to full names
  const wellFunctionMap = {
    CP2: "constantProduct2",
    cp2: "constantProduct2",
    constantProduct2: "constantProduct2",
    S2: "stable2",
    s2: "stable2",
    stable2: "stable2"
  };

  const normalizedWellFunction = wellFunctionMap[wellFunction];

  if (!normalizedWellFunction) {
    throw new Error(
      `Invalid well function type: ${wellFunction}. Must be one of: CP2, constantProduct2, S2, or stable2`
    );
  }

  // Get well function address
  const wellFunctionTarget = STANDARD_ADDRESSES_BASE[normalizedWellFunction];

  // Build tokens array [Bean, NonBeanToken]
  const tokens = [STANDARD_ADDRESSES_BASE.bean, nonBeanToken];

  // Auto-generate wellFunctionData for S2 if not provided
  let finalWellFunctionData = wellFunctionData;
  if (normalizedWellFunction === "stable2" && wellFunctionData === "0x") {
    if (verbose) {
      console.log(`\nAuto-generating well function data for Stable2...`);
    }

    // Fetch token decimals
    const beanToken = await ethers.getContractAt("IERC20Metadata", STANDARD_ADDRESSES_BASE.bean);
    const nonBeanTokenContract = await ethers.getContractAt("IERC20Metadata", nonBeanToken);

    const beanDecimals = await beanToken.decimals();
    const nonBeanDecimals = await nonBeanTokenContract.decimals();

    if (verbose) {
      console.log(`  Bean decimals: ${beanDecimals}`);
      console.log(`  Non-Bean token decimals: ${nonBeanDecimals}`);
    }

    // Encode decimals for Stable2
    finalWellFunctionData = ethers.utils.defaultAbiCoder.encode(
      ["uint256", "uint256"],
      [beanDecimals, nonBeanDecimals]
    );

    if (verbose) {
      console.log(`  Encoded well function data: ${finalWellFunctionData}\n`);
    }
  }

  if (verbose) {
    console.log(`\nDeploying standard well on Base`);
    console.log(`Using standard infrastructure:`);
    console.log(`  Bean: ${STANDARD_ADDRESSES_BASE.bean}`);
    console.log(`  Aquifer: ${STANDARD_ADDRESSES_BASE.aquifer}`);
    console.log(`  Well Implementation: ${STANDARD_ADDRESSES_BASE.wellImplementation}`);
    console.log(`  Pump: ${STANDARD_ADDRESSES_BASE.pump}`);
    console.log(`  Well Function (${normalizedWellFunction}): ${wellFunctionTarget}\n`);
  }

  // Build well function call
  const wellFunctionCall = {
    target: wellFunctionTarget,
    data: finalWellFunctionData
  };

  // Build pumps array
  const pumps = [
    {
      target: STANDARD_ADDRESSES_BASE.pump,
      data: STANDARD_ADDRESSES_BASE.pumpData
    }
  ];

  // Deploy well
  return await deployUpgradeableWell({
    tokens,
    wellFunction: wellFunctionCall,
    pumps,
    aquifer: STANDARD_ADDRESSES_BASE.aquifer,
    wellImplementation: STANDARD_ADDRESSES_BASE.wellImplementation,
    wellSalt,
    proxySalt,
    name,
    symbol,
    deployer,
    verbose
  });
}

module.exports = {
  encodeWellImmutableData,
  encodeUpgradeableWellDeploymentData,
  deployUpgradeableWell,
  deployUpgradeableWells,
  deployStandardWell,
  DEFAULT_WELL_SALT,
  STANDARD_ADDRESSES_BASE
};

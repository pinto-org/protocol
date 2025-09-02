const path = require("path");
const fs = require("fs");
const glob = require("glob");

require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers");
require("hardhat-contract-sizer");
require("hardhat-gas-reporter");
require("hardhat-tracer");
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();
require("@nomiclabs/hardhat-etherscan");
const { time } = require("@nomicfoundation/hardhat-network-helpers");
const { addLiquidityAndTransfer } = require("./scripts/deployment/addLiquidity");
const { megaInit } = require("./scripts/deployment/megaInit");
const { impersonateSigner, mintEth, getBeanstalk, mintUsdc, getUsdc } = require("./utils");
const { parseDeploymentParameters } = require("./scripts/deployment/parameters/parseParams.js");
const { setBalanceAtSlot } = require("./utils/tokenSlots");
const { to6, toX, to18 } = require("./test/hardhat/utils/helpers.js");
const {
  PINTO,
  L2_PINTO,
  PINTO_DIAMOND_DEPLOYER,
  L2_PCM,
  BASE_BLOCK_TIME,
  PINTO_WETH_WELL_BASE,
  PINTO_CBETH_WELL_BASE,
  PINTO_CBTC_WELL_BASE,
  PINTO_USDC_WELL_BASE,
  PINTO_WSOL_WELL_BASE,
  nameToAddressMap,
  addressToNameMap,
  addressToBalanceSlotMap
} = require("./test/hardhat/utils/constants.js");
const { task } = require("hardhat/config");
const { upgradeWithNewFacets, decodeDiamondCutAction } = require("./scripts/diamond.js");
const { resolveDependencies } = require("./scripts/resolveDependencies");
const { getFacetBytecode, compareBytecode } = require("./test/hardhat/utils/bytecode");

//////////////////////// TASKS ////////////////////////

task("callSunrise", "Calls the sunrise function", async function () {
  beanstalk = await getBeanstalk(L2_PINTO);
  const account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);

  // ensure account has enough eth for gas
  await mintEth(account.address);

  // Simulate the transaction to check if it would succeed
  const lastTimestamp = (await ethers.provider.getBlock("latest")).timestamp;
  const hourTimestamp = parseInt(lastTimestamp / 3600 + 1) * 3600;
  const additionalSeconds = 0;
  await network.provider.send("evm_setNextBlockTimestamp", [hourTimestamp + additionalSeconds]);
  await beanstalk.connect(account).sunrise({ gasLimit: 10000000 });
  await network.provider.send("evm_mine");
  const unixTime = await time.latest();
  const currentTime = new Date(unixTime * 1000).toLocaleString();

  // Get season info
  const { raining, lastSop, lastSopSeason } = await beanstalk.time();
  const currentSeason = await beanstalk.connect(account).season();
  const floodedThisSeason = lastSopSeason === currentSeason;
  // Get total supply of pinto
  const pinto = await ethers.getContractAt("BeanstalkERC20", PINTO);
  const totalSupply = await pinto.totalSupply();

  // console.log(
  //   "sunrise complete!\ncurrent season:",
  //   currentSeason,
  //   "\ncurrent blockchain time:",
  //   unixTime,
  //   "\nhuman readable time:",
  //   currentTime,
  //   "\ncurrent block:",
  //   (await ethers.provider.getBlock("latest")).number,
  //   "\ndeltaB:",
  //   (await beanstalk.totalDeltaB()).toString(),
  //   "\nraining:",
  //   raining,
  //   "\nlast sop:",
  //   lastSop,
  //   "\nlast sop season:",
  //   lastSopSeason,
  //   "\nflooded this season:",
  //   floodedThisSeason,
  //   "\ncurrent pinto supply:",
  //   await ethers.utils.formatUnits(totalSupply, 6)
  // );
});

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

// mint eth task to mint eth to specified account
task("mintEth", "Mints eth to specified account")
  .addParam("account")
  .setAction(async (taskArgs) => {
    await mintEth(taskArgs.account);
  });

task("unpause", "Unpauses the beanstalk contract", async function () {
  let deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
  let beanstalk = await getBeanstalk(L2_PINTO);
  await beanstalk.connect(deployer).unpause();
});

task("mintUsdc", "Mints usdc to specified account")
  .addParam("account")
  .addParam("amount", "Amount of usdc to mint")
  .setAction(async (taskArgs) => {
    await mintUsdc(taskArgs.account, taskArgs.amount);
    // log balance of usdc for this address
    console.log("minted, now going to log amount");
    const usdc = await getUsdc();
    console.log("Balance of account: ", (await usdc.balanceOf(taskArgs.account)).toString());
  });

task("skipMorningAuction", "Skips the morning auction, accounts for block time", async function () {
  const duration = 600; // 10 minutes
  // skip 10 minutes in blocks --> 300 blocks for base
  const blocksToSkip = duration / BASE_BLOCK_TIME;
  for (let i = 0; i < blocksToSkip; i++) {
    await network.provider.send("evm_mine");
  }
  // increase timestamp by 5 minutes from current block timestamp
  const lastTimestamp = (await ethers.provider.getBlock("latest")).timestamp;
  await network.provider.send("evm_setNextBlockTimestamp", [lastTimestamp + duration]);
  // mine a new block to register the new timestamp
  await network.provider.send("evm_mine");
  console.log("---------------------------");
  console.log("Morning auction skipped!");
  console.log("Current block:", (await ethers.provider.getBlock("latest")).number);
  // human readable time
  const unixTime = await time.latest();
  const currentTime = new Date(unixTime * 1000).toLocaleString();
  console.log("Human readable time:", currentTime);
});

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

task("PI-1", "Deploys Pinto improvment set 1").setAction(async function () {
  const mock = false;
  let owner;
  if (mock) {
    await hre.run("updateOracleTimeouts");
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
  }
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: [
      "ClaimFacet",
      "ApprovalFacet",
      "ConvertFacet",
      "ConvertGettersFacet",
      "SiloFacet",
      "SiloGettersFacet",
      "PipelineConvertFacet",
      "SeasonFacet",
      "GaugeGettersFacet",
      "FieldFacet"
    ],
    libraryNames: [
      "LibSilo",
      "LibTokenSilo",
      "LibConvert",
      "LibPipelineConvert",
      "LibGauge",
      "LibIncentive",
      "LibWellMinting",
      "LibGerminate",
      "LibShipping",
      "LibFlood",
      "LibEvaluate",
      "LibDibbler"
    ],
    facetLibraries: {
      ClaimFacet: ["LibSilo", "LibTokenSilo"],
      ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
      SiloFacet: ["LibSilo", "LibTokenSilo"],
      PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
      SeasonFacet: [
        "LibEvaluate",
        "LibFlood",
        "LibGauge",
        "LibGerminate",
        "LibShipping",
        "LibIncentive",
        "LibWellMinting"
      ]
    },
    initFacetName: "InitPI1",
    initArgs: [],
    object: !mock,
    verbose: true,
    account: owner
  });
});

task("PI-2", "Deploys Pinto improvment set 2").setAction(async function () {
  const mock = false;
  let owner;
  if (mock) {
    await hre.run("updateOracleTimeouts");
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
  }
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: ["ConvertFacet", "ConvertGettersFacet"],
    libraryNames: ["LibSilo", "LibTokenSilo", "LibConvert", "LibPipelineConvert"],
    facetLibraries: {
      ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"]
    },
    initArgs: [],
    object: !mock,
    verbose: true,
    account: owner
  });
});

task("test-temp-changes", "Tests temperature changes after upgrade").setAction(async function () {
  // Fork from specific block
  await network.provider.request({
    method: "hardhat_reset",
    params: [
      {
        forking: {
          jsonRpcUrl: process.env.BASE_RPC,
          blockNumber: 22927326 // this block is shortly before a season where a dump would cause the temp to increase
        }
      }
    ]
  });

  const beanstalk = await getBeanstalk(L2_PINTO);

  const RESERVES = "0x4FAE5420F64c282FD908fdf05930B04E8e079770";
  const PINTO_CBTC_WELL = "0x3e11226fe3d85142B734ABCe6e58918d5828d1b4";

  // impersonate reserves address
  const reserves = await impersonateSigner(RESERVES);
  await mintEth(RESERVES);

  // Get Well contract and tokens
  const well = await ethers.getContractAt("IWell", PINTO_CBTC_WELL);
  const tokens = await well.tokens();
  const pinto = tokens[0];
  const cbBTC = tokens[1];

  console.log("\nExecuting swap from Pinto to cbBTC...");
  try {
    // Get current fee data to base our txn fees on
    const feeData = await ethers.provider.getFeeData();

    // Multiply the fees to ensure they're high enough (this took some trial and error)
    const adjustedMaxFeePerGas = feeData.maxFeePerGas.mul(5);
    const adjustedPriorityFeePerGas = feeData.maxPriorityFeePerGas.mul(2);

    const txParams = {
      maxFeePerGas: adjustedMaxFeePerGas,
      maxPriorityFeePerGas: adjustedPriorityFeePerGas,
      gasLimit: 1000000
    };

    console.log("Adjusted Tx Params:", {
      maxFeePerGas: adjustedMaxFeePerGas.toString(),
      maxPriorityFeePerGas: adjustedPriorityFeePerGas.toString(),
      gasLimit: txParams.gasLimit
    });

    // withdraw from internal balance
    console.log("\nTransferring Pinto from internal to external balance...");
    const transferTx = await beanstalk.connect(reserves).transferInternalTokenFrom(
      PINTO, // token address
      RESERVES, // sender
      RESERVES, // recipient
      to6("26000"), // amount
      0, // toMode (0 for external)
      txParams // gas parameters
    );

    var receipt = await transferTx.wait();
    console.log("Transfer complete!");
    console.log("Transaction hash:", transferTx.hash);
    console.log("Gas used:", receipt.gasUsed.toString());

    // approve spending pinto to the well
    console.log("\nApproving Pinto spend to Well...");
    const pintoToken = await ethers.getContractAt("IERC20", pinto);
    const approveTx = await pintoToken
      .connect(reserves)
      .approve(well.address, ethers.constants.MaxUint256, txParams);
    receipt = await approveTx.wait();
    console.log("Approval complete!");
    console.log("Transaction hash:", approveTx.hash);
    console.log("Gas used:", receipt.gasUsed.toString());

    // log pinto balance of reserves
    const pintoBalance = await pintoToken.balanceOf(reserves.address);
    console.log("\nPinto balance of reserves:", pintoBalance.toString());

    // Execute swap
    const amountIn = to6("26000"); // 26000 Pinto with 6 decimals
    const deadline = ethers.constants.MaxUint256;

    console.log("Swapping...");
    const tx = await well.connect(reserves).swapFrom(
      pinto, // fromToken
      cbBTC, // toToken
      amountIn, // amountIn
      0, // minAmountOut (0 for testing)
      reserves.address, // recipient
      deadline, // deadline
      txParams
    );

    receipt = await tx.wait();
    console.log("Swap complete!");
    console.log("Transaction hash:", tx.hash);
    console.log("Gas used:", receipt.gasUsed.toString());
  } catch (error) {
    console.error("Error during swap:", error);
    throw error;
  }

  // Get initial max temperature
  const initialMaxTemp = await beanstalk.maxTemperature();
  console.log("\nInitial max temperature:", initialMaxTemp.toString());

  // Run the upgrade
  console.log("\nRunning temp-changes-upgrade...");
  await hre.run("PI-3");

  // Run sunrise
  console.log("\nRunning sunrise...");
  await hre.run("callSunrise");

  // Get final max temperature
  const finalMaxTemp = await beanstalk.maxTemperature();
  console.log("\nFinal max temperature:", finalMaxTemp.toString());

  // Log the difference
  console.log("\nTemperature change:", finalMaxTemp.sub(initialMaxTemp).toString());
});

task("PI-3", "Deploys Pinto improvment set 3").setAction(async function () {
  const mock = true;
  let owner;
  if (mock) {
    // await hre.run("updateOracleTimeouts");
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
  }
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: [
      "ConvertFacet",
      "PipelineConvertFacet",
      "FieldFacet",
      "SeasonFacet",
      "ApprovalFacet",
      "ConvertGettersFacet",
      "ClaimFacet",
      "SiloFacet",
      "SiloGettersFacet",
      "SeasonGettersFacet"
    ],
    libraryNames: [
      "LibConvert",
      "LibPipelineConvert",
      "LibSilo",
      "LibTokenSilo",
      "LibEvaluate",
      "LibGauge",
      "LibIncentive",
      "LibShipping",
      "LibWellMinting",
      "LibFlood",
      "LibGerminate"
    ],
    facetLibraries: {
      ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
      PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
      SeasonFacet: [
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      ClaimFacet: ["LibSilo", "LibTokenSilo"],
      SiloFacet: ["LibSilo", "LibTokenSilo"],
      SeasonGettersFacet: ["LibWellMinting"]
    },
    initArgs: [],
    initFacetName: "InitPI3",
    object: !mock,
    verbose: true,
    account: owner
  });
});

task("PI-4", "Deploys Pinto improvment set 4").setAction(async function () {
  const mock = true;
  let owner;
  if (mock) {
    // await hre.run("updateOracleTimeouts");
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
  }
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: ["SeasonFacet", "GaugeGettersFacet", "SeasonGettersFacet"],
    libraryNames: [
      "LibEvaluate",
      "LibGauge",
      "LibIncentive",
      "LibShipping",
      "LibWellMinting",
      "LibFlood",
      "LibGerminate"
    ],
    facetLibraries: {
      SeasonFacet: [
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      SeasonGettersFacet: ["LibWellMinting"]
    },
    object: !mock,
    verbose: true,
    account: owner
  });
});

task("PI-5", "Deploys Pinto improvment set 5").setAction(async function () {
  const mock = true;
  let owner;
  if (mock) {
    // await hre.run("updateOracleTimeouts");
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
    console.log("Account address: ", await owner.getAddress());
  }
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: [
      "SeasonFacet",
      "SeasonGettersFacet",
      "FieldFacet",
      "GaugeGettersFacet",
      "ConvertGettersFacet",
      "SiloGettersFacet"
    ],
    libraryNames: [
      "LibEvaluate",
      "LibGauge",
      "LibIncentive",
      "LibShipping",
      "LibWellMinting",
      "LibFlood",
      "LibGerminate"
    ],
    facetLibraries: {
      SeasonFacet: [
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      SeasonGettersFacet: ["LibWellMinting"]
    },
    initArgs: [],
    initFacetName: "InitPI5",
    object: !mock,
    verbose: true,
    account: owner
  });
});

task("PI-6", "Deploys Pinto improvment set 6").setAction(async function () {
  const mock = true;
  let owner;
  if (mock) {
    // await hre.run("updateOracleTimeouts");
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
  }
  // upgrade facets
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: [
      "SeasonFacet",
      "SeasonGettersFacet",
      "GaugeFacet",
      "GaugeGettersFacet",
      "ClaimFacet",
      "PipelineConvertFacet",
      "SiloGettersFacet",
      "OracleFacet"
    ],
    libraryNames: [
      "LibEvaluate",
      "LibGauge",
      "LibIncentive",
      "LibShipping",
      "LibWellMinting",
      "LibFlood",
      "LibGerminate",
      "LibSilo",
      "LibTokenSilo",
      "LibPipelineConvert"
    ],
    facetLibraries: {
      SeasonFacet: [
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      SeasonGettersFacet: ["LibWellMinting"],
      ClaimFacet: ["LibSilo", "LibTokenSilo"],
      PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"]
    },
    object: !mock,
    verbose: true,
    account: owner,
    initArgs: [],
    initFacetName: "InitPI6"
  });
});

task("PI-7", "Deploys Pinto improvment set 7, Convert Down Penalty").setAction(async function () {
  const mock = true;
  let owner;
  if (mock) {
    // await hre.run("updateOracleTimeouts");
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
  }
  // upgrade facets
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: [
      "ConvertFacet",
      "ConvertGettersFacet",
      "PipelineConvertFacet",
      "GaugeFacet",
      "SeasonFacet",
      "ApprovalFacet",
      "SeasonGettersFacet",
      "ClaimFacet",
      "SiloGettersFacet",
      "GaugeGettersFacet",
      "OracleFacet"
    ],
    libraryNames: [
      "LibConvert",
      "LibPipelineConvert",
      "LibSilo",
      "LibTokenSilo",
      "LibEvaluate",
      "LibGauge",
      "LibIncentive",
      "LibShipping",
      "LibWellMinting",
      "LibFlood",
      "LibGerminate"
    ],
    facetLibraries: {
      ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
      PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
      SeasonFacet: [
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      SeasonGettersFacet: ["LibWellMinting"],
      ClaimFacet: ["LibSilo", "LibTokenSilo"]
    },
    object: !mock,
    verbose: true,
    account: owner,
    initArgs: [],
    initFacetName: "InitPI7"
  });
});

task("PI-8", "Deploys Pinto improvement set 8, Tractor, Soil Orderbook").setAction(
  async function () {
    const mock = true;
    let owner;
    if (mock) {
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
    }

    //////////////// External Contracts ////////////////

    // Deploy contracts in correct order

    // Updated Price contract
    const beanstalkPrice = await ethers.getContractFactory("BeanstalkPrice");
    const beanstalkPriceContract = await beanstalkPrice.deploy(L2_PINTO);
    await beanstalkPriceContract.deployed();
    console.log("\nBeanstalkPrice deployed to:", beanstalkPriceContract.address);

    // Price Manipulation
    const priceManipulation = await ethers.getContractFactory("PriceManipulation");
    const priceManipulationContract = await priceManipulation.deploy(L2_PINTO);
    await priceManipulationContract.deployed();
    console.log("\nPriceManipulation deployed to:", priceManipulationContract.address);

    // Deploy OperatorWhitelist
    const operatorWhitelist = await ethers.getContractFactory("OperatorWhitelist");
    const operatorWhitelistContract = await operatorWhitelist.deploy(L2_PCM);
    await operatorWhitelistContract.deployed();
    console.log("\nOperatorWhitelist deployed to:", operatorWhitelistContract.address);

    // Deploy LibTractorHelpers first
    const LibTractorHelpers = await ethers.getContractFactory("LibTractorHelpers");
    const libTractorHelpers = await LibTractorHelpers.deploy();
    await libTractorHelpers.deployed();
    console.log("\nLibTractorHelpers deployed to:", libTractorHelpers.address);

    // Deploy TractorHelpers with library linking
    const TractorHelpers = await ethers.getContractFactory("TractorHelpers", {
      libraries: {
        LibTractorHelpers: libTractorHelpers.address
      }
    });
    const tractorHelpersContract = await TractorHelpers.deploy(
      L2_PINTO, // diamond address
      beanstalkPriceContract.address, // price contract
      L2_PCM, // owner address
      priceManipulationContract.address // price manipulation contract address
    );
    await tractorHelpersContract.deployed();
    console.log("\nTractorHelpers deployed to:", tractorHelpersContract.address);

    // Deploy SowBlueprintv0 and connect it to the existing TractorHelpers
    const sowBlueprint = await ethers.getContractFactory("SowBlueprintv0");
    const sowBlueprintContract = await sowBlueprint.deploy(
      L2_PINTO, // diamond address
      L2_PCM, // owner address
      tractorHelpersContract.address // tractorHelpers contract address
    );

    await sowBlueprintContract.deployed();
    console.log("\nSowBlueprintv0 deployed to:", sowBlueprintContract.address);

    console.log("\nExternal contracts deployed!");

    console.log("\nStarting diamond upgrade...");

    /////////////////////// Diamond Upgrade ///////////////////////

    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: [
        "SiloFacet",
        "SiloGettersFacet",
        "ConvertFacet",
        "PipelineConvertFacet",
        "TractorFacet",
        "FieldFacet",
        "ApprovalFacet",
        "ConvertGettersFacet",
        "GaugeFacet",
        "GaugeGettersFacet",
        "SeasonFacet",
        "SeasonGettersFacet",
        "TokenFacet",
        "TokenSupportFacet",
        "MarketplaceFacet",
        "ClaimFacet",
        "WhitelistFacet"
      ],
      libraryNames: [
        "LibSilo",
        "LibTokenSilo",
        "LibConvert",
        "LibPipelineConvert",
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      facetLibraries: {
        SiloFacet: ["LibSilo", "LibTokenSilo"],
        ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        SeasonFacet: [
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate"
        ],
        SeasonGettersFacet: ["LibWellMinting"],
        ClaimFacet: ["LibSilo", "LibTokenSilo"]
      },
      initArgs: [],
      selectorsToRemove: ["0x2444561c"],
      initFacetName: "InitPI8",
      object: !mock,
      verbose: true,
      account: owner
    });
  }
);
task("PI-10", "Deploys Pinto improvement set 10, Cultivation Factor Change").setAction(
  async function () {
    const mock = true;
    let owner;
    if (mock) {
      // await hre.run("updateOracleTimeouts");
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
      console.log("Account address: ", await owner.getAddress());
    }
    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: ["FieldFacet", "SeasonFacet", "GaugeFacet", "MarketplaceFacet"],
      libraryNames: [
        "LibEvaluate",
        "LibGauge",
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
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate",
          "LibWeather"
        ]
      },
      initArgs: [],
      initFacetName: "InitPI10",
      object: !mock,
      verbose: true,
      account: owner
    });
  }
);

task("PI-11", "Deploys and executes InitPI11 to update convert down penalty gauge").setAction(
  async function () {
    // Get the diamond address
    const diamondAddress = L2_PINTO;

    const mock = false;
    let owner;
    if (mock) {
      await hre.run("updateOracleTimeouts");
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
      console.log("Account address: ", await owner.getAddress());
    }

    // Deploy and execute InitPI11
    console.log("📦 Deploying InitPI11 contract...");
    await upgradeWithNewFacets({
      diamondAddress: diamondAddress,
      facetNames: [
        "ConvertFacet",
        "ConvertGettersFacet",
        "PipelineConvertFacet",
        "GaugeFacet",
        "ApprovalFacet",
        "SeasonFacet",
        "ClaimFacet",
        "SiloGettersFacet",
        "GaugeGettersFacet",
        "OracleFacet",
        "SeasonGettersFacet"
      ],
      libraryNames: [
        "LibConvert",
        "LibPipelineConvert",
        "LibSilo",
        "LibTokenSilo",
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate",
        "LibWeather"
      ],
      facetLibraries: {
        ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        SeasonFacet: [
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate",
          "LibWeather"
        ],
        ClaimFacet: ["LibSilo", "LibTokenSilo"],
        SeasonGettersFacet: ["LibWellMinting"]
      },
      initFacetName: "InitPI11",
      selectorsToRemove: [
        "0x527ec6ba" // `downPenalizedGrownStalk(address,uint256,uint256)`
      ],
      bip: false,
      object: !mock,
      verbose: true,
      account: owner
    });
  }
);

task(
  "PI-12",
  "Deploys Pinto improvement set 12, Misc. Improvements and convert up bonus"
).setAction(async function () {
  const mock = true;
  let owner;
  if (mock) {
    // await hre.run("updateOracleTimeouts");
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
  }
  // upgrade facets
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: [
      "FieldFacet",
      "ConvertFacet",
      "ConvertGettersFacet",
      "PipelineConvertFacet",
      "SiloGettersFacet",
      "GaugeFacet",
      "GaugeGettersFacet",
      "SeasonFacet",
      "SeasonGettersFacet",
      "ApprovalFacet"
    ],
    libraryNames: [
      "LibTokenSilo",
      "LibConvert",
      "LibPipelineConvert",
      "LibSilo",
      "LibEvaluate",
      "LibGauge",
      "LibIncentive",
      "LibShipping",
      "LibWellMinting",
      "LibWeather",
      "LibFlood",
      "LibGerminate"
    ],
    facetLibraries: {
      ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo"],
      PipelineConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo"],
      SeasonFacet: [
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibWeather",
        "LibFlood",
        "LibGerminate"
      ],
      SeasonGettersFacet: ["LibWellMinting"]
    },
    linkedLibraries: {
      LibConvert: "LibTokenSilo"
    },
    object: !mock,
    verbose: true,
    account: owner,
    initArgs: [],
    initFacetName: "InitPI11"
  });
});

task("whitelist-rebalance", "Deploys whitelist rebalance").setAction(async function () {
  const mock = true;
  let owner;
  if (mock) {
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
  }
  // upgrade facets, no new facets or libraries, only init
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: [],
    initArgs: [],
    initFacetName: "InitWhitelistRebalance",
    object: !mock,
    verbose: true,
    account: owner
  });
});

task("silo-tractor-fix", "Deploys silo tractor fix").setAction(async function () {
  const mock = true;
  let owner;
  if (mock) {
    owner = await impersonateSigner(L2_PCM);
    await mintEth(owner.address);
  } else {
    owner = (await ethers.getSigners())[0];
  }
  // upgrade facets
  await upgradeWithNewFacets({
    diamondAddress: L2_PINTO,
    facetNames: [
      "ApprovalFacet",
      "ClaimFacet",
      "ConvertFacet",
      "PipelineConvertFacet",
      "SiloFacet",
      "SiloGettersFacet"
    ],
    libraryNames: ["LibSilo", "LibTokenSilo", "LibConvert", "LibPipelineConvert"],
    facetLibraries: {
      ClaimFacet: ["LibSilo", "LibTokenSilo"],
      ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
      PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
      SiloFacet: ["LibSilo", "LibTokenSilo"]
    },
    object: !mock,
    verbose: true,
    account: owner
  });
});

task("getWhitelistedWells", "Lists all whitelisted wells and their non-pinto tokens").setAction(
  async () => {
    console.log("-----------------------------------");
    console.log("Whitelisted Wells and Their Non-Pinto Tokens:");
    console.log("-----------------------------------");

    const beanstalk = await getBeanstalk(L2_PINTO);
    const wells = await beanstalk.getWhitelistedWellLpTokens();

    for (let i = 0; i < wells.length; i++) {
      const well = await ethers.getContractAt("IWell", wells[i]);
      const tokens = await well.tokens();
      const nonBeanToken = await ethers.getContractAt("MockToken", tokens[1]);

      // Get token details
      const tokenName = addressToNameMap[tokens[1]] || tokens[1];
      const tokenSymbol = await nonBeanToken.symbol();
      const tokenDecimals = await nonBeanToken.decimals();

      // Get well reserves
      const reserves = await well.getReserves();
      const pintoReserve = ethers.utils.formatUnits(reserves[0], 6); // Pinto has 6 decimals
      const tokenReserve = ethers.utils.formatUnits(reserves[1], tokenDecimals);

      console.log(`\nWell Address: ${wells[i]}`);
      console.log(`Non-Pinto Token:`);
      console.log(`  - Address: ${tokens[1]}`);
      console.log(`  - Name: ${tokenName}`);
      console.log(`  - Symbol: ${tokenSymbol}`);
      console.log(`  - Decimals: ${tokenDecimals}`);
      console.log(`Current Reserves:`);
      console.log(`  - Pinto: ${pintoReserve}`);
      console.log(`  - ${tokenSymbol}: ${tokenReserve}`);
    }
  }
);

task("approveTokens", "Approves all non-bean tokens for whitelisted wells")
  .addParam("account", "The account to approve tokens from")
  .setAction(async (taskArgs) => {
    console.log("-----------------------------------");
    console.log(`Approving non-bean tokens for account: ${taskArgs.account}`);

    const wells = [
      PINTO_WETH_WELL_BASE,
      PINTO_CBETH_WELL_BASE,
      PINTO_CBTC_WELL_BASE,
      PINTO_USDC_WELL_BASE,
      PINTO_WSOL_WELL_BASE
    ];

    for (let i = 0; i < wells.length; i++) {
      const well = await ethers.getContractAt("IWell", wells[i]);
      const tokens = await well.tokens();
      // tokens[0] is pinto/bean, tokens[1] is the non-bean token
      const nonBeanToken = await ethers.getContractAt("MockToken", tokens[1]);
      const tokenName = addressToNameMap[tokens[1]] || tokens[1];

      console.log(`Approving ${tokenName}, deployed at: ${tokens[1]} for well: ${wells[i]}`);

      try {
        const signer = await impersonateSigner(taskArgs.account);
        await nonBeanToken.connect(signer).approve(wells[i], ethers.constants.MaxUint256);
        console.log(`Successfully approved ${tokenName}`);
      } catch (error) {
        console.error(`Failed to approve ${tokenName}: ${error.message}`);
      }
    }

    console.log("-----------------------------------");
    console.log("Token approvals complete!");
  });

task("addLiquidity", "Adds liquidity to a well")
  .addParam("well", "The well address to add liquidity to")
  .addParam("amounts", "Comma-separated list of amounts to add to the well ignoring token decimals")
  .addParam("receiver", "receiver of the LP tokens")
  .addFlag("deposit", "Whether to deposit the LP tokens to beanstalk")
  .setAction(async (taskArgs) => {
    taskArgs.amountsArray = taskArgs.amounts.split(",");
    const account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
    await addLiquidityAndTransfer(
      account,
      taskArgs.well,
      taskArgs.receiver,
      taskArgs.amountsArray,
      true,
      taskArgs.deposit
    );
  });

task("addLiquidityToAllWells", "Adds liquidity to all wells")
  .addParam("receiver", "receiver of the LP tokens")
  .setAction(async (taskArgs) => {
    const account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
    const wells = [
      PINTO_WETH_WELL_BASE,
      PINTO_CBETH_WELL_BASE,
      PINTO_CBTC_WELL_BASE,
      PINTO_USDC_WELL_BASE,
      PINTO_WSOL_WELL_BASE
    ];
    const amounts = [
      ["10000", "2"],
      ["10000", "3"],
      ["90000", "2"],
      ["10000", "10000"],
      ["10000", "10"]
    ];
    for (let i = 0; i < wells.length; i++) {
      await addLiquidityAndTransfer(account, wells[i], taskArgs.receiver, amounts[i], false);
    }
  });

task("forceFlood", "Forces a flood to occur", async function () {
  const account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
  // add 1000 pintos and 1000 btc to force deltaB to skyrocket
  const amountsArray = ["1000", "1000"];
  const receiver = await account.getAddress();
  await addLiquidityAndTransfer(account, PINTO_CBTC_WELL_BASE, receiver, amountsArray, false);
  // call sunrise 3 times to force a flood
  for (let i = 0; i < 4; i++) {
    await hre.run("callSunrise");
  }
  console.log("---------------------------");
  console.log("Flood forced!");
});

task("sow", "Sows beans")
  .addParam("receiver", "receiver of the pods")
  .addParam("beans", "Amount of beans to sow")
  .setAction(async (taskArgs) => {
    const account = await impersonateSigner(taskArgs.receiver);
    beanstalk = await getBeanstalk(L2_PINTO);
    const mode = 0;
    const amount = to6(taskArgs.beans);
    // mint eth to receiver
    await mintEth(taskArgs.receiver);
    // mint beans
    const pintoMinter = await impersonateSigner(L2_PINTO);
    await mintEth(pintoMinter.address);
    const bean = await ethers.getContractAt("BeanstalkERC20", PINTO);
    await bean.connect(pintoMinter).mint(taskArgs.receiver, amount);
    // sow
    console.log(amount.toString());
    await beanstalk.connect(account).sow(amount, 1, mode, { gasLimit: 10000000 });
    console.log("---------------------------");
    console.log(`Sowed ${amount} beans from ${taskArgs.receiver}`);
  });

task("getTokens", "Gets tokens to an address")
  .addParam("receiver")
  .addParam("amount")
  .addParam("token")
  .setAction(async (taskArgs) => {
    let tokenAddress;
    let tokenName;
    if (nameToAddressMap[taskArgs.token]) {
      tokenAddress = nameToAddressMap[taskArgs.token];
      tokenName = taskArgs.token;
    } else {
      tokenAddress = taskArgs.token;
      tokenName = addressToNameMap[taskArgs.token];
    }
    // if token is pinto, mint by impersonating the pinto minter to also increase the total supply
    if (tokenAddress === PINTO) {
      console.log("-----------------------------------");
      console.log(`Minting Pinto to address: ${taskArgs.receiver}`);
      await hre.run("mintPinto", { receiver: taskArgs.receiver, amount: taskArgs.amount });
    } else {
      // else manipulate the balance slot
      console.log("-----------------------------------");
      console.log(`Setting the balance of ${tokenName} of: ${taskArgs.receiver}`);
      const token = await ethers.getContractAt("MockToken", tokenAddress);
      const amount = toX(taskArgs.amount, await token.decimals());
      await setBalanceAtSlot(
        tokenAddress,
        taskArgs.receiver,
        addressToBalanceSlotMap[tokenAddress],
        amount,
        false
      );
    }
    const token = await ethers.getContractAt("MockToken", tokenAddress);
    const balance = await token.balanceOf(taskArgs.receiver);
    const tokenDecimals = await token.decimals();
    console.log(
      "Balance of:",
      taskArgs.receiver,
      "for token ",
      tokenName,
      "is:",
      await ethers.utils.formatUnits(balance, tokenDecimals)
    );
    console.log("-----------------------------------");
  });

task("getPrice", async () => {
  const priceContract = await ethers.getContractAt(
    "BeanstalkPrice",
    "0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E"
  );
  const price = await priceContract.price();
  console.log(price);
});

task("getGerminatingStem", async () => {
  const beanstalk = await getBeanstalk(L2_PINTO);
  const stem = await beanstalk.getGerminatingStem(PINTO);
  console.log("pinto stem:", stem);

  const depositIds = await beanstalk.getTokenDepositIdsForAccount(
    "0x00001d167c31a30fca4ccc0fd56df74f1c606524",
    PINTO
  );
  for (let i = 0; i < depositIds.length; i++) {
    const [token, stem] = await beanstalk.getAddressAndStem(depositIds[i]);
    console.log("token:", token, "stem:", stem);
  }
});

task("StalkData")
  .addParam("account")
  .setAction(async (taskArgs) => {
    const beanstalk = await getBeanstalk(L2_PINTO);

    // mow account before checking stalk data
    await beanstalk.mow(taskArgs.account, PINTO);
    const totalStalk = (await beanstalk.totalStalk()).toString();
    const totalGerminatingStalk = (await beanstalk.getTotalGerminatingStalk()).toString();
    const totalRoots = (await beanstalk.totalRoots()).toString();
    const accountStalk = (await beanstalk.balanceOfStalk(taskArgs.account)).toString();
    const accountRoots = (await beanstalk.balanceOfRoots(taskArgs.account)).toString();
    const germinatingStemForBean = (await beanstalk.getGerminatingStem(PINTO)).toString();
    const accountGerminatingStalk = (
      await beanstalk.balanceOfGerminatingStalk(taskArgs.account)
    ).toString();

    console.log("totalStalk:", totalStalk);
    console.log("totalGerminatingStalk:", totalGerminatingStalk);
    console.log("totalRoots:", totalRoots);
    console.log("accountStalk:", accountStalk);
    console.log("accountRoots:", accountRoots);
    console.log("accountGerminatingStalk:", accountGerminatingStalk);
    console.log("germStem:", germinatingStemForBean);
    console.log("stemTip:", (await beanstalk.stemTipForToken(PINTO)).toString());
  });

task("plant", "Plants beans")
  .addParam("account")
  .setAction(async (taskArgs) => {
    console.log("---------Stalk Data Before Planting!---------");
    await hre.run("StalkData", { account: taskArgs.account });
    const beanstalk = await getBeanstalk(L2_PINTO);
    console.log("---------------------------------------------");
    console.log("-----------------Planting!!!!!---------------");
    const account = await impersonateSigner(taskArgs.account);
    console.log("account:", account.address);
    const plantResult = await beanstalk.connect(account).callStatic.plant();
    console.log("beans planted:", plantResult.beans.toString());
    console.log("deposit stem:", plantResult.stem.toString());
    await beanstalk.connect(account).plant();
    console.log("---------------------------------------------");
    console.log("---------Stalk Data After Planting!---------");
    await hre.run("StalkData", { account: taskArgs.account });
    console.log("---------------------------------------------");
  });

task("mintPinto", "Mints Pintos to an address")
  .addParam("receiver")
  .addParam("amount")
  .setAction(async (taskArgs) => {
    const pintoMinter = await impersonateSigner(L2_PINTO);
    await mintEth(pintoMinter.address);
    const pinto = await ethers.getContractAt("BeanstalkERC20", PINTO);
    const amount = to6(taskArgs.amount);
    await pinto.connect(pintoMinter).mint(taskArgs.receiver, amount);
  });

task("diamondABI", "Generates ABI file for diamond, includes all ABIs of facets", async () => {
  console.log("Compiling contracts to get updated artifacts...");
  await hre.run("compile");
  // The path (relative to the root of `protocol` directory) where all modules sit.
  const modulesDir = path.join("contracts", "beanstalk", "facets");

  // The list of modules to combine into a single ABI. All facets (and facet dependencies) will be aggregated.
  const modules = ["diamond", "farm", "field", "market", "silo", "sun", "metadata"];

  // The glob returns the full file path like this:
  // contracts/beanstalk/facets/silo/SiloFacet.sol
  // We want the "SiloFacet" part.
  const getFacetName = (file) => {
    return file.split("/").pop().split(".")[0];
  };

  // Load files across all modules
  const paths = [];
  modules.forEach((module) => {
    const filesInModule = fs.readdirSync(path.join(".", modulesDir, module));
    paths.push(...filesInModule.map((f) => [module, f]));
  });

  // Build ABI
  let abi = [];
  modules.forEach((module) => {
    const pattern = path.join(".", modulesDir, module, "**", "*Facet.sol");
    const files = glob.sync(pattern);
    if (module == "silo") {
      // Manually add in libraries that emit events
      files.push("contracts/libraries/LibIncentive.sol");
      files.push("contracts/libraries/Silo/LibGerminate.sol");
      files.push("contracts/libraries/Minting/LibWellMinting.sol");
      files.push("contracts/libraries/Silo/LibWhitelistedTokens.sol");
      files.push("contracts/libraries/Silo/LibWhitelist.sol");
      files.push("contracts/libraries/Silo/LibTokenSilo.sol");
      files.push("contracts/libraries/LibGauge.sol");
      files.push("contracts/libraries/LibShipping.sol");
      files.push("contracts/libraries/Token/LibTransfer.sol");
      files.push("contracts/libraries/LibEvaluate.sol");
      files.push("contracts/libraries/Silo/LibFlood.sol");
      files.push("contracts/libraries/LibGaugeHelpers.sol");
      files.push("contracts/libraries/Sun/LibWeather.sol");
    }
    files.forEach((file) => {
      const facetName = getFacetName(file);
      const jsonFileName = `${facetName}.json`;
      const jsonFileLoc = path.join(".", "artifacts", file, jsonFileName);

      const json = JSON.parse(fs.readFileSync(jsonFileLoc));

      // Log what's being included
      console.log(`${module}:`.padEnd(10), file);
      json.abi.forEach((item) => console.log(``.padEnd(10), item.type, item.name));
      console.log("");

      abi.push(...json.abi);
    });
  });

  const names = abi.map((a) => a.name);
  fs.writeFileSync(
    "./abi/Beanstalk.json",
    JSON.stringify(
      abi.filter((item, pos) => names.indexOf(item.name) == pos),
      null,
      2
    )
  );

  console.log("ABI written to abi/Beanstalk.json");
});

task("wellOracleSnapshot", "Gets the well oracle snapshot for a given well", async function () {
  const beanstalk = await getBeanstalk(L2_PINTO);
  const tokens = await beanstalk.getWhitelistedWellLpTokens();
  for (let i = 0; i < tokens.length; i++) {
    const snapshot = await beanstalk.wellOracleSnapshot(tokens[i]);
    console.log(snapshot);
  }
});

task("price", "Gets the price of a given token", async function () {
  const beanstalkPrice = await ethers.getContractAt(
    "BeanstalkPrice",
    "0xD0fd333F7B30c7925DEBD81B7b7a4DFE106c3a5E"
  );
  const price = await beanstalkPrice.price();
  for (let i = 0; i < 5; i++) {
    console.log(price[3][i]);
  }
});

/**
 * @notice generates mock diamond ABI.
 */
task("mockDiamondABI", "Generates ABI file for mock contracts", async () => {
  //////////////////////// FACETS ////////////////////////

  // The path (relative to the root of `protocol` directory) where all modules sit.
  const modulesDir = path.join("contracts", "beanstalk", "facets");

  // The list of modules to combine into a single ABI. All facets (and facet dependencies) will be aggregated.
  const modules = ["diamond", "farm", "field", "market", "silo", "sun", "metadata"];

  // The glob returns the full file path like this:
  // contracts/beanstalk/facets/silo/SiloFacet.sol
  // We want the "SiloFacet" part.
  const getFacetName = (file) => {
    return file.split("/").pop().split(".")[0];
  };

  // Load files across all modules
  let paths = [];
  modules.forEach((module) => {
    const filesInModule = fs.readdirSync(path.join(".", modulesDir, module));
    paths.push(...filesInModule.map((f) => [module, f]));
  });

  // Build ABI
  let abi = [];
  modules.forEach((module) => {
    const pattern = path.join(".", modulesDir, module, "**", "*Facet.sol");
    const files = glob.sync(pattern);
    if (module == "silo") {
      // Manually add in libraries that emit events
      files.push("contracts/libraries/LibIncentive.sol");
      files.push("contracts/libraries/Silo/LibGerminate.sol");
      files.push("contracts/libraries/Minting/LibWellMinting.sol");
      files.push("contracts/libraries/Silo/LibWhitelistedTokens.sol");
      files.push("contracts/libraries/Silo/LibWhitelist.sol");
      files.push("contracts/libraries/Silo/LibTokenSilo.sol");
      files.push("contracts/libraries/LibGauge.sol");
      files.push("contracts/libraries/LibShipping.sol");
      files.push("contracts/libraries/Token/LibTransfer.sol");
      files.push("contracts/libraries/LibEvaluate.sol");
      files.push("contracts/libraries/Silo/LibFlood.sol");
      files.push("contracts/libraries/LibGaugeHelpers.sol");
    }
    files.forEach((file) => {
      const facetName = getFacetName(file);
      const jsonFileName = `${facetName}.json`;
      const jsonFileLoc = path.join(".", "artifacts", file, jsonFileName);

      const json = JSON.parse(fs.readFileSync(jsonFileLoc));

      // Log what's being included
      console.log(`${module}:`.padEnd(10), file);
      json.abi.forEach((item) => console.log(``.padEnd(10), item.type, item.name));
      console.log("");

      abi.push(...json.abi);
    });
  });

  ////////////////////////// MOCK ////////////////////////
  // The path (relative to the root of `protocol` directory) where all modules sit.
  const mockModulesDir = path.join("contracts", "mocks", "mockFacets");

  // Load files across all mock modules.
  const filesInModule = fs.readdirSync(path.join(".", mockModulesDir));
  console.log("Mock Facets:");
  console.log(filesInModule);

  // Build ABI
  filesInModule.forEach((module) => {
    const file = path.join(".", mockModulesDir, module);
    const facetName = getFacetName(file);
    const jsonFileName = `${facetName}.json`;
    const jsonFileLoc = path.join(".", "artifacts", file, jsonFileName);
    const json = JSON.parse(fs.readFileSync(jsonFileLoc));

    // Log what's being included
    console.log(`${module}:`.padEnd(10), file);
    json.abi.forEach((item) => console.log(``.padEnd(10), item.type, item.name));
    console.log("");

    abi.push(...json.abi);
  });

  const names = abi.map((a) => a.name);
  fs.writeFileSync(
    "./abi/MockBeanstalk.json",
    JSON.stringify(
      abi.filter((item, pos) => names.indexOf(item.name) == pos),
      null,
      2
    )
  );
});

task("resolveUpgradeDependencies", "Resolves upgrade dependencies")
  .addOptionalParam(
    "facets",
    "Comma-separated list of facet names that were changed in the upgrade"
  )
  .addOptionalParam(
    "libraries",
    "Comma-separated list of library names that were changed in the upgrade"
  )
  .setAction(async function (taskArgs) {
    // Compile first to update the artifacts
    console.log("Compiling contracts to get updated artifacts...");
    await hre.run("compile");
    let facetNames = [];
    let libraryNames = [];
    // Validate input
    if (!taskArgs.facets && !taskArgs.libraries) {
      throw new Error("Either 'facets' or 'libraries' parameters are required.");
    }
    // Process 'facets' if provided
    if (taskArgs.facets) {
      facetNames = taskArgs.facets.split(",").map((name) => name.trim());
      console.log("Resolving dependencies for facets:", facetNames);
    } else {
      console.log("No facets changed, resolving dependencies for libraries only.");
    }
    // Process 'libraries' if provided
    if (taskArgs.libraries) {
      libraryNames = taskArgs.libraries.split(",").map((name) => name.trim());
      console.log("Resolving dependencies for libraries:", libraryNames);
    } else {
      console.log("No libraries changed, resolving dependencies for facets only.");
    }
    resolveDependencies(facetNames, libraryNames);
  });

task("decodeDiamondCut", "Decodes diamondCut calldata into human-readable format")
  .addParam("data", "The calldata to decode")
  .setAction(async ({ data }) => {
    const DIAMOND_CUT_ABI = [
      "function diamondCut((address facetAddress, uint8 action, bytes4[] functionSelectors)[] _diamondCut, address _init, bytes _calldata)"
    ];
    const iface = new ethers.utils.Interface(DIAMOND_CUT_ABI);

    // Decode the calldata
    const decoded = iface.parseTransaction({ data });

    // Extract the decoded parameters
    const { _diamondCut, _init, _calldata } = decoded.args;

    // Pretty print
    console.log("\n===== Decoded Diamond Cut =====");
    _diamondCut.forEach((facetCut, index) => {
      console.log(`\nFacetCut #${index + 1}`);
      console.log("=".repeat(40));
      console.log(`  🏷️  Facet Address  : ${facetCut.facetAddress}`);
      console.log(`  🔧 Action         : ${decodeDiamondCutAction(facetCut.action)}`);
      console.log("  📋 Function Selectors:");
      if (facetCut.functionSelectors.length > 0) {
        facetCut.functionSelectors.forEach((selector, selectorIndex) => {
          console.log(`      ${selectorIndex + 1}. ${selector}`);
        });
      } else {
        console.log("      (No selectors provided)");
      }
      console.log("=".repeat(40));
    });

    console.log("\n Init Facet Address:");
    console.log(`  ${_init}`);

    console.log("\n Init Selector:");
    console.log(`  ${_calldata}`);
  });

task(
  "verifySafeHashes",
  "Computes the expected hashes for a Safe transaction, to be verified against the safe ui and signer wallets"
)
  .addParam("safe", "The address of the safe multisig", undefined, types.string)
  .addParam(
    "to",
    "The address of the contract that the safe is interacting with",
    undefined,
    types.string
  )
  .addParam("data", "The data field in the safe ui (bytes)", undefined, types.string)
  .addOptionalParam("nonce", "The nonce of the transaction", -1, types.int)
  .addOptionalParam("operation", "The operation type of the transaction", 0, types.int)
  .setAction(async (taskArgs) => {
    // Parameters
    const safeAddress = taskArgs.safe;
    const to = taskArgs.to;
    const data = taskArgs.data;
    const dataHashed = ethers.utils.keccak256(data);
    // Default values (used when signing the transaction)
    const value = 0;
    const operation = taskArgs.operation; // Enum.Operation.Call (0 represents Call, 1 represents DelegateCall)
    const safeTxGas = 0;
    const baseGas = 0;
    const gasPrice = 0;
    const gasToken = ethers.constants.AddressZero; // native token (ETH)
    const refundReceiver = ethers.constants.AddressZero;
    // Standard for versions 1.0.0 and above
    const safeTxTypeHash = "0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8";

    const abi = [
      "function getTransactionHash(address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 _nonce) external view returns (bytes32)",
      "function getChainId() external view returns (uint256)",
      "function domainSeparator() external view returns (bytes32)",
      "function nonce() external view returns (uint256)"
    ];
    const safeMultisig = await ethers.getContractAt(abi, safeAddress);

    // Verify chain id
    const chainId = await safeMultisig.getChainId();

    // Get curent nonce if not provided
    let nonce;
    if (taskArgs.nonce === -1) {
      nonce = await safeMultisig.nonce();
    } else {
      nonce = taskArgs.nonce;
    }

    // Verify domain separator
    const domainSeparator = await safeMultisig.domainSeparator();

    // Verify safe transaction hash
    const safeTransactionHash = await safeMultisig.getTransactionHash(
      to,
      value,
      data,
      operation,
      safeTxGas,
      baseGas,
      gasPrice,
      gasToken,
      refundReceiver,
      nonce
    );

    // Verify message hash
    // The message hash is the keccak256 hash of the abi encoded SafeTxStruct struct
    // with the parameters below
    const encodedMsg = ethers.utils.defaultAbiCoder.encode(
      [
        "bytes32", // safeTxTypeHash
        "address", // to
        "uint256", // value
        "bytes32", // dataHashed
        "uint8", // operation
        "uint256", // safeTxGas
        "uint256", // baseGas
        "uint256", // gasPrice
        "address", // gasToken
        "address", // refundReceiver
        "uint256" // nonce
      ],
      [
        safeTxTypeHash,
        to,
        value,
        dataHashed,
        operation,
        safeTxGas,
        baseGas,
        gasPrice,
        gasToken,
        refundReceiver,
        nonce
      ]
    );

    // Keccak256 hash of the encoded message
    const computedMsgHash = ethers.utils.keccak256(encodedMsg);

    // Pretty print results
    console.log("\n\n");
    console.log("=".repeat(90));
    console.log("          🔗 Safe Transaction Details     ");
    console.log("=".repeat(90));
    console.log(`🌐 Chain ID           : ${chainId.toString()}`);
    console.log(`🔹 Safe Address       : ${safeAddress}`);
    console.log(`🔹 Interacting with   : ${to}`);
    console.log(`🔹 Nonce              : ${nonce}`);
    console.log(`🔹 Domain Separator   : ${domainSeparator}`);
    console.log(`🔹 Safe Tx Hash       : ${safeTransactionHash}`);
    console.log(`🔹 Message Hash       : ${computedMsgHash}`);
    console.log("=".repeat(90));
  });
task("verifyBytecode", "Verifies the bytecode of facets with optional library linking")
  .addParam(
    "facets",
    'JSON string mapping facets to their deployed addresses (e.g., \'{"FacetName": "0xAddress"}\')'
  )
  .addOptionalParam(
    "libraries",
    'JSON string mapping facets to their linked libraries (e.g., \'{"FacetName": {"LibName": "0xAddress"}}\')'
  )
  .setAction(async (taskArgs) => {
    // Compile first to update the artifacts
    console.log("Compiling contracts to get updated artifacts...");
    await hre.run("compile");

    // Parse inputs
    const deployedFacetAddresses = JSON.parse(taskArgs.facets);
    const facetLibraries = taskArgs.libraries ? JSON.parse(taskArgs.libraries) : {};

    // Deduce facet names from the keys in the addresses JSON
    const facetNames = Object.keys(deployedFacetAddresses);

    // Log the facet names and libraries
    console.log("-----------------------------------");
    console.log("\n📝 Facet Names:");
    facetNames.forEach((name) => console.log(`  - ${name}`));
    console.log("\n🔗 Facet Libraries:");
    Object.entries(facetLibraries).forEach(([facet, libraries]) => {
      console.log(`  📦 ${facet}:`);
      Object.entries(libraries).forEach(([lib, address]) => {
        console.log(`    🔹 ${lib}: ${address}`);
      });
    });
    console.log("\n📍 Deployed Addresses:");
    Object.entries(deployedFacetAddresses).forEach(([facet, address]) => {
      console.log(`  ${facet}: ${address}\n`);
    });
    console.log("-----------------------------------");

    // Verify bytecode for the facets
    const facetData = await getFacetBytecode(facetNames, facetLibraries, true);
    await compareBytecode(facetData, deployedFacetAddresses, false);
  });

task("pumps", async function () {
  const well = await ethers.getContractAt("IWell", PINTO_CBTC_WELL_BASE);
  const pumps = await well.pumps();
  console.log(pumps);
});

task("singleSidedDeposits", "Deposits non-bean tokens into wells and then into beanstalk")
  .addParam("account", "The account to deposit from")
  .addParam(
    "amounts",
    "Comma-separated list of amounts to deposit for each token (WETH,CBETH,CBTC,USDC,WSOL)"
  )
  .setAction(async (taskArgs) => {
    console.log("-----------------------------------");
    console.log(`Starting single-sided deposits for account: ${taskArgs.account}`);

    const wells = [
      PINTO_WETH_WELL_BASE,
      PINTO_CBETH_WELL_BASE,
      PINTO_CBTC_WELL_BASE,
      PINTO_USDC_WELL_BASE,
      PINTO_WSOL_WELL_BASE
    ];

    const amounts = taskArgs.amounts.split(",");
    if (amounts.length !== wells.length) {
      throw new Error("Must provide same number of amounts as wells");
    }

    const beanstalk = await getBeanstalk(L2_PINTO);
    const signer = await impersonateSigner(taskArgs.account);

    for (let i = 0; i < wells.length; i++) {
      const well = await ethers.getContractAt("IWell", wells[i]);
      const tokens = await well.tokens();
      const nonBeanToken = await ethers.getContractAt("MockToken", tokens[1]);
      const tokenName = addressToNameMap[tokens[1]] || tokens[1];
      const tokenDecimals = await nonBeanToken.decimals();
      const amount = toX(amounts[i], tokenDecimals);

      console.log(`\nProcessing ${tokenName}:`);
      console.log(`Amount: ${amount}`);

      try {
        // Set token balance and approve
        console.log(`Setting balance and approving ${tokenName}`);
        const balanceSlot = addressToBalanceSlotMap[tokens[1]];
        await setBalanceAtSlot(tokens[1], taskArgs.account, balanceSlot, amount, false);
        await nonBeanToken.connect(signer).approve(wells[i], ethers.constants.MaxUint256);

        // Add single-sided liquidity
        console.log(`Adding liquidity to well ${wells[i]}`);
        const tokenAmountsIn = [0, amount];
        await well
          .connect(signer)
          .addLiquidity(tokenAmountsIn, 0, taskArgs.account, ethers.constants.MaxUint256);

        // Approve and deposit LP tokens to beanstalk
        const wellToken = await ethers.getContractAt("IERC20", wells[i]);
        const lpBalance = await wellToken.balanceOf(taskArgs.account);
        console.log(`Received ${lpBalance.toString()} LP tokens`);

        console.log(`Approving ${tokenName} LP tokens for beanstalk`);
        await wellToken.connect(signer).approve(beanstalk.address, ethers.constants.MaxUint256);
        console.log(`Depositing ${tokenName} LP tokens into beanstalk`);
        await beanstalk.connect(signer).deposit(wells[i], lpBalance, 0);
        console.log(`Successfully deposited ${tokenName} LP tokens into beanstalk`);
        // return;
      } catch (error) {
        console.error(`Failed to process ${tokenName}: ${error.message}`);
      }
    }
    console.log("-----------------------------------");
    console.log("Single-sided deposits complete!");
  });

task("updateOracleTimeouts", "Updates oracle timeouts for all whitelisted LP tokens").setAction(
  async () => {
    console.log("Updating oracle timeouts for all whitelisted LP tokens");

    const beanstalk = await getBeanstalk(L2_PINTO);
    const account = await impersonateSigner(L2_PCM);
    await mintEth(account.address);

    // Get all whitelisted LP tokens
    const wells = await beanstalk.getWhitelistedWellLpTokens();

    for (let i = 0; i < wells.length; i++) {
      const well = await ethers.getContractAt("IWell", wells[i]);
      const tokens = await well.tokens();
      // tokens[0] is pinto/bean, tokens[1] is the non-bean token
      const nonPintoToken = tokens[1];
      const tokenName = addressToNameMap[nonPintoToken] || nonPintoToken;

      console.log(`\nProcessing well: ${wells[i]}`);
      console.log(`Non-pinto token: ${tokenName} (${nonPintoToken})`);

      try {
        // Get current oracle implementation for the non-pinto token
        const currentImpl = await beanstalk.getOracleImplementationForToken(nonPintoToken);
        console.log("Current implementation:");
        console.log("- Target:", currentImpl.target);
        console.log("- Selector:", currentImpl.selector);
        console.log("- Encode Type:", currentImpl.encodeType);
        console.log("- Current Data:", currentImpl.data);

        const newImpl = {
          target: currentImpl.target,
          selector: currentImpl.selector,
          encodeType: currentImpl.encodeType,
          data: ethers.utils.hexZeroPad(ethers.utils.hexlify(86400 * 365), 32) // 365 day oracle timeout
        };

        console.log("\nNew implementation:");
        console.log("- Target:", newImpl.target);
        console.log("- Selector:", newImpl.selector);
        console.log("- Encode Type:", newImpl.encodeType);
        console.log("- New Data:", newImpl.data);

        // Update the oracle implementation for token
        await beanstalk
          .connect(account)
          .updateOracleImplementationForToken(nonPintoToken, newImpl, { gasLimit: 10000000 });
        console.log(`Successfully updated oracle timeout for token: ${tokenName}`);
      } catch (error) {
        console.error(`Failed to update oracle timeout for token ${tokenName}:`, error.message);
      }
    }

    console.log("Finished oracle updates");
  }
);

task("ecosystemABI", "Generates ABI files for ecosystem contracts").setAction(async () => {
  try {
    console.log("Compiling contracts to get updated artifacts...");
    await hre.run("compile");

    console.log("Generating ABIs for ecosystem contracts...");

    // Create output directory if it doesn't exist
    const outputDir = "./abi/ecosystem";
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }

    // Generate TractorHelpers ABI
    const tractorHelpersArtifact = await hre.artifacts.readArtifact("TractorHelpers");
    fs.writeFileSync(
      `${outputDir}/TractorHelpers.json`,
      JSON.stringify(tractorHelpersArtifact.abi, null, 2)
    );

    // Generate SiloHelpers ABI
    const siloHelpersArtifact = await hre.artifacts.readArtifact("SiloHelpers");
    fs.writeFileSync(
      `${outputDir}/SiloHelpers.json`,
      JSON.stringify(siloHelpersArtifact.abi, null, 2)
    );

    // Generate SowBlueprintv0 ABI
    const sowBlueprintArtifact = await hre.artifacts.readArtifact("SowBlueprintv0");
    fs.writeFileSync(
      `${outputDir}/SowBlueprintv0.json`,
      JSON.stringify(sowBlueprintArtifact.abi, null, 2)
    );

    // Generate BeanstalkPrice ABI
    const beanstalkPriceArtifact = await hre.artifacts.readArtifact("BeanstalkPrice");
    fs.writeFileSync(
      `${outputDir}/BeanstalkPrice.json`,
      JSON.stringify(beanstalkPriceArtifact.abi, null, 2)
    );

    // Generate WellPrice ABI (parent contract of BeanstalkPrice)
    const wellPriceArtifact = await hre.artifacts.readArtifact("WellPrice");
    fs.writeFileSync(`${outputDir}/WellPrice.json`, JSON.stringify(wellPriceArtifact.abi, null, 2));

    console.log("ABIs generated successfully in", outputDir);
  } catch (error) {
    console.error("Error generating ABIs:", error);
    process.exit(1);
  }
});

task("facetAddresses", "Displays current addresses of specified facets on Base mainnet")
  .addParam(
    "facets",
    "Comma-separated list of facet names to look up (ex: 'FieldFacet,SiloFacet,SeasonFacet')"
  )
  .addFlag("urls", "Show BaseScan URLs for the facets")
  .setAction(async (taskArgs) => {
    const BASESCAN_API_KEY = process.env.ETHERSCAN_KEY_BASE;
    if (!BASESCAN_API_KEY) {
      console.error("❌ Please set ETHERSCAN_KEY_BASE in your environment variables");
      return;
    }

    const diamond = await ethers.getContractAt("IDiamondLoupe", L2_PINTO);

    // Get all facets from the diamond
    const allFacets = await diamond.facets();

    // Get the requested facet names
    const requestedFacets = taskArgs.facets.split(",").map((f) => f.trim());

    console.log("\n🔍 Looking up facet addresses on Base mainnet...");
    console.log("-----------------------------------");

    // Create a map of addresses to their contract names
    const addressToName = new Map();

    // Fetch contract names from BaseScan for each unique address
    const uniqueAddresses = [...new Set(allFacets.map((f) => f.facetAddress))];

    for (const address of uniqueAddresses) {
      try {
        let data;
        let attempts = 0;
        const maxAttempts = 3;

        do {
          const response = await fetch(
            `https://api.basescan.org/api?module=contract&action=getsourcecode&address=${address}&apikey=${BASESCAN_API_KEY}`
          );
          data = await response.json();
          attempts++;

          if (data.status === "1" && data.result[0]) {
            const contractName = data.result[0].ContractName;
            addressToName.set(address, contractName);
            break;
          }

          // Wait 1 second before retrying
          if (data.status === "0" && attempts < maxAttempts) {
            await new Promise((resolve) => setTimeout(resolve, 1000));
          }
        } while (data.status === "0" && attempts < maxAttempts);
      } catch (e) {
        console.log(`⚠️  Error fetching contract name for ${address}: ${e.message}`);
      }
    }

    // For each requested facet, find its address
    for (const facetName of requestedFacets) {
      let found = false;

      for (const facet of allFacets) {
        const contractName = addressToName.get(facet.facetAddress);
        if (contractName && contractName.toLowerCase() === facetName.toLowerCase()) {
          console.log(`📦 ${facetName}: ${facet.facetAddress}`);
          if (taskArgs.urls) {
            console.log(`   🔗 https://basescan.org/address/${facet.facetAddress}`);
          }
          found = true;
          break;
        }
      }

      if (!found) {
        console.log(`❌ ${facetName}: Not found on diamond`);
      }
    }

    console.log("-----------------------------------");
  });

//////////////////////// CONFIGURATION ////////////////////////

module.exports = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      chainId: 1337,
      forking: process.env.FORKING_RPC
        ? {
            url: process.env.FORKING_RPC,
            blockNumber: parseInt(process.env.BLOCK_NUMBER) || undefined
          }
        : undefined,
      allowUnlimitedContractSize: true
    },
    localhost: {
      chainId: 1337,
      url: "http://127.0.0.1:8545/",
      timeout: 1000000000,
      accounts: "remote"
    },
    mainnet: {
      chainId: 1,
      url: process.env.MAINNET_RPC || "",
      timeout: 1000000000
    },
    arbitrum: {
      chainId: 42161,
      url: process.env.ARBITRUM_RPC || "",
      timeout: 1000000000
    },
    base: {
      chainId: 8453,
      url: process.env.BASE_RPC || "",
      timeout: 100000000,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : []
    },
    custom: {
      chainId: 41337,
      url: process.env.CUSTOM_RPC || "",
      timeout: 100000
    }
  },
  etherscan: {
    apiKey: {
      arbitrumOne: process.env.ETHERSCAN_KEY_ARBITRUM,
      mainnet: process.env.ETHERSCAN_KEY,
      base: process.env.ETHERSCAN_KEY_BASE
    },
    customChains: [
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org"
        }
      }
    ]
  },
  solidity: {
    compilers: [
      {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100
          },
          evmVersion: "cancun"
        }
      },
      {
        version: "0.7.6",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100
          }
        }
      }
    ]
  },
  gasReporter: {
    enabled: false
  },
  mocha: {
    timeout: 100000000
  },
  paths: {
    sources: "./contracts",
    cache: "./cache"
  },
  ignoreWarnings: [
    'code["5574"]' // Ignores the specific warning about duplicate definitions
  ]
};

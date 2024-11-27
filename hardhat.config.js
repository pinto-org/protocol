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
  addressToSlotMap
} = require("./test/hardhat/utils/constants.js");
const { task } = require("hardhat/config");
const { upgradeWithNewFacets } = require("./scripts/diamond.js");
const { resolveDependencies } = require("./scripts/resolveDependencies");

//////////////////////// TASKS ////////////////////////

task("callSunrise", "Calls the sunrise function", async function () {
  beanstalk = await getBeanstalk(L2_PINTO);
  const account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);

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

  console.log(
    "sunrise complete!\ncurrent season:",
    currentSeason,
    "\ncurrent blockchain time:",
    unixTime,
    "\nhuman readable time:",
    currentTime,
    "\ncurrent block:",
    (await ethers.provider.getBlock("latest")).number,
    "\ndeltaB:",
    (await beanstalk.totalDeltaB()).toString(),
    "\nraining:",
    raining,
    "\nlast sop:",
    lastSop,
    "\nlast sop season:",
    lastSopSeason,
    "\nflooded this season:",
    floodedThisSeason,
    "\ncurrent pinto supply:",
    await ethers.utils.formatUnits(totalSupply, 6)
  );
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
  const duration = 300; // 5 minutes
  // skip 5 minutes in blocks --> 150 blocks for base
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
        addressToSlotMap[tokenAddress],
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
      files.push("contracts/libraries/Silo/LibWhitelist.sol");
      files.push("contracts/libraries/LibGauge.sol");
      files.push("contracts/libraries/Silo/LibGerminate.sol");
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
    // compile first to update the artifacts
    console.log("Compiling contracts to get updated artifacts...");
    await hre.run("compile");
    let facetNames;
    let libraryNames;
    // get the facet and library names
    if (!taskArgs.facets && !taskArgs.libraries) {
      throw new Error("Either 'facets' or 'libraries' parameters are required.");
    }
    if (!taskArgs.facets) {
      console.log("No facets changed, resolving dependencies for libraries only");
      taskArgs.facets = [];
      libraryNames = taskArgs.libraries.split(",");
    }
    if (!taskArgs.libraries) {
      console.log("No libraries changed, resolving dependencies for facets only");
      taskArgs.libraries = [];
      facetNames = taskArgs.facets.split(",");
    }
    resolveDependencies(facetNames, libraryNames);
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
        const balanceSlot = addressToSlotMap[tokens[1]];
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
      timeout: 100000000
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

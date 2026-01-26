const { task } = require("hardhat/config");
const { time } = require("@nomicfoundation/hardhat-network-helpers");
const { impersonateSigner, mintEth, getBeanstalk } = require("../utils");
const { addLiquidityAndTransfer } = require("../scripts/deployment/addLiquidity");
const { to6 } = require("../test/hardhat/utils/helpers.js");
const {
  PINTO,
  L2_PINTO,
  PINTO_DIAMOND_DEPLOYER,
  BASE_BLOCK_TIME,
  PINTO_CBBTC_WELL_BASE,
  PINTO_WSTETH_WELL_BASE
} = require("../test/hardhat/utils/constants.js");

module.exports = function () {
  /**
   * Internal function to call sunrise logic.
   * Separated for direct invocation from both callSunrise and callSunriseN tasks.
   */
  async function runSunrise({ hre, ethers, network, beanstalk, account }) {
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
  }

  task("callSunrise", "Calls the sunrise function", async function (_, hre) {
    const { ethers, network } = hre;
    const beanstalk = await getBeanstalk(L2_PINTO);
    const account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);

    await runSunrise({ hre, ethers, network, beanstalk, account });
  });

  task("callSunriseN", "Calls the sunrise function N times")
    .addParam("n", "The number of times to call sunrise")
    .setAction(async function (taskArgs, hre) {
      const { ethers, network } = hre;
      const n = parseInt(taskArgs.n);
      if (isNaN(n) || n < 1) {
        throw new Error("Please provide a valid integer for n > 0");
      }
      const beanstalk = await getBeanstalk(L2_PINTO);
      const account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
      for (let i = 0; i < n; i++) {
        console.log(`---- Calling sunrise #${i + 1} of ${n} ----`);
        await runSunrise({ hre, ethers, network, beanstalk, account });
      }
    });

  task("unpause", "Unpauses the beanstalk contract", async function () {
    let deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
    let beanstalk = await getBeanstalk(L2_PINTO);
    await beanstalk.connect(deployer).unpause();
  });

  task(
    "skipMorningAuction",
    "Skips the morning auction, accounts for block time",
    async function () {
      const duration = 900; // 15 minutes (morning auction is 10 minutes)
      // skip 15 minutes in blocks --> 450 blocks for base
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
    }
  );
  task(
    "skipCapacityRamp",
    "Skips the capacity ramp up period, accounts for block time",
    async function () {
      const duration = 1800; // 5 minutes
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
    }
  );

  task("forceFlood", "Forces a flood to occur", async function () {
    const account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
    // add 1000 pintos and 1000 btc to force deltaB to skyrocket
    const amountsArray = ["1000", "1000"];
    const receiver = await account.getAddress();
    await addLiquidityAndTransfer(account, PINTO_CBBTC_WELL_BASE, receiver, amountsArray, false);
    // call sunrise 3 times to force a flood
    for (let i = 0; i < 4; i++) {
      await hre.run("callSunrise");
    }
    console.log("---------------------------");
    console.log("Flood forced!");
  });

  task("getPrices", "Gets the price of a token").setAction(async function () {
    const beanstalkPrice = await ethers.getContractAt(
      "BeanstalkPrice",
      "0x13D25ABCB6a19948d35654715c729c6501230b49"
    );
    const priceData = await beanstalkPrice["price()"]();

    // Helper function to format numbers
    const fmt = (bn, decimals = 6) => ethers.utils.formatUnits(bn, decimals);
    const fmtUSD = (bn) => `$${parseFloat(fmt(bn, 6)).toFixed(4)}`;

    console.log("\n=== BEAN PRICE OVERVIEW ===");
    console.log(`Price: ${fmtUSD(priceData.price)}`);
    console.log(`Total Liquidity: $${parseFloat(fmt(priceData.liquidity, 6)).toLocaleString()}`);
    console.log(`DeltaB: ${parseFloat(fmt(priceData.deltaB, 6)).toLocaleString()} Beans`);

    console.log(`\n=== POOL DETAILS (${priceData.ps.length} pools) ===\n`);

    for (let i = 0; i < priceData.ps.length; i++) {
      const pool = priceData.ps[i];
      console.log(`Pool ${i + 1}: ${pool.pool}`);
      console.log(`  Price: ${fmtUSD(pool.price)}`);
      console.log(`  Total Liquidity: $${parseFloat(fmt(pool.liquidity, 6)).toLocaleString()}`);
      console.log(
        `  Bean Liquidity: ${parseFloat(fmt(pool.beanLiquidity, 6)).toLocaleString()} Beans`
      );
      console.log(
        `  Non-Bean Liquidity: $${parseFloat(fmt(pool.nonBeanLiquidity, 6)).toLocaleString()}`
      );
      console.log(`  DeltaB: ${parseFloat(fmt(pool.deltaB, 6)).toLocaleString()} Beans`);
      console.log(`  LP USD Value: ${fmtUSD(pool.lpUsd)}`);
      console.log(`  LP BDV: ${parseFloat(fmt(pool.lpBdv, 6)).toLocaleString()}`);
      console.log(`  LP BDV: ${pool.lpBdv}`);
      console.log(`  Tokens: ${pool.tokens[0]}, ${pool.tokens[1]}`);
      console.log(
        `  Balances: ${parseFloat(fmt(pool.balances[0], 6)).toLocaleString()}, ${parseFloat(fmt(pool.balances[1], 6)).toLocaleString()}\n`
      );
    }
  });

  task("addLiquidityToWstethWell", "Adds liquidity to the wstETH well")
    .addOptionalParam("well", "The well address", PINTO_WSTETH_WELL_BASE)
    .addOptionalParam("beanAmount", "Amount of Bean tokens to add", "10000")
    .addOptionalParam("wstethAmount", "Amount of wstETH tokens to add", "1")
    .addOptionalParam("receiver", "Receiver of LP tokens", PINTO_DIAMOND_DEPLOYER)
    .addFlag("deposit", "Deposit the LP tokens into Beanstalk silo", true)
    .setAction(async (taskArgs) => {
      console.log("\n=== Adding Liquidity to wstETH Well ===");
      console.log(`Well: ${taskArgs.well}`);
      console.log(`Bean Amount: ${taskArgs.beanAmount}`);
      console.log(`wstETH Amount: ${taskArgs.wstethAmount}`);
      console.log(`Receiver: ${taskArgs.receiver}`);
      console.log(`Deposit to Silo: ${taskArgs.deposit}\n`);

      const account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
      const amounts = [taskArgs.beanAmount, taskArgs.wstethAmount];

      await addLiquidityAndTransfer(
        account,
        taskArgs.well,
        taskArgs.receiver,
        amounts,
        true,
        taskArgs.deposit
      );

      console.log("\n✅ Liquidity added successfully!\n");
    });
};

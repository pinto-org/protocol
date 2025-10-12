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
  PINTO_CBTC_WELL_BASE
} = require("../test/hardhat/utils/constants.js");

module.exports = function () {
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

  task("unpause", "Unpauses the beanstalk contract", async function () {
    let deployer = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);
    let beanstalk = await getBeanstalk(L2_PINTO);
    await beanstalk.connect(deployer).unpause();
  });

  task(
    "skipMorningAuction",
    "Skips the morning auction, accounts for block time",
    async function () {
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
    await addLiquidityAndTransfer(account, PINTO_CBTC_WELL_BASE, receiver, amountsArray, false);
    // call sunrise 3 times to force a flood
    for (let i = 0; i < 4; i++) {
      await hre.run("callSunrise");
    }
    console.log("---------------------------");
    console.log("Flood forced!");
  });
};

const { task } = require("hardhat/config");
const { impersonateSigner, mintEth, getBeanstalk } = require("../utils");
const { to6 } = require("../test/hardhat/utils/helpers.js");
const {
  PINTO,
  L2_PINTO
} = require("../test/hardhat/utils/constants.js");

module.exports = function() {
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
};
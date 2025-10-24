const { task } = require("hardhat/config");
const { addLiquidityAndTransfer } = require("../scripts/deployment/addLiquidity");
const { impersonateSigner, mintEth, getBeanstalk } = require("../utils");
const { setBalanceAtSlot } = require("../utils/tokenSlots");
const { toX } = require("../test/hardhat/utils/helpers.js");
const {
  L2_PINTO,
  PINTO_DIAMOND_DEPLOYER,
  PINTO_WETH_WELL_BASE,
  PINTO_CBETH_WELL_BASE,
  PINTO_CBTC_WELL_BASE,
  PINTO_USDC_WELL_BASE,
  PINTO_WSOL_WELL_BASE,
  addressToNameMap,
  addressToBalanceSlotMap
} = require("../test/hardhat/utils/constants.js");

module.exports = function() {
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
        } catch (error) {
          console.error(`Failed to process ${tokenName}: ${error.message}`);
        }
      }
      console.log("-----------------------------------");
      console.log("Single-sided deposits complete!");
    });
};
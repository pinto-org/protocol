const { task } = require("hardhat/config");
const { impersonateSigner, mintEth, mintUsdc, getUsdc } = require("../utils");
const { setBalanceAtSlot } = require("../utils/tokenSlots");
const { to6, toX } = require("../test/hardhat/utils/helpers.js");
const {
  PINTO,
  L2_PINTO,
  PINTO_DIAMOND_DEPLOYER,
  PINTO_WETH_WELL_BASE,
  PINTO_CBETH_WELL_BASE,
  PINTO_CBTC_WELL_BASE,
  PINTO_USDC_WELL_BASE,
  PINTO_WSOL_WELL_BASE,
  nameToAddressMap,
  addressToNameMap,
  addressToBalanceSlotMap
} = require("../test/hardhat/utils/constants.js");

module.exports = function() {
  task("mintEth", "Mints eth to specified account")
    .addParam("account")
    .setAction(async (taskArgs) => {
      await mintEth(taskArgs.account);
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
};
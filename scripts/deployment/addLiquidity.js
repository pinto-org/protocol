const {
  MAX_UINT256,
  L2_PINTO,
  PINTO,
  PINTO_DIAMOND_DEPLOYER,
  RESERVES_5_PERCENT_MULTISIG,
  addressToBalanceSlotMap,
  addressToNameMap,
  wellToNonPintoTokenMap,
  wellToChainlinkOracleMap
} = require("../../test/hardhat/utils/constants.js");
const { to6, toX } = require("../../test/hardhat/utils/helpers.js");
const { impersonateSigner, mintEth } = require("../../utils/index.js");
const { setBalanceAtSlot } = require("../../utils/tokenSlots.js");
const readline = require("readline-sync");

async function addLiquidityAndTransfer(
  account,
  wellAddress,
  receiver,
  amounts,
  verbose = true,
  deposit
) {
  await mintEth(account.address);
  const pinto = await ethers.getContractAt("BeanstalkERC20", PINTO);

  console.log(`-----------------------------------`);
  const well = await ethers.getContractAt("IWell", wellAddress, account);
  const wellTokens = await well.tokens();
  // tokens[0] is pinto, tokens[1] is nonPinto
  let nonPintoToken = await ethers.getContractAt("MockToken", wellTokens[1]);
  const tokenDecimals = await nonPintoToken.decimals();
  console.log(`Non pintoken decimals: ${tokenDecimals}`);
  console.log(`Minting tokens for ${wellAddress}`);

  // mint non pinto token
  let nonPintoAmount = toX(amounts[1], tokenDecimals);
  // manipulate balance slot
  if (verbose) console.log("Minting nonPinto token by manipulating the balance slot");
  const slot = addressToBalanceSlotMap[wellTokens[1]];
  await setBalanceAtSlot(wellTokens[1], account.address, slot, nonPintoAmount, verbose);
  // log balance of account
  const balance = await nonPintoToken.balanceOf(account.address);
  if (verbose) console.log(`Balance of ${account.address} for token ${wellTokens[1]}: ${balance}`);

  // mint pinto
  console.log("Minting PINTO token");
  const pintoMinter = await impersonateSigner(L2_PINTO);
  await mintEth(pintoMinter.address);
  // parse amount according to decimals. pinto has 6 decimals
  const pintoAmount = to6(amounts[0]);
  await pinto.connect(pintoMinter).mint(account.address, pintoAmount);

  // approve tokens for well
  console.log(`Approving tokens for ${wellAddress}`);
  // log balance of account
  const tokenName = addressToNameMap[wellTokens[1]];
  console.log(`Token name: ${tokenName}`);
  // approve tokens for well
  await nonPintoToken.connect(account).approve(well.address, MAX_UINT256);
  await pinto.connect(account).approve(well.address, MAX_UINT256);
  console.log("done done");

  // add liquidity to well, send to receiver:
  console.log(`Adding liquidity to ${well.address} and performing an update to the well pump.`);
  console.log(`Pinto amount: ${pintoAmount}`, `Non pinto amount: ${nonPintoAmount}`);
  const minAmount = 0;
  await well
    .connect(account)
    .addLiquidity([pintoAmount, nonPintoAmount], minAmount, receiver, MAX_UINT256);
  if (verbose) console.log("Liquidity added");
  // perform a sync to update the well pump:
  await well.connect(account).sync(receiver, 0);
  if (verbose) console.log("Well pump updated");

  // log reserves
  const reserves = await well.getReserves();
  const formattedPintoReserve = ethers.utils.formatUnits(reserves[0], 6);
  const formattedNonPintoReserve = ethers.utils.formatUnits(reserves[1], tokenDecimals);
  console.log(
    `New well reserves: ${formattedPintoReserve} PINTO, ${formattedNonPintoReserve} ${tokenName}`
  );
  console.log(`-----------------------------------`);
  if (deposit) {
    const receiverSigner = await impersonateSigner(receiver);
    console.log("Depositing the LP tokens in the Silo...");
    const silo = await ethers.getContractAt("SiloFacet", L2_PINTO);
    const wellLPToken = await ethers.getContractAt("IERC20", wellAddress);
    await wellLPToken.connect(receiverSigner).approve(silo.address, MAX_UINT256);
    await silo
      .connect(receiverSigner)
      .deposit(wellLPToken.address, await wellLPToken.balanceOf(receiver), 0, {
        gasLimit: 10000000
      });
    console.log("LP tokens deposited");
  }
}

async function addInitialLiquidityAndDeposit(
  account,
  wellAddress,
  usdAmount,
  skipInitialAmountPrompts,
  mock = false
) {
  console.log(`-----------------------------------`);
  console.log(`Adding initial liquidity of ${usdAmount} USD to well...`);
  if (mock) account = await impersonateSigner(PINTO_DIAMOND_DEPLOYER);

  const well = await ethers.getContractAt("IWell", wellAddress, account);
  const wellLPToken = await await ethers.getContractAt("IERC20", wellAddress);
  const nonPintoToken = await ethers.getContractAt(
    "MockToken",
    wellToNonPintoTokenMap[wellAddress]
  );
  const pinto = await ethers.getContractAt("BeanstalkERC20", PINTO);

  // Calculate 100 USD of the NonPinto token
  const oracle = await ethers.getContractAt(
    "IChainlinkAggregator",
    wellToChainlinkOracleMap[wellAddress]
  );
  const chainlinkDecimals = await oracle.decimals();
  const nonPintoPrice = (await oracle.latestRoundData()).answer;
  const nonPintoDecimals = await nonPintoToken.decimals();
  const nonPintoName = addressToNameMap[nonPintoToken.address];
  console.log(
    `${nonPintoName} price: ${ethers.utils.formatUnits(nonPintoPrice, chainlinkDecimals)}`
  );

  // Calculate the amount of nonPintos.
  const nonPintoAmount = ethers.BigNumber.from(usdAmount)
    .mul(ethers.BigNumber.from("10").pow(chainlinkDecimals + nonPintoDecimals))
    .div(nonPintoPrice);
  console.log(
    `Calculated ${nonPintoName} amount to deposit: ${ethers.utils.formatUnits(nonPintoAmount, nonPintoDecimals)} ${nonPintoName} (${nonPintoAmount})`
  );

  // if mock, mint the nonPinto token
  if (mock) {
    console.log(
      `Minting ${ethers.utils.formatUnits(nonPintoAmount, nonPintoDecimals)} ${nonPintoName}`
    );
    await setBalanceAtSlot(
      nonPintoToken.address,
      account.address,
      addressToBalanceSlotMap[nonPintoToken.address],
      nonPintoAmount,
      false
    );
  }

  const pintoAmount = ethers.BigNumber.from(usdAmount).mul(ethers.BigNumber.from("10").pow(6));
  const lpAmountCalculated = await well.getAddLiquidityOut([pintoAmount, nonPintoAmount]);
  console.log(`Calculated LP tokens to receive: ${lpAmountCalculated}`);

  console.log(
    `Do you want to deposit ${ethers.utils.formatUnits(nonPintoAmount, nonPintoDecimals)} ${nonPintoName} to get LP tokens?`
  );
  if (!skipInitialAmountPrompts) {
    let response = readline.question("Type 'y' to continue: ");
    if (response !== "y") {
      console.log("Exiting...");
      return;
    }
  } else {
    console.log("> yes, skipping initial amount prompts...");
  }

  console.log(`Approving ${nonPintoName} and PINTO for well...`);
  await nonPintoToken.connect(account).approve(well.address, MAX_UINT256);
  await pinto.connect(account).approve(well.address, MAX_UINT256);
  console.log(`Approvals done.`);
  console.log(`Adding liquidity to the well...`);
  await well
    .connect(account)
    .addLiquidity([pintoAmount, nonPintoAmount], 0, account.address, MAX_UINT256);
  const lpAmount = await wellLPToken.balanceOf(account.address);
  console.log(`Initial liquidity added. LP Amount received: ${lpAmount}`);
  console.log(`Performing an update to the well pump.`);
  await well.connect(account).sync(account.address, 0);
  console.log("Well pump updated");
  console.log(`-----------------------------------`);
  console.log("Depositing initial liquidity in the Silo...");
  const silo = await ethers.getContractAt("SiloFacet", L2_PINTO);
  await wellLPToken.connect(account).approve(silo.address, MAX_UINT256);
  await silo
    .connect(account)
    .deposit(wellLPToken.address, lpAmountCalculated, 0, { gasLimit: 10000000 });
  console.log("Initial liquidity deposited");
  console.log(`-----------------------------------`);
  console.log("Transferring deposit to the 5% reserves multisig...");
  const stem = 0;
  await silo
    .connect(account)
    .transferDeposit(
      account.address,
      RESERVES_5_PERCENT_MULTISIG,
      wellLPToken.address,
      stem,
      lpAmountCalculated
    );
  console.log(`-----------------------------------`);
  console.log("Done!");
}

exports.addLiquidityAndTransfer = addLiquidityAndTransfer;
exports.addInitialLiquidityAndDeposit = addInitialLiquidityAndDeposit;

const { expect } = require("chai");
const { deploy } = require("../../scripts/deploy.js");
const { to18, to6, advanceTime } = require("./utils/helpers.js");
const { BEAN, BEAN_ETH_WELL, BEAN_WSTETH_WELL, WETH, WSTETH } = require("./utils/constants.js");
const { takeSnapshot, revertToSnapshot } = require("./utils/snapshot.js");
const {
  setReserves,
  impersonateBeanWstethWell,
  impersonateBeanEthWell
} = require("../../utils/well.js");
const { setEthUsdChainlinkPrice, setStethEthChainlinkPrice } = require("../../utils/oracle.js");
const { getAllBeanstalkContracts } = require("../../utils/contracts");
const { initWhitelistOracles } = require("../../scripts/deploy.js");

let user, owner;

// temporary skip until tractor has merged into this branch.
describe.skip("BeanstalkPrice", function () {
  before(async function () {
    [owner, user] = await ethers.getSigners();
    const contracts = await deploy((verbose = false), (mock = true), (reset = true));
    ownerAddress = contracts.account;
    this.diamond = contracts.beanstalkDiamond;
    // `beanstalk` contains all functions that the regular beanstalk has.
    // `mockBeanstalk` has functions that are only available in the mockFacets.
    [beanstalk, mockBeanstalk] = await getAllBeanstalkContracts(this.diamond.address);

    await impersonateBeanEthWell();
    await impersonateBeanWstethWell();
    this.beanEthWell = await ethers.getContractAt("IWell", BEAN_ETH_WELL);
    this.beanWstethWell = await ethers.getContractAt("IWell", BEAN_WSTETH_WELL);
    this.wellToken = await ethers.getContractAt("IERC20", BEAN_ETH_WELL);
    bean = await ethers.getContractAt("MockToken", BEAN);
    await bean.mint(user.address, to6("10000000000"));
    await bean.mint(ownerAddress, to6("1000000000"));
    await this.wellToken.connect(owner).approve(beanstalk.address, ethers.constants.MaxUint256);
    await bean.connect(owner).approve(beanstalk.address, ethers.constants.MaxUint256);
    // set reserves of bean eth and bean wsteth wells.
    await setReserves(owner, this.beanEthWell, [to6("1000000"), to18("1000")]);
    await setReserves(owner, this.beanWstethWell, [to6("1000000"), to18("1000")]);
    await setEthUsdChainlinkPrice("1000");
    await setStethEthChainlinkPrice("1");

    const BeanstalkPrice = await ethers.getContractFactory("BeanstalkPrice");
    const _beanstalkPrice = await BeanstalkPrice.deploy(beanstalk.address);
    await _beanstalkPrice.deployed();
    this.beanstalkPrice = await ethers.getContractAt("BeanstalkPrice", _beanstalkPrice.address);

    // setup whitelist config
    await initWhitelistOracles();
  });

  beforeEach(async function () {
    snapshotId = await takeSnapshot();
  });

  afterEach(async function () {
    await revertToSnapshot(snapshotId);
  });

  describe("Price", async function () {
    it("deltaB = 0", async function () {
      const p = await this.beanstalkPrice.price();
      // price is within +/- 1 due to rounding
      expect(p.price).to.equal("999999");
      expect(p.liquidity).to.equal("3999998000000");
      expect(p.deltaB).to.be.eq("0");
    });

    it("deltaB > 0, wells only", async function () {
      await advanceTime(1800);
      await setReserves(owner, this.beanEthWell, [to6("500000"), to18("1000")]);
      await advanceTime(1800);
      await user.sendTransaction({
        to: beanstalk.address,
        value: 0
      });

      const p = await this.beanstalkPrice.price();
      const w = await this.beanstalkPrice.getWell(BEAN_ETH_WELL);

      expect(p.price).to.equal("1499997");
      expect(p.liquidity).to.equal("3999997000000");
      expect(p.deltaB).to.equal("207106781186");

      expect(w.price).to.equal("1999996");
      expect(w.liquidity).to.equal("1999998000000");
      expect(w.deltaB).to.equal("207106781186");
    });

    it("deltaB < 0, wells only", async function () {
      await advanceTime(1800);
      await setReserves(owner, this.beanEthWell, [to6("2000000"), to18("1000")]);
      await advanceTime(1800);
      await user.sendTransaction({
        to: beanstalk.address,
        value: 0
      });

      const p = await this.beanstalkPrice.price();
      const w = await this.beanstalkPrice.getWell(BEAN_ETH_WELL);

      expect(p.price).to.equal("749999");
      expect(p.liquidity).to.equal("3999997000000");
      expect(p.deltaB).to.equal("-585786437627");

      expect(w.price).to.equal("499999");
      expect(w.liquidity).to.equal("1999998000000");
      expect(w.deltaB).to.equal("-585786437627");
    });

    it("getBestWellForUsdIn", async function () {
      // get the best well for swapping 1000 USD.
      let usdOut_sd = await this.beanstalkPrice.getBestWellForUsdIn(to6("1000"));
      assertSwapData(usdOut_sd, BEAN_ETH_WELL, WETH, to6("1000"), to6("999.000999"));

      // increase the bean reserve of the bean wsteth well.
      await setReserves(owner, this.beanWstethWell, [to6("2000000"), to18("1000")]);

      // get the best well for swapping 1000 USD.
      usdOut_sd = await this.beanstalkPrice.getBestWellForUsdIn(to6("1000"));

      // verify that the best well is now the bean wsteth well.
      assertSwapData(usdOut_sd, BEAN_WSTETH_WELL, WSTETH, to6("1000"), to6("1998.001998"));

      // revert the reserve of the bean wsteth well.
      await setReserves(owner, this.beanWstethWell, [to6("1000000"), to18("1000")]);

      // decrease the price of wsteth.
      await setStethEthChainlinkPrice("0.75");

      // get the best well for swapping 1000 USD.
      usdOut_sd = await this.beanstalkPrice.getBestWellForUsdIn(to6("1000"));

      // verify that the best well is the bean wsteth well.
      assertSwapData(usdOut_sd, BEAN_WSTETH_WELL, WSTETH, to6("1000"), to6("1331.557922"));
    });

    it("getBestWellForBeanIn", async function () {
      // get the best well for swapping 1000 Beans.
      let beanOut_sd = await this.beanstalkPrice.getBestWellForBeanIn(to6("1000"));

      assertSwapData(
        beanOut_sd,
        BEAN_ETH_WELL,
        WETH,
        to6("999.000999"),
        to18("0.999000999000999001")
      );

      // increase the wsteth reserve of the bean wsteth well.
      await setReserves(owner, this.beanWstethWell, [to6("1000000"), to18("2000")]);

      // get the best well for swapping 1000 Beans.
      beanOut_sd = await this.beanstalkPrice.getBestWellForBeanIn(to6("1000"));

      // verify that the best well is now the bean wsteth well.
      assertSwapData(
        beanOut_sd,
        BEAN_WSTETH_WELL,
        WSTETH,
        to6("1998.001998"),
        to18("1.998001998001998002")
      );

      // revert the reserve of the bean wsteth well.
      await setReserves(owner, this.beanWstethWell, [to6("1000000"), to18("1000")]);

      // increase the price of wsteth.
      await setStethEthChainlinkPrice("1.5");

      // get the best well for swapping 1000 Beans.
      beanOut_sd = await this.beanstalkPrice.getBestWellForBeanIn(to6("1000"));

      // verify that the best well is the bean wsteth well.
      assertSwapData(
        beanOut_sd,
        BEAN_WSTETH_WELL,
        WSTETH,
        to6("1498.501498"),
        to18("0.999000999000999001")
      );
    });

    it("all wells", async function () {
      let amountOut_sds = await this.beanstalkPrice.getSwapDataBeanInAll(to6("1000"));
      let beanOut_sds = await this.beanstalkPrice.getSwapDataUsdInAll(to6("1000"));

      assertSwapData(
        amountOut_sds[0],
        BEAN_ETH_WELL,
        WETH,
        to6("999.000999"),
        to18("0.999000999000999001")
      );
      assertSwapData(
        amountOut_sds[1],
        BEAN_WSTETH_WELL,
        WSTETH,
        to6("999.000999"),
        to18("0.999000999000999001")
      );

      assertSwapData(beanOut_sds[0], BEAN_ETH_WELL, WETH, to6("1000"), to6("999.000999"));
      assertSwapData(beanOut_sds[1], BEAN_WSTETH_WELL, WSTETH, to6("1000"), to6("999.000999"));

      // increase the wsteth reserve of the bean wsteth well.
      await setReserves(owner, this.beanWstethWell, [to6("1000000"), to18("2000")]);

      amountOut_sds = await this.beanstalkPrice.getSwapDataBeanInAll(to6("1000"));
      beanOut_sds = await this.beanstalkPrice.getSwapDataUsdInAll(to6("1000"));
      let bestAmountOut_sd = await this.beanstalkPrice.getBestWellForBeanIn(to6("1000"));
      let bestBeanOut_sd = await this.beanstalkPrice.getBestWellForUsdIn(to6("1000"));

      assertSwapData(
        amountOut_sds[0],
        BEAN_ETH_WELL,
        WETH,
        to6("999.000999"),
        to18("0.999000999000999001")
      );
      assertSwapData(
        amountOut_sds[1],
        BEAN_WSTETH_WELL,
        WSTETH,
        to6("1998.001998"),
        to18("1.998001998001998002")
      );
      assertSwapData(
        bestAmountOut_sd,
        amountOut_sds[1].well,
        amountOut_sds[1].token,
        amountOut_sds[1].usdValue,
        amountOut_sds[1].amountOut
      );

      assertSwapData(beanOut_sds[0], BEAN_ETH_WELL, WETH, to6("1000"), to6("999.000999"));
      assertSwapData(beanOut_sds[1], BEAN_WSTETH_WELL, WSTETH, to6("1000"), to6("499.750124"));
      assertSwapData(
        bestBeanOut_sd,
        beanOut_sds[0].well,
        beanOut_sds[0].token,
        beanOut_sds[0].usdValue,
        beanOut_sds[0].amountOut
      );

      // revert the reserve of the bean wsteth well, decrease the price of wsteth.
      await setReserves(owner, this.beanWstethWell, [to6("1000000"), to18("1000")]);
      await setStethEthChainlinkPrice("0.75");

      amountOut_sds = await this.beanstalkPrice.getSwapDataBeanInAll(to6("1000"));
      beanOut_sds = await this.beanstalkPrice.getSwapDataUsdInAll(to6("1000"));
      bestAmountOut_sd = await this.beanstalkPrice.getBestWellForBeanIn(to6("1000"));
      bestBeanOut_sd = await this.beanstalkPrice.getBestWellForUsdIn(to6("1000"));

      assertSwapData(
        amountOut_sds[0],
        BEAN_ETH_WELL,
        WETH,
        to6("999.000999"),
        to18("0.999000999000999001")
      );
      assertSwapData(
        amountOut_sds[1],
        BEAN_WSTETH_WELL,
        WSTETH,
        to6("749.250749"),
        to18("0.999000999000999001")
      );

      // to get the most amount out, we want to swap in beans to the bean eth well.
      assertSwapData(
        bestAmountOut_sd,
        amountOut_sds[0].well,
        amountOut_sds[0].token,
        amountOut_sds[0].usdValue,
        amountOut_sds[0].amountOut
      );

      // to get the most beans out, we want to swap in USD to the bean wsteth well.
      assertSwapData(beanOut_sds[0], BEAN_ETH_WELL, WETH, to6("1000"), to6("999.000999"));
      assertSwapData(beanOut_sds[1], BEAN_WSTETH_WELL, WSTETH, to6("1000"), to6("1331.557922"));
      assertSwapData(
        bestBeanOut_sd,
        beanOut_sds[1].well,
        beanOut_sds[1].token,
        beanOut_sds[1].usdValue,
        beanOut_sds[1].amountOut
      );
    });
  });

  function assertSwapData(sd, well, token, usdValue, amountOut) {
    expect(sd.well).to.equal(well);
    expect(sd.token).to.equal(token);
    expect(sd.usdValue).to.equal(usdValue);
    expect(sd.amountOut).to.equal(amountOut);
  }
});

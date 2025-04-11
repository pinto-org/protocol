const { expect } = require("chai");
const { deploy } = require("../../scripts/deploy.js");
const {
  setEthUsdChainlinkPrice,
  setStethEthChainlinkPrice,
  setWstethEthUniswapPrice
} = require("../../utils/oracle.js");
const { getBean, getAllBeanstalkContracts } = require("../../utils/contracts");
const {
  initContracts,
  signRequisition,
  draftDepositInternalBeanBalance,
  draftMow,
  draftPlant,
  draftConvert,
  draftDepositInternalBeansWithLimit,
  RATIO_FACTOR,
  ConvertKind
} = require("./utils/tractor.js");

const {
  setReserves,
  impersonateBeanWstethWell,
  impersonateBeanEthWell,
  deployMockPump
} = require("../../utils/well.js");
const { initWhitelistOracles } = require("../../scripts/deploy.js");

const { BEAN, BEAN_ETH_WELL, WETH, BEAN_WSTETH_WELL } = require("./utils/constants.js");

const { EXTERNAL } = require("./utils/balances.js");
const { to6, to18, toStalk } = require("./utils/helpers.js");
const { takeSnapshot, revertToSnapshot } = require("./utils/snapshot");
const { ethers } = require("hardhat");
const { time, mine } = require("@nomicfoundation/hardhat-network-helpers");

let publisher, operator, user;
let advancedFarmCalls;

describe("Tractor", function () {
  before(async function (verbose = false) {
    [owner, publisher, operator, user] = await ethers.getSigners();

    if (verbose) {
      console.log("publisher", publisher.address);
      console.log("operator", operator.address);
    }

    const contracts = await deploy((verbose = false), (mock = true), (reset = true));
    this.diamond = contracts.beanstalkDiamond;
    [beanstalk, mockBeanstalk] = await getAllBeanstalkContracts(this.diamond.address);
    bean = await getBean();
    this.tractorFacet = await ethers.getContractAt("TractorFacet", this.diamond.address);
    this.farmFacet = await ethers.getContractAt("FarmFacet", this.diamond.address);
    this.seasonFacet = await ethers.getContractAt("MockSeasonFacet", this.diamond.address);
    this.siloFacet = await ethers.getContractAt("MockSiloFacet", this.diamond.address);
    this.siloGettersFacet = await ethers.getContractAt("SiloGettersFacet", this.diamond.address);
    this.tokenFacet = await ethers.getContractAt("TokenFacet", this.diamond.address);

    await initContracts();

    this.weth = await ethers.getContractAt("MockToken", WETH);

    this.well = await ethers.getContractAt("IWell", BEAN_ETH_WELL);

    this.wellToken = await ethers.getContractAt("IERC20", BEAN_ETH_WELL);

    await this.wellToken.connect(owner).approve(this.diamond.address, ethers.constants.MaxUint256);
    await bean.connect(owner).approve(this.diamond.address, ethers.constants.MaxUint256);

    await setEthUsdChainlinkPrice("999.998018");

    await bean.mint(owner.address, to6("10000000000"));
    await this.weth.mint(owner.address, to18("1000000000"));
    await bean.mint(publisher.address, to6("20000"));

    await bean.connect(publisher).approve(this.diamond.address, ethers.constants.MaxUint256);
    await this.weth.connect(publisher).approve(this.diamond.address, ethers.constants.MaxUint256);
    await this.wellToken
      .connect(publisher)
      .approve(this.diamond.address, ethers.constants.MaxUint256);

    await bean.connect(owner).approve(this.well.address, ethers.constants.MaxUint256);
    await this.weth.connect(owner).approve(this.well.address, ethers.constants.MaxUint256);
    await bean.connect(publisher).approve(this.well.address, ethers.constants.MaxUint256);
    await this.weth.connect(publisher).approve(this.well.address, ethers.constants.MaxUint256);

    if (verbose) {
      console.log("impersonating beans and weth wells");
    }
    await impersonateBeanEthWell();
    await impersonateBeanWstethWell();
    this.beanEthWell = await ethers.getContractAt("IWell", BEAN_ETH_WELL);
    this.beanWstethWell = await ethers.getContractAt("IWell", BEAN_WSTETH_WELL);
    await setEthUsdChainlinkPrice("1000");
    await setStethEthChainlinkPrice("1");
    await setWstethEthUniswapPrice("1");

    const BeanstalkPrice = await ethers.getContractFactory("BeanstalkPrice");
    const _beanstalkPrice = await BeanstalkPrice.deploy(beanstalk.address);
    await _beanstalkPrice.deployed();
    this.beanstalkPrice = await ethers.getContractAt("BeanstalkPrice", _beanstalkPrice.address);

    // setup whitelist config
    await initWhitelistOracles();

    await deployMockPump();
    await setReserves(owner, this.beanEthWell, [to6("1000000"), to18("1000")]);
    await setReserves(owner, this.beanWstethWell, [to6("1000000"), to18("1000")]);

    // P > 1.
    await this.well
      .connect(owner)
      .addLiquidity([to6("1000000"), to18("2000")], 0, owner.address, ethers.constants.MaxUint256);
    this.blueprint = {
      publisher: publisher.address,
      data: ethers.utils.hexlify("0x"),
      operatorPasteInstrs: [],
      maxNonce: 100,
      startTime: Math.floor(Date.now() / 1000) - 10 * 3600,
      endTime: Math.floor(Date.now() / 1000) + 10 * 3600
    };

    this.requisition = {
      blueprint: this.blueprint,
      blueprintHash: await this.tractorFacet.connect(publisher).getBlueprintHash(this.blueprint)
    };
    await signRequisition(this.requisition, publisher);
    if (verbose) {
      console.log(this.requisition);
    }
  });

  beforeEach(async function () {
    snapshotId = await takeSnapshot();
  });

  afterEach(async function () {
    await revertToSnapshot(snapshotId);
  });

  describe("Publish Blueprint", function () {
    it("should fail when signature is invalid #1", async function () {
      this.requisition.signature = "0x0000";
      await expect(
        this.tractorFacet.connect(publisher).publishRequisition(this.requisition)
      ).to.be.revertedWith("ECDSAInvalidSignatureLength");
    });

    it("should fail when signature is invalid #2", async function () {
      this.requisition.signature =
        "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
      await expect(
        this.tractorFacet.connect(publisher).publishRequisition(this.requisition)
      ).to.be.revertedWith("ECDSAInvalidSignature");
    });

    it("should fail when signature is invalid #3", async function () {
      await signRequisition(this.requisition, user);
      await expect(
        this.tractorFacet.connect(publisher).publishRequisition(this.requisition)
      ).to.be.revertedWith("TractorFacet: signer mismatch");
    });

    it("should publish blueprint", async function () {
      await signRequisition(this.requisition, publisher);
      await this.tractorFacet.connect(publisher).publishRequisition(this.requisition);
    });
  });

  describe("Cancel Requisition", function () {
    it("should fail when signature is invalid #1", async function () {
      this.requisition.signature = "0x0000";
      await expect(
        this.tractorFacet.connect(publisher).cancelBlueprint(this.requisition)
      ).to.be.revertedWith("ECDSAInvalidSignatureLength");
    });

    it("should fail when signature is invalid #2", async function () {
      this.requisition.signature =
        "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
      await expect(
        this.tractorFacet.connect(publisher).cancelBlueprint(this.requisition)
      ).to.be.revertedWith("ECDSAInvalidSignature");
    });

    it("should fail when signature is invalid #3", async function () {
      await signRequisition(this.requisition, publisher);
      await expect(
        this.tractorFacet.connect(user).cancelBlueprint(this.requisition)
      ).to.be.revertedWith("TractorFacet: not publisher");
    });

    it("should cancel Requisition", async function () {
      await signRequisition(this.requisition, publisher);
      const tx = await this.tractorFacet.connect(publisher).cancelBlueprint(this.requisition);

      await expect(tx)
        .to.emit(this.tractorFacet, "CancelBlueprint")
        .withArgs(this.requisition.blueprintHash);

      const nonce = await this.tractorFacet.getBlueprintNonce(this.requisition.blueprintHash);
      expect(nonce).to.be.eq(ethers.constants.MaxUint256);
    });

    it("should revert when trying to publish a cancelled requisition", async function () {
      await signRequisition(this.requisition, publisher);
      await this.tractorFacet.connect(publisher).cancelBlueprint(this.requisition);

      await expect(
        this.tractorFacet.connect(publisher).publishRequisition(this.requisition)
      ).to.be.revertedWith("TractorFacet: maxNonce reached");
    });
  });

  describe("Run Tractor", function () {
    it("Deposit Publisher Internal Beans", async function () {
      [advancedFarmCalls, this.blueprint.operatorPasteInstrs] =
        await draftDepositInternalBeanBalance(to6("10"));
      this.blueprint.data = this.farmFacet.interface.encodeFunctionData("advancedFarm", [
        advancedFarmCalls
      ]);
      this.requisition.blueprintHash = await this.tractorFacet
        .connect(publisher)
        .getBlueprintHash(this.blueprint);
      await signRequisition(this.requisition, publisher);

      // Transfer Bean to internal balance.
      mockBeanstalk
        .connect(publisher)
        .transferToken(bean.address, publisher.address, to6("1000"), 0, 1);
      expect(await this.tokenFacet.getInternalBalance(publisher.address, bean.address)).to.be.eq(
        to6("1000")
      );

      await this.tractorFacet.connect(publisher).publishRequisition(this.requisition);

      // No operator calldata used.
      operatorData = ethers.utils.hexlify("0x");
      await this.tractorFacet.connect(operator).tractor(this.requisition, operatorData);

      // Confirm final state.
      expect(await this.tokenFacet.getInternalBalance(publisher.address, bean.address)).to.be.eq(
        to6("0")
      );
      expect(await bean.balanceOf(operator.address)).to.be.eq(to6("10"));
    });

    it("Deposit with Counter Limit", async function () {
      [advancedFarmCalls, this.blueprint.operatorPasteInstrs] =
        await draftDepositInternalBeansWithLimit(to6("1000"));
      this.blueprint.data = this.farmFacet.interface.encodeFunctionData("advancedFarm", [
        advancedFarmCalls
      ]);
      this.requisition.blueprintHash = await this.tractorFacet
        .connect(publisher)
        .getBlueprintHash(this.blueprint);
      await signRequisition(this.requisition, publisher);

      // Transfer Bean to internal balance.
      mockBeanstalk
        .connect(publisher)
        .transferToken(bean.address, publisher.address, to6("2000"), 0, 1);
      expect(await this.tokenFacet.getInternalBalance(publisher.address, bean.address)).to.be.eq(
        to6("2000")
      );

      await this.tractorFacet.connect(publisher).publishRequisition(this.requisition);

      // No operator calldata used.
      const operatorData = ethers.utils.hexlify("0x");

      for (let i = 0; i < 9; i++) {
        await this.tractorFacet.connect(operator).tractor(this.requisition, operatorData);
      }

      // Confirm final state.
      expect(
        this.tractorFacet.connect(operator).tractor(this.requisition, operatorData)
      ).to.be.revertedWith("Junction: check failed");
      expect(await this.tokenFacet.getInternalBalance(publisher.address, bean.address)).to.be.eq(
        to6("1000")
      );
    });

    it("Mow publisher", async function (verbose = false) {
      // Give publisher Grown Stalk.
      this.result = await this.siloFacet
        .connect(publisher)
        .deposit(bean.address, to6("10000"), EXTERNAL);
      await this.seasonFacet.siloSunrise(to6("0"));
      await time.increase(3600); // wait until end of season to get earned
      await mine(25);
      expect(
        await this.siloGettersFacet.balanceOfGrownStalk(publisher.address, bean.address)
      ).to.eq(toStalk("2"));

      // Capture init state.
      const initPublisherStalk = await this.siloGettersFacet.balanceOfStalk(publisher.address);
      const initPublisherBeans = await bean.balanceOf(publisher.address);
      const initOperatorBeans = await bean.balanceOf(operator.address);

      // Tip operator 50% of Stalk change in Beans. Factor in decimal difference of Stalk and Bean.
      const tipRatio = ethers.BigNumber.from(1)
        .mul(RATIO_FACTOR)
        .div(2)
        .mul(ethers.BigNumber.from(10).pow(6))
        .div(ethers.BigNumber.from(10).pow(10));
      [advancedFarmCalls, this.blueprint.operatorPasteInstrs] = await draftMow(tipRatio);
      this.blueprint.data = this.farmFacet.interface.encodeFunctionData("advancedFarm", [
        advancedFarmCalls
      ]);
      this.requisition.blueprintHash = await this.tractorFacet
        .connect(publisher)
        .getBlueprintHash(this.blueprint);
      await signRequisition(this.requisition, publisher);

      await this.tractorFacet.connect(publisher).publishRequisition(this.requisition);

      // Operator data matches shape expected by blueprint. Each item is in a 32 byte slot.
      let operatorData = ethers.utils.defaultAbiCoder.encode(
        ["address"], // token
        [BEAN]
      );

      await this.tractorFacet.connect(operator).tractor(this.requisition, operatorData);

      // Confirm final state.
      const publisherStalkGain =
        (await this.siloGettersFacet.balanceOfStalk(publisher.address)) - initPublisherStalk;
      const operatorPaid = (await bean.balanceOf(operator.address)) - initOperatorBeans;
      if (verbose) {
        console.log(
          "Publisher Stalk increase: " + ethers.utils.formatUnits(publisherStalkGain, 10)
        );
        console.log("Operator Payout: " + ethers.utils.formatUnits(operatorPaid, 6) + " Beans");
      }

      expect(
        await this.siloGettersFacet.balanceOfGrownStalk(publisher.address, bean.address),
        "publisher Grown Stalk did not decrease"
      ).to.eq(toStalk("0"));
      expect(publisherStalkGain, "publisher Stalk did not increase").to.be.gt(0);
      expect(await bean.balanceOf(publisher.address), "publisher did not pay").to.be.lt(
        initPublisherBeans
      );
      expect(operatorPaid, "unpaid operator").to.be.gt(0);
    });

    it("Plant publisher", async function (verbose = false) {
      // Give publisher Earned Beans.
      this.result = await this.siloFacet
        .connect(publisher)
        .deposit(bean.address, to6("10000"), EXTERNAL);
      await this.seasonFacet.siloSunrise(to6("1000"));
      await time.increase(3600);
      await mine(25);
      await this.seasonFacet.siloSunrise(to6("1000"));
      expect(await this.siloGettersFacet.balanceOfEarnedBeans(publisher.address)).to.gt(0);

      // Capture init state.
      const initPublisherStalkBalance = await this.siloGettersFacet.balanceOfStalk(
        publisher.address
      );
      const initPublisherBeans = await bean.balanceOf(publisher.address);
      const initOperatorBeans = await bean.balanceOf(operator.address);

      // Tip operator 50% of Bean change in Beans.
      const tipRatio = ethers.BigNumber.from(1).mul(RATIO_FACTOR).div(2);
      [advancedFarmCalls, this.blueprint.operatorPasteInstrs] = await draftPlant(tipRatio);
      this.blueprint.data = this.farmFacet.interface.encodeFunctionData("advancedFarm", [
        advancedFarmCalls
      ]);
      this.requisition.blueprintHash = await this.tractorFacet
        .connect(publisher)
        .getBlueprintHash(this.blueprint);
      await signRequisition(this.requisition, publisher);

      await this.tractorFacet.connect(publisher).publishRequisition(this.requisition);

      // Operator data matches shape expected by blueprint. Each item is in a 32 byte slot.
      let operatorData = ethers.utils.hexlify("0x000000");

      await this.tractorFacet.connect(operator).tractor(this.requisition, operatorData);

      // Confirm final state.
      expect(
        await this.siloGettersFacet.balanceOfEarnedBeans(publisher.address),
        "publisher Earned Bean did not go to 0"
      ).to.eq(0);

      const publisherStalkGain =
        (await this.siloGettersFacet.balanceOfStalk(publisher.address)) - initPublisherStalkBalance;
      const operatorPaid = (await bean.balanceOf(operator.address)) - initOperatorBeans;
      if (verbose) {
        console.log(
          "Publisher Stalk increase: " + ethers.utils.formatUnits(publisherStalkGain, 10)
        );
        console.log("Operator Payout: " + ethers.utils.formatUnits(operatorPaid, 6) + " Beans");
      }

      expect(publisherStalkGain, "publisher stalk balance did not increase").to.be.gt(0);
      expect(await bean.balanceOf(publisher.address), "publisher did not pay").to.be.lt(
        initPublisherBeans
      );
      expect(operatorPaid, "unpaid operator").to.be.gt(0);
    });
  });

  describe("Bi-directional convert of publisher", async function () {
    // Prepare Beanstalk
    beforeEach(async function () {
      await this.siloFacet.connect(publisher).deposit(bean.address, to6("2000"), EXTERNAL);
      await this.seasonFacet.siloSunrise(0);
      await this.seasonFacet.siloSunrise(0);
      await this.seasonFacet.siloSunrise(0);
      await this.seasonFacet.siloSunrise(0);
    });

    beforeEach(async function () {
      // Transfer Bean to publisher internal balance.
      await mockBeanstalk
        .connect(publisher)
        .transferToken(bean.address, publisher.address, to6("100"), 0, 1);
    });
    // Confirm initial state.
    beforeEach(async function () {
      expect(
        await this.siloGettersFacet.getTotalDeposited(bean.address),
        "initial totalDeposited Bean"
      ).to.eq(to6("2000"));
      expect(
        await this.siloGettersFacet.getTotalDepositedBdv(bean.address),
        "initial totalDepositedBDV Bean"
      ).to.eq(to6("2000"));
      expect(
        await this.siloGettersFacet.getTotalDeposited(this.well.address),
        "initial totalDeposited LP"
      ).to.eq("0");
      expect(
        await this.siloGettersFacet.getTotalDepositedBdv(this.well.address),
        "initial totalDepositedBDV LP"
      ).to.eq("0");
      expect(await this.siloGettersFacet.totalStalk(), "initial totalStalk").to.gt("0");
      expect(
        await this.siloGettersFacet.balanceOfStalk(publisher.address),
        "initial publisher balanceOfStalk"
      ).to.eq(toStalk("2000"));

      let deposit = await this.siloGettersFacet.getDeposit(publisher.address, bean.address, 0);
      expect(deposit[0], "initial publisher bean deposit amount").to.eq(to6("2000"));
      expect(deposit[1], "initial publisher bean deposit BDV").to.eq(to6("2000"));
      deposit = await this.siloGettersFacet.getDeposit(publisher.address, this.well.address, 0);
      expect(deposit[0], "initial publisher lp deposit amount").to.eq("0");
      expect(deposit[1], "initial publisher lp deposit BDV").to.eq("0");

      //  This is the stem that results from conversions. Stem manually retrieved from logs.
      this.BeanToLpDepositStem = 8000000;
      this.BeanToLpToBeanDepositStem = 2939304;
    });

    afterEach(async function () {
      await revertToSnapshot(snapshotId);
    });

    it("Generalized convert", async function () {
      [advancedFarmCalls, this.blueprint.operatorPasteInstrs] = await draftConvert(to6("20"), 0, 0);
      this.blueprint.data = this.farmFacet.interface.encodeFunctionData("advancedFarm", [
        advancedFarmCalls
      ]);
      this.requisition.blueprintHash = await this.tractorFacet
        .connect(publisher)
        .getBlueprintHash(this.blueprint);
      await signRequisition(this.requisition, publisher);
      await this.tractorFacet.connect(publisher).publishRequisition(this.requisition);

      // Operator data matches shape expected by blueprint. Each item is in a 32 byte slot.
      let operatorData = ethers.utils.defaultAbiCoder.encode(
        ["int96", "uint8"], // stem, convertKind
        [0, ConvertKind.BEANS_TO_WELL_LP]
      );
      await this.tractorFacet.connect(operator).tractor(this.requisition, operatorData);

      // Confirm mid state.
      expect(
        await this.siloGettersFacet.getTotalDeposited(bean.address),
        "mid totalDeposited Bean"
      ).to.eq("0");
      expect(
        await this.siloGettersFacet.getTotalDepositedBdv(bean.address),
        "mid totalDepositedBDV Bean"
      ).to.eq("0");
      expect(
        await this.siloGettersFacet.getTotalDeposited(this.well.address),
        "mid totalDeposited LP"
      ).to.gt("1");
      expect(
        await this.siloGettersFacet.getTotalDepositedBdv(this.well.address),
        "mid totalDepositedBDV LP"
      ).to.gt("0");
      expect(await this.siloGettersFacet.totalStalk(), "mid totalStalk").to.gt(toStalk("2000"));
      expect(
        await this.siloGettersFacet.balanceOfStalk(publisher.address),
        "mid publisher balanceOfStalk"
      ).to.gt(toStalk("2000"));
      let deposit = await this.siloGettersFacet.getDeposit(publisher.address, this.well.address, 0);
      expect(deposit[0], "mid publisher Bean deposit amount").to.eq("0");
      expect(deposit[1], "mid publisher Bean deposit BDV").to.eq("0");
      deposit = await this.siloGettersFacet.getDeposit(
        publisher.address,
        this.well.address,
        this.BeanToLpDepositStem
      );
      expect(deposit[0], "mid publisher LP deposit amount").to.gt("1");
      expect(deposit[1], "mid publisher LP deposit BDV").to.gte(to6("2000"));

      // Make P < 1.
      await this.well
        .connect(owner)
        .addLiquidity([to6("3000000"), to18("0")], 0, owner.address, ethers.constants.MaxUint256);

      // Convert in other direction (LP->Bean).
      operatorData = ethers.utils.defaultAbiCoder.encode(
        ["int96", "uint8"], // stem, convertKind
        [this.BeanToLpDepositStem, ConvertKind.WELL_LP_TO_BEANS]
      );
      await this.tractorFacet.connect(operator).tractor(this.requisition, operatorData);

      // Confirm final state.
      expect(
        await this.siloGettersFacet.getTotalDeposited(bean.address),
        "final totalDeposited Bean"
      ).to.gte(to6("2000"));
      expect(
        await this.siloGettersFacet.getTotalDepositedBdv(bean.address),
        "final totalDepositedBDV Bean"
      ).to.gt("2000"); // gt 0
      expect(
        await this.siloGettersFacet.getTotalDeposited(this.well.address),
        "final totalDeposited LP"
      ).to.eq("0");
      expect(
        await this.siloGettersFacet.getTotalDepositedBdv(this.well.address),
        "final totalDepositedBDV LP"
      ).to.eq("0");
      expect(await this.siloGettersFacet.totalStalk(), "final totalStalk").to.gt(toStalk("2000"));
      expect(
        await this.siloGettersFacet.balanceOfStalk(publisher.address),
        "final publisher balanceOfStalk"
      ).to.gt(toStalk("2000"));
      deposit = await this.siloGettersFacet.getDeposit(
        publisher.address,
        bean.address,
        this.BeanToLpToBeanDepositStem
      );
      expect(deposit[0], "final publisher Bean deposit amount").to.gt(to6("2000"));
      expect(deposit[1], "final publisher Bean deposit BDV").to.gt(to6("2000"));
      deposit = await this.siloGettersFacet.getDeposit(publisher.address, this.well.address, 0);
      expect(deposit[0], "final publisher LP deposit amount").to.eq("0");
      expect(deposit[1], "final publisher LP deposit BDV").to.eq("0");
    });
  });
});

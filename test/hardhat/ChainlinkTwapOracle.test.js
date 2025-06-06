const { expect } = require("chai");
const { deploy } = require("../../scripts/deploy.js");
const { getBean } = require("../../utils/contracts.js");
const { takeSnapshot, revertToSnapshot } = require("./utils/snapshot.js");
const { getAllBeanstalkContracts } = require("../../utils/contracts");
const { ETH_USD_CHAINLINK_AGGREGATOR, BEANSTALK, WETH } = require("./utils/constants.js");

let user, owner;

let timestamp;

async function setToSecondsAfterHour(seconds = 0) {
  const lastTimestamp = (await ethers.provider.getBlock("latest")).timestamp;
  const hourTimestamp = parseInt(lastTimestamp / 3600 + 1) * 3600 + seconds;
  await network.provider.send("evm_setNextBlockTimestamp", [hourTimestamp]);
}

describe("TWAP Chainlink Oracle", function () {
  before(async function () {
    [owner, user, user2] = await ethers.getSigners();
    await deploy((verbose = false), (mock = true), (reset = true));

    // `beanstalk` contains all functions that the regular beanstalk has.
    // `mockBeanstalk` has functions that are only available in the mockFacets.
    [beanstalk, mockBeanstalk] = await getAllBeanstalkContracts(BEANSTALK);
    bean = await getBean();
    await setToSecondsAfterHour(0);
    await owner.sendTransaction({ to: user.address, value: 0 });

    ethUsdChainlinkAggregator = await ethers.getContractAt(
      "MockChainlinkAggregator",
      ETH_USD_CHAINLINK_AGGREGATOR
    );

    timestamp = (await ethers.provider.getBlock("latest")).timestamp;
  });

  beforeEach(async function () {
    snapshotId = await takeSnapshot();
  });

  afterEach(async function () {
    await revertToSnapshot(snapshotId);
  });

  it("returns 0 if no rounds", async function () {
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("0");
  });

  it("reverts if timeout", async function () {
    await ethUsdChainlinkAggregator.addRound("0", timestamp - 14500, timestamp - 14500, "1");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("0");
  });

  it("returns 0 if failed rounds", async function () {
    await ethUsdChainlinkAggregator.addRound("0", timestamp - 3500, timestamp - 3500, "1");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("0");
  });

  it("returns 0 if no round > lookback ago", async function () {
    await ethUsdChainlinkAggregator.addRound("10000", timestamp - 3500, timestamp - 3500, "1");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("0");
  });

  it("returns 0 if invalid timestamp", async function () {
    await ethUsdChainlinkAggregator.addRound("10000", timestamp + 100, timestamp + 100, "1");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("0");
  });

  it("returns 0 if older invalid round", async function () {
    await ethUsdChainlinkAggregator.addRound("0", timestamp - 3500, timestamp - 3500, "1");
    await ethUsdChainlinkAggregator.addRound("10000", timestamp - 1800, timestamp - 1800, "1");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("0");
  });

  it("returns 0 if multiple rounds, but no round > lookback ago", async function () {
    await ethUsdChainlinkAggregator.addRound("10000", timestamp - 3500, timestamp - 3500, "1");
    await ethUsdChainlinkAggregator.addRound("10000", timestamp - 3400, timestamp - 3500, "1");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("0");
  });

  it("reports result if last round is older than lookback", async function () {
    await ethUsdChainlinkAggregator.addRound("10000", timestamp - 4000, timestamp - 4000, "1");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("10000");
  });

  it("reports average of 2 rounds", async function () {
    await ethUsdChainlinkAggregator.addRound("10000", timestamp - 4000, timestamp - 4000, "1");
    await ethUsdChainlinkAggregator.addRound("15000", timestamp - 1798, timestamp - 1798, "2");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("12500");
  });

  it("reports average of 3 rounds", async function () {
    await ethUsdChainlinkAggregator.addRound("10000", timestamp - 4000, timestamp - 4000, "1");
    await ethUsdChainlinkAggregator.addRound("15000", timestamp - 1797, timestamp - 1797, "2");
    await ethUsdChainlinkAggregator.addRound("25000", timestamp - 897, timestamp - 897, "3");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("15000");
  });

  it("reports average of 4 rounds with an old round", async function () {
    await ethUsdChainlinkAggregator.addRound("8000", timestamp - 5000, timestamp - 5000, "1");
    await ethUsdChainlinkAggregator.addRound("10000", timestamp - 4000, timestamp - 4000, "2");
    await ethUsdChainlinkAggregator.addRound("12500", timestamp - 2695, timestamp - 2695, "3");
    await ethUsdChainlinkAggregator.addRound("15000", timestamp - 1795, timestamp - 1795, "3");
    await ethUsdChainlinkAggregator.addRound("17500", timestamp - 895, timestamp - 895, "4");
    expect(await mockBeanstalk.getTokenUsdTwap(WETH, "3600")).to.be.equal("13750");
  });
});

const {
  USDC,
  USDT,
  DAI,
  ETH_USD_CHAINLINK_AGGREGATOR,
  STETH_ETH_CHAINLINK_PRICE_AGGREGATOR,
  WETH,
  WSTETH,
  WSTETH_ETH_UNIV3_01_POOL
} = require("../test/hardhat/utils/constants.js");
const diamond = require("./diamond.js");
const {
  impersonateBean,
  impersonateWeth,
  impersonatePrice,
  impersonateChainlinkAggregator,
  impersonateUniswapV3,
  impersonatePipeline,
  impersonateToken
} = require("./impersonate.js");
const { getBeanstalk } = require("../utils/contracts");
const { impersonateBeanstalkOwner } = require("../utils/signer");
const { deployBasin } = require("./basin");
const { impersonateBeanEthWell, impersonateBeanWstethWell } = require("../utils/well");

/**
 * @notice deploys a new instance of beanstalk.
 * @dev SHOULD NOT be used to deploy new beanstalks on mainnet,
 * as the "Bean" token is always impersonated to the mainnet bean address.
 * For new deployments, ensure that the "Bean" token assigns the minter role
 * to the new beanstalk diamond.
 */
async function main(
  verbose = false, // if true, print all logs
  mock = true, // if true, deploy "Mock" versions of the facets
  reset = true, // if true, reset hardhat network
  impersonateERC20 = true, // if true, call `impersonateERC20s`
  oracle = true, // if true, deploy and impersonate oracles
  basin = true // if true, deploy and impersonate basin
) {
  if (verbose) {
    console.log("MOCKS ENABLED: ", mock);
  }

  // Disable forking / reset hardhat network.
  //hardhat.org/hardhat-network/docs/reference
  https: if (mock && reset) {
    await network.provider.request({
      method: "hardhat_reset",
      params: []
    });
  }

  const accounts = await ethers.getSigners();
  const account = await accounts[0].getAddress();
  if (verbose) {
    console.log("Account: " + account);
    console.log("---");
  }
  let tx;
  let totalGasUsed = ethers.BigNumber.from("0");
  let receipt;

  // Deploy all facets and external libraries.
  [facets, libraryNames, facetLibraries, linkedLibraries] = await getFacetData();
  let facetsAndNames = await deployFacets(
    verbose,
    mock,
    facets,
    libraryNames,
    facetLibraries,
    linkedLibraries,
    totalGasUsed
  );

  // Fetch init diamond contract
  const initDiamondArg = mock
    ? "contracts/mocks/newMockInitDiamond.sol:MockInitDiamond"
    : "contracts/beanstalk/init/newInitDiamond.sol:InitDiamond";

  // Impersonate various contracts that beanstalk interacts with.
  // These should be impersonated on a fresh network state.
  let basinComponents = [];
  if (reset) {
    await impersonatePrice(); // BeanstalkPrice contract (frontend price)
    await impersonatePipeline(); // Pipeline contract.
  }

  if (basin) {
    basinComponents = await deployBasin(true, false); // Basin deployment.

    // deploy bean-eth well.
    await impersonateBeanEthWell();

    // deploy bean-wstETH well.
    await impersonateBeanWstethWell();
  }

  // Impersonate various ERC20s, if enabled.
  // Bean and WETH are included by default.
  // Non-default ERC20s should have their own impersonation function.
  if (mock) await impersonateBean();
  if (impersonateERC20) await impersonateERC20s(mock);

  // Impersonate oracles. Used within beanstalk to calculate BDV/DeltaB.
  if (oracle) await impersonateOracles();

  const [beanstalkDiamond, diamondCut] = await diamond.deploy({
    diamondName: "BeanstalkDiamond",
    initDiamond: initDiamondArg,
    facets: facetsAndNames,
    owner: account,
    args: [],
    verbose: verbose,
    impersonate: mock && reset
  });

  tx = beanstalkDiamond.deployTransaction;
  if (tx) {
    receipt = await tx.wait();
    if (verbose) console.log("Beanstalk diamond deploy gas used: " + strDisplay(receipt.gasUsed));
    if (verbose) console.log("Beanstalk diamond cut gas used: " + strDisplay(diamondCut.gasUsed));
    totalGasUsed = totalGasUsed.add(receipt.gasUsed).add(diamondCut.gasUsed);
  }

  if (verbose) {
    console.log("--");
    console.log("Beanstalk diamond address:" + beanstalkDiamond.address);
    console.log("--");
    console.log("Total gas used: " + strDisplay(totalGasUsed));
  }

  // sets up ETH/WSTETH oracles
  await initWhitelistOracles();

  return {
    account: account,
    beanstalkDiamond: beanstalkDiamond,
    basinComponents: basinComponents
  };
}

// Deploy all facets and libraries.
// if mock is enabled, deploy "Mock" versions of the facets.
async function deployFacets(
  verbose,
  mock,
  facets,
  libraryNames = [],
  facetLibraries = {},
  linkedLibraries = {},
  totalGasUsed
) {
  const instancesAndNames = [];
  const libraries = {};

  for (const name of libraryNames) {
    if (verbose) console.log(`Deploying: ${name}`);
    let libraryFactory;
    if (linkedLibraries[name]) {
      let linkedLibrary = Object.keys(libraries).reduce((acc, val) => {
        if (linkedLibraries[name].includes(val)) acc[val] = libraries[val];
        return acc;
      }, {});
      libraryFactory = await ethers.getContractFactory(name, {
        libraries: linkedLibrary
      });
    } else {
      libraryFactory = await ethers.getContractFactory(name);
    }
    libraryFactory = await libraryFactory.deploy();
    await libraryFactory.deployed();
    const receipt = await libraryFactory.deployTransaction.wait();
    if (verbose) console.log(`${name} deploy gas used: ` + strDisplay(receipt.gasUsed));
    if (verbose) console.log(`Deployed at ${libraryFactory.address}`);
    libraries[name] = libraryFactory.address;
  }

  for (let facet of facets) {
    let constructorArgs = [];
    if (Array.isArray(facet)) {
      [facet, constructorArgs] = facet;
    }
    let factory;
    // if mocks are enabled, and if the facet has an extenral library,
    // append "Mock" to the facet name when deploying, and run a try/catch.
    if (mock && facetLibraries[facet] !== undefined) {
      let facetLibrary = Object.keys(libraries).reduce((acc, val) => {
        if (facetLibraries[facet].includes(val)) acc[val] = libraries[val];
        return acc;
      }, {});
      try {
        mockFacet = "Mock" + facet;
        factory = await ethers.getContractFactory(mockFacet, {
          libraries: facetLibrary
        });
        facet = mockFacet;
      } catch (e) {
        factory = await ethers.getContractFactory(facet, {
          libraries: facetLibrary
        });
      }
    } else if (facetLibraries[facet] !== undefined) {
      let facetLibrary = Object.keys(libraries).reduce((acc, val) => {
        if (facetLibraries[facet].includes(val)) acc[val] = libraries[val];
        return acc;
      }, {});
      factory = await ethers.getContractFactory(facet, {
        libraries: facetLibrary
      });
    } else {
      // if mock is enabled, append "Mock" to the facet name, and run a try/catch.
      if (mock) {
        try {
          mockFacet = "Mock" + facet;
          factory = await ethers.getContractFactory(mockFacet);
          facet = mockFacet;
        } catch (e) {
          factory = await ethers.getContractFactory(facet);
        }
      } else {
        factory = await ethers.getContractFactory(facet);
      }
    }
    const facetInstance = await factory.deploy(...constructorArgs);
    await facetInstance.deployed();
    const tx = facetInstance.deployTransaction;
    const receipt = await tx.wait();
    if (verbose) console.log(`${facet} deploy gas used: ` + strDisplay(receipt.gasUsed));
    totalGasUsed = totalGasUsed.add(receipt.gasUsed);
    instancesAndNames.push([facet, facetInstance]);
  }
  return instancesAndNames;
}

async function getFacetData() {
  // if new facets are added to beanstalk,
  // append them here.
  // "Mock" versions are automatically detected,
  // if mocks are enabled (make sure to append "Mock" to the facet name).
  facets = [
    "BDVFacet",
    "ApprovalFacet",
    "ConvertGettersFacet",
    "FarmFacet",
    "PauseFacet",
    "DepotFacet",
    "SeasonGettersFacet",
    "GaugeGettersFacet",
    "OwnershipFacet",
    "TokenFacet",
    "TokenSupportFacet",
    "MetadataFacet",
    "GaugeFacet",
    "SiloGettersFacet",
    "LiquidityWeightFacet",
    "ConvertFacet",
    "FieldFacet",
    "MarketplaceFacet",
    "SeasonFacet",
    "SiloFacet",
    "WhitelistFacet",
    "TractorFacet",
    "PipelineConvertFacet",
    "ClaimFacet",
    "OracleFacet"
  ];

  // A list of public libraries that need to be deployed separately.
  libraryNames = [
    "LibGauge",
    "LibIncentive",
    "LibConvert",
    "LibWellMinting",
    "LibGerminate",
    "LibPipelineConvert",
    "LibSilo",
    "LibShipping",
    "LibFlood",
    "LibTokenSilo",
    "LibEvaluate",
    "LibWeather"
  ];

  // A mapping of facet to public library names that will be linked to it.
  // MockFacets will be deployed with the same public libraries.
  facetLibraries = {
    SeasonFacet: [
      "LibGauge",
      "LibIncentive",
      "LibWellMinting",
      "LibGerminate",
      "LibShipping",
      "LibFlood",
      "LibEvaluate",
      "LibWeather"
    ],
    ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
    PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
    SeasonGettersFacet: ["LibWellMinting"],
    SiloFacet: ["LibSilo", "LibTokenSilo"],
    ClaimFacet: ["LibSilo", "LibTokenSilo"]
  };

  // A mapping of external libraries to external libraries that need to be linked.
  // note: if a library depends on another library, the dependency will need to come
  // before itself in `libraryNames`
  libraryLinks = {};

  return [facets, libraryNames, facetLibraries, libraryLinks];
}

/**
 * Deploys "MockToken" versions of common ERC20s.
 * @dev called if "impersonate" flag is enabled.
 * New ERC20s can be added via the `tokens` array.
 */
async function impersonateERC20s() {
  await impersonateWeth();

  // New default ERC20s should be added here.
  tokens = [
    [USDC, 6],
    [USDT, 18],
    [DAI, 18],
    [WSTETH, 18]
  ];
  for (let token of tokens) {
    await impersonateToken(token[0], token[1]);
  }
}

/**
 * @notice Deploy and impersonate oracles.
 */
async function impersonateOracles() {
  // Eth:USD oracle
  await impersonateChainlinkAggregator(ETH_USD_CHAINLINK_AGGREGATOR);

  // WStEth oracle
  await impersonateChainlinkAggregator(STETH_ETH_CHAINLINK_PRICE_AGGREGATOR);
  await impersonateUniswapV3(WSTETH_ETH_UNIV3_01_POOL, WSTETH, WETH, 100);

  // New oracles for wells should be added here.
}

async function initWhitelistOracles() {
  // init ETH:USD oracle
  await updateOracleImplementationForTokenUsingChainlinkAggregator(
    WETH,
    ETH_USD_CHAINLINK_AGGREGATOR
  );
  await setupWstethOracleImplementation();
}

async function updateOracleImplementationForTokenUsingChainlinkAggregator(token, oracleAddress) {
  const FOUR_HOUR_TIMEOUT = 14400; // 4 hours in seconds

  const oracleImplementation = {
    target: oracleAddress,
    selector: "0x00000000",
    encodeType: "0x01",
    data: ethers.utils.defaultAbiCoder.encode(["uint256"], [FOUR_HOUR_TIMEOUT])
  };

  var owner = await impersonateBeanstalkOwner();

  const beanstalk = await getBeanstalk();
  await beanstalk.connect(owner).updateOracleImplementationForToken(token, oracleImplementation);
}

async function setupWstethOracleImplementation() {
  // Deploy new staking eth oracle contract
  const LSDChainlinkOracle = await ethers.getContractFactory("LSDChainlinkOracle");
  const oracleAddress = await LSDChainlinkOracle.deploy();

  const _ethChainlinkOracle = ETH_USD_CHAINLINK_AGGREGATOR;
  const _ethTimeout = 3600 * 4;
  const _xEthChainlinkOracle = STETH_ETH_CHAINLINK_PRICE_AGGREGATOR;
  const _xEthTimeout = 3600 * 4;
  const _token = WSTETH;

  // Create the oracleImplementation object
  const oracleImplementation = {
    target: oracleAddress.address,
    selector: LSDChainlinkOracle.interface.getSighash("getPrice"),
    encodeType: "0x00",
    data: ethers.utils.defaultAbiCoder.encode(
      ["address", "uint256", "address", "uint256"],
      [_ethChainlinkOracle, _ethTimeout, _xEthChainlinkOracle, _xEthTimeout]
    )
  };

  var owner = await impersonateBeanstalkOwner();
  const beanstalk = await getBeanstalk();
  await beanstalk.connect(owner).updateOracleImplementationForToken(_token, oracleImplementation);
}

function addCommas(nStr) {
  nStr += "";
  const x = nStr.split(".");
  let x1 = x[0];
  const x2 = x.length > 1 ? "." + x[1] : "";
  var rgx = /(\d+)(\d{3})/;
  while (rgx.test(x1)) {
    x1 = x1.replace(rgx, "$1" + "," + "$2");
  }
  return x1 + x2;
}

function strDisplay(str) {
  return addCommas(str.toString());
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
exports.deploy = main;
exports.initWhitelistOracles = initWhitelistOracles;

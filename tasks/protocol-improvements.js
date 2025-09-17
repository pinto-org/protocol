const { task } = require("hardhat/config");
const { upgradeWithNewFacets } = require("../scripts/diamond.js");
const { impersonateSigner, mintEth, getBeanstalk } = require("../utils");
const { addLiquidityAndTransfer } = require("../scripts/deployment/addLiquidity");
const { to6 } = require("../test/hardhat/utils/helpers.js");
const { L2_PINTO, L2_PCM, PINTO_CBTC_WELL_BASE } = require("../test/hardhat/utils/constants.js");

module.exports = function () {
  task("PI-1", "Deploys Pinto improvment set 1").setAction(async function () {
    const mock = false;
    let owner;
    if (mock) {
      await hre.run("updateOracleTimeouts");
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
    }
    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: [
        "ClaimFacet",
        "ApprovalFacet",
        "ConvertFacet",
        "ConvertGettersFacet",
        "SiloFacet",
        "SiloGettersFacet",
        "PipelineConvertFacet",
        "SeasonFacet",
        "GaugeGettersFacet",
        "FieldFacet"
      ],
      libraryNames: [
        "LibSilo",
        "LibTokenSilo",
        "LibConvert",
        "LibPipelineConvert",
        "LibGauge",
        "LibIncentive",
        "LibWellMinting",
        "LibGerminate",
        "LibShipping",
        "LibFlood",
        "LibEvaluate",
        "LibDibbler"
      ],
      facetLibraries: {
        ClaimFacet: ["LibSilo", "LibTokenSilo"],
        ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        SiloFacet: ["LibSilo", "LibTokenSilo"],
        PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        SeasonFacet: [
          "LibEvaluate",
          "LibFlood",
          "LibGauge",
          "LibGerminate",
          "LibShipping",
          "LibIncentive",
          "LibWellMinting"
        ]
      },
      initFacetName: "InitPI1",
      initArgs: [],
      object: !mock,
      verbose: true,
      account: owner
    });
  });

  task("PI-2", "Deploys Pinto improvment set 2").setAction(async function () {
    const mock = false;
    let owner;
    if (mock) {
      await hre.run("updateOracleTimeouts");
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
    }
    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: ["ConvertFacet", "ConvertGettersFacet"],
      libraryNames: ["LibSilo", "LibTokenSilo", "LibConvert", "LibPipelineConvert"],
      facetLibraries: {
        ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"]
      },
      initArgs: [],
      object: !mock,
      verbose: true,
      account: owner
    });
  });

  task("PI-3", "Deploys Pinto improvment set 3").setAction(async function () {
    const mock = true;
    let owner;
    if (mock) {
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
    }
    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: [
        "ConvertFacet",
        "PipelineConvertFacet",
        "FieldFacet",
        "SeasonFacet",
        "ApprovalFacet",
        "ConvertGettersFacet",
        "ClaimFacet",
        "SiloFacet",
        "SiloGettersFacet",
        "SeasonGettersFacet"
      ],
      libraryNames: [
        "LibConvert",
        "LibPipelineConvert",
        "LibSilo",
        "LibTokenSilo",
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      facetLibraries: {
        ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
        SeasonFacet: [
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate"
        ],
        ClaimFacet: ["LibSilo", "LibTokenSilo"],
        SiloFacet: ["LibSilo", "LibTokenSilo"],
        SeasonGettersFacet: ["LibWellMinting"]
      },
      initArgs: [],
      initFacetName: "InitPI3",
      object: !mock,
      verbose: true,
      account: owner
    });
  });

  task("PI-4", "Deploys Pinto improvment set 4").setAction(async function () {
    const mock = true;
    let owner;
    if (mock) {
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
    }
    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: ["SeasonFacet", "GaugeGettersFacet", "SeasonGettersFacet"],
      libraryNames: [
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      facetLibraries: {
        SeasonFacet: [
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate"
        ],
        SeasonGettersFacet: ["LibWellMinting"]
      },
      object: !mock,
      verbose: true,
      account: owner
    });
  });

  task("PI-5", "Deploys Pinto improvment set 5").setAction(async function () {
    const mock = true;
    let owner;
    if (mock) {
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
      console.log("Account address: ", await owner.getAddress());
    }
    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: [
        "SeasonFacet",
        "SeasonGettersFacet",
        "FieldFacet",
        "GaugeGettersFacet",
        "ConvertGettersFacet",
        "SiloGettersFacet"
      ],
      libraryNames: [
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate"
      ],
      facetLibraries: {
        SeasonFacet: [
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate"
        ],
        SeasonGettersFacet: ["LibWellMinting"]
      },
      initArgs: [],
      initFacetName: "InitPI5",
      object: !mock,
      verbose: true,
      account: owner
    });
  });

  task("PI-6", "Deploys Pinto improvment set 6").setAction(async function () {
    const mock = true;
    let owner;
    if (mock) {
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
    }
    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: [
        "SeasonFacet",
        "SeasonGettersFacet",
        "GaugeFacet",
        "GaugeGettersFacet",
        "ClaimFacet",
        "PipelineConvertFacet",
        "SiloGettersFacet",
        "OracleFacet"
      ],
      libraryNames: [
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibFlood",
        "LibGerminate",
        "LibSilo",
        "LibTokenSilo",
        "LibPipelineConvert"
      ],
      facetLibraries: {
        SeasonFacet: [
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate"
        ],
        SeasonGettersFacet: ["LibWellMinting"],
        ClaimFacet: ["LibSilo", "LibTokenSilo"],
        PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"]
      },
      object: !mock,
      verbose: true,
      account: owner,
      initArgs: [],
      initFacetName: "InitPI6"
    });
  });

  task("PI-7", "Deploys Pinto improvement set 7, Convert Down Penalty").setAction(
    async function () {
      const mock = true;
      let owner;
      if (mock) {
        // await hre.run("updateOracleTimeouts");
        owner = await impersonateSigner(L2_PCM);
        await mintEth(owner.address);
      } else {
        owner = (await ethers.getSigners())[0];
      }
      // upgrade facets
      await upgradeWithNewFacets({
        diamondAddress: L2_PINTO,
        facetNames: [
          "ConvertFacet",
          "ConvertGettersFacet",
          "PipelineConvertFacet",
          "GaugeFacet",
          "SeasonFacet",
          "ApprovalFacet",
          "SeasonGettersFacet",
          "ClaimFacet",
          "SiloGettersFacet",
          "GaugeGettersFacet",
          "OracleFacet"
        ],
        libraryNames: [
          "LibConvert",
          "LibPipelineConvert",
          "LibSilo",
          "LibTokenSilo",
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate"
        ],
        facetLibraries: {
          ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
          PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
          SeasonFacet: [
            "LibEvaluate",
            "LibGauge",
            "LibIncentive",
            "LibShipping",
            "LibWellMinting",
            "LibFlood",
            "LibGerminate"
          ],
          SeasonGettersFacet: ["LibWellMinting"],
          ClaimFacet: ["LibSilo", "LibTokenSilo"]
        },
        object: !mock,
        verbose: true,
        account: owner,
        initArgs: [],
        initFacetName: "InitPI7"
      });
    }
  );

  task("PI-8", "Deploys Pinto improvement set 8, Tractor, Soil Orderbook").setAction(
    async function () {
      const mock = true;
      let owner;
      if (mock) {
        owner = await impersonateSigner(L2_PCM);
        await mintEth(owner.address);
      } else {
        owner = (await ethers.getSigners())[0];
      }

      //////////////// External Contracts ////////////////

      // Deploy contracts in correct order

      // Updated Price contract
      const beanstalkPrice = await ethers.getContractFactory("BeanstalkPrice");
      const beanstalkPriceContract = await beanstalkPrice.deploy(L2_PINTO);
      await beanstalkPriceContract.deployed();
      console.log("\nBeanstalkPrice deployed to:", beanstalkPriceContract.address);

      // Price Manipulation
      const priceManipulation = await ethers.getContractFactory("PriceManipulation");
      const priceManipulationContract = await priceManipulation.deploy(L2_PINTO);
      await priceManipulationContract.deployed();
      console.log("\nPriceManipulation deployed to:", priceManipulationContract.address);

      // Deploy OperatorWhitelist
      const operatorWhitelist = await ethers.getContractFactory("OperatorWhitelist");
      const operatorWhitelistContract = await operatorWhitelist.deploy(L2_PCM);
      await operatorWhitelistContract.deployed();
      console.log("\nOperatorWhitelist deployed to:", operatorWhitelistContract.address);

      // Deploy LibTractorHelpers first
      const LibTractorHelpers = await ethers.getContractFactory("LibTractorHelpers");
      const libTractorHelpers = await LibTractorHelpers.deploy();
      await libTractorHelpers.deployed();
      console.log("\nLibTractorHelpers deployed to:", libTractorHelpers.address);

      // Deploy TractorHelpers with library linking
      const TractorHelpers = await ethers.getContractFactory("TractorHelpers", {
        libraries: {
          LibTractorHelpers: libTractorHelpers.address
        }
      });
      const tractorHelpersContract = await TractorHelpers.deploy(
        L2_PINTO, // diamond address
        beanstalkPriceContract.address, // price contract
        L2_PCM, // owner address
        priceManipulationContract.address // price manipulation contract address
      );
      await tractorHelpersContract.deployed();
      console.log("\nTractorHelpers deployed to:", tractorHelpersContract.address);

      // Deploy SowBlueprintv0 and connect it to the existing TractorHelpers
      const sowBlueprint = await ethers.getContractFactory("SowBlueprintv0");
      const sowBlueprintContract = await sowBlueprint.deploy(
        L2_PINTO, // diamond address
        L2_PCM, // owner address
        tractorHelpersContract.address // tractorHelpers contract address
      );

      await sowBlueprintContract.deployed();
      console.log("\nSowBlueprintv0 deployed to:", sowBlueprintContract.address);

      console.log("\nExternal contracts deployed!");

      console.log("\nStarting diamond upgrade...");

      /////////////////////// Diamond Upgrade ///////////////////////

      await upgradeWithNewFacets({
        diamondAddress: L2_PINTO,
        facetNames: [
          "SiloFacet",
          "SiloGettersFacet",
          "ConvertFacet",
          "PipelineConvertFacet",
          "TractorFacet",
          "FieldFacet",
          "ApprovalFacet",
          "ConvertGettersFacet",
          "GaugeFacet",
          "GaugeGettersFacet",
          "SeasonFacet",
          "SeasonGettersFacet",
          "TokenFacet",
          "TokenSupportFacet",
          "MarketplaceFacet",
          "ClaimFacet",
          "WhitelistFacet"
        ],
        libraryNames: [
          "LibSilo",
          "LibTokenSilo",
          "LibConvert",
          "LibPipelineConvert",
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate"
        ],
        facetLibraries: {
          SiloFacet: ["LibSilo", "LibTokenSilo"],
          ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
          PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
          SeasonFacet: [
            "LibEvaluate",
            "LibGauge",
            "LibIncentive",
            "LibShipping",
            "LibWellMinting",
            "LibFlood",
            "LibGerminate"
          ],
          SeasonGettersFacet: ["LibWellMinting"],
          ClaimFacet: ["LibSilo", "LibTokenSilo"]
        },
        initArgs: [],
        selectorsToRemove: ["0x2444561c"],
        initFacetName: "InitPI8",
        object: !mock,
        verbose: true,
        account: owner
      });
    }
  );

  task("PI-10", "Deploys Pinto improvement set 10, Cultivation Factor Change").setAction(
    async function () {
      const mock = true;
      let owner;
      if (mock) {
        // await hre.run("updateOracleTimeouts");
        owner = await impersonateSigner(L2_PCM);
        await mintEth(owner.address);
      } else {
        owner = (await ethers.getSigners())[0];
        console.log("Account address: ", await owner.getAddress());
      }
      await upgradeWithNewFacets({
        diamondAddress: L2_PINTO,
        facetNames: ["FieldFacet", "SeasonFacet", "GaugeFacet", "MarketplaceFacet"],
        libraryNames: [
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate",
          "LibWeather"
        ],
        facetLibraries: {
          SeasonFacet: [
            "LibEvaluate",
            "LibGauge",
            "LibIncentive",
            "LibShipping",
            "LibWellMinting",
            "LibFlood",
            "LibGerminate",
            "LibWeather"
          ]
        },
        initArgs: [],
        initFacetName: "InitPI10",
        object: !mock,
        verbose: true,
        account: owner
      });
    }
  );

  task("PI-11", "Deploys and executes InitPI11 to update convert down penalty gauge").setAction(
    async function () {
      // Get the diamond address
      const diamondAddress = L2_PINTO;

      const mock = false;
      let owner;
      if (mock) {
        await hre.run("updateOracleTimeouts");
        owner = await impersonateSigner(L2_PCM);
        await mintEth(owner.address);
      } else {
        owner = (await ethers.getSigners())[0];
        console.log("Account address: ", await owner.getAddress());
      }

      // Deploy and execute InitPI11
      console.log("📦 Deploying InitPI11 contract...");
      await upgradeWithNewFacets({
        diamondAddress: diamondAddress,
        facetNames: [
          "ConvertFacet",
          "ConvertGettersFacet",
          "PipelineConvertFacet",
          "GaugeFacet",
          "ApprovalFacet",
          "SeasonFacet",
          "ClaimFacet",
          "SiloGettersFacet",
          "GaugeGettersFacet",
          "OracleFacet",
          "SeasonGettersFacet"
        ],
        libraryNames: [
          "LibConvert",
          "LibPipelineConvert",
          "LibSilo",
          "LibTokenSilo",
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibFlood",
          "LibGerminate",
          "LibWeather"
        ],
        facetLibraries: {
          ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
          PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
          SeasonFacet: [
            "LibEvaluate",
            "LibGauge",
            "LibIncentive",
            "LibShipping",
            "LibWellMinting",
            "LibFlood",
            "LibGerminate",
            "LibWeather"
          ],
          ClaimFacet: ["LibSilo", "LibTokenSilo"],
          SeasonGettersFacet: ["LibWellMinting"]
        },
        initFacetName: "InitPI11",
        selectorsToRemove: [
          "0x527ec6ba" // `downPenalizedGrownStalk(address,uint256,uint256)`
        ],
        bip: false,
        object: !mock,
        verbose: true,
        account: owner
      });
    }
  );

  task(
    "PI-13",
    "Deploys Pinto improvement set 13, Misc. Improvements and convert up bonus"
  ).setAction(async function () {
    const mock = true;
    let owner;
    if (mock) {
      // await hre.run("updateOracleTimeouts");
      owner = await impersonateSigner(L2_PCM);
      await mintEth(owner.address);
    } else {
      owner = (await ethers.getSigners())[0];
    }
    // upgrade facets
    await upgradeWithNewFacets({
      diamondAddress: L2_PINTO,
      facetNames: [
        "FieldFacet",
        "ConvertFacet",
        "ConvertGettersFacet",
        "PipelineConvertFacet",
        "SiloGettersFacet",
        "GaugeFacet",
        "GaugeGettersFacet",
        "SeasonFacet",
        "SeasonGettersFacet",
        "ApprovalFacet"
      ],
      libraryNames: [
        "LibTokenSilo",
        "LibConvert",
        "LibPipelineConvert",
        "LibSilo",
        "LibEvaluate",
        "LibGauge",
        "LibIncentive",
        "LibShipping",
        "LibWellMinting",
        "LibWeather",
        "LibFlood",
        "LibGerminate"
      ],
      facetLibraries: {
        ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo"],
        PipelineConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo"],
        SeasonFacet: [
          "LibEvaluate",
          "LibGauge",
          "LibIncentive",
          "LibShipping",
          "LibWellMinting",
          "LibWeather",
          "LibFlood",
          "LibGerminate"
        ],
        SeasonGettersFacet: ["LibWellMinting"]
      },
      linkedLibraries: {
        LibConvert: "LibTokenSilo"
      },
      object: !mock,
      verbose: true,
      account: owner,
      initArgs: [],
      initFacetName: "InitPI13"
    });
  });

  task("testPI3", "Tests temperature changes after PI-3 upgrade").setAction(async function () {
    // Fork from specific block
    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.BASE_RPC,
            blockNumber: 22927326 // this block is shortly before a season where a dump would cause the temp to increase
          }
        }
      ]
    });

    const beanstalk = await getBeanstalk(L2_PINTO);

    const RESERVES = "0x4FAE5420F64c282FD908fdf05930B04E8e079770";

    // impersonate reserves address
    const reserves = await impersonateSigner(RESERVES);
    await mintEth(RESERVES);

    // Get Well contract and tokens
    const well = await ethers.getContractAt("IWell", PINTO_CBTC_WELL_BASE);
    const tokens = await well.tokens();
    const pinto = tokens[0];
    const cbBTC = tokens[1];

    console.log("\nExecuting swap from Pinto to cbBTC...");
    try {
      // Get current fee data to base our txn fees on
      const feeData = await ethers.provider.getFeeData();

      // Multiply the fees to ensure they're high enough (this took some trial and error)
      const adjustedMaxFeePerGas = feeData.maxFeePerGas.mul(5);
      const adjustedPriorityFeePerGas = feeData.maxPriorityFeePerGas.mul(2);

      const txParams = {
        maxFeePerGas: adjustedMaxFeePerGas,
        maxPriorityFeePerGas: adjustedPriorityFeePerGas,
        gasLimit: 1000000
      };

      console.log("Adjusted Tx Params:", {
        maxFeePerGas: adjustedMaxFeePerGas.toString(),
        maxPriorityFeePerGas: adjustedPriorityFeePerGas.toString(),
        gasLimit: txParams.gasLimit
      });

      // withdraw from internal balance
      console.log("\nTransferring Pinto from internal to external balance...");
      const transferTx = await beanstalk.connect(reserves).transferInternalTokenFrom(
        PINTO, // token address
        RESERVES, // sender
        RESERVES, // recipient
        to6("26000"), // amount
        0, // toMode (0 for external)
        txParams // gas parameters
      );

      var receipt = await transferTx.wait();
      console.log("Transfer complete!");
      console.log("Transaction hash:", transferTx.hash);
      console.log("Gas used:", receipt.gasUsed.toString());

      // approve spending pinto to the well
      console.log("\nApproving Pinto spend to Well...");
      const pintoToken = await ethers.getContractAt("IERC20", pinto);
      const approveTx = await pintoToken
        .connect(reserves)
        .approve(well.address, ethers.constants.MaxUint256, txParams);
      receipt = await approveTx.wait();
      console.log("Approval complete!");
      console.log("Transaction hash:", approveTx.hash);
      console.log("Gas used:", receipt.gasUsed.toString());

      // log pinto balance of reserves
      const pintoBalance = await pintoToken.balanceOf(reserves.address);
      console.log("\nPinto balance of reserves:", pintoBalance.toString());

      // Execute swap
      const amountIn = to6("26000"); // 26000 Pinto with 6 decimals
      const deadline = ethers.constants.MaxUint256;

      console.log("Swapping...");
      const tx = await well.connect(reserves).swapFrom(
        pinto, // fromToken
        cbBTC, // toToken
        amountIn, // amountIn
        0, // minAmountOut (0 for testing)
        reserves.address, // recipient
        deadline, // deadline
        txParams
      );

      receipt = await tx.wait();
      console.log("Swap complete!");
      console.log("Transaction hash:", tx.hash);
      console.log("Gas used:", receipt.gasUsed.toString());
    } catch (error) {
      console.error("Error during swap:", error);
      throw error;
    }

    // Get initial max temperature
    const initialMaxTemp = await beanstalk.maxTemperature();
    console.log("\nInitial max temperature:", initialMaxTemp.toString());

    // Run the upgrade
    console.log("\nRunning temp-changes-upgrade...");
    await hre.run("PI-3");

    // Run sunrise
    console.log("\nRunning sunrise...");
    await hre.run("callSunrise");

    // Get final max temperature
    const finalMaxTemp = await beanstalk.maxTemperature();
    console.log("\nFinal max temperature:", finalMaxTemp.toString());

    // Log the difference
    console.log("\nTemperature change:", finalMaxTemp.sub(initialMaxTemp).toString());
  });
};

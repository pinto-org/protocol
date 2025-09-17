const { task, types } = require("hardhat/config");
const { resolveDependencies } = require("../scripts/resolveDependencies");
const { decodeDiamondCutAction } = require("../scripts/diamond.js");
const { getFacetBytecode, compareBytecode } = require("../test/hardhat/utils/bytecode");

module.exports = function() {
  task("resolveUpgradeDependencies", "Resolves upgrade dependencies")
    .addOptionalParam(
      "facets",
      "Comma-separated list of facet names that were changed in the upgrade"
    )
    .addOptionalParam(
      "libraries",
      "Comma-separated list of library names that were changed in the upgrade"
    )
    .setAction(async function (taskArgs) {
      // Compile first to update the artifacts
      console.log("Compiling contracts to get updated artifacts...");
      await hre.run("compile");
      let facetNames = [];
      let libraryNames = [];
      // Validate input
      if (!taskArgs.facets && !taskArgs.libraries) {
        throw new Error("Either 'facets' or 'libraries' parameters are required.");
      }
      // Process 'facets' if provided
      if (taskArgs.facets) {
        facetNames = taskArgs.facets.split(",").map((name) => name.trim());
        console.log("Resolving dependencies for facets:", facetNames);
      } else {
        console.log("No facets changed, resolving dependencies for libraries only.");
      }
      // Process 'libraries' if provided
      if (taskArgs.libraries) {
        libraryNames = taskArgs.libraries.split(",").map((name) => name.trim());
        console.log("Resolving dependencies for libraries:", libraryNames);
      } else {
        console.log("No libraries changed, resolving dependencies for facets only.");
      }
      resolveDependencies(facetNames, libraryNames);
    });

  task("decodeDiamondCut", "Decodes diamondCut calldata into human-readable format")
    .addParam("data", "The calldata to decode")
    .setAction(async ({ data }) => {
      const DIAMOND_CUT_ABI = [
        "function diamondCut((address facetAddress, uint8 action, bytes4[] functionSelectors)[] _diamondCut, address _init, bytes _calldata)"
      ];
      const iface = new ethers.utils.Interface(DIAMOND_CUT_ABI);

      // Decode the calldata
      const decoded = iface.parseTransaction({ data });

      // Extract the decoded parameters
      const { _diamondCut, _init, _calldata } = decoded.args;

      // Pretty print
      console.log("\n===== Decoded Diamond Cut =====");
      _diamondCut.forEach((facetCut, index) => {
        console.log(`\nFacetCut #${index + 1}`);
        console.log("=".repeat(40));
        console.log(`  🏷️  Facet Address  : ${facetCut.facetAddress}`);
        console.log(`  🔧 Action         : ${decodeDiamondCutAction(facetCut.action)}`);
        console.log("  📋 Function Selectors:");
        if (facetCut.functionSelectors.length > 0) {
          facetCut.functionSelectors.forEach((selector, selectorIndex) => {
            console.log(`      ${selectorIndex + 1}. ${selector}`);
          });
        } else {
          console.log("      (No selectors provided)");
        }
        console.log("=".repeat(40));
      });

      console.log("\n Init Facet Address:");
      console.log(`  ${_init}`);

      console.log("\n Init Selector:");
      console.log(`  ${_calldata}`);
    });

  task(
    "verifySafeHashes",
    "Computes the expected hashes for a Safe transaction, to be verified against the safe ui and signer wallets"
  )
    .addParam("safe", "The address of the safe multisig", undefined, types.string)
    .addParam(
      "to",
      "The address of the contract that the safe is interacting with",
      undefined,
      types.string
    )
    .addParam("data", "The data field in the safe ui (bytes)", undefined, types.string)
    .addOptionalParam("nonce", "The nonce of the transaction", -1, types.int)
    .addOptionalParam("operation", "The operation type of the transaction", 0, types.int)
    .setAction(async (taskArgs) => {
      // Parameters
      const safeAddress = taskArgs.safe;
      const to = taskArgs.to;
      const data = taskArgs.data;
      const dataHashed = ethers.utils.keccak256(data);
      // Default values (used when signing the transaction)
      const value = 0;
      const operation = taskArgs.operation; // Enum.Operation.Call (0 represents Call, 1 represents DelegateCall)
      const safeTxGas = 0;
      const baseGas = 0;
      const gasPrice = 0;
      const gasToken = ethers.constants.AddressZero; // native token (ETH)
      const refundReceiver = ethers.constants.AddressZero;
      // Standard for versions 1.0.0 and above
      const safeTxTypeHash = "0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8";

      const abi = [
        "function getTransactionHash(address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 _nonce) external view returns (bytes32)",
        "function getChainId() external view returns (uint256)",
        "function domainSeparator() external view returns (bytes32)",
        "function nonce() external view returns (uint256)"
      ];
      const safeMultisig = await ethers.getContractAt(abi, safeAddress);

      // Verify chain id
      const chainId = await safeMultisig.getChainId();

      // Get curent nonce if not provided
      let nonce;
      if (taskArgs.nonce === -1) {
        nonce = await safeMultisig.nonce();
      } else {
        nonce = taskArgs.nonce;
      }

      // Verify domain separator
      const domainSeparator = await safeMultisig.domainSeparator();

      // Verify safe transaction hash
      const safeTransactionHash = await safeMultisig.getTransactionHash(
        to,
        value,
        data,
        operation,
        safeTxGas,
        baseGas,
        gasPrice,
        gasToken,
        refundReceiver,
        nonce
      );

      // Verify message hash
      // The message hash is the keccak256 hash of the abi encoded SafeTxStruct struct
      // with the parameters below
      const encodedMsg = ethers.utils.defaultAbiCoder.encode(
        [
          "bytes32", // safeTxTypeHash
          "address", // to
          "uint256", // value
          "bytes32", // dataHashed
          "uint8", // operation
          "uint256", // safeTxGas
          "uint256", // baseGas
          "uint256", // gasPrice
          "address", // gasToken
          "address", // refundReceiver
          "uint256" // nonce
        ],
        [
          safeTxTypeHash,
          to,
          value,
          dataHashed,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          nonce
        ]
      );

      // Keccak256 hash of the encoded message
      const computedMsgHash = ethers.utils.keccak256(encodedMsg);

      // Pretty print results
      console.log("\n\n");
      console.log("=".repeat(90));
      console.log("          🔗 Safe Transaction Details     ");
      console.log("=".repeat(90));
      console.log(`🌐 Chain ID           : ${chainId.toString()}`);
      console.log(`🔹 Safe Address       : ${safeAddress}`);
      console.log(`🔹 Interacting with   : ${to}`);
      console.log(`🔹 Nonce              : ${nonce}`);
      console.log(`🔹 Domain Separator   : ${domainSeparator}`);
      console.log(`🔹 Safe Tx Hash       : ${safeTransactionHash}`);
      console.log(`🔹 Message Hash       : ${computedMsgHash}`);
      console.log("=".repeat(90));
    });

  task("verifyBytecode", "Verifies the bytecode of facets with optional library linking")
    .addParam(
      "facets",
      'JSON string mapping facets to their deployed addresses (e.g., \'{"FacetName": "0xAddress"}\')'
    )
    .addOptionalParam(
      "libraries",
      'JSON string mapping facets to their linked libraries (e.g., \'{"FacetName": {"LibName": "0xAddress"}}\')'
    )
    .setAction(async (taskArgs) => {
      // Compile first to update the artifacts
      console.log("Compiling contracts to get updated artifacts...");
      await hre.run("compile");

      // Parse inputs
      const deployedFacetAddresses = JSON.parse(taskArgs.facets);
      const facetLibraries = taskArgs.libraries ? JSON.parse(taskArgs.libraries) : {};

      // Deduce facet names from the keys in the addresses JSON
      const facetNames = Object.keys(deployedFacetAddresses);

      // Log the facet names and libraries
      console.log("-----------------------------------");
      console.log("\n📝 Facet Names:");
      facetNames.forEach((name) => console.log(`  - ${name}`));
      console.log("\n🔗 Facet Libraries:");
      Object.entries(facetLibraries).forEach(([facet, libraries]) => {
        console.log(`  📦 ${facet}:`);
        Object.entries(libraries).forEach(([lib, address]) => {
          console.log(`    🔹 ${lib}: ${address}`);
        });
      });
      console.log("\n📍 Deployed Addresses:");
      Object.entries(deployedFacetAddresses).forEach(([facet, address]) => {
        console.log(`  ${facet}: ${address}\n`);
      });
      console.log("-----------------------------------");

      // Verify bytecode for the facets
      const facetData = await getFacetBytecode(facetNames, facetLibraries, true);
      await compareBytecode(facetData, deployedFacetAddresses, false);
    });
};
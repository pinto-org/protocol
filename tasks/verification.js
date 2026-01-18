const { task, types } = require("hardhat/config");
const { resolveDependencies } = require("../scripts/resolveDependencies");
const { decodeDiamondCutAction } = require("../scripts/diamond.js");
const { getFacetBytecode, compareBytecode } = require("../test/hardhat/utils/bytecode");

module.exports = function () {
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
      const fs = require("fs");
      const path = require("path");

      // Build selector to function name mapping from out folder
      const selectorMap = {};
      const selectorToFile = {};
      const outDir = path.join(__dirname, "../out");

      // Helper to recursively find all .json files
      const findJsonFiles = (dir) => {
        const files = [];
        const items = fs.readdirSync(dir);
        for (const item of items) {
          const fullPath = path.join(dir, item);
          const stat = fs.statSync(fullPath);
          if (stat.isDirectory()) {
            files.push(...findJsonFiles(fullPath));
          } else if (item.endsWith(".json") && !item.includes("build-info")) {
            files.push(fullPath);
          }
        }
        return files;
      };

      // Build the selector map
      try {
        const jsonFiles = findJsonFiles(outDir);
        for (const file of jsonFiles) {
          const content = JSON.parse(fs.readFileSync(file, "utf8"));
          if (content.methodIdentifiers) {
            // Extract contract name from file path (e.g., "out/SeasonFacet.sol/SeasonFacet.json" -> "SeasonFacet")
            const contractName = path.basename(file, ".json");

            // Skip test files, interfaces, and mocks
            // Match: test*, Mock*, IBeanstalk, I[A-Z]* (interfaces like IWell, IDiamond, etc.)
            if (
              contractName.startsWith("test") ||
              contractName.includes("Mock") ||
              contractName === "IBeanstalk" ||
              contractName === "TestnetMetadataFacet" ||
              /^I[A-Z]/.test(contractName)
            ) {
              continue;
            }

            for (const [signature, selector] of Object.entries(content.methodIdentifiers)) {
              // Store with 0x prefix for easier lookup
              const selectorHex = "0x" + selector;
              selectorMap[selectorHex] = signature;
              selectorToFile[selectorHex] = contractName;
            }
          }
        }
        console.log(`\n📚 Built selector map with ${Object.keys(selectorMap).length} functions\n`);
      } catch (error) {
        console.log("⚠️  Warning: Could not build selector map from out folder");
        console.log(`   Error: ${error.message}\n`);
      }

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
        // Get facet name from first selector
        let facetName =
          facetCut.functionSelectors.length > 0
            ? selectorToFile[facetCut.functionSelectors[0]] || "Unknown"
            : "Unknown";

        // Manual mapping for abstract contracts that are part of SeasonFacet
        if (facetName === "Weather" || facetName === "Sun" || facetName === "Oracle") {
          facetName = "SeasonFacet";
        }

        console.log(`\nFacetCut #${index + 1} - ${facetName}`);
        console.log("=".repeat(40));
        console.log(`  🏷️  Facet Address  : ${facetCut.facetAddress}`);
        console.log(`  🔧 Action         : ${decodeDiamondCutAction(facetCut.action)}`);
        console.log("  📋 Function Selectors:");
        if (facetCut.functionSelectors.length > 0) {
          facetCut.functionSelectors.forEach((selector, selectorIndex) => {
            const functionName = selectorMap[selector] || "Unknown function";
            console.log(`      ${selectorIndex + 1}. ${selector} → ${functionName}`);
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

  task("getFacetAddresses", "Get current diamond facet addresses with names from Basescan")
    .addOptionalParam("diamond", "Diamond address", undefined, types.string)
    .setAction(async (taskArgs) => {
      const diamondAddress = taskArgs.diamond || require("../test/hardhat/utils/constants.js").L2_PINTO;

      console.log("\n" + "=".repeat(80));
      console.log("🔍 Fetching Current Diamond Facet Addresses");
      console.log("=".repeat(80));
      console.log(`Diamond: ${diamondAddress}\n`);

      // Get diamond contract
      const diamond = await ethers.getContractAt("IDiamondLoupe", diamondAddress);

      // Get all facets (returns array of {facetAddress, functionSelectors})
      const facets = await diamond.facets();

      console.log(`Found ${facets.length} facets\n`);

      // Query Basescan for each facet to get the contract name
      const axios = require("axios");
      const basescanApiKey = process.env.ETHERSCAN_API_KEY;

      if (!basescanApiKey) {
        console.log("⚠️  Warning: ETHERSCAN_API_KEY not found in environment");
        console.log("Proceeding without contract name verification...\n");
      }

      const facetInfo = [];

      for (let i = 0; i < facets.length; i++) {
        const facetAddress = facets[i].facetAddress;
        let contractName = "Unknown";

        if (basescanApiKey && facetAddress !== ethers.constants.AddressZero) {
          try {
            const response = await axios.get(
              `https://api.etherscan.io/v2/api?apikey=${basescanApiKey}&chainid=8453&module=contract&action=getsourcecode&address=${facetAddress}`
            )

            if (response.data.status === "1" && response.data.result[0].ContractName) {
              contractName = response.data.result[0].ContractName;
            }

            // Small delay to avoid rate limiting
            await new Promise(resolve => setTimeout(resolve, 400));
          } catch (error) {
            console.log(`⚠️  Could not fetch name for ${facetAddress}: ${error.message}`);
          }
        }

        facetInfo.push({
          name: contractName,
          address: facetAddress,
          selectorCount: facets[i].functionSelectors.length
        });

        console.log(`[${i + 1}/${facets.length}] ${contractName}`);
        console.log(`  Address: ${facetAddress}`);
        console.log(`  Functions: ${facets[i].functionSelectors.length}\n`);
      }

      // Print summary table
      console.log("=".repeat(80));
      console.log("📊 Summary");
      console.log("=".repeat(80));
      console.log("\nJSON Output:");
      console.log(JSON.stringify(facetInfo, null, 2));

      return facetInfo;
    });

  task(
    "batchVerify",
    "Batch verify multiple contracts on Etherscan/Basescan with contract paths"
  )
    .addParam(
      "contracts",
      'JSON array of contracts to verify: [{"address": "0x...", "name": "ContractName", "path": "contracts/path/Contract.sol"}]. Path is optional - will auto-discover if omitted.'
    )
    .setAction(async (taskArgs, hre) => {
      const contracts = JSON.parse(taskArgs.contracts);
      const network = hre.network.name;

      console.log("\n" + "=".repeat(80));
      console.log("🔍 Batch Contract Verification");
      console.log("=".repeat(80));
      console.log(`Network: ${network}`);
      console.log(`Contracts to verify: ${contracts.length}\n`);

      const results = [];

      for (let i = 0; i < contracts.length; i++) {
        const contract = contracts[i];
        const { address, name, path } = contract;

        console.log(`\n[${i + 1}/${contracts.length}] Verifying ${name}...`);
        console.log(`  Address: ${address}`);

        try {
          // If path is provided, add the --contract flag
          if (path) {
            console.log(`  Contract: ${path}:${name}`);
          } else {
            console.log(`  Auto-discovering contract path...`);
          }

          await hre.run("verify:verify", {
            address: address,
            contract: path ? `${path}:${name}` : undefined
          });

          results.push({ name, address, status: "✅ SUCCESS" });
          console.log(`  ✅ Verified successfully!`);
        } catch (error) {
          if (error.message.includes("Already Verified")) {
            results.push({ name, address, status: "✓ Already verified" });
            console.log(`  ✓ Already verified`);
          } else {
            results.push({ name, address, status: `❌ FAILED: ${error.message}` });
            console.log(`  ❌ Failed: ${error.message}`);
          }
        }
      }

      // Summary
      console.log("\n" + "=".repeat(80));
      console.log("📊 Verification Summary");
      console.log("=".repeat(80));
      results.forEach((result) => {
        console.log(`${result.status} - ${result.name} (${result.address})`);
      });
      console.log("=".repeat(80) + "\n");

      const successCount = results.filter((r) => r.status.includes("SUCCESS")).length;
      const alreadyVerifiedCount = results.filter((r) => r.status.includes("Already")).length;
      const failedCount = results.filter((r) => r.status.includes("FAILED")).length;

      console.log(`Total: ${contracts.length}`);
      console.log(`✅ Newly verified: ${successCount}`);
      console.log(`✓  Already verified: ${alreadyVerifiedCount}`);
      console.log(`❌ Failed: ${failedCount}\n`);
    });
};

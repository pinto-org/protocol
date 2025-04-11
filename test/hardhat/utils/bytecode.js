

async function getFacetBytecode(facetNames, facetLibraries, verbose = false) {
  if (verbose) {
    console.log("\nStarting Bytecode Verification...");
  }
  data = [];
  // loop through all facets:
  for (const facet of facetNames) {
    if (verbose) {
      console.log(`Deploying ${facet}`);
    }

    // deploy facet:
    const facetFactory = await ethers.getContractFactory(facet, {
      libraries: facetLibraries[facet]
    });

    facetContract = await facetFactory.deploy();
    await facetContract.deployed();

    const bytecode = await ethers.provider.getCode(facetContract.address);
    // add facet to data dictionary:
    facetData = {};
    facetData[facet] = {
      "Contract Creation Code": facetContract.deployTransaction["data"].slice(2),
      "Deployed Bytecode": bytecode
    };
    data.push(facetData);
  }
  return data;
}


async function compareBytecode(data, deployedFacetAddresses, verbose = true) {
  invalidFacets = [];
  validFacets = [];
  console.log("\nComparing On Chain Bytecode to locally deployed bytecode...");
  for (const facets of data) {
    const [name] = Object.keys(facets);
    address = deployedFacetAddresses[name];
    const onchainBytecode = await ethers.provider.getCode(address);
    const jsonBytecode = facets[name]["Deployed Bytecode"];

    if (onchainBytecode != jsonBytecode) {
      invalidFacets.push(name);
    } else {
      validFacets.push(name);
    }
  }
  if (verbose) {
    console.log("valid facets: ", validFacets);
    console.log("invalid facets: ", invalidFacets);
  }
  if (invalidFacets.length > 0) {
    console.log("----------------------------------------")
    console.log("Invalid Facet Bytecode: ", invalidFacets + "❌");
    console.log("----------------------------------------")
  } else {
    console.log("\n----------------------------------------")
    console.log("All Facets Bytecode are valid! ✅");
    console.log("----------------------------------------")
  }
}

exports.getFacetBytecode = getFacetBytecode;
exports.compareBytecode = compareBytecode;
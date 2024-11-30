const fs = require("fs");
const path = require("path");

// Paths
const artifactsPath = "./artifacts/contracts";
const facetsPath = "./contracts/beanstalk/facets";
const librariesPath = "./contracts/libraries";

// Dependency Resolver Function
function resolveDependencies(changedFacets = [], changedLibraries = []) {
  let facetNames = new Set();
  let libraryNames = new Set();
  let facetLibraries = {};

  const loadJSON = (filePath) => {
    try {
      return JSON.parse(fs.readFileSync(filePath, "utf8"));
    } catch (error) {
      console.error(`Error reading ${filePath}:`, error);
      return null;
    }
  };
  const getContractJSONPath = (contractName) => {
    const searchDirectory = (directory) => {
      const files = fs.readdirSync(directory, { withFileTypes: true });
      for (const file of files) {
        const fullPath = path.join(directory, file.name);
        if (file.isDirectory()) {
          // Recursively search subdirectories
          const result = searchDirectory(fullPath);
          if (result) return result;
        } else if (file.isFile() && file.name === `${contractName}.json`) {
          // Found the matching JSON file
          return fullPath;
        }
      }
      return null;
    };
    return searchDirectory(artifactsPath);
  };

  // Resolve dependencies for a facet
  const resolveFacetDependencies = (facetName) => {
    const facetJSONPath = getContractJSONPath(facetName);
    if (!facetJSONPath) {
      console.error(`Facet JSON not found for: ${facetName}`);
      return;
    }

    const facetData = loadJSON(facetJSONPath);
    if (!facetData) return;

    facetNames.add(facetName);

    // Add libraries linked to this facet
    if (facetData.linkReferences) {
      Object.keys(facetData.linkReferences).forEach((filePath) => {
        const libraries = Object.keys(facetData.linkReferences[filePath]);
        libraries.forEach((libraryName) => {
          libraryNames.add(libraryName);
          if (!facetLibraries[facetName]) {
            facetLibraries[facetName] = [];
          }
          if (!facetLibraries[facetName].includes(libraryName)) {
            facetLibraries[facetName].push(libraryName);
          }
        });
      });
    }
  };

  // Resolve dependencies for a library
  const resolveLibraryDependencies = (libraryName) => {
    // Search for all facets using this library
    const facetFolders = fs.readdirSync(facetsPath, { withFileTypes: true });
    facetFolders.forEach((folder) => {
      if (folder.isDirectory()) {
        const facetFiles = fs.readdirSync(path.join(facetsPath, folder.name));
        facetFiles.forEach((file) => {
          const facetName = file.replace(".sol", "");
          const facetJSONPath = getContractJSONPath(facetName);
          if (!facetJSONPath) return;

          const facetData = loadJSON(facetJSONPath);
          if (facetData && facetData.linkReferences) {
            Object.keys(facetData.linkReferences).forEach((filePath) => {
              if (Object.keys(facetData.linkReferences[filePath]).includes(libraryName)) {
                resolveFacetDependencies(facetName);
              }
            });
          }
        });
      }
    });
  };

  // Process changed facets if any
  if (changedFacets.length > 0) {
    changedFacets.forEach(resolveFacetDependencies);
  }

  // Process changed libraries if any
  if (changedLibraries.length > 0) {
    changedLibraries.forEach((libraryName) => {
      libraryNames.add(libraryName);
      resolveLibraryDependencies(libraryName);
    });
  }
  console.log("\n------------- Upgrade Task Dependencies -------------");
  console.log("facetNames:", Array.from(facetNames));
  console.log("libraryNames:", Array.from(libraryNames));
  console.log("facetLibraries:", facetLibraries);
}

exports.resolveDependencies = resolveDependencies;

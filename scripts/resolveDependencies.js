const fs = require("fs");
const path = require("path");

// Paths
const artifactsPath = "./artifacts/contracts";
const facetsPath = "./contracts/beanstalk/facets";
const librariesPath = "./contracts/libraries";

// Dependency Resolver
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
          const result = searchDirectory(fullPath);
          if (result) return result;
        } else if (file.isFile() && file.name === `${contractName}.json`) {
          return fullPath;
        }
      }
      return null;
    };
    return searchDirectory(artifactsPath);
  };

  const getFacetSourcePath = (facetName) => {
    const searchDirectory = (directory) => {
      const files = fs.readdirSync(directory, { withFileTypes: true });
      for (const file of files) {
        const fullPath = path.join(directory, file.name);
        if (file.isDirectory()) {
          const result = searchDirectory(fullPath);
          if (result) return result;
        } else if (file.isFile() && file.name === `${facetName}.sol`) {
          return fullPath;
        }
      }
      return null;
    };
    return searchDirectory(facetsPath);
  };

  const resolveFacetDependencies = (facetName) => {
    const facetJSONPath = getContractJSONPath(facetName);
    if (!facetJSONPath) {
      console.error(`Facet JSON not found for: ${facetName}`);
      return;
    }

    const facetData = loadJSON(facetJSONPath);
    if (!facetData) return;

    facetNames.add(facetName);

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

  const resolveLibraryDependencies = (libraryName) => {
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

  // checks usage of internal libraries in facets
  const findFacetsUsingInternalLibraries = () => {
    changedLibraries.forEach((libraryName) => {
      const libraryRegex = new RegExp(`\\b${libraryName}\\b`, "g");
      const facetFolders = fs.readdirSync(facetsPath, { withFileTypes: true });

      facetFolders.forEach((folder) => {
        if (folder.isDirectory()) {
          const facetFiles = fs.readdirSync(path.join(facetsPath, folder.name));
          facetFiles.forEach((file) => {
            const facetName = file.replace(".sol", "");
            const facetSourcePath = getFacetSourcePath(facetName);
            if (!facetSourcePath) return;

            const sourceCode = fs.readFileSync(facetSourcePath, "utf8");
            // if a changed internal library is used in a facet, resolve the facet
            if (libraryRegex.test(sourceCode)) {
              console.log(`Facet "${facetName}" uses internal library "${libraryName}"`);
              resolveFacetDependencies(facetName);
            }
          });
        }
      });
    });
  };

  // log input
  console.log("\n------------- Upgrade Task Input -------------");
  console.log("changedFacets:", changedFacets);
  console.log("changedLibraries:", changedLibraries);

  // if facets were changed, resolve the libraries that need to be linked
  if (changedFacets.length > 0) {
    changedFacets.forEach(resolveFacetDependencies);
  }

  // if libraries were changed
  if (changedLibraries.length > 0) {
    // check to see if those libraries are internal and used in any facets
    // if they are internal, they do not need to be linked,
    // but the facets that use them will need to be included
    findFacetsUsingInternalLibraries();

    changedLibraries.forEach((libraryName) => {
      // Check if the library is internal-only (does not require linking)
      const isInternalOnly = (() => {
        const libraryJSONPath = getContractJSONPath(libraryName);
        if (!libraryJSONPath) return true; // Assume internal if JSON not found
        const libraryData = loadJSON(libraryJSONPath);
        return !(
          libraryData &&
          libraryData.linkReferences &&
          Object.keys(libraryData.linkReferences).length > 0
        );
      })();
      if (!isInternalOnly) {
        // Add to libraryNames only if it is not internal-only
        libraryNames.add(libraryName);
        // Resolve dependencies for facets that use this library
        resolveLibraryDependencies(libraryName);
      } else {
        console.log(`Excluding internal-only library: ${libraryName}`);
      }
    });
  }

  console.log("\n------------- Upgrade Task Dependencies -------------");
  console.log("facetNames:", Array.from(facetNames));
  console.log("libraryNames:", Array.from(libraryNames));
  console.log("facetLibraries:", facetLibraries);
}

exports.resolveDependencies = resolveDependencies;

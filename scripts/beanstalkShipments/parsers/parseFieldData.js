const fs = require('fs');
const path = require('path');

/**
 * Parses field export data into the beanstalkPlots format
 * 
 * Expected output format:
 * beanstalkPlots.json: Array of [account, [[plotIndex, pods]]]
 * 
 * @param {boolean} includeContracts - Whether to include contract addresses alongside arbEOAs
 * @param {string[]} detectedContractAddresses - Array of detected contract addresses to redirect to distributor
 */
function parseFieldData(includeContracts = false, detectedContractAddresses = []) {
  const inputPath = path.join(__dirname, '../data/exports/beanstalk_field.json');
  const outputPath = path.join(__dirname, '../data/beanstalkPlots.json');
  
  const fieldData = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  
  const { arbEOAs, arbContracts = {}, ethContracts = {} } = fieldData;
  
  console.log(`Processing ${Object.keys(arbEOAs).length} arbEOAs`);
  if (includeContracts) {
    console.log(`Processing ${Object.keys(arbContracts).length} arbContracts`);
    console.log(`Processing ${Object.keys(ethContracts).length} ethContracts`);
  }
  
  // Load distributor address from cache
  const { getDeployedAddresses } = require('../utils/addressCache.js');
  const cachedAddresses = getDeployedAddresses();
  if (!cachedAddresses || !cachedAddresses.contractPaybackDistributor) {
    throw new Error(
      "ContractPaybackDistributor address not found in cache. Run 'npx hardhat precomputeDistributorAddress' first."
    );
  }
  const DISTRIBUTOR_ADDRESS = cachedAddresses.contractPaybackDistributor;
  
  // Combine data sources and reassign ethContracts to distributor
  const allAccounts = { ...arbEOAs };
  if (includeContracts) {
    Object.assign(allAccounts, arbContracts);
  }
  
  // Reassign all ethContracts plot assets to the distributor contract
  for (const [, plotsMap] of Object.entries(ethContracts)) {
    if (plotsMap && typeof plotsMap === 'object') {
      // If distributor already has data, merge plot data
      if (allAccounts[DISTRIBUTOR_ADDRESS]) {
        // Merge plot data
        for (const [plotIndex, pods] of Object.entries(plotsMap)) {
          // If same plot index exists, add the pod amounts
          if (allAccounts[DISTRIBUTOR_ADDRESS][plotIndex]) {
            const existingPods = parseInt(allAccounts[DISTRIBUTOR_ADDRESS][plotIndex]);
            const newPods = parseInt(pods);
            allAccounts[DISTRIBUTOR_ADDRESS][plotIndex] = (existingPods + newPods).toString();
          } else {
            allAccounts[DISTRIBUTOR_ADDRESS][plotIndex] = pods;
          }
        }
      } else {
        allAccounts[DISTRIBUTOR_ADDRESS] = { ...plotsMap };
      }
    }
  }
  
  // Reassign detected contract addresses plot assets to the distributor contract
  for (const detectedAddress of detectedContractAddresses) {
    const normalizedDetectedAddress = detectedAddress.toLowerCase();
    
    // Check if this detected contract has plot assets in arbEOAs that need to be redirected
    const detectedContract = Object.keys(allAccounts).find(addr => addr.toLowerCase() === normalizedDetectedAddress);
    
    if (detectedContract && allAccounts[detectedContract] && typeof allAccounts[detectedContract] === 'object') {
      const contractPlotData = allAccounts[detectedContract];
      
      // If distributor already has data, merge plot data
      if (allAccounts[DISTRIBUTOR_ADDRESS]) {
        // Merge plot data
        for (const [plotIndex, pods] of Object.entries(contractPlotData)) {
          // If same plot index exists, add the pod amounts
          if (allAccounts[DISTRIBUTOR_ADDRESS][plotIndex]) {
            const existingPods = parseInt(allAccounts[DISTRIBUTOR_ADDRESS][plotIndex]);
            const newPods = parseInt(pods);
            allAccounts[DISTRIBUTOR_ADDRESS][plotIndex] = (existingPods + newPods).toString();
          } else {
            allAccounts[DISTRIBUTOR_ADDRESS][plotIndex] = pods;
          }
        }
      } else {
        allAccounts[DISTRIBUTOR_ADDRESS] = { ...contractPlotData };
      }
      
      // Remove the detected contract from allAccounts since its assets are now redirected
      delete allAccounts[detectedContract];
    }
  }
  
  // Build plots data structure
  const plotsData = [];
  
  // Process all accounts
  for (const [accountAddress, plotsMap] of Object.entries(allAccounts)) {
    if (!plotsMap || typeof plotsMap !== 'object') continue;
    
    const accountPlots = [];
    
    // Convert plot map to array format
    for (const [plotIndex, pods] of Object.entries(plotsMap)) {
      accountPlots.push([plotIndex, pods]);
    }
    
    // Sort plots by index (numerically)
    accountPlots.sort((a, b) => {
      const indexA = typeof a[0] === 'string' ? parseInt(a[0]) : a[0];
      const indexB = typeof b[0] === 'string' ? parseInt(b[0]) : b[0];
      return indexA - indexB;
    });
    
    if (accountPlots.length > 0) {
      plotsData.push([accountAddress, accountPlots]);
    }
  }
  
  // Sort accounts by address for consistent output
  plotsData.sort((a, b) => a[0].localeCompare(b[0]));
  
  // Calculate statistics
  const totalAccounts = plotsData.length;
  const totalPlots = plotsData.reduce((sum, [, plots]) => sum + plots.length, 0);
  const totalPods = plotsData.reduce((sum, [, plots]) => {
    return sum + plots.reduce((plotSum, [, pods]) => plotSum + parseInt(pods), 0);
  }, 0);
  
  // Write output file
  fs.writeFileSync(outputPath, JSON.stringify(plotsData, null, 2));
  
  console.log(`Accounts with plots: ${totalAccounts}`);
  console.log(`Total plots: ${totalPlots}`);
  console.log(`Total pods: ${totalPods.toLocaleString()}`);
  
  return {
    plotsData,
    stats: {
      totalAccounts,
      totalPlots,
      totalPods,
      includeContracts
    }
  };
}

// Export for use in other scripts
module.exports = parseFieldData;
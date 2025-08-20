const fs = require('fs');
const path = require('path');

/**
 * Parses field export data into the beanstalkPlots format
 * 
 * Expected output format:
 * beanstalkPlots.json: Array of [account, [[plotIndex, pods]]]
 * 
 * @param {boolean} includeContracts - Whether to include contract addresses alongside arbEOAs
 */
function parseFieldData(includeContracts = false) {
  const inputPath = path.join(__dirname, '../data/exports/beanstalk_field.json');
  const outputPath = path.join(__dirname, '../data/beanstalkPlots.json');
  
  console.log('Reading field export data...');
  const fieldData = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  
  const { arbEOAs, arbContracts = {}, ethContracts = {} } = fieldData;
  
  console.log(`📋 Processing ${Object.keys(arbEOAs).length} arbEOAs`);
  if (includeContracts) {
    console.log(`📋 Processing ${Object.keys(arbContracts).length} arbContracts`);
    console.log(`📋 Processing ${Object.keys(ethContracts).length} ethContracts`);
  }
  
  // Combine data sources based on flag
  // Note: ethContracts are excluded as they are handled by ContractPaybackDistributor
  const allAccounts = { ...arbEOAs };
  if (includeContracts) {
    Object.assign(allAccounts, arbContracts);
    // ethContracts intentionally excluded - handled by ContractPaybackDistributor
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
  console.log('💾 Writing beanstalkPlots.json...');
  fs.writeFileSync(outputPath, JSON.stringify(plotsData, null, 2));
  
  console.log('✅ Field data parsing complete!');
  console.log(`   📊 Accounts with plots: ${totalAccounts}`);
  console.log(`   📊 Total plots: ${totalPlots}`);
  console.log(`   📊 Total pods: ${totalPods.toLocaleString()}`);
  console.log(`   📊 Include contracts: ${includeContracts}`);
  console.log(''); // Add spacing
  
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
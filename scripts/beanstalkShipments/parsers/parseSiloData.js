const fs = require('fs');
const path = require('path');

/**
 * Parses silo export data into the unripeBdvTokens format
 * 
 * Expected output format:
 * unripeBdvTokens.json: Array of [account, totalBdvAtRecapitalization]
 * 
 * @param {boolean} includeContracts - Whether to include contract addresses alongside arbEOAs
 */
function parseSiloData(includeContracts = false) {
  const inputPath = path.join(__dirname, '../data/exports/beanstalk_silo.json');
  const outputPath = path.join(__dirname, '../data/unripeBdvTokens.json');
  
  console.log('Reading silo export data...');
  const siloData = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  
  const { arbEOAs, arbContracts = {}, ethContracts = {} } = siloData;
  
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
  
  // Build unripe BDV data structure
  const unripeBdvData = [];
  
  // Process all accounts
  for (const [accountAddress, accountData] of Object.entries(allAccounts)) {
    if (!accountData || !accountData.bdvAtRecapitalization || !accountData.bdvAtRecapitalization.total) continue;
    
    const { bdvAtRecapitalization } = accountData;
    
    // Use the pre-calculated total BDV at recapitalization
    const totalBdv = parseInt(bdvAtRecapitalization.total);
    
    if (totalBdv > 0) {
      unripeBdvData.push([accountAddress, totalBdv.toString()]);
    }
  }
  
  // Sort accounts by address for consistent output
  unripeBdvData.sort((a, b) => a[0].localeCompare(b[0]));
  
  // Calculate statistics
  const totalAccounts = unripeBdvData.length;
  const totalBdv = unripeBdvData.reduce((sum, [, bdv]) => sum + parseInt(bdv), 0);
  const averageBdv = totalAccounts > 0 ? Math.floor(totalBdv / totalAccounts) : 0;
  
  // Write output file
  console.log('💾 Writing unripeBdvTokens.json...');
  fs.writeFileSync(outputPath, JSON.stringify(unripeBdvData, null, 2));
  
  console.log('✅ Silo data parsing complete!');
  console.log(`   📊 Accounts with BDV: ${totalAccounts}`);
  console.log(`   📊 Total BDV: ${totalBdv.toLocaleString()}`);
  console.log(`   📊 Average BDV per account: ${averageBdv.toLocaleString()}`);
  console.log(`   📊 Include contracts: ${includeContracts}`);
  console.log(''); // Add spacing
  
  return {
    unripeBdvData,
    stats: {
      totalAccounts,
      totalBdv,
      averageBdv,
      includeContracts
    }
  };
}

// Export for use in other scripts
module.exports = parseSiloData;
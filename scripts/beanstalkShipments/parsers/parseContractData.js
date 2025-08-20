const fs = require('fs');
const path = require('path');

/**
 * Parses ethContracts data from all export files into ContractPaybackDistributor constructor format
 * 
 * Expected output format:
 * contractDistributorData.json: {
 *   contractAccounts: address[],
 *   siloPaybackTokensOwed: uint256[],
 *   fertilizerClaims: AccountFertilizerClaimData[],
 *   plotClaims: AccountPlotClaimData[]
 * }
 */
function parseContractData() {
  const siloInputPath = path.join(__dirname, '../data/exports/beanstalk_silo.json');
  const barnInputPath = path.join(__dirname, '../data/exports/beanstalk_barn.json');
  const fieldInputPath = path.join(__dirname, '../data/exports/beanstalk_field.json');
  const outputPath = path.join(__dirname, '../data/contractDistributorData.json');
  
  console.log('📋 Parsing ethContracts data for ContractPaybackDistributor...');
  
  // Load all export data files
  console.log('📖 Reading export data files...');
  const siloData = JSON.parse(fs.readFileSync(siloInputPath, 'utf8'));
  const barnData = JSON.parse(fs.readFileSync(barnInputPath, 'utf8'));
  const fieldData = JSON.parse(fs.readFileSync(fieldInputPath, 'utf8'));
  
  const siloContracts = siloData.ethContracts || {};
  const barnContracts = barnData.ethContracts || {};
  const fieldContracts = fieldData.ethContracts || {};
  
  console.log(`🏭 Found ${Object.keys(siloContracts).length} silo contracts`);
  console.log(`🚜 Found ${Object.keys(barnContracts).length} barn contracts`);
  console.log(`🌾 Found ${Object.keys(fieldContracts).length} field contracts`);
  
  // Get all unique contract addresses
  const allContractAddresses = new Set([
    ...Object.keys(siloContracts),
    ...Object.keys(barnContracts),
    ...Object.keys(fieldContracts)
  ]);
  
  const contractAccounts = Array.from(allContractAddresses);
  console.log(`🔗 Total unique contract accounts: ${contractAccounts.length}`);
  
  // Build arrays for constructor parameters
  const siloPaybackTokensOwed = [];
  const fertilizerClaims = [];
  const plotClaims = [];
  
  // Process each contract account
  for (const contractAccount of contractAccounts) {
    // Process silo data
    const siloAccount = siloContracts[contractAccount];
    let siloOwed = "0";
    if (siloAccount && siloAccount.bdvAtRecapitalization && siloAccount.bdvAtRecapitalization.total) {
      siloOwed = siloAccount.bdvAtRecapitalization.total;
    }
    siloPaybackTokensOwed.push(siloOwed);
    
    // Process barn data (fertilizer)
    const barnAccount = barnContracts[contractAccount];
    let fertilizerIds = [];
    let fertilizerAmounts = [];
    
    if (barnAccount && barnAccount.beanFert) {
      for (const [fertId, amount] of Object.entries(barnAccount.beanFert)) {
        fertilizerIds.push(fertId);
        fertilizerAmounts.push(amount);
      }
    }
    
    fertilizerClaims.push({
      contractAccount: contractAccount,
      fertilizerIds: fertilizerIds,
      fertilizerAmounts: fertilizerAmounts
    });
    
    // Process field data (plots)
    const fieldAccount = fieldContracts[contractAccount];
    let plotIds = [];
    let starts = [];
    let ends = [];
    
    if (fieldAccount && typeof fieldAccount === 'object') {
      // Sort plot indices numerically
      const plotIndices = Object.keys(fieldAccount).sort((a, b) => parseInt(a) - parseInt(b));
      
      for (const plotIndex of plotIndices) {
        const podAmount = parseInt(fieldAccount[plotIndex]);
        if (podAmount > 0) {
          plotIds.push(plotIndex);
          starts.push("0"); // Start from beginning of plot
          ends.push(podAmount.toString()); // End is the pod amount
        }
      }
    }
    
    plotClaims.push({
      contractAccount: contractAccount,
      fieldId: "1", // Payback field ID
      ids: plotIds,
      starts: starts,
      ends: ends
    });
  }
  
  // Calculate statistics
  const totalSiloOwed = siloPaybackTokensOwed.reduce((sum, amount) => sum + parseInt(amount), 0);
  const totalFertilizers = fertilizerClaims.reduce((sum, claim) => sum + claim.fertilizerIds.length, 0);
  const totalPlots = plotClaims.reduce((sum, claim) => sum + claim.ids.length, 0);
  
  // Build output data structure
  const contractDistributorData = {
    contractAccounts,
    siloPaybackTokensOwed,
    fertilizerClaims,
    plotClaims
  };
  
  // Write output file
  console.log('💾 Writing contractDistributorData.json...');
  fs.writeFileSync(outputPath, JSON.stringify(contractDistributorData, null, 2));
  
  console.log('✅ Contract data parsing complete!');
  console.log(`   📊 Contract accounts: ${contractAccounts.length}`);
  console.log(`   📊 Total silo BDV owed: ${totalSiloOwed.toLocaleString()}`);
  console.log(`   📊 Total fertilizer claims: ${totalFertilizers}`);
  console.log(`   📊 Total plot claims: ${totalPlots}`);
  console.log('');
  
  return {
    contractDistributorData,
    stats: {
      contractAccounts: contractAccounts.length,
      totalSiloOwed,
      totalFertilizers,
      totalPlots
    }
  };
}

// Export for use in other scripts
module.exports = parseContractData;
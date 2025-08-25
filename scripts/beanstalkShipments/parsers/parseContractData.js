const fs = require('fs');
const path = require('path');

/**
 * Parses contract data from all export files to generate initialization data for ContractPaybackDistributor
 * 
 * Expected output format:
 * contractAccountDistributorInit.json: Array of AccountData objects for contract initialization
 * 
 * @param {boolean} includeContracts - Whether to include contract addresses alongside arbEOAs
 * @param {Function} detectContractAddresses - Function to detect contract addresses
 */
async function parseContractData(includeContracts = false, detectContractAddresses = null) {
  if (!includeContracts) {
    return {
      contractAccounts: [],
      accountData: [],
      stats: {
        totalContracts: 0,
        includeContracts: false
      }
    };
  }
  
  // Input paths for all export files
  const siloInputPath = path.join(__dirname, '../data/exports/beanstalk_silo.json');
  const barnInputPath = path.join(__dirname, '../data/exports/beanstalk_barn.json'); 
  const fieldInputPath = path.join(__dirname, '../data/exports/beanstalk_field.json');
  
  // Output paths
  const outputAccountsPath = path.join(__dirname, '../data/contractAccounts.json');
  const outputInitPath = path.join(__dirname, '../data/contractAccountDistributorInit.json');
  
  // Load all export data
  const siloData = JSON.parse(fs.readFileSync(siloInputPath, 'utf8'));
  const barnData = JSON.parse(fs.readFileSync(barnInputPath, 'utf8'));
  const fieldData = JSON.parse(fs.readFileSync(fieldInputPath, 'utf8'));
  
  // Extract ethContracts from each file
  const siloEthContracts = siloData.ethContracts || {};
  const barnEthContracts = barnData.ethContracts || {};
  const fieldEthContracts = fieldData.ethContracts || {};
  
  console.log(`Found ethContracts - Silo: ${Object.keys(siloEthContracts).length}, Barn: ${Object.keys(barnEthContracts).length}, Field: ${Object.keys(fieldEthContracts).length}`);
  
  // Get detected contract accounts from external function
  let detectedContractAccounts = [];
  
  if (detectContractAddresses) {
    // Get all arbEOAs addresses to check for contract code
    const allArbEOAAddresses = [
      ...Object.keys(siloData.arbEOAs || {}),
      ...Object.keys(barnData.arbEOAs || {}),
      ...Object.keys(fieldData.arbEOAs || {})
    ];
    
    // Deduplicate addresses
    const uniqueArbEOAAddresses = [...new Set(allArbEOAAddresses)];
    
    // Dynamically detect which arbEOAs have contract code
    detectedContractAccounts = await detectContractAddresses(uniqueArbEOAAddresses);
  }

  // Get all unique contract addresses and normalize to lowercase
  const allContractAddressesRaw = [
    ...Object.keys(siloEthContracts),
    ...Object.keys(barnEthContracts),
    ...Object.keys(fieldEthContracts),
    ...detectedContractAccounts // Include dynamically detected contract accounts
  ];
  
  // Normalize addresses to lowercase and deduplicate
  const allContractAddresses = [...new Set(allContractAddressesRaw.map(addr => addr.toLowerCase()))];
  
  console.log(`Total contract addresses to process: ${allContractAddresses.length}`);
  
  
  // Build contract data for each address, merging data from different cases
  const contractAccounts = [];
  const accountDataArray = [];
  
  for (const normalizedAddress of allContractAddresses) {
    
    // Initialize AccountData structure (matching contract format)
    const accountData = {
      whitelisted: true,
      claimed: false,
      siloPaybackTokensOwed: "0",
      fertilizerIds: [],
      fertilizerAmounts: [],
      plotIds: [],
      plotEnds: []  // Only plotEnds needed - plotStarts is always 0 (constant in contract)
    };
    
    // Helper function to find contract data by normalized address
    const findContractData = (contractsObj) => {
      const entries = Object.entries(contractsObj);
      return entries.filter(([addr]) => addr.toLowerCase() === normalizedAddress);
    };
    
    // Helper function to check if this is a detected contract account that needs special handling
    const isDetectedContract = detectedContractAccounts
      .map(addr => addr.toLowerCase())
      .includes(normalizedAddress);
    
    // For detected contracts, also check arbEOAs data
    const findArbEOAData = (arbEOAsObj) => {
      if (!isDetectedContract) return [];
      const entries = Object.entries(arbEOAsObj);
      return entries.filter(([addr]) => addr.toLowerCase() === normalizedAddress);
    };
    
    // Process silo data - merge all matching addresses (check both ethContracts and arbEOAs for detected contracts)
    const siloEntries = findContractData(siloEthContracts);
    const siloArbEntries = findArbEOAData(siloData.arbEOAs || {});
    const allSiloEntries = [...siloEntries, ...siloArbEntries];
    
    let totalSiloBdv = BigInt(0);
    for (const [originalAddr, siloData] of allSiloEntries) {
      if (siloData && siloData.bdvAtRecapitalization && siloData.bdvAtRecapitalization.total) {
        totalSiloBdv += BigInt(siloData.bdvAtRecapitalization.total);
      }
    }
    if (totalSiloBdv > 0n) {
      accountData.siloPaybackTokensOwed = totalSiloBdv.toString();
    }
    
    // Process barn data - merge all matching addresses (check both ethContracts and arbEOAs for detected contracts)
    const barnEntries = findContractData(barnEthContracts);
    const barnArbEntries = findArbEOAData(barnData.arbEOAs || {});
    const allBarnEntries = [...barnEntries, ...barnArbEntries];
    
    const fertilizerMap = new Map(); // fertId -> total amount
    for (const [originalAddr, barnData] of allBarnEntries) {
      if (barnData && barnData.beanFert) {
        for (const [fertId, amount] of Object.entries(barnData.beanFert)) {
          const currentAmount = fertilizerMap.get(fertId) || BigInt(0);
          fertilizerMap.set(fertId, currentAmount + BigInt(amount));
        }
      }
    }
    
    // Convert fertilizer map to arrays
    for (const [fertId, totalAmount] of fertilizerMap) {
      accountData.fertilizerIds.push(fertId);
      accountData.fertilizerAmounts.push(totalAmount.toString());
    }
    
    // Process field data - merge all matching addresses (check both ethContracts and arbEOAs for detected contracts)
    const fieldEntries = findContractData(fieldEthContracts);
    const fieldArbEntries = findArbEOAData(fieldData.arbEOAs || {});
    const allFieldEntries = [...fieldEntries, ...fieldArbEntries];
    
    const plotMap = new Map(); // plotIndex -> total pods
    for (const [originalAddr, fieldData] of allFieldEntries) {
      if (fieldData) {
        for (const [plotIndex, pods] of Object.entries(fieldData)) {
          const currentPods = plotMap.get(plotIndex) || BigInt(0);
          plotMap.set(plotIndex, currentPods + BigInt(pods));
        }
      }
    }
    
    // Convert plot map to arrays
    for (const [plotIndex, totalPods] of plotMap) {
      // For ContractPaybackDistributor, we only need plotIds and plotEnds
      // plotStarts is always 0 (constant in contract), plotEnds contains the pod amounts
      accountData.plotIds.push(plotIndex);
      accountData.plotEnds.push(totalPods.toString());  // plotEnds = pod amounts, not calculated end indices
    }
    
    // Only include contracts that have some assets
    const hasAssets = accountData.siloPaybackTokensOwed !== "0" || 
                     accountData.fertilizerIds.length > 0 || 
                     accountData.plotIds.length > 0;
    
    if (hasAssets) {
      contractAccounts.push(normalizedAddress);
      accountDataArray.push(accountData);
    }
  }
  
  // Sort by contract address for deterministic output
  const sortedData = contractAccounts
    .map((address, index) => ({ address, data: accountDataArray[index] }))
    .sort((a, b) => a.address.localeCompare(b.address));
  
  const finalContractAccounts = sortedData.map(item => item.address);
  const finalAccountData = sortedData.map(item => item.data);
  
  // Calculate statistics
  const totalContracts = finalContractAccounts.length;
  const totalSiloTokens = finalAccountData.reduce((sum, data) => sum + BigInt(data.siloPaybackTokensOwed), 0n);
  const totalFertilizers = finalAccountData.reduce((sum, data) => sum + data.fertilizerIds.length, 0);
  const totalPlots = finalAccountData.reduce((sum, data) => sum + data.plotIds.length, 0);
  
  // Write output files
  fs.writeFileSync(outputAccountsPath, JSON.stringify(finalContractAccounts, null, 2));
  fs.writeFileSync(outputInitPath, JSON.stringify(finalAccountData, null, 2));
  
  console.log(`Contracts with assets: ${totalContracts}`);
  console.log(`Total silo tokens owed: ${totalSiloTokens.toString()}`);
  console.log(`Total fertilizer entries: ${totalFertilizers}`);
  console.log(`Total plot entries: ${totalPlots}`);
  
  return {
    contractAccounts: finalContractAccounts,
    accountData: finalAccountData,
    stats: {
      totalContracts,
      totalSiloTokens: totalSiloTokens.toString(),
      totalFertilizers,
      totalPlots,
      includeContracts
    }
  };
}

// Export for use in other scripts
module.exports = parseContractData;
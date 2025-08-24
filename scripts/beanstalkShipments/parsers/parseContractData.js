const fs = require('fs');
const path = require('path');

/**
 * Parses contract data from all export files to generate initialization data for ContractPaybackDistributor
 * 
 * Expected output format:
 * ethAccountDistributorInit.json: Array of AccountData objects for contract initialization
 * 
 * @param {boolean} includeContracts - Whether to include contract addresses alongside arbEOAs
 */
function parseContractData(includeContracts = false) {
  if (!includeContracts) {
    console.log('⚠️  Contract parsing disabled - skipping parseContractData');
    return {
      contractAccounts: [],
      accountData: [],
      stats: {
        totalContracts: 0,
        includeContracts: false
      }
    };
  }

  console.log('🏢 Parsing contract data for ContractPaybackDistributor initialization...');
  
  // Input paths for all export files
  const siloInputPath = path.join(__dirname, '../data/exports/beanstalk_silo.json');
  const barnInputPath = path.join(__dirname, '../data/exports/beanstalk_barn.json'); 
  const fieldInputPath = path.join(__dirname, '../data/exports/beanstalk_field.json');
  
  // Output paths
  const outputAccountsPath = path.join(__dirname, '../data/ethContractAccounts.json');
  const outputInitPath = path.join(__dirname, '../data/ethAccountDistributorInit.json');
  
  // Load all export data
  console.log('📁 Loading export data...');
  const siloData = JSON.parse(fs.readFileSync(siloInputPath, 'utf8'));
  const barnData = JSON.parse(fs.readFileSync(barnInputPath, 'utf8'));
  const fieldData = JSON.parse(fs.readFileSync(fieldInputPath, 'utf8'));
  
  // Extract ethContracts from each file
  const siloEthContracts = siloData.ethContracts || {};
  const barnEthContracts = barnData.ethContracts || {};
  const fieldEthContracts = fieldData.ethContracts || {};
  
  console.log(`📋 Found ethContracts - Silo: ${Object.keys(siloEthContracts).length}, Barn: ${Object.keys(barnEthContracts).length}, Field: ${Object.keys(fieldEthContracts).length}`);
  
  // Define fertilizer contract accounts (delegated contracts on Base that need special handling)
  const fertilizerContractAccounts = [
    '0x63a7255C515041fD243440e3db0D10f62f9936ae',
    '0xdff24806405f62637E0b44cc2903F1DfC7c111Cd', 
    '0x36DeF8a94e727A0Ff7B01d2f50780F0a28Fb74b6',
    '0x4088E870e785320413288C605FD1BD6bD9D5BDAe',
    '0x8a6EEb9b64EEBA8D3B4404bF67A7c262c555e25B',
    '0x49072cd3Bf4153DA87d5eB30719bb32bdA60884B',
    '0xbfc7E3604c3bb518a4A15f8CeEAF06eD48Ac0De2',
    '0x44db0002349036164dD46A04327201Eb7698A53e',
    '0x542A94e6f4D9D15AaE550F7097d089f273E38f85',
    '0xB423A1e013812fCC9Ab47523297e6bE42Fb6157e',
    '0x7e04231a59C9589D17bcF2B0614bC86aD5Df7C11'
  ];

  // Get all unique contract addresses and normalize to lowercase
  const allContractAddressesRaw = [
    ...Object.keys(siloEthContracts),
    ...Object.keys(barnEthContracts),
    ...Object.keys(fieldEthContracts),
    ...fertilizerContractAccounts // Include the delegated contract accounts
  ];
  
  // Normalize addresses to lowercase and deduplicate
  const allContractAddresses = [...new Set(allContractAddressesRaw.map(addr => addr.toLowerCase()))];
  
  console.log(`📊 Total raw contract addresses: ${allContractAddressesRaw.length}`);
  console.log(`📊 Total unique normalized addresses: ${allContractAddresses.length}`);
  
  // Build contract data for each address, merging data from different cases
  const contractAccounts = [];
  const accountDataArray = [];
  
  for (const normalizedAddress of allContractAddresses) {
    console.log(`\n🔍 Processing contract: ${normalizedAddress}`);
    
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
    
    // Helper function to check if this is a fertilizer contract account that needs special handling
    const isFertilizerContract = fertilizerContractAccounts
      .map(addr => addr.toLowerCase())
      .includes(normalizedAddress);
    
    // For fertilizer contracts, also check arbEOAs data
    const findArbEOAData = (arbEOAsObj) => {
      if (!isFertilizerContract) return [];
      const entries = Object.entries(arbEOAsObj);
      return entries.filter(([addr]) => addr.toLowerCase() === normalizedAddress);
    };
    
    // Process silo data - merge all matching addresses (check both ethContracts and arbEOAs for fertilizer contracts)
    const siloEntries = findContractData(siloEthContracts);
    const siloArbEntries = findArbEOAData(siloData.arbEOAs || {});
    const allSiloEntries = [...siloEntries, ...siloArbEntries];
    
    let totalSiloBdv = BigInt(0);
    for (const [originalAddr, siloData] of allSiloEntries) {
      if (siloData && siloData.bdvAtRecapitalization && siloData.bdvAtRecapitalization.total) {
        totalSiloBdv += BigInt(siloData.bdvAtRecapitalization.total);
        console.log(`   💰 Merged silo BDV from ${originalAddr}: ${siloData.bdvAtRecapitalization.total}`);
      }
    }
    if (totalSiloBdv > 0n) {
      accountData.siloPaybackTokensOwed = totalSiloBdv.toString();
    }
    
    // Process barn data - merge all matching addresses (check both ethContracts and arbEOAs for fertilizer contracts)
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
        console.log(`   🌱 Merged fertilizer data from ${originalAddr}: ${Object.keys(barnData.beanFert).length} entries`);
      }
    }
    
    // Convert fertilizer map to arrays
    for (const [fertId, totalAmount] of fertilizerMap) {
      accountData.fertilizerIds.push(fertId);
      accountData.fertilizerAmounts.push(totalAmount.toString());
    }
    
    // Process field data - merge all matching addresses (check both ethContracts and arbEOAs for fertilizer contracts)
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
        console.log(`   🌾 Merged field data from ${originalAddr}: ${Object.keys(fieldData).length} entries`);
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
      console.log(`   ✅ Contract included with merged assets`);
      console.log(`      - Silo BDV: ${accountData.siloPaybackTokensOwed}`);
      console.log(`      - Fertilizers: ${accountData.fertilizerIds.length}`);
      console.log(`      - Plots: ${accountData.plotIds.length} (plotEnds as pod amounts)`);
    } else {
      console.log(`   ⚠️  Contract has no assets - skipping`);
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
  console.log('\n💾 Writing contract accounts file...');
  fs.writeFileSync(outputAccountsPath, JSON.stringify(finalContractAccounts, null, 2));
  
  console.log('💾 Writing distributor initialization file...');
  fs.writeFileSync(outputInitPath, JSON.stringify(finalAccountData, null, 2));
  
  console.log('\n✅ Contract data parsing complete!');
  console.log(`   📊 Contracts with assets: ${totalContracts}`);
  console.log(`   📊 Total silo tokens owed: ${totalSiloTokens.toString()}`);
  console.log(`   📊 Total fertilizer entries: ${totalFertilizers}`);
  console.log(`   📊 Total plot entries: ${totalPlots}`);
  console.log(`   📊 Include contracts: ${includeContracts}`);
  console.log('');
  
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
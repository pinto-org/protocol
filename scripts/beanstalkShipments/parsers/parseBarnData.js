const fs = require('fs');
const path = require('path');

/**
 * Parses barn export data into the beanstalkAccountFertilizer and beanstalkGlobalFertilizer formats
 * 
 * Expected output formats:
 * beanstalkAccountFertilizer.json: Array of [fertId, [[account, amount, lastBpf]]]
 * beanstalkGlobalFertilizer.json: [fertIds[], amounts[], activeFertilizer, fertilizedIndex, unfertilizedIndex, fertilizedPaidIndex, fertFirst, fertLast, bpf, leftoverBeans]
 * 
 * @param {boolean} includeContracts - Whether to include contract addresses alongside arbEOAs
 */
function parseBarnData(includeContracts = false) {
  const inputPath = path.join(__dirname, '../data/exports/beanstalk_barn.json');
  const outputAccountPath = path.join(__dirname, '../data/beanstalkAccountFertilizer.json');
  const outputGlobalPath = path.join(__dirname, '../data/beanstalkGlobalFertilizer.json');
  
  console.log('Reading barn export data...');
  const barnData = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  
  const { 
    beanBpf, 
    arbEOAs, 
    arbContracts = {},
    ethContracts = {},
    storage
  } = barnData;
  
  const {
    fertilizer: storageFertilizer = {},
    activeFertilizer,
    fertilizedIndex,
    unfertilizedIndex,
    fertilizedPaidIndex,
    fertFirst,
    fertLast,
    bpf,
    leftoverBeans
  } = storage || {};
  
  console.log(`🌱 Using beanBpf: ${beanBpf}`);
  console.log(`📋 Processing ${Object.keys(arbEOAs).length} arbEOAs`);
  if (includeContracts) {
    console.log(`📋 Processing ${Object.keys(arbContracts).length} arbContracts`);
    console.log(`📋 Processing ${Object.keys(ethContracts).length} ethContracts`);
  }
  
  // Load constants for distributor address
  const constants = require('../../../test/hardhat/utils/constants.js');
  const DISTRIBUTOR_ADDRESS = constants.BEANSTALK_CONTRACT_PAYBACK_DISTRIBUTOR;
  
  // Combine data sources and reassign ethContracts to distributor
  const allAccounts = { ...arbEOAs };
  if (includeContracts) {
    Object.assign(allAccounts, arbContracts);
  }
  
  // Reassign all ethContracts fertilizer assets to the distributor contract
  for (const [ethContractAddress, ethContractData] of Object.entries(ethContracts)) {
    if (ethContractData && ethContractData.beanFert) {
      // If distributor already has data, merge fertilizer data
      if (allAccounts[DISTRIBUTOR_ADDRESS]) {
        if (!allAccounts[DISTRIBUTOR_ADDRESS].beanFert) {
          allAccounts[DISTRIBUTOR_ADDRESS].beanFert = {};
        }
        // Merge fertilizer amounts for same IDs
        for (const [fertId, amount] of Object.entries(ethContractData.beanFert)) {
          const existingAmount = parseInt(allAccounts[DISTRIBUTOR_ADDRESS].beanFert[fertId] || '0');
          const newAmount = parseInt(amount);
          allAccounts[DISTRIBUTOR_ADDRESS].beanFert[fertId] = (existingAmount + newAmount).toString();
        }
      } else {
        allAccounts[DISTRIBUTOR_ADDRESS] = {
          beanFert: { ...ethContractData.beanFert }
        };
      }
    }
  }
  
  // Use storage fertilizer data directly for global fertilizer
  const sortedFertIds = Object.keys(storageFertilizer).sort((a, b) => parseInt(a) - parseInt(b));
  const fertAmounts = sortedFertIds.map(fertId => storageFertilizer[fertId]);
  
  // Build fertilizer data structures for account fertilizer
  const fertilizerMap = new Map(); // fertId -> { accounts: [[account, amount]], totalAmount: number }
  
  // Process all accounts
  for (const [accountAddress, accountData] of Object.entries(allAccounts)) {
    const { beanFert } = accountData;
    
    if (!beanFert) continue;
    
    for (const [fertId, amount] of Object.entries(beanFert)) {
      if (!fertilizerMap.has(fertId)) {
        fertilizerMap.set(fertId, {
          accounts: [],
          totalAmount: 0
        });
      }

      // note: beanBpf here is the lastBpf and it is the same across all accounts
      // since we claimed on behalf of them during the l2 migration and there were no
      // beans distributed to fertilizer during this period
      const fertData = fertilizerMap.get(fertId);
      fertData.accounts.push([accountAddress, amount, beanBpf]);
      fertData.totalAmount += parseInt(amount);
    }
  }
  
  // Build account fertilizer output format
  const accountFertilizer = [];
  for (const fertId of sortedFertIds) {
    const fertData = fertilizerMap.get(fertId);
    if (fertData && fertData.accounts.length > 0) {
      accountFertilizer.push([fertId, fertData.accounts]);
    }
  }
  
  const globalFertilizer = [
    sortedFertIds,                    // fertilizerIds (uint128[])
    fertAmounts,                      // fertilizerAmounts (uint256[])
    activeFertilizer || "0",          // activeFertilizer (uint256)
    fertilizedIndex || "0",           // fertilizedIndex (uint256)
    unfertilizedIndex || "0",         // unfertilizedIndex (uint256)
    fertilizedPaidIndex || "0",       // fertilizedPaidIndex (uint256)
    fertFirst || "0",                 // fertFirst (uint128)
    fertLast || "0",                  // fertLast (uint128)
    bpf || "0",                       // bpf (uint128)
    leftoverBeans || "0"              // leftoverBeans (uint256)
  ];
  
  // Write output files
  console.log('💾 Writing beanstalkAccountFertilizer.json...');
  fs.writeFileSync(outputAccountPath, JSON.stringify(accountFertilizer, null, 2));
  
  console.log('💾 Writing beanstalkGlobalFertilizer.json...');
  fs.writeFileSync(outputGlobalPath, JSON.stringify(globalFertilizer, null, 2));
  
  console.log('✅ Barn data parsing complete!');
  console.log(`   📊 Account fertilizer entries: ${accountFertilizer.length}`);
  console.log(`   📊 Global fertilizer IDs: ${sortedFertIds.length}`);
  console.log(`   📊 Active fertilizer: ${activeFertilizer}`);
  console.log(`   📊 Include contracts: ${includeContracts}`);
  console.log('');
  
  return {
    accountFertilizer,
    globalFertilizer,
    stats: {
      fertilizerIds: sortedFertIds.length,
      accountEntries: accountFertilizer.length,
      activeFertilizer: activeFertilizer || "0",
      includeContracts
    }
  };
}

// Export for use in other scripts
module.exports = parseBarnData;
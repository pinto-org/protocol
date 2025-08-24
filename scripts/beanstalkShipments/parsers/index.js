const parseBarnData = require('./parseBarnData');
const parseFieldData = require('./parseFieldData');
const parseSiloData = require('./parseSiloData');
const parseContractData = require('./parseContractData');
const fs = require('fs');
const path = require('path');

/**
 * Main parser orchestrator that runs all parsers
 * @param {boolean} includeContracts - Whether to include contract addresses alongside arbEOAs
 */
function parseAllExportData(parseContracts = false) {
  console.log('⚙️  Starting export data parsing...');
  console.log(`📄 Include contracts: ${parseContracts}`);
  
  const results = {};
  
  try {
    // Parse barn data
    console.log('\n🏛️  BARN DATA');
    console.log('-'.repeat(30));
    results.barn = parseBarnData(parseContracts);
    
    // Parse field data  
    console.log('🌾 FIELD DATA');
    console.log('-'.repeat(30));
    results.field = parseFieldData(parseContracts);
    
    // Parse silo data
    console.log('🏢 SILO DATA');
    console.log('-'.repeat(30));
    results.silo = parseSiloData(parseContracts);
    
    // Parse contract data for distributor initialization
    console.log('🏗️  CONTRACT DISTRIBUTOR DATA');
    console.log('-'.repeat(30));
    results.contracts = parseContractData(parseContracts);
    
    console.log('📋 PARSING SUMMARY');
    console.log('-'.repeat(30));
    console.log(`📊 Barn: ${results.barn.stats.fertilizerIds} fertilizer IDs, ${results.barn.stats.accountEntries} account entries`);
    console.log(`📊 Field: ${results.field.stats.totalAccounts} accounts, ${results.field.stats.totalPlots} plots`);
    console.log(`📊 Silo: ${results.silo.stats.totalAccounts} accounts with BDV`);
    console.log(`📊 Contracts: ${results.contracts.stats.totalContracts} contracts for distributor`);
    console.log(`📊 Include contracts: ${parseContracts}`);
    
    return results;
  } catch (error) {
    console.error('Error during parsing:', error);
    throw error;
  }
}

/**
 * Generates address files from the parsed JSON export data
 * Reads the JSON files and extracts addresses to text files
 */
function generateAddressFiles() {
  console.log('📝 Generating address files from export data...');
  
  try {
    // Define excluded addresses
    const excludedAddresses = [
      '0x0245934a930544c7046069968eb4339b03addfcf',
      '0x4df59c31a3008509B3C1FeE7A808C9a28F701719'
    ];
    
    // Define fertilizer contract accounts (delegated contracts that need special handling)
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
    
    // Define file paths
    const dataDir = path.join(__dirname, '../data/exports');
    const accountsDir = path.join(dataDir, 'accounts');
    
    // Create accounts directory if it doesn't exist
    if (!fs.existsSync(accountsDir)) {
      fs.mkdirSync(accountsDir, { recursive: true });
    }
    
    // Read the parsed JSON files
    const siloData = JSON.parse(fs.readFileSync(path.join(dataDir, 'beanstalk_silo.json')));
    const barnData = JSON.parse(fs.readFileSync(path.join(dataDir, 'beanstalk_barn.json')));
    const fieldData = JSON.parse(fs.readFileSync(path.join(dataDir, 'beanstalk_field.json')));
    
    // Combine all addresses to exclude
    const allExcludedAddresses = [...excludedAddresses, ...fertilizerContractAccounts];
    
    // Extract and filter addresses from each JSON file
    const siloAddresses = Object.keys(siloData.arbEOAs || {}).filter(addr => 
      !allExcludedAddresses.includes(addr.toLowerCase()) && !allExcludedAddresses.includes(addr)
    );
    const barnAddresses = Object.keys(barnData.arbEOAs || {}).filter(addr => 
      !allExcludedAddresses.includes(addr.toLowerCase()) && !allExcludedAddresses.includes(addr)
    );
    const fieldAddresses = Object.keys(fieldData.arbEOAs || {}).filter(addr => 
      !allExcludedAddresses.includes(addr.toLowerCase()) && !allExcludedAddresses.includes(addr)
    );
    
    // Write addresses to text files
    fs.writeFileSync(path.join(accountsDir, 'silo_addresses.txt'), siloAddresses.join('\n'));
    fs.writeFileSync(path.join(accountsDir, 'barn_addresses.txt'), barnAddresses.join('\n'));
    fs.writeFileSync(path.join(accountsDir, 'field_addresses.txt'), fieldAddresses.join('\n'));
    
    console.log(`✅ Generated address files:`);
    console.log(`   - silo_addresses.txt (${siloAddresses.length} addresses)`);
    console.log(`   - barn_addresses.txt (${barnAddresses.length} addresses)`);
    console.log(`   - field_addresses.txt (${fieldAddresses.length} addresses)`);
    
    return {
      siloAddresses: siloAddresses.length,
      barnAddresses: barnAddresses.length,
      fieldAddresses: fieldAddresses.length
    };
  } catch (error) {
    console.error('❌ Failed to generate address files:', error);
    throw error;
  }
}

// Export individual parsers and main function
module.exports = {
  parseBarnData,
  parseFieldData,
  parseSiloData,
  parseContractData,
  parseAllExportData,
  generateAddressFiles
};
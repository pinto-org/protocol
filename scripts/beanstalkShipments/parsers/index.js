const parseBarnData = require('./parseBarnData');
const parseFieldData = require('./parseFieldData');
const parseSiloData = require('./parseSiloData');
const parseContractData = require('./parseContractData');
const fs = require('fs');
const path = require('path');
const { ethers } = require("hardhat");

/**
 * Detects which addresses have associated contract code on the active hardhat network
 */
async function detectContractAddresses(addresses) {
  console.log(`Checking ${addresses.length} addresses for contract code...`);
  const contractAddresses = [];
  
  for (const address of addresses) {
    try {
      const code = await ethers.provider.getCode(address);
      if (code.length > 2) {
        contractAddresses.push(address.toLowerCase());
      }
    } catch (error) {
      console.error(`Error checking address ${address}:`, error.message);
    }
  }
  
  console.log(`Found ${contractAddresses.length} addresses with contract code`);
  return contractAddresses;
}

/**
 * Main parser orchestrator that runs all parsers
 * @param {boolean} includeContracts - Whether to include contract addresses alongside arbEOAs
 */
async function parseAllExportData(parseContracts = false) {
  console.log('Starting export data parsing...');
  console.log(`Include contracts: ${parseContracts}`);
  
  const results = {};
  
  try {
    console.log('\nProcessing barn data...');
    results.barn = parseBarnData(parseContracts);
    
    console.log('Processing field data...');
    results.field = parseFieldData(parseContracts);
    
    console.log('Processing silo data...');
    results.silo = parseSiloData(parseContracts);
    
    console.log('Processing contract data...');
    results.contracts = await parseContractData(parseContracts, detectContractAddresses);
    
    console.log('\nParsing complete');
    console.log(`Barn: ${results.barn.stats.fertilizerIds} fertilizer IDs, ${results.barn.stats.accountEntries} account entries`);
    console.log(`Field: ${results.field.stats.totalAccounts} accounts, ${results.field.stats.totalPlots} plots`);
    console.log(`Silo: ${results.silo.stats.totalAccounts} accounts with BDV`);
    console.log(`Contracts: ${results.contracts.stats.totalContracts} contracts for distributor`);
    
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
async function generateAddressFiles() {
  console.log('Generating address files from export data...');
  
  try {
    // Define excluded addresses
    const excludedAddresses = [
      '0x0245934a930544c7046069968eb4339b03addfcf',
      '0x4df59c31a3008509B3C1FeE7A808C9a28F701719'
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
    
    // Get all arbEOAs addresses to check for contract code
    const allArbEOAAddresses = [
      ...Object.keys(siloData.arbEOAs || {}),
      ...Object.keys(barnData.arbEOAs || {}),
      ...Object.keys(fieldData.arbEOAs || {})
    ];
    
    // Deduplicate addresses
    const uniqueArbEOAAddresses = [...new Set(allArbEOAAddresses)];
    
    // Dynamically detect which arbEOAs have contract code
    const detectedContractAccounts = await detectContractAddresses(uniqueArbEOAAddresses);
    
    // Combine all addresses to exclude
    const allExcludedAddresses = [...excludedAddresses, ...detectedContractAccounts];
    
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
    
    console.log(`Generated address files:`);
    console.log(`- silo_addresses.txt (${siloAddresses.length} addresses)`);
    console.log(`- barn_addresses.txt (${barnAddresses.length} addresses)`);
    console.log(`- field_addresses.txt (${fieldAddresses.length} addresses)`);
    
    return {
      siloAddresses: siloAddresses.length,
      barnAddresses: barnAddresses.length,
      fieldAddresses: fieldAddresses.length
    };
  } catch (error) {
    console.error('Failed to generate address files:', error);
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
  generateAddressFiles,
  detectContractAddresses
};
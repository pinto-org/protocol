const parseBarnData = require('./parseBarnData');
const parseFieldData = require('./parseFieldData');
const parseSiloData = require('./parseSiloData');
const parseContractData = require('./parseContractData');
const fs = require('fs');
const path = require('path');
const ethersLib = require('ethers');

require('dotenv').config();

const BATCH_SIZE = 50;
const MAX_RETRIES = 3;
const RETRY_DELAY = 1000;

const isEthersV6 = ethersLib.JsonRpcProvider !== undefined;
const createProvider = (url) => {
  if (isEthersV6) {
    return new ethersLib.JsonRpcProvider(url);
  } else {
    return new ethersLib.providers.JsonRpcProvider(url);
  }
};

async function withRetry(fn, retries = MAX_RETRIES) {
  for (let i = 0; i < retries; i++) {
    try {
      return await fn();
    } catch (e) {
      if (i === retries - 1) throw e;
      await new Promise(r => setTimeout(r, RETRY_DELAY * (i + 1)));
    }
  }
}

/**
 * Detects which addresses have contract code on Ethereum or Arbitrum
 * using direct RPC calls. An address is flagged as a contract if it has
 * bytecode on either chain, since it may not be able to claim on Base.
 * Requires MAINNET_RPC and ARBITRUM_RPC in .env
 */
async function detectContractAddresses(addresses) {
  console.log(`Checking ${addresses.length} addresses for contract code on Ethereum and Arbitrum...`);

  const mainnetRpc = process.env.MAINNET_RPC;
  const arbitrumRpc = process.env.ARBITRUM_RPC;

  if (!mainnetRpc || !arbitrumRpc) {
    throw new Error('MAINNET_RPC and ARBITRUM_RPC must be set in .env for contract detection');
  }

  const ethProvider = createProvider(mainnetRpc);
  const arbProvider = createProvider(arbitrumRpc);

  // Verify connections
  const ethBlock = await ethProvider.getBlockNumber();
  const arbBlock = await arbProvider.getBlockNumber();
  console.log(`  Ethereum: block ${ethBlock}`);
  console.log(`  Arbitrum: block ${arbBlock}`);

  const contractAddresses = [];
  const totalBatches = Math.ceil(addresses.length / BATCH_SIZE);

  for (let b = 0; b < totalBatches; b++) {
    const batch = addresses.slice(b * BATCH_SIZE, (b + 1) * BATCH_SIZE);

    const results = await Promise.allSettled(
      batch.map(async (address) => {
        const [ethCode, arbCode] = await Promise.all([
          withRetry(() => ethProvider.getCode(address)),
          withRetry(() => arbProvider.getCode(address))
        ]);
        const hasEthCode = ethCode && ethCode !== '0x';
        const hasArbCode = arbCode && arbCode !== '0x';
        return { address, isContract: hasEthCode || hasArbCode };
      })
    );

    for (const result of results) {
      if (result.status === 'fulfilled' && result.value.isContract) {
        contractAddresses.push(result.value.address.toLowerCase());
      } else if (result.status === 'rejected') {
        console.error(`  Error checking address: ${result.reason?.message}`);
      }
    }

    process.stdout.write(`\r  Batch ${b + 1}/${totalBatches} (${contractAddresses.length} contracts found)`);
  }

  console.log(`\nFound ${contractAddresses.length} addresses with contract code`);
  return contractAddresses;
}

/**
 * Main parser orchestrator that runs all parsers
 */
async function parseAllExportData(parseContracts) {
  console.log('Starting export data parsing...');
  console.log(`Include contracts: ${parseContracts}`);
  
  const results = {};
  let detectedContractAddresses = [];
  
  try {
    // Detect contract addresses once at the beginning if needed
    if (parseContracts) {
      console.log('\nDetecting contract addresses...');
      const fs = require('fs');
      const path = require('path');
      
      // Read export data to get all arbEOA addresses
      const siloData = JSON.parse(fs.readFileSync(path.join(__dirname, '../data/exports/beanstalk_silo.json')));
      const barnData = JSON.parse(fs.readFileSync(path.join(__dirname, '../data/exports/beanstalk_barn.json')));
      const fieldData = JSON.parse(fs.readFileSync(path.join(__dirname, '../data/exports/beanstalk_field.json')));
      
      const allArbEOAAddresses = [
        ...Object.keys(siloData.arbEOAs || {}),
        ...Object.keys(barnData.arbEOAs || {}),
        ...Object.keys(fieldData.arbEOAs || {})
      ];
      
      // Deduplicate addresses
      const uniqueArbEOAAddresses = [...new Set(allArbEOAAddresses)];
      
      // Detect which arbEOAs are actually contracts
      detectedContractAddresses = await detectContractAddresses(uniqueArbEOAAddresses);
      
      console.log(`Found ${detectedContractAddresses.length} contract addresses in arbEOAs that will be redirected to distributor`);
    }
    
    console.log('\nProcessing barn data...');
    results.barn = parseBarnData(parseContracts, detectedContractAddresses);
    
    console.log('Processing field data...');
    results.field = parseFieldData(parseContracts, detectedContractAddresses);
    
    console.log('Processing silo data...');
    results.silo = parseSiloData(parseContracts, detectedContractAddresses);
    
    console.log('Processing contract data...');
    results.contracts = await parseContractData(parseContracts, detectedContractAddresses);
    
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
 * Used in foundry fork tests for the shipments
 */
async function generateAddressFiles() {
  console.log('Generating address files from export data...');
  
  try {
    // Define excluded addresses that have almost 0 BDV and no other assets
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
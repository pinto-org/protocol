const parseBarnData = require('./parseBarnData');
const parseFieldData = require('./parseFieldData');
const parseSiloData = require('./parseSiloData');
const parseContractData = require('./parseContractData');

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
    
    // Parse contract data for ContractPaybackDistributor
    console.log('🏭 CONTRACT DISTRIBUTOR DATA');
    console.log('-'.repeat(30));
    results.contracts = parseContractData();
    
    console.log('📋 PARSING SUMMARY');
    console.log('-'.repeat(30));
    console.log(`📊 Barn: ${results.barn.stats.fertilizerIds} fertilizer IDs, ${results.barn.stats.accountEntries} account entries`);
    console.log(`📊 Field: ${results.field.stats.totalAccounts} accounts, ${results.field.stats.totalPlots} plots`);
    console.log(`📊 Silo: ${results.silo.stats.totalAccounts} accounts with BDV`);
    console.log(`📊 Contracts: ${results.contracts.stats.contractAccounts} accounts, ${results.contracts.stats.totalFertilizers} fertilizers, ${results.contracts.stats.totalPlots} plots`);
    console.log(`📊 Include contracts: ${parseContracts}`);
    
    return results;
  } catch (error) {
    console.error('Error during parsing:', error);
    throw error;
  }
}

// Export individual parsers and main function
module.exports = {
  parseBarnData,
  parseFieldData,
  parseSiloData,
  parseContractData,
  parseAllExportData
};
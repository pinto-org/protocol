const fs = require('fs');

/**
 * Extracts addresses from beanstalk field JSON and writes them to a file
 * @param {string} inputPath - Path to the beanstalk field JSON file
 * @param {string} outputPath - Path where to write the addresses file
 */
function extractAddressesFromFieldJson(inputPath, outputPath) {
  try {
    const fieldData = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
    const addresses = Object.keys(fieldData.arbEOAs);
    
    // Write addresses to file, one per line
    fs.writeFileSync(outputPath, addresses.join('\n') + '\n');
    
    console.log(`✅ Extracted ${addresses.length} addresses from field to ${outputPath}`);
    return addresses;
  } catch (error) {
    console.error('Error extracting addresses from field:', error);
    throw error;
  }
}

/**
 * Extracts addresses from silo JSON
 */
function extractAddressesFromSiloJson(inputPath, outputPath) {
  try {
    const siloData = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
    const addresses = Object.keys(siloData.arbEOAs);
    
    // Write addresses to file, one per line  
    fs.writeFileSync(outputPath, addresses.join('\n') + '\n');
    
    console.log(`✅ Extracted ${addresses.length} addresses from silo to ${outputPath}`);
    return addresses;
  } catch (error) {
    console.error('Error extracting addresses from silo:', error);
    throw error;
  }
}

/**
 * Extracts addresses from fertilizer JSON
 * Format: [[fertilizerIndex, [[account, balance, supply], ...]], ...]
 */
function extractAddressesFromFertilizerJson(inputPath, outputPath) {
  try {
    const fertilizerData = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
    const addressesSet = new Set();
    
    // Each entry is [fertilizerIndex, accountData[]]
    fertilizerData.forEach(([fertilizerIndex, accountDataArray]) => {
      // Each accountData is [account, balance, supply]
      accountDataArray.forEach(([account, balance, supply]) => {
        addressesSet.add(account);
      });
    });
    
    const addresses = Array.from(addressesSet);
    
    // Write addresses to file, one per line
    fs.writeFileSync(outputPath, addresses.join('\n') + '\n');
    
    console.log(`✅ Extracted ${addresses.length} unique addresses from fertilizer to ${outputPath}`);
    return addresses;
  } catch (error) {
    console.error('Error extracting addresses from fertilizer:', error);
    throw error;
  }
}

// If called directly, extract from all sources
if (require.main === module) {
  const baseDir = './scripts/beanstalkShipments/data';
  const exportsDir = `${baseDir}/exports`;
  
  // Create exports directory if it doesn't exist
  if (!fs.existsSync(exportsDir)) {
    fs.mkdirSync(exportsDir, { recursive: true });
  }
  
  // Extract field addresses
  extractAddressesFromFieldJson(
    `${exportsDir}/beanstalk_field.json`,
    `${exportsDir}/field_addresses.txt`
  );
  
  // Extract silo addresses
  extractAddressesFromSiloJson(
    `${exportsDir}/beanstalk_silo.json`,
    `${exportsDir}/silo_addresses.txt`
  );
  
  // Extract fertilizer addresses
  extractAddressesFromFertilizerJson(
    `${baseDir}/beanstalkAccountFertilizer.json`,
    `${exportsDir}/barn_addresses.txt`
  );
}

module.exports = {
  extractAddressesFromFieldJson,
  extractAddressesFromSiloJson,
  extractAddressesFromFertilizerJson
};
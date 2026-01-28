const fs = require("fs");
const { ethers } = require("ethers");

function findFertilizer(jsonFilePath, targetAccount) {
  // Load the JSON file
  const jsonData = JSON.parse(fs.readFileSync(jsonFilePath, "utf8"));

  const fertBalances = [];
  
  // Get the global beanBpf value to use as lastBpf for all fertilizers
  const globalBpf = BigInt(jsonData.beanBpf || "0");

  // Check if account exists in arbEOAs
  if (jsonData.arbEOAs && jsonData.arbEOAs[targetAccount]) {
    const accountData = jsonData.arbEOAs[targetAccount];
    
    // Check if account has beanFert data
    if (accountData.beanFert) {
      // Loop through each fertilizer ID and amount
      for (const [fertId, amount] of Object.entries(accountData.beanFert)) {
        fertBalances.push({
          fertId: BigInt(fertId),
          amount: BigInt(amount),
          lastBpf: globalBpf // Use the global beanBpf value
        });
      }
    }
  }

  // ABI encode the array of FertDepositData structs
  const encodedData = ethers.utils.defaultAbiCoder.encode(
    ["tuple(uint256 fertId, uint256 amount, uint256 lastBpf)[]"],
    [fertBalances]
  );

  return encodedData;
}

// Get the command line arguments
const args = process.argv.slice(2);
const jsonFilePath = args[0];
const account = args[1];

try {
  // Run the function and output the result
  const encodedFertilizerData = findFertilizer(jsonFilePath, account);
  console.log(encodedFertilizerData);
} catch (error) {
  // If there's an error or no data found, return empty encoded array
  const encodedData = ethers.utils.defaultAbiCoder.encode(
    ["tuple(uint256 fertId, uint256 amount, uint256 lastBpf)[]"],
    [[]]
  );
  console.log(encodedData);
}
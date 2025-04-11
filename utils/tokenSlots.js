const toBytes32 = (bn) => {
  return ethers.utils.hexlify(ethers.utils.zeroPad(bn.toHexString(), 32));
};

const setStorageAt = async (address, index, value) => {
  await ethers.provider.send("hardhat_setStorageAt", [address, index, value]);
  await ethers.provider.send("evm_mine", []); // Just mines to the next block
};

const getIndex = async (userAddress, balanceSlot) => {
  return ethers.utils.solidityKeccak256(
    ["uint256", "uint256"],
    [userAddress, balanceSlot] // key, slot
  );
};

const getNestedIndex = async (key1, key2, baseSlot) => {
  // First hash: key1 and baseSlot
  const initialHash = ethers.utils.solidityKeccak256(["uint256", "uint256"], [key1, baseSlot]);
  // Second hash: key2 and initialHash
  return ethers.utils.solidityKeccak256(["uint256", "uint256"], [key2, initialHash]);
};

async function setAllowanceAtSlot(
  tokenAddress,
  ownerAddress,
  spenderAddress,
  allowanceSlot,
  allowanceAmount,
  verbose = false
) {
  // Calculate the storage slot for the allowance for the given owner and spender
  const index = await getNestedIndex(ownerAddress, spenderAddress, allowanceSlot);
  // Set the storage at the calculated index
  await setStorageAt(tokenAddress, index.toString(), toBytes32(allowanceAmount).toString());
  if (verbose) {
    console.log(
      `Set allowance at slot ${allowanceSlot} for owner ${ownerAddress} and spender ${spenderAddress} to ${allowanceAmount}`
    );
  }
}

async function setBalanceAtSlot(tokenAddress, userAddress, balanceSlot, balance, verbose = false) {
  const index = await getIndex(userAddress, balanceSlot);
  await setStorageAt(tokenAddress, index.toString(), toBytes32(balance).toString());
  if (verbose) {
    console.log(`Set balance at slot ${balanceSlot} for user ${userAddress} to ${balance}`);
  }
}

exports.setBalanceAtSlot = setBalanceAtSlot;
exports.setAllowanceAtSlot = setAllowanceAtSlot;

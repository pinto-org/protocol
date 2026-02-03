/**
 * Analyze Shipment Contracts for Beanstalk Shipments
 *
 * Analyzes all addresses with Beanstalk assets to determine claimability on Base.
 * Detects contract types, Safe wallet versions, upgrades, and cross-chain deployability.
 *
 * Usage:
 *   node scripts/beanstalkShipments/analyzeShipmentContracts.js
 *
 * Required env vars (set in .env):
 *   - MAINNET_RPC
 *   - ARBITRUM_RPC
 *   - BASE_RPC
 */

require('dotenv').config();
const fs = require('fs');
const path = require('path');
const ethers = require('ethers');

const isEthersV6 = ethers.JsonRpcProvider !== undefined;
const createProvider = (url) => {
  if (isEthersV6) {
    return new ethers.JsonRpcProvider(url);
  } else {
    return new ethers.providers.JsonRpcProvider(url);
  }
};

const RPC_URLS = {
  ethereum: process.env.MAINNET_RPC,
  arbitrum: process.env.ARBITRUM_RPC,
  base: process.env.BASE_RPC
};

// Concurrency for parallel requests
const BATCH_SIZE = 30;
const MAX_RETRIES = 3;
const RETRY_DELAY = 1000;

// Known Safe singleton addresses (normalized to lowercase)
const SAFE_SINGLETONS = {
  '0xb6029ea3b2c51d09a50b53ca8012feeb05bda35a': '1.0.0',
  '0x34cfac646f301356faa8b21e94227e3583fe3f5f': '1.1.0',
  '0xae32496491b53841efb51829d6f886387708f99b': '1.1.1',
  '0x6851d6fdfafd08c0295c392436245e5bc78b0185': '1.2.0',
  '0xd9db270c1b5e3bd161e8c8503c55ceabee709552': '1.3.0',
  '0x3e5c63644e683549055b9be8653de26e0b4cd36e': '1.3.0-L2',
  '0x69f4d1788e39c87893c980c06edf4b7f686e2938': '1.3.0',
  '0x41675c099f32341bf84bfc5382af534df5c7461a': '1.4.1',
  '0x29fcb43b46531bca003ddc8fcb67ffe91900c762': '1.4.1-L2',
};

// Ambire known addresses
const AMBIRE_IDENTITIES = [
  '0x2a2b85eb1054d6f0c6c2e37da05ed3e5fea684ef',
  '0xf1822eb71b8f09ca07f10c4bebb064c36faf39bb',
];

// Safe ABI
const SAFE_ABI = [
  'function VERSION() view returns (string)',
  'function getThreshold() view returns (uint256)',
];

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

function parseVersion(version) {
  if (!version) return 0;
  const clean = version.replace('-L2', '').replace(/[^0-9.]/g, '');
  const parts = clean.split('.').map(Number);
  return parts[0] * 10000 + (parts[1] || 0) * 100 + (parts[2] || 0);
}

function isVersionClaimable(version) {
  return parseVersion(version) >= parseVersion('1.3.0');
}

// Binary search for the first block where the contract has code.
async function findDeploymentBlock(provider, address) {
  const currentBlock = await provider.getBlockNumber();
  let low = 0;
  let high = currentBlock;

  while (low < high) {
    const mid = Math.floor((low + high) / 2);
    const code = await provider.getCode(address, mid);
    if (code && code !== '0x') {
      high = mid;
    } else {
      low = mid + 1;
    }
  }

  const code = await provider.getCode(address, low);
  if (!code || code === '0x') return null;

  return low;
}

// Compare singleton at deployment vs current to detect upgrades.
// Safe proxies store the singleton in slot 0; changeMasterCopy() only updates slot 0.
async function detectSafeUpgrade(provider, address) {
  try {
    const currentSlot0 = await provider.getStorageAt(address, 0);
    const currentSingleton = '0x' + currentSlot0.slice(26).toLowerCase();

    const deployBlock = await findDeploymentBlock(provider, address);
    if (!deployBlock) return null;

    const originalSlot0 = await provider.getStorageAt(address, 0, deployBlock);
    const originalSingleton = '0x' + originalSlot0.slice(26).toLowerCase();

    const originalVersion = SAFE_SINGLETONS[originalSingleton] || null;
    const currentVersion = SAFE_SINGLETONS[currentSingleton] || null;
    const isUpgraded = currentSingleton !== originalSingleton;

    return {
      deployBlock,
      originalSingleton,
      originalVersion,
      currentSingleton,
      currentVersion,
      isUpgraded,
    };
  } catch (e) {
    return null;
  }
}

async function batchCheckSafeUpgrades(safeAddresses, providers) {
  const results = new Map();

  for (let i = 0; i < safeAddresses.length; i++) {
    const { address, chainName } = safeAddresses[i];
    const provider = providers[chainName];

    process.stdout.write(`\r  Checking ${i + 1}/${safeAddresses.length}: ${address.slice(0, 10)}...`);

    try {
      const upgrade = await detectSafeUpgrade(provider, address);
      if (upgrade) {
        results.set(address, {
          ...upgrade,
          isUpgraded: upgrade.isUpgraded && upgrade.originalVersion && !isVersionClaimable(upgrade.originalVersion)
        });
      }
    } catch (e) {}
  }

  process.stdout.write('\r' + ' '.repeat(80) + '\r');
  return results;
}

async function getCode(provider, address) {
  try {
    return await withRetry(async () => {
      const code = await provider.getCode(address);
      return code && code !== '0x' ? code : null;
    });
  } catch (e) {
    return { error: e.message };
  }
}

function detectEIP7702(code) {
  if (code && code.toLowerCase().startsWith('0xef0100')) {
    return {
      type: 'EIP-7702',
      delegateAddress: '0x' + code.slice(8, 48)
    };
  }
  return null;
}

function detectEIP1167Proxy(code) {
  if (!code) return null;
  const hex = code.slice(2).toLowerCase();
  if (hex.startsWith('363d3d373d3d3d363d73')) {
    const impl = '0x' + hex.slice(20, 60);
    return { implementation: impl.toLowerCase() };
  }
  return null;
}

function detectAmbire(code) {
  const proxy = detectEIP1167Proxy(code);
  if (proxy && AMBIRE_IDENTITIES.includes(proxy.implementation)) {
    return { implementation: proxy.implementation };
  }
  return null;
}

async function detectSafeVersion(provider, address, code) {
  try {
    const proxy = detectEIP1167Proxy(code);
    if (proxy && SAFE_SINGLETONS[proxy.implementation]) {
      return { version: SAFE_SINGLETONS[proxy.implementation], method: 'EIP-1167' };
    }

    try {
      const contract = new ethers.Contract(address, SAFE_ABI, provider);
      const version = await withRetry(async () => {
        const v = await contract.VERSION();
        await contract.getThreshold();
        return v;
      }, 2);
      return { version, method: 'VERSION()' };
    } catch (e) {}

    return null;
  } catch (e) {
    return null;
  }
}

async function analyzeAddressOnChain(provider, address, code) {
  const result = {
    isContract: false,
    type: null,
    details: null,
    error: null
  };

  if (code && code.error) {
    result.error = code.error;
    return result;
  }

  if (!code) {
    return result;
  }

  result.isContract = true;
  result.codeSize = (code.length - 2) / 2;

  const eip7702 = detectEIP7702(code);
  if (eip7702) {
    result.type = 'EIP-7702';
    result.details = eip7702;
    return result;
  }

  const ambire = detectAmbire(code);
  if (ambire) {
    result.type = 'Ambire';
    result.details = ambire;
    return result;
  }

  const safe = await detectSafeVersion(provider, address, code);
  if (safe) {
    result.type = 'Safe';
    result.details = safe;
    return result;
  }

  const proxy = detectEIP1167Proxy(code);
  if (proxy) {
    result.type = 'EIP-1167 Proxy';
    result.details = proxy;
    return result;
  }

  result.type = 'Unknown';
  result.details = { codePrefix: code.slice(0, 22) };
  return result;
}

async function analyzeAddressBatch(providers, addresses, addressInfoMap, errorAddresses) {
  const results = [];

  const codePromises = addresses.map(async (address) => {
    const codeResults = await Promise.allSettled([
      getCode(providers.ethereum, address),
      getCode(providers.arbitrum, address),
      getCode(providers.base, address)
    ]);

    return {
      address,
      ethCode: codeResults[0].status === 'fulfilled' ? codeResults[0].value : { error: codeResults[0].reason?.message },
      arbCode: codeResults[1].status === 'fulfilled' ? codeResults[1].value : { error: codeResults[1].reason?.message },
      baseCode: codeResults[2].status === 'fulfilled' ? codeResults[2].value : { error: codeResults[2].reason?.message }
    };
  });

  const codesSettled = await Promise.allSettled(codePromises);

  for (const codeResult of codesSettled) {
    if (codeResult.status === 'rejected') {
      const address = 'unknown';
      errorAddresses.push({ address, error: codeResult.reason?.message || 'Unknown error' });
      continue;
    }

    const { address, ethCode, arbCode, baseCode } = codeResult.value;

    try {
      const analysisResults = await Promise.allSettled([
        analyzeAddressOnChain(providers.ethereum, address, ethCode),
        analyzeAddressOnChain(providers.arbitrum, address, arbCode),
        analyzeAddressOnChain(providers.base, address, baseCode)
      ]);

      const ethereum = analysisResults[0].status === 'fulfilled'
        ? analysisResults[0].value
        : { isContract: false, type: null, details: null, error: analysisResults[0].reason?.message };
      const arbitrum = analysisResults[1].status === 'fulfilled'
        ? analysisResults[1].value
        : { isContract: false, type: null, details: null, error: analysisResults[1].reason?.message };
      const base = analysisResults[2].status === 'fulfilled'
        ? analysisResults[2].value
        : { isContract: false, type: null, details: null, error: analysisResults[2].reason?.message };

      const hasErrors = ethereum.error || arbitrum.error || base.error;
      if (hasErrors) {
        errorAddresses.push({
          address,
          errors: {
            ethereum: ethereum.error || null,
            arbitrum: arbitrum.error || null,
            base: base.error || null
          }
        });
      }

      results.push({
        address,
        info: addressInfoMap.get(address),
        chains: { ethereum, arbitrum, base },
        hasErrors
      });
    } catch (e) {
      errorAddresses.push({ address, error: e.message });
    }
  }

  return results;
}

function loadAllAddresses() {
  const dataDir = path.join(__dirname, 'data/exports');

  const siloData = JSON.parse(fs.readFileSync(path.join(dataDir, 'beanstalk_silo.json')));
  const fieldData = JSON.parse(fs.readFileSync(path.join(dataDir, 'beanstalk_field.json')));
  const barnData = JSON.parse(fs.readFileSync(path.join(dataDir, 'beanstalk_barn.json')));

  const allAddresses = new Map();

  const addAddress = (addr, source, category, assets) => {
    const normalized = addr.toLowerCase();
    if (!allAddresses.has(normalized)) {
      allAddresses.set(normalized, {
        sources: [],
        categories: new Set(),
        assets: { silo: null, field: null, barn: null }
      });
    }
    const entry = allAddresses.get(normalized);
    if (!entry.sources.includes(source)) entry.sources.push(source);
    entry.categories.add(category);
    if (source === 'silo') entry.assets.silo = assets;
    if (source === 'field') entry.assets.field = assets;
    if (source === 'barn') entry.assets.barn = assets;
  };

  for (const [addr, data] of Object.entries(siloData.arbEOAs || {})) addAddress(addr, 'silo', 'arbEOA', data);
  for (const [addr, data] of Object.entries(siloData.arbContracts || {})) addAddress(addr, 'silo', 'arbContract', data);
  for (const [addr, data] of Object.entries(siloData.ethContracts || {})) addAddress(addr, 'silo', 'ethContract', data);

  for (const [addr, data] of Object.entries(fieldData.arbEOAs || {})) addAddress(addr, 'field', 'arbEOA', data);
  for (const [addr, data] of Object.entries(fieldData.arbContracts || {})) addAddress(addr, 'field', 'arbContract', data);
  for (const [addr, data] of Object.entries(fieldData.ethContracts || {})) addAddress(addr, 'field', 'ethContract', data);

  for (const [addr, data] of Object.entries(barnData.arbEOAs || {})) addAddress(addr, 'barn', 'arbEOA', data);
  for (const [addr, data] of Object.entries(barnData.arbContracts || {})) addAddress(addr, 'barn', 'arbContract', data);
  for (const [addr, data] of Object.entries(barnData.ethContracts || {})) addAddress(addr, 'barn', 'ethContract', data);

  return allAddresses;
}

function determineClaimability(analysis, upgradeInfo) {
  const { ethereum, arbitrum, base } = analysis.chains;

  const isContractOnEthOrArb = ethereum.isContract || arbitrum.isContract;
  const isContractOnBase = base.isContract;

  if (!isContractOnEthOrArb) {
    return { canClaim: true, reason: 'EOA', category: 'eoa' };
  }

  if (isContractOnBase) {
    return { canClaim: true, reason: 'Already on Base', category: 'onBase' };
  }

  if (ethereum.type === 'EIP-7702' || arbitrum.type === 'EIP-7702') {
    return { canClaim: true, reason: 'EIP-7702 (private key)', category: 'eip7702' };
  }

  if (ethereum.type === 'Ambire' || arbitrum.type === 'Ambire') {
    return { canClaim: true, reason: 'Ambire (CREATE2 deploy)', category: 'ambire' };
  }

  const safeDetails = ethereum.details || arbitrum.details;
  if (ethereum.type === 'Safe' || arbitrum.type === 'Safe') {
    if (safeDetails) {
      const version = safeDetails.version;

      if (isVersionClaimable(version) && upgradeInfo) {
        const upgrade = upgradeInfo.get(analysis.address);
        if (upgrade && upgrade.isUpgraded) {
          return {
            canClaim: false,
            reason: `Safe ${version} (upgraded from ${upgrade.originalVersion})`,
            category: 'upgradedSafe'
          };
        }
      }

      if (isVersionClaimable(version)) {
        return {
          canClaim: true,
          reason: `Safe ${version} (cross-chain deploy)`,
          category: 'claimableSafe'
        };
      }
      return {
        canClaim: false,
        reason: `Safe ${version} (too old for cross-chain)`,
        category: 'oldSafe'
      };
    }
  }

  const contractType = ethereum.type || arbitrum.type || 'Unknown';
  return {
    canClaim: false,
    reason: `${contractType} contract`,
    category: 'unknownContract'
  };
}

async function main() {
  console.log('Analyzing Shipment Contracts for Beanstalk');
  console.log('='.repeat(60) + '\n');

  const missingRpcs = Object.entries(RPC_URLS).filter(([, url]) => !url).map(([name]) => name);
  if (missingRpcs.length > 0) {
    console.error(`Missing RPC URLs in .env: ${missingRpcs.map(n => n === 'ethereum' ? 'MAINNET_RPC' : n === 'arbitrum' ? 'ARBITRUM_RPC' : 'BASE_RPC').join(', ')}`);
    process.exit(1);
  }

  console.log('Connecting to networks...');
  const providers = {
    ethereum: createProvider(RPC_URLS.ethereum),
    arbitrum: createProvider(RPC_URLS.arbitrum),
    base: createProvider(RPC_URLS.base)
  };

  for (const [name, provider] of Object.entries(providers)) {
    try {
      const block = await provider.getBlockNumber();
      console.log(`  ${name}: block ${block}`);
    } catch (e) {
      console.error(`  ${name}: FAILED - ${e.message}`);
      process.exit(1);
    }
  }

  console.log('\nLoading addresses from export files...');
  const allAddresses = loadAllAddresses();
  const addressList = Array.from(allAddresses.keys());
  console.log(`  Found ${addressList.length} unique addresses\n`);

  console.log(`Analyzing addresses (batch size: ${BATCH_SIZE})...\n`);

  const allResults = [];
  const errorAddresses = [];
  const startTime = Date.now();

  for (let i = 0; i < addressList.length; i += BATCH_SIZE) {
    const batch = addressList.slice(i, i + BATCH_SIZE);
    const batchNum = Math.floor(i / BATCH_SIZE) + 1;
    const totalBatches = Math.ceil(addressList.length / BATCH_SIZE);

    process.stdout.write(`\r  Batch ${batchNum}/${totalBatches} (${Math.round((i + batch.length) / addressList.length * 100)}%)...`);

    try {
      const results = await analyzeAddressBatch(providers, batch, allAddresses, errorAddresses);
      allResults.push(...results);
    } catch (e) {
      console.error(`\n  Batch ${batchNum} failed: ${e.message}`);
      for (const addr of batch) {
        errorAddresses.push({ address: addr, error: `Batch failed: ${e.message}` });
      }
    }

    if (i + BATCH_SIZE < addressList.length) {
      await new Promise(r => setTimeout(r, 1000));
    }
  }

  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  console.log(`\n  Completed in ${elapsed}s`);
  if (errorAddresses.length > 0) {
    console.log(`  ${errorAddresses.length} addresses had errors\n`);
  } else {
    console.log('');
  }

  // Check Safe wallets showing >= 1.3.0 for upgrades from older versions
  const safesToCheck = [];
  for (const result of allResults) {
    const { ethereum, arbitrum, base } = result.chains;
    if (base.isContract) continue;

    for (const chainName of ['ethereum', 'arbitrum']) {
      const chain = result.chains[chainName];
      if (chain.type === 'Safe' && chain.details && isVersionClaimable(chain.details.version)) {
        safesToCheck.push({ address: result.address, chainName });
        break;
      }
    }
  }

  let upgradeInfo = new Map();
  if (safesToCheck.length > 0) {
    console.log(`Checking ${safesToCheck.length} Safe wallet(s) for upgrades...`);
    upgradeInfo = await batchCheckSafeUpgrades(safesToCheck, providers);
    const upgradedCount = Array.from(upgradeInfo.values()).filter(v => v.isUpgraded).length;
    if (upgradedCount > 0) {
      console.log(`  Found ${upgradedCount} upgraded Safe wallet(s) (originally < 1.3.0)`);
    } else {
      console.log('  No upgraded Safe wallets detected');
    }
    console.log('');
  }

  const stats = {
    total: allResults.length,
    claimable: { eoa: 0, onBase: 0, eip7702: 0, ambire: 0, claimableSafe: 0 },
    unclaimable: { oldSafe: 0, upgradedSafe: 0, unknownContract: 0 }
  };

  const unclaimableContracts = [];
  const claimableContracts = [];
  const eip7702Addresses = [];

  for (const result of allResults) {
    const claimability = determineClaimability(result, upgradeInfo);
    result.claimability = claimability;

    const info = result.info;
    const contractData = {
      address: result.address,
      sources: info.sources,
      categories: Array.from(info.categories),
      claimability,
      chains: result.chains,
      assets: {
        hasSilo: info.assets.silo !== null,
        hasField: info.assets.field !== null,
        hasBarn: info.assets.barn !== null,
        siloBdv: info.assets.silo?.bdvAtRecapitalization?.total || '0'
      }
    };

    const upgrade = upgradeInfo.get(result.address);
    if (upgrade) {
      contractData.upgradeInfo = upgrade;
    }

    if (claimability.canClaim) {
      if (claimability.category === 'eoa') {
        stats.claimable.eoa++;
      } else {
        stats.claimable[claimability.category]++;
        claimableContracts.push(contractData);

        if (claimability.category === 'eip7702') {
          eip7702Addresses.push(contractData);
        }
      }
    } else {
      stats.unclaimable[claimability.category]++;
      unclaimableContracts.push(contractData);
    }
  }

  unclaimableContracts.sort((a, b) => {
    if (a.claimability.category !== b.claimability.category) {
      return a.claimability.category.localeCompare(b.claimability.category);
    }
    return a.address.localeCompare(b.address);
  });

  const outputPath = path.join(__dirname, 'data/shipmentContractAnalysis.json');
  const output = {
    generatedAt: new Date().toISOString(),
    description: 'Analysis of contracts for Beanstalk Shipments claimability on Base',
    stats,
    errorCount: errorAddresses.length,
    unclaimableContracts,
    claimableContracts,
    eip7702Addresses,
    errorAddresses: errorAddresses.length > 0 ? errorAddresses : undefined
  };

  fs.writeFileSync(outputPath, JSON.stringify(output, null, 2));

  const eip7702Path = path.join(__dirname, 'data/eip7702Addresses.json');
  const eip7702List = eip7702Addresses.map(e => e.address).sort();
  fs.writeFileSync(eip7702Path, JSON.stringify(eip7702List, null, 2) + '\n');

  const unclaimablePath = path.join(__dirname, 'data/unclaimableContractAddresses.json');
  const unclaimableList = unclaimableContracts.map(e => e.address).sort();
  fs.writeFileSync(unclaimablePath, JSON.stringify(unclaimableList, null, 2) + '\n');

  console.log('='.repeat(60));
  console.log('ANALYSIS COMPLETE\n');

  console.log('Claimable:');
  console.log(`  EOAs: ${stats.claimable.eoa}`);
  console.log(`  Already on Base: ${stats.claimable.onBase}`);
  console.log(`  EIP-7702 (private key): ${stats.claimable.eip7702}`);
  console.log(`  Ambire (CREATE2): ${stats.claimable.ambire}`);
  console.log(`  Safe >= 1.3.0 (cross-chain): ${stats.claimable.claimableSafe}`);

  console.log('\nUnclaimable (need special handling):');
  console.log(`  Old Safe (< 1.3.0): ${stats.unclaimable.oldSafe}`);
  console.log(`  Upgraded Safe (originally < 1.3.0): ${stats.unclaimable.upgradedSafe}`);
  console.log(`  Unknown contracts: ${stats.unclaimable.unknownContract}`);

  const totalUnclaimable = Object.values(stats.unclaimable).reduce((a, b) => a + b, 0);
  console.log(`\nTotal unclaimable: ${totalUnclaimable}`);

  if (errorAddresses.length > 0) {
    console.log(`\nErrors: ${errorAddresses.length} addresses failed to analyze`);
  }

  console.log(`\nResults written to: ${outputPath}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Error:', error);
    process.exit(1);
  });

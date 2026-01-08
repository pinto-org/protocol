# Well Deployment Guide

This guide explains how to deploy upgradeable Wells using the Pinto protocol's deployment scripts and tasks.

## Overview

Wells are liquidity pools deployed via the Basin protocol's Aquifer factory. The Pinto protocol uses **upgradeable Wells** that combine:

1. **WellUpgradeable** - Base implementation contract
2. **ERC1967Proxy** - Upgradeable proxy pattern for each well
3. **Aquifer** - Factory for deploying wells with CREATE2
4. **Well Function** - Pricing curve (ConstantProduct2 or Stable2)
5. **MultiFlowPump** - Time-weighted average price oracle

## Architecture

```
┌─────────────────┐
│  ERC1967Proxy   │  ← User-facing well address (CREATE2 via CreateX)
│   (Well Token)  │
└────────┬────────┘
         │ delegates to
         ▼
┌─────────────────┐
│ WellUpgradeable │  ← Well clone (CREATE2 via Aquifer)
│   Implementation│
└─────────────────┘

Well Components:
- Tokens: [Bean, NonBeanToken]
- Well Function: ConstantProduct2 or Stable2
- Pump: MultiFlowPump (price oracle)
- CREATE2 Factories: Aquifer (well clone) + CreateX (proxy)
```

## Methods

### Method 1: Using Standard Well Deployment (Easiest)

Deploy a well using the standard Base network infrastructure with minimal parameters:

```bash
npx hardhat deployStandardWell \
  --non-bean-token 0x4200000000000000000000000000000000000006 \
  --well-function CP2 \
  --name "PINTO:WETH Constant Product 2 Well" \
  --symbol "U-PINTOWETHCP2w" \
  --network base
```

This automatically uses:
- Bean: `0xb170000aeeFa790fa61D6e837d1035906839a3c8`
- Aquifer: `0xBA51AA60B3b8d9A36cc748a62Aa56801060183f8`
- Well Implementation: `0xBA510990a720725Ab1F9a0D231F045fc906909f4`
- Pump: `0xBA51AAaA66DaB6c236B356ad713f759c206DcB93`
- Standard pump configuration

**Well Function Shorthand (case-insensitive):**
- `CP2` or `cp2` = ConstantProduct2 (x * y = k curve)
- `S2` or `s2` = Stable2 (StableSwap curve for similar assets)
- Full names also work: `constantProduct2`, `stable2`

**For Stable2 wells (stablecoins):**

```bash
npx hardhat deployStandardWell \
  --non-bean-token 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  --well-function S2 \
  --name "PINTO:USDC Stable 2 Well" \
  --symbol "U-PINTOUSDCS2w" \
  --network base
```

> **Note**: For S2 wells, the well function data (token decimals) is **automatically fetched and encoded** from the token contracts. You don't need to provide `--well-function-data` unless you want to override the auto-detected values.

**Programmatic usage:**

```javascript
const { deployStandardWell } = require("./utils/wellDeployment");

// CP2 well (no wellFunctionData needed)
const wethWell = await deployStandardWell({
  nonBeanToken: "0x4200000000000000000000000000000000000006",
  wellFunction: "CP2",
  salt: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MY-WETH-WELL")),
  name: "PINTO:WETH Well",
  symbol: "PINTOWETH",
  deployer,
  verbose: true
});

// S2 well (decimals auto-detected from tokens)
const usdcWell = await deployStandardWell({
  nonBeanToken: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  wellFunction: "S2",
  salt: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MY-USDC-WELL")),
  name: "PINTO:USDC Well",
  symbol: "PINTOUSDC",
  deployer,
  verbose: true
});
```

### Method 2: Using the Script

Deploy wells using the main script with a JSON configuration file:

```bash
npx hardhat run scripts/deployWell.js --network base
```

The script will:
- Load configuration from `scripts/deployment/parameters/input/deploymentParams.json`
- Deploy all wells defined in the config
- Save deployment results to `./deployments/`

#### Custom Configuration File

```bash
WELL_CONFIG_PATH=./my-wells.json npx hardhat run scripts/deployWell.js --network base
```

#### Override Bean Address

```bash
BEAN_ADDRESS=0xb170000aeeFa790fa61D6e837d1035906839a3c8 npx hardhat run scripts/deployWell.js --network base
```

### Method 3: Using Hardhat Tasks

#### Deploy a Single Well

```bash
npx hardhat deployWell \
  --bean 0xb170000aeeFa790fa61D6e837d1035906839a3c8 \
  --non-bean-token 0x4200000000000000000000000000000000000006 \
  --aquifer 0xBA51AA60B3b8d9A36cc748a62Aa56801060183f8 \
  --well-implementation 0xBA510990a720725Ab1F9a0D231F045fc906909f4 \
  --well-function 0xBA510C289fD067EBbA41335afa11F0591940d6fe \
  --pump 0xBA51AAaA66DaB6c236B356ad713f759c206DcB93 \
  --pump-data 0x3ffefd29d6deab9c... \
  --name "PINTO:WETH Constant Product 2 Well" \
  --symbol "U-PINTOWETHCP2w" \
  --network base
```

#### Deploy Multiple Wells from Config

```bash
npx hardhat deployWellsFromConfig \
  --config ./scripts/deployment/parameters/input/deploymentParams.json \
  --network base
```

### Method 4: Programmatic Usage

Use the deployment utilities in your own scripts:

```javascript
const { deployUpgradeableWells } = require("./utils/wellDeployment");

const beanAddress = "0xb170000aeeFa790fa61D6e837d1035906839a3c8";
const wellsData = [
  {
    nonBeanToken: "0x4200000000000000000000000000000000000006",
    wellImplementation: "0xBA510990a720725Ab1F9a0D231F045fc906909f4",
    wellFunctionTarget: "0xBA510C289fD067EBbA41335afa11F0591940d6fe",
    wellFunctionData: "0x",
    aquifer: "0xBA51AA60B3b8d9A36cc748a62Aa56801060183f8",
    pump: "0xBA51AAaA66DaB6c236B356ad713f759c206DcB93",
    pumpData: "0x3ffefd29d6deab9c...",
    salt: "0xd1a0d188e861ed9d15773a2f3574a2e94134ba8f41c1de71aa9cede63741a8da",
    name: "PINTO:WETH Constant Product 2 Well",
    symbol: "U-PINTOWETHCP2w"
  }
];

const [deployer] = await ethers.getSigners();
const results = await deployUpgradeableWells(beanAddress, wellsData, deployer, true);

console.log(`Deployed well at: ${results[0].proxyAddress}`);
```

## Configuration Format

### Full Configuration Example

```json
{
  "wellComponents": {
    "wellUpgradeableImplementation": "0xBA510990a720725Ab1F9a0D231F045fc906909f4",
    "aquifer": "0xBA51AA60B3b8d9A36cc748a62Aa56801060183f8",
    "pump": "0xBA51AAaA66DaB6c236B356ad713f759c206DcB93",
    "pumpData": "0x3ffefd29d6deab9ccdef2300d0c1c903..."
  },
  "whitelistData": {
    "tokens": ["0xb170000aeeFa790fa61D6e837d1035906839a3c8"]
  },
  "wells": [
    {
      "nonBeanToken": "0x4200000000000000000000000000000000000006",
      "wellFunctionTarget": "0xBA510C289fD067EBbA41335afa11F0591940d6fe",
      "wellFunctionData": "0x",
      "salt": "0xd1a0d188e861ed9d15773a2f3574a2e94134ba8f41c1de71aa9cede63741a8da",
      "name": "PINTO:WETH Constant Product 2 Upgradeable Well",
      "symbol": "U-PINTOWETHCP2w"
    }
  ]
}
```

### Component Addresses (Base Mainnet)

```javascript
// Well Infrastructure
WellUpgradeable Implementation: 0xBA510990a720725Ab1F9a0D231F045fc906909f4
Aquifer (Well Clone Factory): 0xBA51AA60B3b8d9A36cc748a62Aa56801060183f8
CreateX (Proxy Factory): 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
MultiFlowPump: 0xBA51AAaA66DaB6c236B356ad713f759c206DcB93

// Well Functions
ConstantProduct2: 0xBA510C289fD067EBbA41335afa11F0591940d6fe
Stable2: 0xBA51055a97b40d7f41f3F64b57469b5D45B67c87

// Tokens
Bean (PINTO): 0xb170000aeeFa790fa61D6e837d1035906839a3c8
WETH: 0x4200000000000000000000000000000000000006
cbETH: 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22
cbBTC: 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
wSOL: 0x1C61629598e4a901136a81BC138E5828dc150d67
```

## Pump Data Encoding

The `pumpData` parameter configures the MultiFlowPump oracle. It's a hex-encoded struct:

```solidity
struct PumpData {
    bytes16 alpha;                    // Smoothing factor
    uint256 capInterval;              // Cap interval in seconds
    CapReservesParameters capReserves; // Max rate changes and LP supply limits
}
```

Example encoding (from deploymentParams.json):
```
0x3ffefd29d6deab9ccdef2300d0c1c903000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000603ffd0000000000000000000000000000000000000000000000000000000000003ffd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003ffd00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000023ffd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
```

## Well Function Data

### ConstantProduct2 (CP2)

No data needed:
```json
{
  "wellFunctionTarget": "0xBA510C289fD067EBbA41335afa11F0591940d6fe",
  "wellFunctionData": "0x"
}
```

### Stable2 (S2)

**Auto-generated** when using `deployStandardWell()`:
- The function automatically fetches decimals from both token contracts
- Encodes them as `abi.encode(uint256(beanDecimals), uint256(nonBeanDecimals))`
- No manual encoding required!

**Manual encoding** (if needed for non-standard deployment):
```json
{
  "wellFunctionTarget": "0xBA51055a97b40d7f41f3F64b57469b5D45B67c87",
  "wellFunctionData": "0x00000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000006"
}
```

This encodes: `abi.encode(uint256(6), uint256(6))` for PINTO (6 decimals) and USDC (6 decimals).

**To manually encode:**
```javascript
const wellFunctionData = ethers.utils.defaultAbiCoder.encode(
  ["uint256", "uint256"],
  [6, 6] // [beanDecimals, nonBeanDecimals]
);
```

## Salt Generation

Wells use CREATE2 deployment for deterministic addresses at **two levels**:

### 1. Well Clone Salt (`wellSalt`)
Determines the well implementation clone address deployed via Aquifer:
- **Default**: `0x0000...0010` (shared across similar wells)
- **Custom**: Generate unique salt per well to avoid collisions

### 2. Proxy Salt (`proxySalt`)
Determines the ERC1967Proxy address deployed via CreateX:
- **Required**: Must be unique per well
- **Recommended**: Use descriptive hash for reproducibility

```javascript
// Example: Generate unique salts
const wellSalt = ethers.utils.keccak256(
  ethers.utils.toUtf8Bytes("PINTO:WETH-Well-Clone")
);

const proxySalt = ethers.utils.keccak256(
  ethers.utils.toUtf8Bytes("PINTO:WETH-Proxy-v1")
);
```

**Important**: Both salts together determine the final well addresses. If you get a CREATE2 collision, change either salt (or both).

## Deployment Output

### Console Output

```
========================================
Deploying Well 1/1
========================================

Deploying upgradeable well: PINTO:WETH Constant Product 2 Upgradeable Well
Tokens: 0xb170000aeeFa790fa61D6e837d1035906839a3c8, 0x4200000000000000000000000000000000000006
Well Function: 0xBA510C289fD067EBbA41335afa11F0591940d6fe
Aquifer: 0xBA51AA60B3b8d9A36cc748a62Aa56801060183f8
Well Implementation: 0xBA510990a720725Ab1F9a0D231F045fc906909f4
Base well deployed at: 0x1234...
Deploying proxy at: 0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3
✅ Proxy deployed at: 0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3
Well Name: PINTO:WETH Constant Product 2 Upgradeable Well
Well Symbol: U-PINTOWETHCP2w
```

### JSON Output

Saved to `./deployments/wells-base-{timestamp}.json`:

```json
{
  "network": "base",
  "deployer": "0x...",
  "timestamp": "2024-01-15T12:00:00.000Z",
  "beanAddress": "0xb170000aeeFa790fa61D6e837d1035906839a3c8",
  "wellComponents": { ... },
  "wells": [
    {
      "proxyAddress": "0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3",
      "implementationAddress": "0x1234...",
      "name": "PINTO:WETH Constant Product 2 Upgradeable Well",
      "symbol": "U-PINTOWETHCP2w",
      "nonBeanToken": "0x4200000000000000000000000000000000000006"
    }
  ]
}
```

## Verification

Verify deployed wells on Basescan:

```bash
npx hardhat verifyWellDeployment \
  --proxy 0x3e11001CfbB6dE5737327c59E10afAB47B82B5d3 \
  --implementation 0x1234... \
  --name "PINTO:WETH Constant Product 2 Upgradeable Well" \
  --symbol "U-PINTOWETHCP2w" \
  --network base
```

## Whitelisting Wells in Beanstalk

After deployment, wells must be whitelisted in Beanstalk's Silo to enable deposits. This is done via diamond upgrade with `InitWells.sol` or separately via governance.

See `contracts/beanstalk/init/deployment/InitWells.sol:143-199` for whitelist logic.

## Troubleshooting

### "Configuration file not found"

Ensure the config path is correct:
```bash
WELL_CONFIG_PATH=./scripts/deployment/parameters/input/deploymentParams.json
```

### "Bean address not found"

Either:
1. Set `BEAN_ADDRESS` environment variable
2. Include Bean in `whitelistData.tokens[0]` in config

### "Deployer has no ETH balance"

Fund the deployer account with ETH on the target network.

### CREATE2 Address Mismatch

The proxy address is deterministic based on:
- Deployer address
- Salt value
- Constructor arguments

If redeploying, use a different salt.

## References

- **InitWells.sol**: `contracts/beanstalk/init/deployment/InitWells.sol`
- **LibWellDeployer.sol**: `contracts/libraries/Basin/LibWellDeployer.sol`
- **Utils**: `utils/wellDeployment.js`
- **Script**: `scripts/deployWell.js`
- **Tasks**: `tasks/well-deployment.js`
- **Basin Docs**: https://docs.basin.exchange

## Security Notes

⚠️ **Important**:
- Wells are **upgradeable** via ERC1967Proxy
- Only the Beanstalk owner can upgrade well implementations
- Verify all addresses before deployment
- Use unique salts for each well
- Test on testnet before mainnet deployment
- Ensure sufficient deployer balance for gas

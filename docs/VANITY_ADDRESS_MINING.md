# Vanity Address Mining for Wells

This guide explains how to mine for vanity addresses when deploying Wells.

## Overview

When deploying an upgradeable well, two addresses are created:

1. **Well Implementation** - Deployed via Aquifer using CREATE2
2. **Proxy** - Deployed via CreateX using CREATE2

Both can have vanity addresses by mining for the right salt value.

## CREATE2 Proxy Mining

The proxy address is determined by:

- Deployer address (either CreateX factory or InitDeployAndWhitelistWell contract)
- Salt (32 bytes)
- Init code (proxy bytecode + constructor args)

### Deployment Methods

There are two ways to deploy the proxy:

1. **Via InitDeployAndWhitelistWell contract** (recommended for Beanstalk integration):
   - The InitDeployAndWhitelistWell contract deploys the proxy using `new ERC1967Proxy{salt: proxySalt}(...)`
   - Use `--deployer <InitDeployAndWhitelistWell_ADDRESS>` to mine salts for this method

2. **Via CreateX factory** (standalone deployments):
   - CreateX deploys the proxy using its CREATE2 factory
   - Use `--createx <CREATEX_ADDRESS>` or `--deployer <CREATEX_ADDRESS>`

**IMPORTANT**: The deployer address affects the resulting proxy address! Make sure to use the same deployer address when mining and deploying.

### Quick Start

```bash
# Mine for InitDeployAndWhitelistWell deployment (recommended)
npx hardhat mineProxySalt \
  --prefix BEEF \
  --implementation 0xYourImplementationAddress \
  --name "PINTO:WETH Well" \
  --symbol "PINTOWETH" \
  --deployer 0xYourInitDeployAndWhitelistWellAddress

# Mine for CreateX deployment (legacy/standalone)
npx hardhat mineProxySalt \
  --prefix BEEF \
  --implementation 0xYourImplementationAddress \
  --name "PINTO:WETH Well" \
  --symbol "PINTOWETH" \
  --createx 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed

# Specify number of worker threads (default: auto-detect CPU cores)
npx hardhat mineProxySalt \
  --prefix BEEF \
  --implementation 0xYourImplementationAddress \
  --name "PINTO:WETH Well" \
  --symbol "PINTOWETH" \
  --deployer 0xYourDeployerAddress \
  --num-workers 8

# Check difficulty before mining
npx hardhat mineProxySalt \
  --prefix DEADBEEF \
  --implementation 0xYourImplementationAddress \
  --name "PINTO:WETH Well" \
  --symbol "PINTOWETH" \
  --deployer 0xYourDeployerAddress \
  --estimate-only
```

### Options

```bash
--prefix <hex>              # Desired address prefix (required, no 0x)
--implementation <address>  # Well implementation address (required)
--name <string>            # Well name for init call (required)
--symbol <string>          # Well symbol for init call (required)
--deployer <address>       # Address that will deploy the proxy (required for InitDeployAndWhitelistWell)
--createx <address>        # CreateX factory address (deprecated, use --deployer) (default: Base CreateX)
--num-workers <number>     # Number of worker threads (default: auto-detect CPU cores)
--max-iterations <number>  # Max attempts for single-threaded mode (default: 1,000,000)
--case-sensitive           # Enable case-sensitive matching (matches checksummed addresses)
--estimate-only            # Show difficulty without mining
```

**Note**: By default, the miner uses multi-threaded mode with all available CPU cores for maximum performance. Use `--max-iterations` to force single-threaded mode, or `--num-workers` to control thread count.

### Case-Sensitive Matching

When using `--case-sensitive`, the miner matches against checksummed Ethereum addresses (EIP-55). This allows you to create addresses with specific capitalization patterns:

```bash
# Match "CaFe" exactly (will be much harder than case-insensitive)
npx hardhat mineProxySalt \
  --prefix CaFe \
  --implementation 0x... \
  --name "My Well" \
  --symbol "WELL" \
  --case-sensitive

# Case-insensitive "cafe" (matches cafe, CaFe, CAFE, etc.)
npx hardhat mineProxySalt \
  --prefix cafe \
  --implementation 0x... \
  --name "My Well" \
  --symbol "WELL"
```

**Note**: Case-sensitive matching is ~22x harder per character since each hex letter can be uppercase or lowercase (6 letters × 2 cases = 12, plus 10 digits = 22 possibilities per position vs. 16 for case-insensitive).

### Examples

```bash
# Basic 4-character prefix
npx hardhat mineProxySalt \
  --prefix FEED \
  --implementation 0xa6Ef458c8b51Aa1D1A1A4f0c3B06f37F5BEe7f93 \
  --name "PINTO:WETH Well" \
  --symbol "PINTOWETH"

# Longer prefix with more iterations
npx hardhat mineProxySalt \
  --prefix CAFEB \
  --implementation 0xa6Ef458c8b51Aa1D1A1A4f0c3B06f37F5BEe7f93 \
  --name "PINTO:WETH Well" \
  --symbol "PINTOWETH" \
  --max-iterations 5000000

# Just check if it's feasible
npx hardhat mineProxySalt \
  --prefix CAFEBABE \
  --implementation 0xa6Ef458c8b51Aa1D1A1A4f0c3B06f37F5BEe7f93 \
  --name "PINTO:WETH Well" \
  --symbol "PINTOWETH" \
  --estimate-only
```

### Difficulty Guide

| Prefix Length | Difficulty | Expected Time\* | Example  |
| ------------- | ---------- | --------------- | -------- |
| 1-2 chars     | Very Easy  | < 1 second      | `BE`     |
| 3 chars       | Easy       | < 5 seconds     | `BEE`    |
| 4 chars       | Medium     | 1-2 minutes     | `BEEF`   |
| 5 chars       | Hard       | 15-30 minutes   | `CAFEF`  |
| 6+ chars      | Very Hard  | Hours to days   | `CAFEBE` |

\*Multi-threaded on 8-core CPU at ~800k attempts/second. Single-threaded: ~100k attempts/second.

### Using in Deployment

Once you find a salt, use it in your deployment config:

```javascript
const result = await deployUpgradeableWell({
  tokens: [beanAddress, wethAddress],
  wellFunction: { target: cp2Address, data: "0x" },
  pumps: [{ target: pumpAddress, data: pumpData }],
  aquifer: aquiferAddress,
  wellImplementation: wellImplAddress,
  wellSalt: "0x0000...0010", // For implementation (covered in part 2)
  proxySalt: "0xa1b2c3d4...", // Your mined salt!
  name: "PINTO:WETH Well",
  symbol: "PINTOWETH",
  deployer: signer
});
```

## Well Implementation Mining

Mining for the well implementation address is more complex than proxy mining because:

- It uses Aquifer's `boreWell()` with CREATE2
- The salt is combined with `msg.sender` to prevent frontrunning
- The address depends on the immutable data (tokens, well function, pumps)
- Prediction requires calling `aquifer.predictWellAddress()` on-chain

### How It Works

The well miner uses a clever technique:

1. **Deploy Helper Contract**: Deploys `WellAddressMiner.sol` temporarily
2. **Bytecode Overwrite**: Uses `hardhat_setCode` to overwrite the sender address with the helper contract bytecode
3. **Batch Mining**: Calls `batchMineAddressCaseInsensitive()` on the helper contract to test multiple salts in one call
4. **On-Chain Prediction**: Each batch call tests multiple salts using `aquifer.predictWellAddress()`

This approach is much faster than calling `predictWellAddress()` separately for each salt.

### Quick Start

```bash
# Mine for a well implementation address (uses defaults for Bean, pump, etc.)
npx hardhat mineWellSalt \
  --prefix BEA \
  --aquifer 0xYourAquiferAddress \
  --implementation 0xYourWellImplAddress \
  --sender 0xYourDeployerAddress \
  --non-bean-token 0xWETHAddress \
  --well-function 0xCP2Address

# Specify batch size for performance tuning
npx hardhat mineWellSalt \
  --prefix BEA \
  --aquifer 0xYourAquiferAddress \
  --implementation 0xYourWellImplAddress \
  --sender 0xYourDeployerAddress \
  --non-bean-token 0xWETHAddress \
  --well-function 0xCP2Address \
  --batch-size 50

# Check difficulty before mining
npx hardhat mineWellSalt \
  --prefix BEANWETH \
  --aquifer 0xYourAquiferAddress \
  --implementation 0xYourWellImplAddress \
  --sender 0xYourDeployerAddress \
  --non-bean-token 0xWETHAddress \
  --well-function 0xCP2Address \
  --estimate-only
```

### Options

```bash
--prefix <hex>                # Desired address prefix (required, no 0x)
--aquifer <address>           # Aquifer factory address (required)
--implementation <address>    # Well implementation address (required)
--sender <address>            # Deployer address (msg.sender) (required)
--non-bean-token <address>    # Non-Bean token address (required*)
--well-function <address>     # Well function address (required*)
--well-function-data <hex>    # Well function data (default: 0x)
--bean <address>              # Bean token address (default: Base Bean)
--pump <address>              # Pump address (default: Base pump)
--pump-data <hex>             # Pump data (default: Base pump data)
--immutable-data <hex>        # Pre-encoded immutable data (alternative to individual params)
--batch-size <number>         # Salts to test per batch (default: 20)
--case-sensitive              # Enable case-sensitive matching
--estimate-only               # Show difficulty without mining
```

\*Required unless `--immutable-data` is provided

### Performance Notes

**Batch Size**: Controls how many salts are tested per on-chain call

- **Smaller (10-20)**: More frequent progress updates, easier to interrupt
- **Larger (50-100)**: Fewer RPC calls, potentially faster overall
- **Default (20)**: Good balance for most cases

**Mining Rate**: Much slower than proxy mining (~100 attempts/second) due to:

- On-chain `predictWellAddress()` calls required
- RPC overhead for each batch
- Cannot be parallelized effectively (depends on RPC node)

### Difficulty Guide

| Prefix Length | Difficulty | Expected Time\* | Example |
| ------------- | ---------- | --------------- | ------- |
| 1-2 chars     | Easy       | < 30 seconds    | `BE`    |
| 3 chars       | Medium     | 1-5 minutes     | `BEA`   |
| 4 chars       | Hard       | 30-90 minutes   | `BEAN`  |
| 5+ chars      | Very Hard  | Hours to days   | `BEANW` |

\*At ~100 attempts/second via RPC. Much slower than proxy mining!

### Examples

```bash
# Basic BEAN prefix
npx hardhat mineWellSalt \
  --prefix BEA \
  --aquifer 0xBA51AAAA95FD4cb0BBE0fbA7AECc4DE8e034C569 \
  --implementation 0xa6Ef458c8b51Aa1D1A1A4f0c3B06f37F5BEe7f93 \
  --sender 0xYourAddress \
  --non-bean-token 0x4200000000000000000000000000000000000006 \
  --well-function 0xBA510C20FD2c52E4cb0d23CFC3cCD092F9165a6E

# With custom pump configuration
npx hardhat mineWellSalt \
  --prefix BEA \
  --aquifer 0xBA51AAAA95FD4cb0BBE0fbA7AECc4DE8e034C569 \
  --implementation 0xa6Ef458c8b51Aa1D1A1A4f0c3B06f37F5BEe7f93 \
  --sender 0xYourAddress \
  --non-bean-token 0x4200000000000000000000000000000000000006 \
  --well-function 0xBA510C20FD2c52E4cb0d23CFC3cCD092F9165a6E \
  --pump 0xCustomPumpAddress \
  --pump-data 0xCustomData

# Using pre-encoded immutable data
npx hardhat mineWellSalt \
  --prefix BEA \
  --aquifer 0xBA51AAAA95FD4cb0BBE0fbA7AECc4DE8e034C569 \
  --implementation 0xa6Ef458c8b51Aa1D1A1A4f0c3B06f37F5BEe7f93 \
  --sender 0xYourAddress \
  --immutable-data 0xYourEncodedData
```

### Using in Deployment

Once you find a salt, use it in your well deployment:

```javascript
const result = await deployUpgradeableWell({
  tokens: [beanAddress, wethAddress],
  wellFunction: { target: cp2Address, data: "0x" },
  pumps: [{ target: pumpAddress, data: pumpData }],
  aquifer: aquiferAddress,
  wellImplementation: wellImplAddress,
  wellSalt: "0xa1b2c3d4...", // Your mined salt!
  proxySalt: "0x1234...", // From proxy mining
  name: "PINTO:WETH Well",
  symbol: "PINTOWETH",
  deployer: signer
});
```

### Important Notes

**Sender Address Matters**: The well implementation address depends on `msg.sender`. You MUST:

- Use the same sender address when mining and deploying
- Verify the sender will have the same address on mainnet (not behind a proxy that could change)

**Immutable Data**: The address depends on:

- Token addresses (sorted order)
- Well function address and data
- Pump addresses and data

Any change to these parameters changes the resulting address!

**Testing Required**: Always test the deployment on testnet first with your mined salt to verify the address matches.

## Tips & Tricks

### Choosing a Good Prefix

- **Brand identity**: Use protocol name (e.g., `PINT`, `BEAN`)
- **Token pairs**: Use token symbols (e.g., `WETH`, `USDC`)
- **Well type**: Indicate function (e.g., `CP2`, `STAB`)
- **Sequential**: Number your wells (e.g., `0001`, `0002`)

### Optimization

- **Case insensitive** (default) is ~22x easier than case sensitive
- **Shorter is better** - Each additional character is 16x harder
- **Multi-threading** (default) - Proxy mining automatically uses all CPU cores
- **Parallel mining** - Run multiple instances with different prefixes for even faster results
- **Start simple** - Test with 2-3 char prefix first
- **Proxy vs Well** - Proxy mining is 8-10x faster than well implementation mining

### Common Patterns

```bash
# Token pair prefix
PREFIX=WETH npx hardhat run scripts/mineProxySalt.js

# Protocol branding
PREFIX=PINT npx hardhat run scripts/mineProxySalt.js

# Well number/sequence
PREFIX=0001 npx hardhat run scripts/mineProxySalt.js

# Well type indicator
PREFIX=CP2 npx hardhat run scripts/mineProxySalt.js
```

## Understanding CREATE2

The CREATE2 address formula:

```
address = keccak256(0xff ++ deployerAddress ++ salt ++ keccak256(initCode))
```

Where:

- `deployerAddress` = CreateX factory
- `salt` = Your mined 32-byte value
- `initCode` = Proxy bytecode + encoded constructor args

This is deterministic - same inputs always produce the same address.

## Security Notes

- **Salt uniqueness**: Each salt can only be used once per init code
- **Frontrunning protection**: CreateX doesn't add sender to salt (unlike Aquifer)
- **Verification**: Always verify the computed address matches expectations
- **Testing**: Test on testnet first with your found salt

## Programmatic Usage

### Proxy Mining (Multi-threaded)

```javascript
const { mineProxySalt, estimateDifficulty } = require("../utils/mineProxySalt");

// Check difficulty
const estimate = estimateDifficulty("BEEF", false);
console.log(`Expected time: ${estimate.expectedTime}`);

// Mine for salt with InitDeployAndWhitelistWell (multi-threaded, default)
const result = await mineProxySalt({
  implementationAddress: "0x...",
  initCalldata: "0x...",
  deployerAddress: "0x...", // InitDeployAndWhitelistWell or CreateX address
  prefix: "BEEF",
  numWorkers: 8, // Optional: defaults to CPU core count
  caseSensitive: false,
  onProgress: ({ iterations, elapsed, rate }) => {
    console.log(
      `${iterations.toLocaleString()} attempts in ${elapsed.toFixed(1)}s at ${rate.toLocaleString()}/sec`
    );
  }
});

// Backward compatible: still accepts createXAddress
const resultLegacy = await mineProxySalt({
  implementationAddress: "0x...",
  initCalldata: "0x...",
  createXAddress: "0x...", // Deprecated but still works
  prefix: "BEEF",
  caseSensitive: false
});

if (result) {
  console.log(`Found! Salt: ${result.salt}`);
  console.log(`Address: ${result.address}`);
  console.log(`Iterations: ${result.iterations}`);
}
```

### Proxy Mining (Single-threaded)

```javascript
// Force single-threaded mode by providing maxIterations
const result = mineProxySalt({
  implementationAddress: "0x...",
  initCalldata: "0x...",
  deployerAddress: "0x...", // Use deployerAddress (new) or createXAddress (deprecated)
  prefix: "BEEF",
  maxIterations: 1000000, // Forces single-threaded
  caseSensitive: false,
  onProgress: ({ iterations, elapsed, rate }) => {
    console.log(`${iterations} attempts at ${rate}/sec`);
  }
});
```

### Well Implementation Mining

```javascript
const { mineWellSalt } = require("../utils/mineWellSalt");

// Mine for well implementation address
const result = await mineWellSalt({
  aquifer: "0x...",
  implementation: "0x...",
  sender: "0x...", // Your deployer address
  bean: "0x...",
  nonBeanToken: "0x...",
  wellFunctionTarget: "0x...",
  wellFunctionData: "0x",
  pumpTarget: "0x...",
  pumpData: "0x...",
  prefix: "BEA",
  batchSize: 20, // Salts to test per batch
  caseSensitive: false,
  onProgress: ({ iterations, elapsed, rate, batchCount }) => {
    console.log(`${iterations} attempts | ${batchCount} batches | ${rate}/sec`);
  }
});

if (result) {
  console.log(`Found! Salt: ${result.salt}`);
  console.log(`Well Address: ${result.address}`);
}
```

## Troubleshooting

### Proxy Mining Issues

**No match found after max iterations**

- Try a shorter prefix
- Switch to multi-threaded mode (default) or increase `--num-workers`
- Consider case-insensitive matching

**Mining is too slow**

- Ensure multi-threaded mode is enabled (default)
- Check CPU usage - should be using all cores
- Consider running multiple instances with different prefixes simultaneously

**Address doesn't match in actual deployment**

- **CRITICAL**: Ensure deployer address is correct - it directly affects the result!
  - For InitDeployAndWhitelistWell deployment: use the init contract address
  - For CreateX deployment: use the CreateX factory address
- Ensure init calldata exactly matches (name, symbol must be identical)
- Check that implementation address hasn't changed

**Deployer address confusion**

- If deploying via `InitDeployAndWhitelistWell.sol`, use `--deployer <INIT_CONTRACT_ADDRESS>`
- If deploying via CreateX standalone, use `--createx <CREATEX_ADDRESS>` or `--deployer <CREATEX_ADDRESS>`
- The deployer MUST be the contract that executes `new ERC1967Proxy{salt: ...}(...)`

### Well Mining Issues

**Mining is very slow**

- Well mining requires on-chain calls and is inherently slower (~100 attempts/sec)
- Increase `--batch-size` to reduce RPC overhead (try 50-100)
- Use shorter prefixes (3-4 characters max)
- Consider mining proxy address instead if possible

**Address doesn't match in actual deployment**

- Verify sender address is exactly the same
- Check that immutable data matches (tokens, well function, pumps)
- Ensure token addresses are in the same order
- Test on testnet first

**RPC errors or timeouts**

- Reduce `--batch-size` to put less load on RPC
- Use a different RPC endpoint
- Add delays between batches if needed

## Architecture & Implementation Details

### Proxy Mining Architecture

**Multi-threaded (Default)**:

- Uses Node.js `worker_threads` to parallelize mining
- Each worker generates random salts independently
- First worker to find a match stops all others
- Scales linearly with CPU cores (8 cores ≈ 8x faster)
- Implementation: `utils/mineProxySalt.js` + `utils/mineProxySaltWorker.js`

**Single-threaded**:

- Legacy mode for compatibility
- Useful for debugging or low-memory environments
- Activated by providing `--max-iterations` parameter

### Well Mining Architecture

**Batch Mining with Helper Contract**:

1. Deploys `WellAddressMiner.sol` helper contract
2. Uses `hardhat_setCode` to overwrite sender address with helper bytecode
3. Helper contract provides `batchMineAddressCaseInsensitive()` function
4. Each batch tests N salts by incrementing from a random starting point
5. Uses on-chain `aquifer.predictWellAddress()` for accurate prediction
6. Reverts if no match, allowing efficient batch processing

**Why This Approach**:

- **Accuracy**: Uses same `predictWellAddress()` as actual deployment
- **Efficiency**: Batches multiple attempts into single RPC call
- **Frontrunning Protection**: Respects Aquifer's `msg.sender` salt mixing
- **Fork Testing**: Works on local Hardhat forks for safe testing

### File Structure

```
utils/
├── mineProxySalt.js          # Main proxy miner (multi & single-threaded)
├── mineProxySaltWorker.js    # Worker thread for parallel proxy mining
└── mineWellSalt.js           # Well implementation miner

contracts/test/
└── WellAddressMiner.sol      # On-chain helper for batch well mining

tasks/
└── well-deployment.js        # Hardhat tasks integrating the miners
```

## Next Steps

### For Proxy Address Mining:

1. Mine your desired proxy salt using `mineProxySalt`
2. Use multi-threaded mode for best performance (default)
3. Use it in your well deployment configuration
4. Deploy and verify the address matches

### For Well Implementation Mining:

1. Determine your well parameters (tokens, well function, pumps)
2. Mine your desired well salt using `mineWellSalt`
3. Use the same sender address for mining and deployment
4. Test on testnet first to verify address matches
5. Deploy on mainnet with confidence

### Full Vanity Deployment:

1. Mine proxy salt first (faster, easier)
2. Mine well implementation salt (slower, but more visible)
3. Use both salts in `deployUpgradeableWell()`
4. Get addresses like `0xBEA...` (implementation) and `0xFEED...` (proxy)

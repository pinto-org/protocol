# Pinto Protocol Codebase Guide

## Quick Navigation for AI Agents

### 🎯 Most Important Files
```
contracts/beanstalk/facets/sun/SeasonFacet.sol    # Main entry point - sunrise()
contracts/beanstalk/storage/AppStorage.sol        # Core state structure
contracts/libraries/LibEvaluate.sol               # Protocol health evaluation
contracts/libraries/LibCases.sol                  # 144 weather cases
contracts/beanstalk/facets/sun/abstract/Sun.sol   # Minting/burning logic
```

### 🏗️ Architecture Patterns

#### Diamond Proxy (EIP-2535)
- **Main Contract**: `contracts/beanstalk/Diamond.sol`
- **Storage**: Shared via `AppStorage` struct
- **Facets**: Modular functionality in `contracts/beanstalk/facets/`
- **Libraries**: Pure functions in `contracts/libraries/`

#### State Management
```solidity
// Access global state anywhere
AppStorage storage s = LibAppStorage.diamondStorage();

// Common state access patterns
s.sys.season.current           // Current season number
s.sys.weather.temp            // Interest rate for sowing
s.sys.soil                    // Available debt capacity
s.sys.fields[fieldId]         // Field-specific data
```

### 🔄 Economic Flow

#### Season Advancement (Every Hour)
1. `SeasonFacet.sunrise()` - Anyone can call
2. `Oracle.stepOracle()` - Capture price data  
3. `Weather.calcCaseIdAndHandleRain()` - Evaluate state
4. `Sun.stepSun()` - Mint/burn based on price

#### Price Discovery Chain
```
Wells (DEX pools) → LibDeltaB → LibEvaluate → LibCases → Weather adjustments
```

### 🧪 Testing Patterns

#### Foundry Tests
```bash
forge test --match-test testSunrise          # Season tests
forge test --match-contract SeasonTest       # Specific contract
forge test --fork-url $RPC --match-test test # Fork testing
```

#### Test Structure
- `test/foundry/` - Foundry tests (preferred for protocol logic)
- `test/hardhat/` - Hardhat tests (integration tests)
- Fork tests at specific block numbers for consistency

### 🛠️ Development Workflow

#### Common Commands
```bash
forge build                    # Compile contracts
forge test                     # Run all tests
forge test --gas-report        # Gas usage analysis
forge coverage                 # Test coverage
yarn test                      # Hardhat tests
```

#### Code Patterns
- Always use `LibAppStorage.diamondStorage()` for state access
- Include events for state changes
- Use `SafeCast` for type conversions
- Follow existing naming conventions (`calc*`, `step*`, `update*`)

### 📊 Key Metrics to Monitor

#### Protocol Health
- **Pod Rate**: `pods / beanSupply` (debt ratio)
- **L2SR**: Liquidity to Supply Ratio
- **Temperature**: Interest rate for Pod purchases
- **DeltaB**: Beans needed to reach $1 peg

#### State Variables
```solidity
s.sys.season.current              // Season number
s.sys.weather.temp               // Current temperature (interest rate)
s.sys.seedGauge.beanToMaxLpGpPerBdvRatio  // Bean vs LP incentives
s.sys.silo.stalk                 // Total governance power
```

### 🔍 Debugging Tips

#### Common Issues
- **Oracle failures**: Check Well reserves and pump data
- **Case ID errors**: Verify evaluation parameters are within bounds
- **Minting failures**: Check global and per-well maximum constraints
- **Permission errors**: Ensure proper Diamond proxy setup

#### Useful View Functions
```solidity
// Protocol state
getBeanstalkState()              // Current evaluation metrics
getCurrentTemp()                 // Active interest rate
getSoil()                       // Available debt capacity

// Silo information  
balanceOfStalk(account)         // User's governance power
getDeposit(account, token, stem) // Specific deposit details
```

### 🚨 Security Considerations

#### Access Control
- Diamond proxy uses `onlyOwner` for critical functions
- Some functions restricted to specific contracts
- Emergency pause functionality via `PauseFacet`

#### Economic Safety
- Maximum mint limits (absolute and percentage-based)
- Oracle manipulation protection via time-weighted averages
- Gradual adjustments to prevent system shock

### 📈 Gas Optimization

#### Expensive Operations
- Season advancement (complex multi-step process)
- Silo operations with many deposits
- Convert operations (token swaps)

#### Optimization Patterns
- Batch operations when possible
- Use events instead of returning large data
- Cache frequently accessed state variables
- Minimize external calls within loops

This guide should help AI agents quickly understand and navigate the Pinto protocol codebase effectively.
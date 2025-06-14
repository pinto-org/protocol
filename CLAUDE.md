# Pinto Protocol - AI Agent Guide

## Overview

Pinto is an algorithmic stablecoin protocol that creates endogenous money called "Bean" with a $1 price target. It's based on the Beanstalk protocol and uses sophisticated economic mechanisms to maintain price stability without relying on external collateral.

## Core Concepts

### What is Pinto?
- **Algorithmic stablecoin**: Maintains $1 peg through code, not collateral
- **Endogenous money**: Value comes from protocol's own mechanisms, not external backing
- **Credit-based system**: Like a decentralized central bank with algorithmic monetary policy
- **Dual-token model**: Bean (stablecoin) + Pod (debt instrument)

### Key Components

#### 1. Seasons (Economic Cycles)
- **Duration**: 1 hour periods
- **Function**: Economic adjustments happen each season
- **Trigger**: Anyone can call `sunrise()` to advance the season
- **Location**: `contracts/beanstalk/facets/sun/SeasonFacet.sol`

#### 2. Price Stability Mechanisms

**Above Peg (Price > $1)**:
- Mint new Beans and distribute to stakeholders
- Issue Soil (debt capacity) for future expansion
- Increase supply to push price down

**Below Peg (Price < $1)**:
- Issue Soil allowing users to burn Beans for Pods
- Reduce supply by incentivizing Bean burning
- Pod holders get future Bean claims

#### 3. State Evaluation System
The protocol evaluates health across multiple metrics:
- **Pod Rate**: Debt level relative to Bean supply
- **L2SR**: Liquidity to Supply Ratio
- **DeltaB**: Beans needed to reach $1 peg
- **Soil Demand**: Speed of debt instrument purchases

#### 4. Weather System (144 Cases)
Based on state evaluation, selects one of 144 predefined cases that determine:
- **Temperature**: Interest rate for burning Beans
- **Bean-to-LP Ratio**: Relative rewards structure
- **Location**: `contracts/libraries/LibCases.sol`

#### 5. Cultivation Factor
Dynamic scaling (1%-100%) for soil issuance based on:
- Previous season demand
- Pod rate levels
- Protocol performance
- **Location**: `contracts/beanstalk/facets/sun/GaugeFacet.sol`

## Architecture

### Key Contracts Structure
```
contracts/
├── beanstalk/
│   ├── storage/
│   │   ├── AppStorage.sol     # Main state storage
│   │   └── System.sol         # System-level state
│   ├── facets/
│   │   ├── sun/
│   │   │   ├── SeasonFacet.sol      # Season advancement
│   │   │   ├── GaugeFacet.sol       # Cultivation factor
│   │   │   └── abstract/
│   │   │       ├── Sun.sol          # Minting/soil logic
│   │   │       ├── Weather.sol      # Temperature control
│   │   │       └── Oracle.sol       # Price discovery
│   │   ├── silo/                    # Staking system
│   │   └── field/                   # Debt system
│   └── Diamond.sol            # EIP-2535 Diamond proxy
├── libraries/
│   ├── LibEvaluate.sol        # State evaluation
│   ├── LibCases.sol           # Weather cases
│   └── Oracle/
│       └── LibDeltaB.sol      # Price calculation
└── tokens/
    └── Bean.sol               # The stablecoin
```

### Diamond Pattern (EIP-2535)
- Uses diamond proxy pattern for upgradability
- Multiple facets share single storage
- Allows modular functionality upgrades

## Economic Mechanisms

### Silo (Staking System)
- **Purpose**: Long-term Bean holding incentives
- **Rewards**: Stalk (governance) + Seeds (compound growth)
- **Effect**: Reduces selling pressure, stabilizes price

### Field (Debt System)
- **Sowing**: Burn Beans for Pods (debt instruments)
- **Harvesting**: Redeem mature Pods for new Beans
- **Temperature**: Dynamic interest rate (morning auction)

### Wells (Liquidity Pools)
- Integration with Basin DEX protocol
- Multi-market price discovery
- Liquidity incentives for deep markets

## Key Libraries and Functions

### Price Discovery
- `LibDeltaB.overallCurrentDeltaB()`: Calculate beans needed for peg
- `LibWellMinting.getTotalInstantaneousDeltaB()`: Instant price check
- Time-weighted averages prevent manipulation

### State Evaluation
- `LibEvaluate.evaluateBeanstalk()`: Main evaluation function
- Returns caseId (0-144) based on current state
- Considers pod rate, L2SR, deltaB, soil demand

### Weather/Temperature
- `LibCases.getDataFromCase()`: Get adjustments for caseId
- Temperature affects sowing interest rates
- Bean-to-LP ratio affects reward distribution

### Minting/Burning
- `Sun.stepSun()`: Core supply adjustment logic
- `BeanstalkERC20.mint()`: Create new Beans when above peg
- Soil issuance for Bean burning when below peg

## Understanding the Codebase

### State Variables (AppStorage)
- `s.sys.season`: Current season info
- `s.sys.weather`: Temperature and soil data
- `s.sys.silo`: Staking balances and rewards
- `s.sys.fields`: Debt and Pod data

### Common Patterns
- Most economic logic in abstract contracts under `facets/sun/abstract/`
- Libraries for complex calculations
- Events for state changes
- SafeMath/casting for numerical operations

### Testing
- Hardhat tests in `test/hardhat/`
- Foundry tests in `test/foundry/`  
- Fork testing against mainnet state

## Development Notes

### Build Commands
```bash
forge build        # Compile contracts
yarn test          # Run Hardhat tests
forge test         # Run Foundry tests
```

### Key Constants (C.sol)
- `CURRENT_SEASON_PERIOD`: 3600 seconds (1 hour)
- `PRECISION`: 1e18 for mathematical operations
- `GLOBAL_ABSOLUTE_MAX`: 800,000 Beans max issuance

### Oracle Integration
- Chainlink price feeds for USD values
- Basin Well reserves for Bean price
- Time-weighted averages for stability

This protocol represents a sophisticated attempt at creating decentralized, algorithmic money that maintains stability through economic incentives rather than collateral backing.
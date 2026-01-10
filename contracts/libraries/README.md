# Libraries

This directory contains shared libraries used across the Pinto Protocol.

## Overview

Libraries provide reusable logic for mathematical operations, storage management, and protocol-specific calculations. They are designed to be stateless and called via `delegatecall` or as internal functions.

## Categories

### Storage Libraries

| Library | Description |
|---------|-------------|
| `LibAppStorage` | Access to the shared `AppStorage` struct |
| `LibDiamond` | Diamond storage and facet management |

### Math Libraries

Located in `Math/`:
- `LibRedundantMath256` - Safe math operations
- Various mathematical utilities for precision calculations

### Protocol Libraries

| Library | Description |
|---------|-------------|
| `LibDibbler` | Field sowing mechanics |
| `LibEvaluate` | Evaluation functions for protocol state |
| `LibGauge` | Gauge system calculations |
| `LibGaugeHelpers` | Helper functions for gauge operations |

### Silo Libraries

Located in `Silo/`:
- Deposit and withdrawal logic
- Stalk and Seed calculations
- Germination mechanics

### Convert Libraries

Located in `Convert/`:
- Conversion calculations between Silo assets
- Lambda convert functions

### Token Libraries

| Library | Description |
|---------|-------------|
| `LibBytes` | Byte manipulation utilities |
| `LibBytes64` | 64-bit byte operations |
| `Token/` | Token transfer and balance utilities |

### Oracle Libraries

Located in `Oracle/`:
- Price oracle integrations
- TWAP calculations

### Utility Libraries

| Library | Description |
|---------|-------------|
| `LibClipboard` | Data encoding for Farm calls |
| `LibFarm` | Farm operation utilities |
| `LibFunction` | Function selector utilities |
| `LibCases` | Protocol case handling |

## Usage

Libraries are typically imported and used in facets:

```solidity
import {LibSilo} from "contracts/libraries/Silo/LibSilo.sol";

contract SiloFacet {
    function deposit(address token, uint256 amount) external {
        LibSilo._deposit(msg.sender, token, amount);
    }
}
```

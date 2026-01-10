# Pipeline

This directory contains Pipeline contracts for composable protocol interactions.

## Overview

Pipeline is a utility contract that enables chaining multiple protocol calls in a single transaction. It allows users to compose complex operations by "piping" data between calls.

## Key Features

- **Call Composition**: Chain multiple contract calls together
- **Data Passing**: Pass output from one call as input to the next
- **Gas Efficiency**: Execute multiple operations in a single transaction
- **Flexibility**: Interact with any external protocol

## Usage

Pipeline integrates with the protocol through the `DepotFacet`, allowing users to:

1. Execute external calls to other protocols
2. Compose Pinto operations with DeFi integrations
3. Build complex farming strategies

## Integration

Pipeline is commonly used with:
- **Farm**: Combine Farm operations with external calls
- **Tractor**: Automate complex multi-step operations
- **Conversions**: Execute conversions through external DEXs

## Example

```solidity
// Compose a swap and deposit in one transaction
depot.pipe([
    // Swap ETH for Bean on an external DEX
    encodeSwap(ETH, BEAN, amount),
    // Deposit the received Beans into the Silo
    encodeDeposit(BEAN, receivedAmount)
]);
```

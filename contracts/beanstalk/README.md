# Beanstalk Core

This directory contains the core protocol contracts implementing the Pinto Diamond.

## Overview

Pinto inherits its architecture from Beanstalk and uses the EIP-2535 Diamond pattern. The Diamond serves as the main entry point, delegating calls to various facets based on function selectors.

## Directory Structure

| Directory | Description |
|-----------|-------------|
| `facets/` | Modular contract facets implementing protocol functionality |
| `init/` | Initialization contracts for protocol upgrades |
| `storage/` | Storage layout contracts defining `AppStorage` |

## Key Contracts

| Contract | Description |
|----------|-------------|
| `Diamond.sol` | Main Diamond proxy contract, entry point for all protocol interactions |
| `Invariable.sol` | Invariant checks to ensure protocol safety |
| `ReentrancyGuard.sol` | Reentrancy protection for protocol functions |

## Facets

Facets are organized by functionality:

- **diamond/**: Core Diamond operations (DiamondCut, DiamondLoupe, Ownership)
- **farm/**: Token operations, Depot, Farm actions, Tractor automation
- **field/**: Field mechanics for sowing and harvesting Pods
- **market/**: Pod Marketplace for trading Pods
- **metadata/**: NFT metadata for deposit tokens
- **silo/**: Silo deposits, withdrawals, conversions, and rewards
- **sun/**: Season advancement, gauges, oracles, and incentives

## Storage

The protocol uses a single `AppStorage` struct shared across all facets, ensuring consistent state management.

## Initialization

`init/` contracts handle state migrations during protocol upgrades (e.g., `InitPI1.sol` through `InitPI13.sol` for Protocol Improvements).

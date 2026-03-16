# Contracts

This directory contains all smart contracts for the Pinto Protocol.

## Overview

Pinto is a low-volatility money protocol with a $1 price target, built using the EIP-2535 Diamond pattern for modular upgradability.

## Directory Structure

| Directory | Description |
|-----------|-------------|
| `beanstalk/` | Core protocol contracts including Diamond, facets, storage, and initializers |
| `ecosystem/` | Peripheral contracts for oracles, price feeds, and integrations |
| `interfaces/` | Solidity interfaces for all protocol contracts |
| `libraries/` | Shared libraries for math, storage, and utility functions |
| `mocks/` | Mock contracts used for testing |
| `pipeline/` | Pipeline contracts for composing protocol interactions |
| `tokens/` | Token contracts including the Bean ERC20 token |

## Key Files

| File | Description |
|------|-------------|
| `C.sol` | Protocol constants and configuration values |

## Architecture

The protocol uses EIP-2535 (Diamond Standard) which allows:
- **Modular Upgrades**: Individual facets can be upgraded without redeploying the entire contract
- **Unlimited Contract Size**: Circumvents the 24KB contract size limit
- **Shared Storage**: All facets share common storage through `AppStorage`

## Getting Started

See the [main README](../README.md) for build and test instructions.

## Documentation

- [Pinto Docs](https://docs.pinto.money)
- [EIP-2535 Diamond Standard](https://eips.ethereum.org/EIPS/eip-2535)

# Ecosystem

This directory contains peripheral ecosystem contracts that support the Pinto Protocol.

## Overview

Ecosystem contracts provide supporting infrastructure for the core protocol, including price oracles, gauge point calculations, and external integrations.

## Directory Structure

| Directory | Description |
|-----------|-------------|
| `gaugePoints/` | Gauge point calculation contracts |
| `junction/` | Junction contracts for multi-protocol integration |
| `oracles/` | Oracle implementations for price feeds |
| `price/` | Price calculation contracts |
| `tractor/` | Tractor automation utilities |

## Key Contracts

| Contract | Description |
|----------|-------------|
| `ShipmentPlanner.sol` | Plans and coordinates shipments of newly minted Beans |

## Price Contracts

The `price/` directory contains contracts for calculating Bean price across liquidity pools:
- `BeanstalkPrice.sol`: Main price aggregation contract
- `WellPrice.sol`: Price calculations for Well liquidity pools

## Oracles

Oracle contracts provide manipulation-resistant price data for protocol operations including:
- Minting calculations
- Silo reward distribution
- Gauge weight adjustments

## Gauge Points

Gauge point contracts calculate the distribution of incentives across different Silo assets based on protocol-defined criteria.

## Tractor

Tractor utilities enable automated operations like recurring deposits, conversions, and other protocol interactions.

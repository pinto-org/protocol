# Tokens

This directory contains token contracts for the Pinto Protocol.

## Overview

Pinto's primary token is Bean (PINTO), a low-volatility ERC20 token with a $1 price target.

## Directory Structure

| Directory/File | Description |
|----------------|-------------|
| `Bean.sol` | Main Bean token contract |
| `ERC20/` | ERC20 base implementations and extensions |

## Bean Token

The Bean token (`Bean.sol`) is the core stablecoin of the Pinto Protocol. Key features:

- **Price Target**: $1 USD
- **Low Volatility**: Peg stability through credit-based mechanisms
- **Minting**: Controlled by the protocol during Seasons
- **Burning**: Occurs during certain protocol operations

## ERC20 Extensions

The `ERC20/` directory contains ERC20 implementations with additional features required by the protocol:
- Permit functionality (EIP-2612)
- Protocol-specific access controls
- Integration with the Diamond architecture

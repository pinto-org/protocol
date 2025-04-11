[discord-badge]: https://img.shields.io/discord/1308123512216748105?label=Pinto%20Discord
[discord-url]: https://pinto.money/discord

<img src="https://github.com/user-attachments/assets/862c01d8-38cb-4149-9c47-ac2399a4b71f" alt="pinto logo" width="120" />

# Pinto

[![Discord][discord-badge]][discord-url]

Pinto is low volatility money built on Base.

Code Version: `1.0.0` <br>
Whitepaper Version: `1.0.0`

## Documentation

- [GitBook](https://docs.pinto.money)
- [Whitepaper](https://pinto.money/pinto.pdf)

## Audits

Pinto inherits significant audit coverage from Beanstalk. Prior Beanstalk audits can be found [here](https://github.com/BeanstalkFarms/Beanstalk-Audits). A list of changes in Pinto can be found [here](https://docs.pinto.money/resources/audits).

## Contracts

A comprehensive list of deployed contract addresses related to Pinto is available [here](https://docs.pinto.money/resources/contracts).

## Repository

This directory contains the code for the core Pinto protocol, including its contracts, interfaces, ecosystem contracts and tests.

## EIP-2535 Diamond

The Pinto contract is a multi-facet proxy that implements [EIP-2535](https://eips.ethereum.org/EIPS/eip-2535). Thus, the Pinto contract implements functionality from multiple different Facet contracts that all share a common storage.

- [Pinto on Louper, The Ethereum Diamond Inspector (LINK TBD)](https://louper.dev/diamond/TBD)

## Quickstart

### Setup

1. Clone the repository, enter root directory
2. Install dependencies

```bash
yarn install
```

3. Build contracts

```bash
foundryup
forge install foundry-rs/forge-std --no-commit
forge build
```

### Testing

#### Hardhat

1. Ensure you are in the root directory
2. Have a [FORKING_RPC](https://hardhat.org/hardhat-network/docs/guides/forking-other-networks) as an [environment variable](https://www.npmjs.com/package/dotenv) pointing to ETH Mainnet.
   1. _We fork ETH Mainnet to run our test suite locally. Note, this will make a large number of API calls to your `FORKING_RPC`_
3. Run all tests

```bash
yarn test
```

#### Foundry

1. Ensure you are in the root directory
2. Install foundry with `foundryup` - instructions [here](https://book.getfoundry.sh/getting-started/installation)
3. `forge install foundry-rs/forge-std --no-commit`
4. `forge test`

### Forking Locally

1. Ensure you are in the root repository
2. Run `foundryup` to ensure you have downloaded the latest version
3. Start a locally forked node with the following command:

```bash
anvil --fork-url <FORKING_RPC> --fork-block-number <BLOCK_NUMBER> --chain-id 1337
```

For `<FORKING_RPC>`, use an Alchemy or Infura RPC URL.

**Note: `anvil` will cache the blockchain provided that `BLOCK_NUMBER` does NOT change. Given this, we recommend picking a block and sticking to it.**

## License

[MIT](https://github.com/pintomoney/protocol/blob/main/LICENSE.txt)

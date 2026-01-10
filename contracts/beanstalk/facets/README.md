# Facets

This directory contains all Diamond facets implementing Pinto Protocol functionality.

## Overview

Facets are modular contracts that provide specific functionality to the Diamond. Each facet is a separate contract that can be added, replaced, or removed through the DiamondCut mechanism.

## Directory Structure

| Directory | Description |
|-----------|-------------|
| `diamond/` | Core Diamond management facets |
| `farm/` | Token and farming operation facets |
| `field/` | Pod Field mechanics |
| `market/` | Pod Marketplace |
| `metadata/` | NFT metadata generation |
| `silo/` | Silo deposits and yield distribution |
| `sun/` | Season advancement and gauges |

## Diamond Facets

| Facet | Description |
|-------|-------------|
| `DiamondCutFacet` | Add, replace, or remove facet functions |
| `DiamondLoupeFacet` | Introspection functions to view facet information |
| `OwnershipFacet` | Contract ownership management |

## Farm Facets

| Facet | Description |
|-------|-------------|
| `DepotFacet` | Pipeline integration for external protocol calls |
| `FarmFacet` | Composable farming operations |
| `TokenFacet` | Internal token balance management |
| `TokenSupportFacet` | Token whitelisting and support |
| `TractorFacet` | Automated action execution (Tractor) |

## Field Facets

| Facet | Description |
|-------|-------------|
| `FieldFacet` | Sowing Beans for Pods, harvesting mature Pods |

## Market Facets

| Facet | Description |
|-------|-------------|
| `MarketplaceFacet` | Pod listing, ordering, and trading |

## Silo Facets

| Facet | Description |
|-------|-------------|
| `SiloFacet` | Deposit, withdraw, and transfer Silo assets |
| `SiloGettersFacet` | View functions for Silo state |
| `ConvertFacet` | Convert between whitelisted Silo assets |
| `ConvertGettersFacet` | View functions for conversions |
| `PipelineConvertFacet` | Pipeline-based conversions |
| `ClaimFacet` | Claim Silo rewards and Earned Beans |
| `ApprovalFacet` | Deposit approval management |
| `BDVFacet` | Bean Denominated Value calculations |
| `WhitelistFacet` | Silo asset whitelisting |

## Sun Facets

| Facet | Description |
|-------|-------------|
| `SeasonFacet` | Advance the Season (sunrise) |
| `SeasonGettersFacet` | View functions for Season state |
| `GaugeFacet` | Gauge system for directing incentives |
| `GaugeGettersFacet` | View functions for gauge state |
| `OracleFacet` | Price oracle integration |
| `LiquidityWeightFacet` | Liquidity weight calculations |

---
status: unstarted
owner: TBD
---

# Gravity L1 Core Smart Contracts Specification

## Overview

This document specifies the core smart contracts for the Gravity L1 blockchain. These contracts are system-level infrastructure that enables the fundamental operations of the Gravity chain.

## Design Principles

1. **Security First**: All contracts undergo rigorous security review. Access control and input validation are mandatory.
2. **Simplicity**: Prefer simple, readable code over complex optimizations. Keep it simple and stupid (KISS).
3. **Modularity**: Each component has a single responsibility and clear interfaces.
4. **Minimal Trust**: Minimize trust assumptions. Validate at system boundaries.
5. **Gas Efficiency**: Optimize for gas where it doesn't compromise security or readability.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Gravity L1 Blockchain                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐               │
│  │   Blocker    │───▶│  Timestamp   │    │    Epoch     │               │
│  │  (Block.sol) │    │              │    │   Manager    │               │
│  └──────────────┘    └──────────────┘    └──────────────┘               │
│         │                   │                   │                        │
│         │                   ▼                   ▼                        │
│         │            ┌──────────────────────────────────┐               │
│         │            │         Stake Module             │               │
│         │            │  ┌─────────────┐ ┌────────────┐  │               │
│         │            │  │  Validator  │ │   Stake    │  │               │
│         │            │  │   Manager   │ │   Config   │  │               │
│         │            │  └─────────────┘ └────────────┘  │               │
│         │            └──────────────────────────────────┘               │
│         │                       │                                        │
│         ▼                       ▼                                        │
│  ┌──────────────┐    ┌──────────────────────────────────┐               │
│  │   Oracle     │    │        Randomness (DKG)          │               │
│  │  (Hash/JWK)  │    │  ┌─────────┐ ┌────────────────┐  │               │
│  │              │    │  │   DKG   │ │ RandomnessConf │  │               │
│  └──────────────┘    │  └─────────┘ └────────────────┘  │               │
│                      └──────────────────────────────────┘               │
│                                                                          │
│  ┌──────────────────────────────────────────────────────┐               │
│  │                    Governance                         │               │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐  │               │
│  │  │ Governor │ │ Timelock │ │ GovToken │ │ GovHub  │  │               │
│  │  └──────────┘ └──────────┘ └──────────┘ └─────────┘  │               │
│  └──────────────────────────────────────────────────────┘               │
│                                                                          │
│  ┌──────────────────────────────────────────────────────┐               │
│  │                  System Registry                      │               │
│  │         (Address Constants & Configuration)           │               │
│  └──────────────────────────────────────────────────────┘               │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Core Components

| Component | Description | Spec File |
|-----------|-------------|-----------|
| **System Registry** | Central registry for system addresses and constants | [registry.spec.md](./registry.spec.md) |
| **Timestamp** | On-chain time management, microsecond precision | [timestamp.spec.md](./timestamp.spec.md) |
| **Blocker** | Block prologue handler, called on each new block | [blocker.spec.md](./blocker.spec.md) |
| **Epoch Manager** | Manages consensus epoch transitions | [epoch.spec.md](./epoch.spec.md) |
| **Stake Module** | Validator staking management (simplified) | [stake.spec.md](./stake.spec.md) |
| **Oracle** | Cross-chain verification (hash, JWK, DNS) | [oracle.spec.md](./oracle.spec.md) |
| **Randomness** | Secure random number generation via DKG | [randomness.spec.md](./randomness.spec.md) |
| **Governance** | On-chain governance for parameter changes | [governance.spec.md](./governance.spec.md) |

## Contract Address Allocation

All system contracts are deployed at predetermined addresses in the `0x2000` - `0x20FF` range:

| Address | Contract |
|---------|----------|
| `0x2000` | SYSTEM_CALLER (reserved for blockchain runtime) |
| `0x2008` | Genesis |
| `0x2010` | EpochManager |
| `0x2011` | StakeConfig |
| `0x2012` | (Reserved) |
| `0x2013` | ValidatorManager |
| `0x2016` | Block |
| `0x2017` | Timestamp |
| `0x2018` | JWKManager |
| `0x201A` | SystemReward |
| `0x201B` | GovHub |
| `0x201D` | GovToken |
| `0x201E` | Governor |
| `0x201F` | Timelock |
| `0x2020` | RandomnessConfig |
| `0x2021` | DKG |
| `0x2022` | ReconfigurationWithDKG |
| `0x2023` | HashOracle |
| `0x20FF` | SystemContract (registry) |

## Initialization Flow

1. **Genesis Block**: All contracts are deployed with initial bytecode
2. **Genesis Initialization**: `Genesis` contract calls `initialize()` on each system contract
3. **Order of Initialization**:
   - System Registry
   - Timestamp (sets initial time to 0)
   - StakeConfig (sets staking parameters)
   - ValidatorManager (registers genesis validators)
   - EpochManager (starts epoch 0)
   - RandomnessConfig
   - DKG
   - Governance contracts
   - Oracle contracts

## Access Control Model

### Caller Types

| Caller | Description |
|--------|-------------|
| `SYSTEM_CALLER` | Blockchain runtime (block production) |
| `GENESIS_ADDR` | Genesis initialization only |
| `GOV_HUB_ADDR` | Governance parameter updates |
| `TIMELOCK_ADDR` | Time-delayed governance execution |
| System Contracts | Inter-contract calls |

### Permission Matrix

| Operation | System Caller | Genesis | Governance | Validator | Public |
|-----------|:-------------:|:-------:|:----------:|:---------:|:------:|
| Initialize contracts | | ✓ | | | |
| Update timestamp | ✓ | | | | |
| Block prologue | ✓ | | | | |
| Epoch transition | ✓ | ✓ | | | |
| Update parameters | | | ✓ | | |
| Register validator | | | | ✓ | |
| Read state | ✓ | ✓ | ✓ | ✓ | ✓ |

## Event Standards

All significant state changes emit events following this pattern:

```solidity
event <Action><Subject>(
    indexed address actor,
    indexed uint256 identifier,
    <relevant data...>
);
```

## Error Handling

Custom errors are preferred over require strings for gas efficiency:

```solidity
error NotAuthorized(address caller);
error InvalidParameter(string name, bytes value);
error InvalidState(string message);
```

## Upgrade Strategy

System contracts support upgrades through:

1. **Transparent Proxy Pattern**: For most contracts
2. **Governance-controlled**: Upgrades require governance approval
3. **Timelock**: Mandatory delay before upgrade execution

## Security Considerations

1. **Reentrancy Protection**: All state-changing functions use checks-effects-interactions pattern
2. **Access Control**: Strict modifier-based access control on all privileged functions
3. **Input Validation**: All external inputs are validated
4. **Overflow Protection**: Solidity 0.8+ built-in overflow checks
5. **Pausability**: Critical contracts can be paused in emergencies

## Testing Requirements

1. **Unit Tests**: 100% coverage of public/external functions
2. **Integration Tests**: Cross-contract interaction testing
3. **Fuzz Tests**: Property-based testing for edge cases
4. **Invariant Tests**: Critical invariants verified across all states
5. **Fork Tests**: Testing against mainnet state

## Related Documents

- [registry.spec.md](./registry.spec.md) - System Registry Specification
- [timestamp.spec.md](./timestamp.spec.md) - Timestamp Specification  
- [blocker.spec.md](./blocker.spec.md) - Blocker Specification
- [epoch.spec.md](./epoch.spec.md) - Epoch Manager Specification
- [stake.spec.md](./stake.spec.md) - Stake Module Specification
- [oracle.spec.md](./oracle.spec.md) - Oracle Specification
- [randomness.spec.md](./randomness.spec.md) - Randomness Specification
- [governance.spec.md](./governance.spec.md) - Governance Specification


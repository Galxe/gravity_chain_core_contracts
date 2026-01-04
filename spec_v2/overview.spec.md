---
status: draft
owner: @yxia
---

# Gravity Core Contracts — Architecture Overview

## Introduction

Gravity Core Contracts form the on-chain infrastructure for the Gravity blockchain. The system follows a **layered architecture** where each layer builds upon the layers below, ensuring clear dependencies, separation of concerns, and maintainability.

---

## Layered Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│                              EXTERNAL SYSTEMS                               │
│                     (Consensus Engine, VM Runtime, Users)                   │
│                                                                             │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
┌───────────────┐         ┌───────────────┐         ┌───────────────┐
│   GOVERNANCE  │         │    ORACLE     │         │    BLOCKER    │
│   (Layer 5)   │         │   (Layer 6)   │         │   (Layer 4)   │
│               │         │               │         │               │
│ • Proposals   │         │ • Cross-chain │         │ • Epoch Mgmt  │
│ • Voting      │         │ • JWK/DNS     │         │ • Block Start │
│ • Execution   │         │ • Callbacks   │         │ • DKG Coord   │
└───────┬───────┘         └───────────────┘         └───────┬───────┘
        │                                                   │
        │         ┌─────────────────────────────────────────┘
        │         │
        ▼         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      STAKING & VALIDATOR (Layers 2-3)                       │
│                                                                             │
│  ┌─────────────────────────────┐   ┌─────────────────────────────────────┐  │
│  │      STAKING (Layer 2)      │   │   VALIDATOR MANAGEMENT (Layer 3)   │  │
│  │                             │   │                                     │  │
│  │  • StakePool Factory        │◄──│  • Validator Registration           │  │
│  │  • Individual Pools         │   │  • Join/Leave Lifecycle             │  │
│  │  • Bucket-Based Withdrawals │   │  • Epoch Transitions                │  │
│  │  • Voting Power Queries     │   │  • Index Assignment                 │  │
│  └─────────────────────────────┘   └─────────────────────────────────────┘  │
└─────────────────────────────────────────┬───────────────────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            RUNTIME (Layer 1)                                │
│                                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Timestamp  │  │StakingConfig│  │ValidatorCfg │  │ Epoch/Version/DKG   │ │
│  │  (μs time)  │  │             │  │             │  │ Consensus/Execution │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────┬───────────────────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           FOUNDATION (Layer 0)                              │
│                                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐  ┌────────────┐  │
│  │ SystemAddresses │  │SystemAccessCtrl │  │    Types    │  │   Errors   │  │
│  │  (constants)    │  │ (free funcs)    │  │  (structs)  │  │  (custom)  │  │
│  └─────────────────┘  └─────────────────┘  └─────────────┘  └────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Layer Summaries

### Layer 0: Foundation

**Purpose**: Zero-dependency bedrock for all contracts.

- **SystemAddresses** — Compile-time constants for system contract addresses (~3 gas vs ~2100 for SLOAD)
- **SystemAccessControl** — Free functions for access control (no inheritance required)
- **Types** — Core data structures (StakePosition, ValidatorRecord, Proposal, etc.)
- **Errors** — Unified custom errors across all contracts

📄 **Details**: [foundation.spec.md](./foundation.spec.md)

---

### Layer 1: Runtime

**Purpose**: Mutable parameters and time infrastructure.

- **Timestamp** — On-chain time oracle (microsecond precision)
- **Config Contracts** — StakingConfig, ValidatorConfig, EpochConfig, VersionConfig
- **Pending Config Contracts** — RandomnessConfig, ConsensusConfig, ExecutionConfig (epoch-boundary updates)
- **DKG** — Distributed Key Generation session lifecycle

📄 **Details**: [runtime.spec.md](./runtime.spec.md) | [randomness.spec.md](./randomness.spec.md)

---

### Layers 2-3: Staking & Validator Management

**Purpose**: Generic staking infrastructure and validator lifecycle.

**Staking (Layer 2)**:
- StakePool factory via CREATE2
- Two-role separation (Owner/Staker)
- O(log n) bucket-based withdrawals with prefix sums
- Time-parameterized voting power queries

**Validator Management (Layer 3)**:
- Validator registration and lifecycle (INACTIVE → PENDING_ACTIVE → ACTIVE → PENDING_INACTIVE)
- Epoch-based transitions with index assignment
- Voting power limits and minimum bond protection

📄 **Details**: [staking.spec.md](./staking.spec.md) | [validator_management.spec.md](./validator_management.spec.md)

---

### Layer 4: Blocker

**Purpose**: Epoch lifecycle and block prologue.

- **Reconfiguration** — Central orchestrator for epoch transitions with DKG coordination
- **Blocker** — Block prologue entry point called by VM at each block start
- Time-based epochs (default 2 hours)
- Two-phase transitions (start via Blocker, finish via consensus/governance)

📄 **Details**: [blocker.spec.md](./blocker.spec.md)

---

### Layer 5: Governance

**Purpose**: On-chain governance for protocol changes.

- Stake-based voting via StakePool's voter address
- Hash-verified execution model
- Partial voting and early resolution support
- Voting power calculated at proposal expiration time (inherently requires sufficient lockup)

📄 **Details**: [governance.spec.md](./governance.spec.md)

---

### Layer 6: Oracle

**Purpose**: Consensus-gated external data.

- Cross-chain events (Ethereum, other EVM chains)
- Real-world state (JWK keys, DNS records)
- Hash-only mode (storage-efficient) or data mode (direct access)
- Governance-controlled callbacks with failure tolerance

📄 **Details**: [oracle.spec.md](./oracle.spec.md)

---

## Key Design Principles

| Principle | Description |
|-----------|-------------|
| **Layered Dependencies** | Higher layers depend only on lower layers |
| **Microsecond Time** | All timestamps use `uint64` microseconds |
| **Compile-time Addresses** | System addresses inlined for gas efficiency |
| **Epoch-Boundary Updates** | Sensitive config changes apply at epoch transitions |
| **Two-Role Separation** | Owner (admin) vs Staker (funds) in StakePools |
| **Consensus-Gated** | Critical state changes require validator consensus |

---

## Contract Dependency Summary

```
                        ┌──────────────────┐
                        │    Governance    │───────────────┐
                        └────────┬─────────┘               │
                                 │                         │
                        ┌────────▼─────────┐               │
                        │     Blocker      │               │
                        │  Reconfiguration │               │
                        └────────┬─────────┘               │
                                 │                         │
          ┌──────────────────────┼──────────────────────┐  │
          │                      │                      │  │
          ▼                      ▼                      ▼  ▼
   ┌──────────────┐     ┌────────────────┐     ┌───────────────┐
   │ValidatorMgmt │────▶│    Staking     │     │ NativeOracle  │
   └──────┬───────┘     │  (Factory)     │     └───────┬───────┘
          │             └────────┬───────┘             │
          │                      │                     │
          │             ┌────────▼───────┐             │
          │             │   StakePool    │             │
          │             └────────┬───────┘             │
          │                      │                     │
          └──────────────────────┼─────────────────────┘
                                 │
                        ┌────────▼─────────┐
                        │     Runtime      │
                        │  (Timestamp,     │
                        │   Configs, DKG)  │
                        └────────┬─────────┘
                                 │
                        ┌────────▼─────────┐
                        │   Foundation     │
                        │ (Addresses,Types,│
                        │  Errors, Access) │
                        └──────────────────┘
```

---

## Quick Reference

| Layer | Contracts | System Address(es) |
|-------|-----------|-------------------|
| Foundation | SystemAddresses, Types, Errors | — |
| Runtime | Timestamp, StakingConfig, ValidatorConfig, etc. | `0x...2017`, `0x...2011`, `0x...2015` |
| Staking | Staking, StakePool | `0x...2012` |
| Validator | ValidatorManagement | `0x...2013` |
| Blocker | Blocker, Reconfiguration | `0x...2016`, `0x...2010` |
| Governance | Governance, GovernanceConfig | `0x...2014`, `0x...2026` |
| Oracle | NativeOracle | `0x...2023` |

*All addresses follow the `0x...1625F2xxx` pattern reserved at genesis.*

---

## Specification Index

1. [Foundation Layer](./foundation.spec.md)
2. [Runtime Layer](./runtime.spec.md)
3. [Staking Layer](./staking.spec.md)
4. [Validator Management](./validator_management.spec.md)
5. [Blocker Layer](./blocker.spec.md)
6. [Governance Layer](./governance.spec.md)
7. [Oracle Layer](./oracle.spec.md)
8. [Randomness Layer](./randomness.spec.md)


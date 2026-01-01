# Aptos On-Chain Parameters Documentation

This document provides a comprehensive reference of all on-chain configuration parameters stored on the Aptos blockchain. These parameters are explicitly stored in Move resources under the `@aptos_framework` address and govern the blockchain's behavior.

---

## Table of Contents

1. [Core Chain Configuration](#1-core-chain-configuration)
2. [Consensus Configuration](#2-consensus-configuration)
3. [Execution Configuration](#3-execution-configuration)
4. [Version Configuration](#4-version-configuration)
5. [Gas Schedule Configuration](#5-gas-schedule-configuration)
6. [Storage Gas Configuration](#6-storage-gas-configuration)
7. [Staking Configuration](#7-staking-configuration)
8. [Staking Rewards Configuration](#8-staking-rewards-configuration)
9. [Epoch & Block Configuration](#9-epoch--block-configuration)
10. [Governance Configuration](#10-governance-configuration)
11. [Randomness Configuration](#11-randomness-configuration)
12. [JWK Consensus Configuration](#12-jwk-consensus-configuration)
13. [Validator Set](#13-validator-set)
14. [State Storage](#14-state-storage)
15. [Timestamp](#15-timestamp)
16. [Configuration Update Mechanism](#16-configuration-update-mechanism)

---

## 1. Core Chain Configuration

### ChainId

**Module**: `aptos_framework::chain_id`  
**Resource**: `ChainId`

Distinguishes between different chains (e.g., mainnet, testnet, devnet). Prevents transactions intended for one chain from being executed on another.

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | `u8` | Unique identifier for the chain (e.g., 1=mainnet, 2=testnet) |

**Key Properties**:
- Set only during genesis
- Cannot be changed after initialization
- Used in transaction validation to reject cross-chain replays

---

### ChainStatus

**Module**: `aptos_framework::chain_status`  
**Resource**: `GenesisEndMarker`

Tracks whether the blockchain is still in genesis phase or operating normally.

| State | Condition |
|-------|-----------|
| Genesis | `GenesisEndMarker` does not exist at `@aptos_framework` |
| Operating | `GenesisEndMarker` exists at `@aptos_framework` |

**Key Properties**:
- Certain operations are only allowed during genesis
- `GenesisEndMarker` is published at the end of genesis initialization

---

## 2. Consensus Configuration

**Module**: `aptos_framework::consensus_config`  
**Resource**: `ConsensusConfig`

Contains all consensus-related parameters as serialized bytes. The actual parameters are defined in Rust and serialized/deserialized via BCS.

| Parameter | Type | Description |
|-----------|------|-------------|
| `config` | `vector<u8>` | BCS-serialized consensus configuration |

**Typical Parameters Inside** (defined off-chain in Rust):
- Block size limits
- Block gas limits
- Round timeout durations
- Maximum transaction bytes per block
- Validator transaction enabled flag
- Two-chain consensus settings

**Update Mechanism**:
- Updated via governance proposals
- Uses `set_for_next_epoch()` + reconfiguration pattern
- Changes take effect at the next epoch boundary

---

## 3. Execution Configuration

**Module**: `aptos_framework::execution_config`  
**Resource**: `ExecutionConfig`

Controls VM execution behavior. Stored as serialized bytes.

| Parameter | Type | Description |
|-----------|------|-------------|
| `config` | `vector<u8>` | BCS-serialized execution configuration |

**Typical Parameters Inside** (defined off-chain in Rust):
- Transaction shuffler type
- Block gas limit configuration
- Transaction deduplication settings
- Parallel execution settings

**Update Mechanism**:
- Updated via governance proposals
- Uses `set_for_next_epoch()` + reconfiguration pattern

---

## 4. Version Configuration

**Module**: `aptos_framework::version`  
**Resource**: `Version`

Tracks the protocol version for coordinating upgrades.

| Parameter | Type | Description |
|-----------|------|-------------|
| `major` | `u64` | Major version number of the protocol |

**Key Properties**:
- Version can only be increased, never decreased
- Used to gate new features and behaviors
- Updated via governance proposals

---

## 5. Gas Schedule Configuration

**Module**: `aptos_framework::gas_schedule`  
**Resource**: `GasScheduleV2`

Defines gas costs for all Move operations and instructions.

| Parameter | Type | Description |
|-----------|------|-------------|
| `feature_version` | `u64` | Version number of the gas schedule |
| `entries` | `vector<GasEntry>` | Key-value pairs of gas parameters |

**GasEntry Structure**:
```move
struct GasEntry {
    key: String,    // Parameter name
    val: u64,       // Gas cost value
}
```

**Example Entries**:
- `txn.min_transaction_gas_units` - Minimum gas for any transaction
- `txn.max_transaction_size_in_bytes` - Maximum transaction size
- `instr.*` - Costs for individual VM instructions
- `move_stdlib.*` - Costs for standard library functions
- `aptos_framework.*` - Costs for framework functions

**Update Mechanism**:
- Updated via governance proposals
- Feature version must be >= current version
- Uses `set_for_next_epoch()` + reconfiguration pattern

---

## 6. Storage Gas Configuration

**Module**: `aptos_framework::storage_gas`  
**Resources**: `StorageGasConfig`, `StorageGas`

Dynamic storage gas pricing based on utilization.

### StorageGasConfig

| Parameter | Type | Description |
|-----------|------|-------------|
| `item_config` | `UsageGasConfig` | Per-item gas configuration |
| `byte_config` | `UsageGasConfig` | Per-byte gas configuration |

### UsageGasConfig Structure

```move
struct UsageGasConfig {
    target_usage: u64,      // Target utilization
    read_curve: GasCurve,   // Gas curve for reads
    create_curve: GasCurve, // Gas curve for creates
    write_curve: GasCurve,  // Gas curve for writes
}
```

### StorageGas (Dynamic, Recalculated Each Epoch)

| Parameter | Type | Description |
|-----------|------|-------------|
| `per_item_read` | `u64` | Current cost to read an item |
| `per_item_create` | `u64` | Current cost to create an item |
| `per_item_write` | `u64` | Current cost to write an item |
| `per_byte_read` | `u64` | Current cost to read a byte |
| `per_byte_create` | `u64` | Current cost to create a byte |
| `per_byte_write` | `u64` | Current cost to write a byte |

**Default Targets**:
- Item target: 2 billion items
- Byte target: 1 TB

**Key Properties**:
- Uses exponential curve (base 8192) for price escalation
- Prices recalculated at each epoch based on utilization ratio
- At 50% utilization, gas is ~1% above minimum

---

## 7. Staking Configuration

**Module**: `aptos_framework::staking_config`  
**Resource**: `StakingConfig`

Core validator staking parameters.

| Parameter | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| `minimum_stake` | `u64` | Minimum stake to join validator set | > 0 |
| `maximum_stake` | `u64` | Maximum stake per validator | >= minimum_stake |
| `recurring_lockup_duration_secs` | `u64` | Duration of stake lockup period | > 0 |
| `allow_validator_set_change` | `bool` | Whether validators can join/leave post-genesis | - |
| `rewards_rate` | `u64` | Reward rate numerator (deprecated if REWARD_RATE_DECREASE enabled) | <= MAX_REWARDS_RATE (1,000,000) |
| `rewards_rate_denominator` | `u64` | Reward rate denominator | > 0 |
| `voting_power_increase_limit` | `u64` | Max % of voting power that can join per epoch | 1-50 |

**Example Values** (mainnet approximate):
- `minimum_stake`: 1,000,000 APT (1M APT)
- `maximum_stake`: 50,000,000 APT (50M APT)
- `recurring_lockup_duration_secs`: 2,592,000 (30 days)
- `voting_power_increase_limit`: 20%

---

## 8. Staking Rewards Configuration

**Module**: `aptos_framework::staking_config`  
**Resource**: `StakingRewardsConfig`

Advanced reward rate configuration with time-based decay.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rewards_rate` | `FixedPoint64` | Current epoch rewards rate |
| `min_rewards_rate` | `FixedPoint64` | Minimum rewards rate floor |
| `rewards_rate_period_in_secs` | `u64` | Period for rate decrease (typically 1 year) |
| `last_rewards_rate_period_start_in_secs` | `u64` | Start of current rate period |
| `rewards_rate_decrease_rate` | `FixedPoint64` | Rate of decrease per period (in BPS) |

**Key Properties**:
- Rewards rate decreases periodically (e.g., annually)
- Cannot decrease below `min_rewards_rate`
- Decrease rate cannot exceed 100%

**Constants**:
- `ONE_YEAR_IN_SECS`: 31,536,000
- `BPS_DENOMINATOR`: 10,000

---

## 9. Epoch & Block Configuration

### BlockResource

**Module**: `aptos_framework::block`  
**Resource**: `BlockResource`

| Parameter | Type | Description |
|-----------|------|-------------|
| `height` | `u64` | Current block height |
| `epoch_interval` | `u64` | Epoch duration in microseconds |

**Key Properties**:
- `epoch_interval` must be > 0
- Epoch transition occurs when `current_time - last_reconfiguration_time >= epoch_interval`
- Updated via `update_epoch_interval_microsecs()`

### Configuration (Reconfiguration)

**Module**: `aptos_framework::reconfiguration`  
**Resource**: `Configuration`

| Parameter | Type | Description |
|-----------|------|-------------|
| `epoch` | `u64` | Current epoch number |
| `last_reconfiguration_time` | `u64` | Timestamp of last reconfiguration |

**Key Properties**:
- Epoch starts at 1 after genesis
- Reconfiguration emits `NewEpochEvent`
- Multiple reconfigurations in same block are deduplicated

---

## 10. Governance Configuration

**Module**: `aptos_framework::aptos_governance`  
**Resource**: `GovernanceConfig`

| Parameter | Type | Description |
|-----------|------|-------------|
| `min_voting_threshold` | `u128` | Minimum votes required to pass proposal |
| `required_proposer_stake` | `u64` | Minimum stake to create proposal |
| `voting_duration_secs` | `u64` | Duration of voting period |

**Additional Governance State**:
- `ApprovedExecutionHashes`: Tracks approved proposal execution hashes
- `VotingRecords`/`VotingRecordsV2`: Tracks stake pool votes per proposal

**Key Properties**:
- Early resolution if > 50% of total supply votes
- Proposer's stake must be locked >= voting_duration_secs

---

## 11. Randomness Configuration

### RandomnessConfig

**Module**: `aptos_framework::randomness_config`  
**Resource**: `RandomnessConfig`

| Parameter | Type | Description |
|-----------|------|-------------|
| `variant` | `Any` | Polymorphic config (ConfigOff, ConfigV1, or ConfigV2) |

**ConfigV1 Parameters**:
| Parameter | Type | Description |
|-----------|------|-------------|
| `secrecy_threshold` | `FixedPoint64` | Max power ratio that shouldn't reconstruct randomness |
| `reconstruction_threshold` | `FixedPoint64` | Min power ratio that can always reconstruct |

**ConfigV2 Parameters** (adds fast path):
| Parameter | Type | Description |
|-----------|------|-------------|
| `fast_path_secrecy_threshold` | `FixedPoint64` | Threshold for fast path reconstruction |

### RandomnessConfigSeqNum

**Module**: `aptos_framework::randomness_config_seqnum`  
**Resource**: `RandomnessConfigSeqNum`

| Parameter | Type | Description |
|-----------|------|-------------|
| `seq_num` | `u64` | Sequence number for emergency override |

**Used for**: Recovery from randomness stall situations.

### RandomnessApiV0Config

**Module**: `aptos_framework::randomness_api_v0_config`  
**Resources**: `RequiredGasDeposit`, `AllowCustomMaxGasFlag`

| Parameter | Type | Description |
|-----------|------|-------------|
| `gas_amount` | `Option<u64>` | Required gas deposit for randomness calls |
| `value` | `bool` | Whether custom max_gas in `#[randomness()]` is allowed |

---

## 12. JWK Consensus Configuration

**Module**: `aptos_framework::jwk_consensus_config`  
**Resource**: `JWKConsensusConfig`

Configuration for JSON Web Key (JWK) consensus for keyless accounts.

| Parameter | Type | Description |
|-----------|------|-------------|
| `variant` | `Any` | ConfigOff or ConfigV1 |

**ConfigV1 Parameters**:
| Parameter | Type | Description |
|-----------|------|-------------|
| `oidc_providers` | `vector<OIDCProvider>` | List of OIDC providers to monitor |

**OIDCProvider Structure**:
```move
struct OIDCProvider {
    name: String,       // Provider identifier
    config_url: String, // OIDC configuration URL
}
```

---

## 13. Validator Set

**Module**: `aptos_framework::stake`  
**Resource**: `ValidatorSet`

| Parameter | Type | Description |
|-----------|------|-------------|
| `consensus_scheme` | `u8` | Consensus algorithm identifier |
| `active_validators` | `vector<ValidatorInfo>` | Current active validators |
| `pending_inactive` | `vector<ValidatorInfo>` | Validators leaving next epoch |
| `pending_active` | `vector<ValidatorInfo>` | Validators joining next epoch |
| `total_voting_power` | `u128` | Total current voting power |
| `total_joining_power` | `u128` | Voting power waiting to join |

**ValidatorInfo Structure**:
```move
struct ValidatorInfo {
    addr: address,          // Validator's stake pool address
    voting_power: u64,      // Validator's voting power
    config: ValidatorConfig // Consensus config
}
```

**ValidatorConfig Structure**:
```move
struct ValidatorConfig {
    consensus_pubkey: vector<u8>,  // BLS public key
    network_addresses: vector<u8>, // Validator network addresses
    fullnode_addresses: vector<u8>, // Full node addresses
    validator_index: u64,           // Index in active set
}
```

**Constants**:
- `MAX_VALIDATOR_SET_SIZE`: 65,536

---

## 14. State Storage

**Module**: `aptos_framework::state_storage`  
**Resource**: `StateStorageUsage`

| Parameter | Type | Description |
|-----------|------|-------------|
| `epoch` | `u64` | Epoch when usage was recorded |
| `usage.items` | `u64` | Total number of items in storage |
| `usage.bytes` | `u64` | Total bytes in storage |

**Key Properties**:
- Updated at the beginning of each epoch
- Used for dynamic storage gas pricing

---

## 15. Timestamp

**Module**: `aptos_framework::timestamp`  
**Resource**: `CurrentTimeMicroseconds`

| Parameter | Type | Description |
|-----------|------|-------------|
| `microseconds` | `u64` | Current Unix timestamp in microseconds |

**Key Properties**:
- Updated by consensus during block prologue
- Must be strictly increasing (except for nil blocks)
- Only VM can update this value

---

## 16. Configuration Update Mechanism

Aptos uses a **two-phase configuration update** pattern for safe reconfiguration:

### Phase 1: Buffer the Change
```move
// Example: Update gas schedule
gas_schedule::set_for_next_epoch(&framework_signer, new_gas_schedule_bytes);
```

The new configuration is stored in `config_buffer::PendingConfigs`.

### Phase 2: Apply During Reconfiguration
```move
// Trigger reconfiguration
aptos_governance::reconfigure(&framework_signer);
```

During reconfiguration (`on_new_epoch`):
1. Pending configs are extracted from buffer
2. Active configs are replaced
3. New epoch begins with updated configs

### Config Buffer

**Module**: `aptos_framework::config_buffer`  
**Resource**: `PendingConfigs`

```move
struct PendingConfigs {
    configs: SimpleMap<String, Any>  // Type name -> pending config
}
```

**Supported Buffered Configs**:
- `ConsensusConfig`
- `ExecutionConfig`
- `GasScheduleV2`
- `Version`
- `RandomnessConfig`
- `RandomnessConfigSeqNum`
- `RandomnessApiV0Config`
- `JWKConsensusConfig`

---

## Summary Table

| Category | Parameters | Update Mechanism |
|----------|------------|------------------|
| Chain ID | id | Genesis only |
| Version | major | Governance + reconfigure |
| Consensus | config bytes | Governance + reconfigure |
| Execution | config bytes | Governance + reconfigure |
| Gas Schedule | feature_version, entries | Governance + reconfigure |
| Storage Gas | curves, targets | Governance + reconfigure |
| Staking | min/max stake, lockup, rewards | Governance |
| Epoch | epoch_interval | Governance |
| Governance | thresholds, durations | Governance |
| Randomness | thresholds | Governance + reconfigure |
| Validator Set | validators | Automatic each epoch |
| Timestamp | microseconds | Block prologue (VM) |

---

## Design Principles

1. **Epoch-based Updates**: Most configuration changes take effect at epoch boundaries to ensure all validators transition simultaneously.

2. **Governance Control**: Critical parameters require governance proposals with sufficient voting power.

3. **Genesis-locked**: Some parameters (like chain_id) are immutable after genesis.

4. **Dynamic Pricing**: Storage gas uses utilization-based pricing to manage state growth.

5. **Separation of Concerns**: Configuration is split across modules by domain (consensus, execution, staking, etc.).

6. **Forward Compatibility**: Version numbers and feature flags enable gradual feature rollout.


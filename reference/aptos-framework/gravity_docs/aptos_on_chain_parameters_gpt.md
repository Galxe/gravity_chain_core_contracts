# Aptos on-chain configuration parameters (framework-level)

This document summarizes **how Aptos stores and applies on-chain configuration**, and enumerates the **configuration parameters explicitly stored on-chain** in this package (`aptos-framework`).

Scope note: Aptos also has on-chain configuration in other packages (e.g., Move stdlib feature flags), but this doc focuses on what is visible in this repo folder: `aptos-move/framework/aptos-framework`.

## What “on-chain config” means in Aptos

In Aptos, many “system parameters” are stored as **Move resources** (typically under the **Aptos framework address** `@aptos_framework` / `0x1`). Validators and the VM read these resources to decide how to run consensus, execute transactions, charge gas, etc.

There are two update styles:

- **Immediate (deprecated for many configs)**: a privileged function updates the resource directly and then triggers reconfiguration.
- **Next-epoch (preferred)**: a privileged function writes a pending value into a **config buffer**, and the pending value is **applied when the chain enters the next epoch**.

## The update/apply lifecycle (governance → next epoch)

At a high level, governance-driven config changes look like:

- **Stage**: call `X::set_for_next_epoch(&framework_signer, ...)` to write a pending config `X` into the buffer.
- **Reconfigure**: call `aptos_framework::aptos_governance::reconfigure(&framework_signer)`.
  - If randomness + validator txns are enabled, Aptos may start DKG and finish reconfiguration asynchronously.
  - Otherwise, it finishes immediately.
- **Apply**: during `reconfiguration_with_dkg::finish`, Aptos applies buffered configs by calling each module’s `on_new_epoch()` and then performs `reconfiguration::reconfigure()` which increments the epoch and emits the new-epoch event.

## Where pending configs are stored: `config_buffer`

Many framework configs use `aptos_framework::config_buffer` as a staging area for “next epoch” updates.

### Stored resource

- **Address**: `@aptos_framework`
- **Resource**: `aptos_framework::config_buffer::PendingConfigs`
- **Fields**:
  - `configs: SimpleMap<String, Any>` where:
    - key = `type_name<T>()` (the fully qualified Move type name),
    - value = `Any` containing the staged config value of type `T`.

## How epochs / reconfiguration are tracked: `reconfiguration`

Entering a new epoch is the “commit point” where buffered configs become active.

### Stored resources

- **Address**: `@aptos_framework`
- **Resources**:
  - `aptos_framework::reconfiguration::Configuration`
    - `epoch: u64`
    - `last_reconfiguration_time: u64` (microseconds)
    - `events: event::EventHandle<NewEpochEvent>`
  - `aptos_framework::reconfiguration::DisableReconfiguration` (marker resource)
    - Existence disables reconfiguration.

## Explicitly stored on-chain configuration parameters (by module)

This section lists the **exact resource fields** that are stored on-chain (i.e., what exists in global state).

### Consensus execution parameters: `consensus_config`

- **Address**: `@aptos_framework`
- **Resource**: `aptos_framework::consensus_config::ConsensusConfig`
- **Fields**:
  - `config: vector<u8>`

Notes:
- The contents are an opaque **BCS-serialized blob** interpreted by the node/consensus implementation.
- Updates are typically staged via `set_for_next_epoch()` and applied in `on_new_epoch()`.

### VM execution parameters: `execution_config`

- **Address**: `@aptos_framework`
- **Resource**: `aptos_framework::execution_config::ExecutionConfig`
- **Fields**:
  - `config: vector<u8>`

Notes:
- Like `ConsensusConfig`, the bytes are interpreted off-chain by the VM/runtime logic.

### Gas schedule parameters: `gas_schedule`

- **Address**: `@aptos_framework`
- **Resource**: `aptos_framework::gas_schedule::GasScheduleV2`
- **Fields**:
  - `feature_version: u64`
  - `entries: vector<GasEntry>` where `GasEntry` is:
    - `key: String`
    - `val: u64`

Notes:
- `feature_version` is monotonic (new schedule must not decrease it).
- `entries` is the concrete “parameter map” for gas costs.

### Chain “major version”: `version`

- **Address**: `@aptos_framework`
- **Resources**:
  - `aptos_framework::version::Version`
    - `major: u64`
  - `aptos_framework::version::SetVersionCapability` (marker capability)

Notes:
- `major` must strictly increase.

### Staking / validator set policy: `staking_config`

- **Address**: `@aptos_framework`
- **Resources**:
  - `aptos_framework::staking_config::StakingConfig`
    - `minimum_stake: u64`
    - `maximum_stake: u64`
    - `recurring_lockup_duration_secs: u64`
    - `allow_validator_set_change: bool`
    - `rewards_rate: u64` *(deprecated when periodic decrease is enabled)*
    - `rewards_rate_denominator: u64` *(deprecated when periodic decrease is enabled)*
    - `voting_power_increase_limit: u64` *(percentage, bounded in (0, 50])*
  - `aptos_framework::staking_config::StakingRewardsConfig`
    - `rewards_rate: FixedPoint64`
    - `min_rewards_rate: FixedPoint64`
    - `rewards_rate_period_in_secs: u64`
    - `last_rewards_rate_period_start_in_secs: u64`
    - `rewards_rate_decrease_rate: FixedPoint64` *(BPS-scaled)*

Notes:
- `StakingRewardsConfig` supports time-based rewards-rate reduction when the corresponding feature flag is enabled.

### Randomness parameters: `randomness_config`, `randomness_config_seqnum`, `randomness_api_v0_config`

#### `randomness_config`

- **Address**: `@aptos_framework`
- **Resource**: `aptos_framework::randomness_config::RandomnessConfig`
- **Fields**:
  - `variant: Any` where the currently used variants include:
    - `ConfigOff {}` (disabled)
    - `ConfigV1 { secrecy_threshold: FixedPoint64, reconstruction_threshold: FixedPoint64 }`
    - `ConfigV2 { secrecy_threshold: FixedPoint64, reconstruction_threshold: FixedPoint64, fast_path_secrecy_threshold: FixedPoint64 }`

#### `randomness_config_seqnum`

- **Address**: `@aptos_framework`
- **Resource**: `aptos_framework::randomness_config_seqnum::RandomnessConfigSeqNum`
- **Fields**:
  - `seq_num: u64`

Notes:
- Used for **emergency stall recovery**: validators can locally override and ignore on-chain randomness config if this seqnum is behind their override.

#### `randomness_api_v0_config`

- **Address**: `@aptos_framework`
- **Resources**:
  - `aptos_framework::randomness_api_v0_config::RequiredGasDeposit`
    - `gas_amount: Option<u64>`
  - `aptos_framework::randomness_api_v0_config::AllowCustomMaxGasFlag`
    - `value: bool`

### JWK consensus + keyless account parameters: `jwk_consensus_config`, `jwks`, `keyless_account`

#### `jwk_consensus_config`

- **Address**: `@aptos_framework`
- **Resource**: `aptos_framework::jwk_consensus_config::JWKConsensusConfig`
- **Fields**:
  - `variant: Any` where the currently used variants include:
    - `ConfigOff {}`
    - `ConfigV1 { oidc_providers: vector<OIDCProvider> }`
      - `OIDCProvider { name: String, config_url: String }`

#### `jwks`

This module is partly designed so validator Rust code can write/read resources directly (without a Move call).

- **Address**: `@aptos_framework` (unless noted otherwise)
- **Resources**:
  - `aptos_framework::jwks::SupportedOIDCProviders`
    - `providers: vector<OIDCProvider>`
      - `OIDCProvider { name: vector<u8>, config_url: vector<u8> }`
  - `aptos_framework::jwks::ObservedJWKs`
    - `jwks: AllProvidersJWKs`
      - `AllProvidersJWKs { entries: vector<ProviderJWKs> }`
        - `ProviderJWKs { issuer: vector<u8>, version: u64, jwks: vector<JWK> }`
  - `aptos_framework::jwks::Patches`
    - `patches: vector<Patch>` (each `Patch` holds `variant: Any`)
  - `aptos_framework::jwks::PatchedJWKs`
    - `jwks: AllProvidersJWKs`
  - **Per-dapp (not under `@aptos_framework`)**: `aptos_framework::jwks::FederatedJWKs`
    - Stored under a dapp owner’s account address.
    - `jwks: AllProvidersJWKs`

#### `keyless_account`

- **Address**: `@aptos_framework`
- **Resource group**: `aptos_framework::keyless_account::Group` (global scope)
- **Group member resources**:
  - `aptos_framework::keyless_account::Groth16VerificationKey`
    - `alpha_g1: vector<u8>`
    - `beta_g2: vector<u8>`
    - `gamma_g2: vector<u8>`
    - `delta_g2: vector<u8>`
    - `gamma_abc_g1: vector<vector<u8>>`
  - `aptos_framework::keyless_account::Configuration`
    - `override_aud_vals: vector<String>`
    - `max_signatures_per_txn: u16`
    - `max_exp_horizon_secs: u64`
    - `training_wheels_pubkey: Option<vector<u8>>`
    - `max_commited_epk_bytes: u16`
    - `max_iss_val_bytes: u16`
    - `max_extra_field_bytes: u16`
    - `max_jwt_header_b64_bytes: u32`

## Quick mental model (useful if you’re designing your own chain)

- **Authoritative storage**: config is just state (resources) under a privileged address.
- **Staging**: governance writes pending configs into a typed key-value buffer.
- **Commit point**: “enter new epoch” is the atomic moment when a batch of changes becomes active.
- **Operational safety**: some configs are blobs to preserve forward compatibility between on-chain state and off-chain node implementations.



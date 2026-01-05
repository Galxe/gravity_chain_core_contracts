# Aptos Reconfiguration with DKG

This document explains how Aptos's reconfiguration (epoch transition) works, with a focus on the DKG-enabled path.

## Overview

Aptos supports two reconfiguration modes:

1. **Simple Reconfiguration** (DKG disabled): Immediate epoch transition when timer expires
2. **Async Reconfiguration with DKG** (DKG enabled): Two-phase epoch transition for randomness support

When DKG is enabled, reconfiguration becomes asynchronous because validators need to run the Distributed Key Generation protocol before the epoch can transition. This enables on-chain randomness in the next epoch.

---

## Key Events

### 1. `DKGStartEvent` (Phase 1 trigger)
- **Location**: `aptos_framework::dkg`
- **Purpose**: Signals validators to start the DKG protocol
- **Emitted by**: `dkg::start()` when epoch timer expires
- **Subscribers**: DKG epoch manager in Rust (`dkg/src/epoch_manager.rs`)

```move
#[event]
struct DKGStartEvent has drop, store {
    session_metadata: DKGSessionMetadata,
    start_time_us: u64,
}
```

### 2. `NewEpochEvent` / `NewEpoch` (Phase 2 completion)
- **Location**: `aptos_framework::reconfiguration`
- **Purpose**: **THE KEY EVENT that tells consensus engine about the new validator set**
- **Emitted by**: `reconfiguration::reconfigure()` at the end of epoch transition
- **Subscribers**: Consensus epoch manager via `ReconfigNotificationListener`

```move
#[event]
struct NewEpochEvent has drop, store {
    epoch: u64,
}

#[event]
struct NewEpoch has drop, store {
    epoch: u64,
}
```

---

## Reconfiguration Flow (DKG Enabled)

### Phase 1: Initiate DKG

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PHASE 1: DKG INITIATION                             │
└─────────────────────────────────────────────────────────────────────────────┘

    Block Prologue (every block)
           │
           ▼
    ┌──────────────────────────────┐
    │ block_prologue_ext()         │  ← VM calls this for each block
    │   - Updates block metadata   │
    │   - Checks epoch timer       │
    └──────────────────────────────┘
           │
           │ if (timestamp - last_reconfiguration_time >= epoch_interval)
           ▼
    ┌──────────────────────────────┐
    │ reconfiguration_with_dkg::   │
    │   try_start()                │
    └──────────────────────────────┘
           │
           ├──► reconfiguration_state::on_reconfig_start()
           │      (marks state as "in progress")
           │
           ▼
    ┌──────────────────────────────┐
    │ dkg::start()                 │
    │   - Records DKG session      │
    │   - Captures current &       │
    │     next validator sets      │
    │   - Emits DKGStartEvent      │
    └──────────────────────────────┘
           │
           ▼
    ┌──────────────────────────────┐
    │     DKGStartEvent            │  ← PHASE 1 OUTPUT
    │  (emitted on-chain)          │
    └──────────────────────────────┘
```

### Off-Chain: DKG Protocol Execution

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    OFF-CHAIN: DKG PROTOCOL                                  │
└─────────────────────────────────────────────────────────────────────────────┘

    State Sync detects DKGStartEvent
           │
           ▼
    ┌──────────────────────────────┐
    │ DKG Epoch Manager            │  (dkg/src/epoch_manager.rs)
    │   on_dkg_start_notification  │
    └──────────────────────────────┘
           │
           ▼
    ┌──────────────────────────────┐
    │ DKGManager                   │  (dkg/src/dkg_manager/mod.rs)
    │   process_dkg_start_event    │
    └──────────────────────────────┘
           │
           │ Each validator:
           ├──► 1. Generates individual DKG transcript
           ├──► 2. Broadcasts transcript via reliable broadcast
           ├──► 3. Collects and aggregates transcripts from other validators
           │
           ▼
    ┌──────────────────────────────┐
    │ Aggregated Transcript Ready  │
    │   process_aggregated_        │
    │   transcript()               │
    └──────────────────────────────┘
           │
           │ Creates ValidatorTransaction::DKGResult
           ▼
    ┌──────────────────────────────┐
    │ Validator Transaction Pool   │  (vtxn_pool)
    │   Topic::DKG                 │
    └──────────────────────────────┘
           │
           │ Block proposer pulls transaction
           ▼
    ┌──────────────────────────────┐
    │ Included in Block            │
    │ as ValidatorTransaction      │
    └──────────────────────────────┘
```

### Phase 2: Complete Reconfiguration

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   PHASE 2: RECONFIGURATION COMPLETION                       │
└─────────────────────────────────────────────────────────────────────────────┘

    VM executes ValidatorTransaction::DKGResult
           │
           ▼
    ┌──────────────────────────────┐
    │ AptosVM::process_dkg_result  │  (aptos-vm/src/validator_txns/dkg.rs)
    │   - Deserialize transcript   │
    │   - Verify transcript        │
    │   - Check epoch match        │
    └──────────────────────────────┘
           │
           ▼
    ┌──────────────────────────────┐
    │ reconfiguration_with_dkg::   │
    │   finish_with_dkg_result()   │
    └──────────────────────────────┘
           │
           ├──► dkg::finish(dkg_result)
           │      (stores DKG transcript)
           │
           ▼
    ┌──────────────────────────────┐
    │ reconfiguration_with_dkg::   │
    │   finish()                   │
    └──────────────────────────────┘
           │
           ├──► dkg::try_clear_incomplete_session()
           ├──► consensus_config::on_new_epoch()     ─┐
           ├──► execution_config::on_new_epoch()      │
           ├──► gas_schedule::on_new_epoch()          │ Apply buffered
           ├──► version::on_new_epoch()               │ on-chain configs
           ├──► features::on_new_epoch()              │
           ├──► jwk_consensus_config::on_new_epoch()  │
           ├──► jwks::on_new_epoch()                  │
           ├──► keyless_account::on_new_epoch()       │
           ├──► randomness_config::on_new_epoch()    ─┘
           │
           ▼
    ┌──────────────────────────────┐
    │ reconfiguration::reconfigure │
    └──────────────────────────────┘
           │
           ├──► reconfiguration_state::on_reconfig_start()
           │      (idempotent if already started)
           │
           ├──► stake::on_new_epoch()
           │      - Distribute rewards
           │      - Process pending validators
           │      - Compute new ValidatorSet
           │
           ├──► storage_gas::on_reconfig()
           │
           ├──► Increment epoch number
           │
           ├──► Emit NewEpochEvent / NewEpoch  ← THE KEY EVENT
           │
           ▼
    ┌──────────────────────────────┐
    │ reconfiguration_state::      │
    │   on_reconfig_finish()       │
    │   (marks state as "stopped") │
    └──────────────────────────────┘
```

---

## Consensus Engine Reaction to NewEpochEvent

```
┌─────────────────────────────────────────────────────────────────────────────┐
│               CONSENSUS ENGINE EPOCH TRANSITION                             │
└─────────────────────────────────────────────────────────────────────────────┘

    State Sync commits transaction with NewEpochEvent
           │
           ▼
    ┌──────────────────────────────┐
    │ EventSubscriptionService::   │  (state-sync/inter-component/
    │   notify_events()            │   event-notifications/src/lib.rs)
    └──────────────────────────────┘
           │
           │ Detects NewEpochEvent via is_new_epoch_event()
           ▼
    ┌──────────────────────────────┐
    │ notify_reconfiguration_      │
    │   subscribers()              │
    │   - Reads on-chain configs   │
    │   - Creates ReconfigNotif.   │
    └──────────────────────────────┘
           │
           │ ReconfigNotification { version, on_chain_configs }
           ▼
    ┌──────────────────────────────┐
    │ Consensus EpochManager       │  (consensus/src/epoch_manager.rs)
    │   await_reconfig_notification│
    │   on_new_epoch()             │
    └──────────────────────────────┘
           │
           ├──► Shutdown current round manager
           ├──► Extract new ValidatorSet from on_chain_configs
           ├──► Create new EpochState
           ├──► Initialize safety rules for new epoch
           ├──► Start new round manager
           │
           ▼
    ┌──────────────────────────────┐
    │ New Epoch Begins!            │
    │ Consensus operates with new  │
    │ validator set                │
    └──────────────────────────────┘
```

---

## Key Function Calls Summary

### Move Framework Functions

| Function | Module | Purpose |
|----------|--------|---------|
| `block_prologue_ext()` | `block` | Entry point, checks epoch timer |
| `try_start()` | `reconfiguration_with_dkg` | Initiates DKG-based reconfiguration |
| `dkg::start()` | `dkg` | Emits `DKGStartEvent`, starts DKG session |
| `finish_with_dkg_result()` | `reconfiguration_with_dkg` | Called by VM when DKG result arrives |
| `dkg::finish()` | `dkg` | Stores DKG transcript |
| `finish()` | `reconfiguration_with_dkg` | Applies buffered configs |
| `reconfigure()` | `reconfiguration` | Computes new validator set, emits `NewEpochEvent` |
| `stake::on_new_epoch()` | `stake` | Processes stake changes, computes `ValidatorSet` |

### Rust/VM Functions

| Function | Location | Purpose |
|----------|----------|---------|
| `process_dkg_result()` | `aptos-vm/.../dkg.rs` | Validates and executes DKG result |
| `on_dkg_start_notification()` | `dkg/epoch_manager.rs` | Handles `DKGStartEvent` |
| `process_dkg_start_event()` | `dkg/dkg_manager/mod.rs` | Starts DKG transcript generation |
| `process_aggregated_transcript()` | `dkg/dkg_manager/mod.rs` | Submits DKG result to vtxn pool |
| `await_reconfig_notification()` | `consensus/epoch_manager.rs` | Waits for epoch change |
| `on_new_epoch()` | `consensus/epoch_manager.rs` | Starts new epoch in consensus |

---

## Event Subscription Setup

The subscription to reconfiguration events is set up during node startup:

```rust
// aptos-node/src/state_sync.rs
let reconfig_events = event_subscription_service
    .subscribe_to_reconfigurations()
    .expect("Consensus must subscribe to reconfigurations");

let dkg_start_events = event_subscription_service
    .subscribe_to_events(vec![], vec!["0x1::dkg::DKGStartEvent".to_string()])
    .expect("Consensus must subscribe to DKG events");
```

---

## Key Data Structures

### ValidatorSet (On-Chain)
```move
struct ValidatorSet has copy, drop, store, key {
    consensus_scheme: u8,
    active_validators: vector<ValidatorInfo>,
    pending_inactive: vector<ValidatorInfo>,
    pending_active: vector<ValidatorInfo>,
    total_voting_power: u128,
    total_joining_power: u128,
}
```

### ReconfigNotification (Rust)
```rust
pub struct ReconfigNotification<P: OnChainConfigProvider> {
    pub version: Version,
    pub on_chain_configs: OnChainConfigPayload<P>,
}
```

The `on_chain_configs` contains:
- `ValidatorSet` - The new validator set
- `OnChainConsensusConfig` - Consensus parameters
- `OnChainExecutionConfig` - Execution parameters
- `OnChainRandomnessConfig` - Randomness parameters
- And other on-chain configs...

---

## Simple Reconfiguration (DKG Disabled)

When DKG is disabled, the flow is simpler:

```
    block_prologue()
           │
           │ if (timestamp - last_reconfiguration_time >= epoch_interval)
           ▼
    reconfiguration::reconfigure()
           │
           ├──► stake::on_new_epoch()
           ├──► Emit NewEpochEvent
           │
           ▼
    Consensus sees ReconfigNotification
           │
           ▼
    New epoch begins immediately
```

Or through governance:

```
    aptos_governance::reconfigure()
           │
           │ if (DKG not enabled)
           ▼
    reconfiguration_with_dkg::finish()
           │
           ▼
    reconfiguration::reconfigure()
           │
           ▼
    NewEpochEvent emitted
```

---

## Reconfiguration State Machine

```
                    ┌───────────────┐
                    │  StateInactive │
                    │  (normal ops)  │
                    └───────┬───────┘
                            │
            on_reconfig_start() 
         (epoch timer expired OR
          governance reconfigure)
                            │
                            ▼
                    ┌───────────────┐
                    │  StateActive   │
                    │ (DKG running)  │
                    │               │
                    │ Validator set │
                    │ changes are   │
                    │ BLOCKED       │
                    └───────┬───────┘
                            │
            on_reconfig_finish()
         (after NewEpochEvent emitted)
                            │
                            ▼
                    ┌───────────────┐
                    │  StateInactive │
                    │  (new epoch)   │
                    └───────────────┘
```

---

## Summary: The Key Event

**Q: Which event is the key event that tells consensus about the validator set of the next epoch?**

**A: `NewEpochEvent` (or `NewEpoch`)** emitted by `reconfiguration::reconfigure()`

This event:
1. Is detected by State Sync's `EventSubscriptionService`
2. Triggers `notify_reconfiguration_subscribers()` 
3. Causes a `ReconfigNotification` to be sent to consensus
4. The notification contains fresh on-chain configs including the new `ValidatorSet`
5. Consensus `EpochManager` receives this and transitions to the new epoch

The `DKGStartEvent` is important for **starting** the DKG protocol, but it does NOT trigger the epoch change. Only `NewEpochEvent` actually signals the epoch transition to consensus.


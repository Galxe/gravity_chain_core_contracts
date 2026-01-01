## Aptos Framework contract dependency diagram (validators / stake / timestamp / epoch / governance)

This document describes a practical **dependency diagram** for the Aptos framework Move modules involved in:

- **validators** (validator set membership + validator consensus identities)
- **stake** (stake pools, rewards, lockups, joining/leaving validator set)
- **timestamp** (on-chain time source)
- **epoch** (epoch transitions, i.e., “reconfiguration”)
- **governance** (proposal + voting + applying config changes)

It is based on the on-chain modules in this repo (e.g. `sources/stake.move`, `sources/reconfiguration.move`, `sources/block.move`, `sources/aptos_governance.move`, etc.).

### Important naming note: “validators” is not a single module

In Aptos framework code, “validators” is best understood as a **cluster** of modules/resources:

- `aptos_framework::stake`: owns `ValidatorSet`, `ValidatorConfig`, stake pools, validator performance, fee/reward distribution.
- `aptos_framework::block`: enforces “who can propose blocks” via the current validator set, and triggers epoch transitions.
- `aptos_framework::staking_config`: defines min/max stake, lockup, reward parameters.
- `aptos_framework::consensus_config`: consensus config changes are buffered and applied on new epoch.
- `aptos_framework::validator_consensus_info`: common type used by stake/DKG to describe validators for consensus.
- `aptos_framework::reconfiguration*`: epoch change mechanism (see below).

### The core dependency loop (governance → reconfig → epoch → validator set)

This diagram focuses on the modules that directly implement governance-driven changes and epoch transitions.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                              CORE DEPENDENCY DIAGRAM                                        │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

                          ┌─────────────────────────┐
                          │      aptos_governance   │
                          │   (on-chain governance) │
                          └───────────┬─────────────┘
                                      │
            ┌─────────────────────────┼─────────────────────────┐
            │                         │                         │
            │ register/create/        │ voting power +          │ creates proposal
            │ vote/resolve            │ eligibility from        │ type (avoids cycles)
            ▼                         │ stake pools             ▼
   ┌────────────────────┐             │              ┌─────────────────────────┐
   │       voting       │             │              │   governance_proposal   │
   │  (generic voting)  │             │              │    (type indirection)   │
   └─────────┬──────────┘             │              └─────────────────────────┘
             │                        │
             │ uses time              │
             │ for expirations        │
             │                        ▼
             │             ┌─────────────────────────┐       uses params
             │             │         stake           │◄──────────────────────┐
             │             │ (validator set + pools) │                       │
             │             └───────────┬─────────────┘                       │
             │                         │                                     │
             │                         │ reads now_seconds()      ┌──────────┴──────────┐
             │                         │ for lockups              │   staking_config    │
             │                         │                          │ (stake/reward params)│
             ▼                         ▼                          └─────────────────────┘
   ┌─────────────────────────────────────────────────┐
   │                   timestamp                     │
   │               (on-chain time)                   │
   └─────────────────────────────────────────────────┘
                         ▲
                         │ reads now_microseconds()
                         │
             ┌───────────┴───────────┐
             │    reconfiguration    │◄────────────┐
             │   (epoch transition)  │             │
             └───────────┬───────────┘             │
                         │                         │
       ┌─────────────────┼─────────────────┐       │
       │                 │                 │       │
       │ marks           │ on epoch        │       │ epoch timeout check
       │ start/finish    │ change: calls   │       │ (block_prologue)
       ▼                 │ on_new_epoch()  │       │
┌──────────────────┐     │                 │       │
│reconfiguration_  │     │                 │       │
│     state        │     │                 │       │
│(reconfig in-     │     │                 │       │
│ progress flag)   │     │                 │       │
└──────────────────┘     │                 │       │
                         │                 │       │
                         ▼                 │       │
             ┌─────────────────────────┐   │       │
             │         stake           │◄──┘       │
             └─────────────────────────┘           │
                                                   │
             ┌─────────────────────────┐           │
             │         block           ├───────────┘
             │  (block prologue/       │
             │   epilogue)             │
             └───────────┬─────────────┘
                         │
                         │ time is part of
                         │ block metadata
                         ▼
             ┌─────────────────────────┐
             │       timestamp         │
             └─────────────────────────┘
```

**Legend:**
- `─▶` = calls / reads / uses
- Each box = a Move module under `aptos_framework::`

### Extended diagram: buffered configs + DKG + "reconfigure with DKG"

Some on-chain config changes are intentionally **buffered** (written "for next epoch") and then applied at epoch boundary.
Also, some networks use `reconfiguration_with_dkg` to incorporate distributed key generation / randomness-related updates.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                        EXTENDED DIAGRAM (DKG + BUFFERED CONFIGS)                            │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

    ┌─────────────────────────┐
    │    aptos_governance     │
    └───────────┬─────────────┘
                │ can update configs
                │ via proposals
                ▼
    ┌─────────────────────────┐      set_for_next_epoch()     ┌─────────────────────────┐
    │    consensus_config     │─────────────────────────────▶│     config_buffer       │
    │       (buffered)        │          upsert               │  (std::config_buffer)   │
    └───────────┬─────────────┘                               └─────────────────────────┘
                ▲
                │ on new epoch:
                │ consensus_config::on_new_epoch()
                │
    ┌───────────┴─────────────────────────────────────────────────────────────────────────┐
    │                                                                                     │
    │                         ┌───────────────────────────────┐                           │
    │                         │   reconfiguration_with_dkg    │                           │
    │                         └─────┬───────────┬─────────┬───┘                           │
    │                               │           │         │                               │
    │          ┌────────────────────┘           │         └──────────────┐                │
    │          │                                │                        │                │
    │          │ start/finish DKG               │ asks stake for         │ marks start   │
    │          │ around epoch                   │ cur/next validator     │               │
    │          ▼                                │ infos                  ▼               │
    │  ┌───────────────┐                        │            ┌──────────────────────┐    │
    │  │      dkg      │                        │            │ reconfiguration_state│    │
    │  └───────┬───────┘                        │            └──────────────────────┘    │
    │          │ uses                           │                        ▲               │
    │          ▼                                ▼                        │               │
    │  ┌───────────────────────┐    ┌─────────────────────────┐         │               │
    │  │ validator_consensus_  │◄───│         stake           │         │               │
    │  │       info (type)     │    │ (cur/next_validator_    │         │               │
    │  └───────────────────────┘    │  consensus_infos())     │         │               │
    │                               └────────────▲────────────┘         │               │
    │                                            │                      │               │
    │                                            │ calls                │               │
    │                                            │                      │               │
    │                               ┌────────────┴────────────┐         │               │
    │  then enters new epoch        │    reconfiguration      │─────────┘               │
    │  ─────────────────────────▶   │   (epoch transition)    │                         │
    │                               └────────────▲────────────┘                         │
    │                                            │                                      │
    └────────────────────────────────────────────┼──────────────────────────────────────┘
                                                 │
                        ┌────────────────────────┴────────────────────────┐
                        │                                                 │
                        │ epoch timeout                   epoch timeout   │
                        │                                 (DKG path)      │
                        │                                                 │
              ┌─────────┴─────────┐                                       │
              │       block       ├───────────────────────────────────────┘
              │  (block prologue) │
              └───────────────────┘


                     ┌──────────────────────────────────────────────────────┐
                     │              EPOCH TRANSITION FLOWS                   │
                     ├──────────────────────────────────────────────────────┤
                     │                                                      │
                     │  Path A (simple):                                    │
                     │    block ──▶ reconfiguration ──▶ stake::on_new_epoch │
                     │                                                      │
                     │  Path B (with DKG):                                  │
                     │    block ──▶ reconfiguration_with_dkg                │
                     │                    │                                 │
                     │                    ├──▶ dkg::start/finish            │
                     │                    ├──▶ consensus_config::on_new_epoch│
                     │                    ├──▶ (other buffered configs...)  │
                     │                    └──▶ reconfiguration::reconfigure │
                     │                              └──▶ stake::on_new_epoch│
                     │                                                      │
                     └──────────────────────────────────────────────────────┘
```

**Legend:**
- `──▶` = calls / reads / depends on
- Boxed modules = Move modules under `aptos_framework::`
- "buffered" configs use the `config_buffer` pattern: `set_for_next_epoch()` writes to buffer, `on_new_epoch()` applies

### Implementation Order (if re-implementing from scratch)

If you were to re-implement all these contracts from scratch, here's the order you should follow based on dependencies. Each layer only depends on layers above it.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                         IMPLEMENTATION ORDER (TOP → BOTTOM)                                 │
│                                                                                             │
│   Code modules from TOP to BOTTOM. Each layer depends only on layers ABOVE it.             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

══════════════════════════════════════════════════════════════════════════════════════════════
 LAYER 0: Foundation (no framework deps, only Move stdlib)
══════════════════════════════════════════════════════════════════════════════════════════════

   ┌──────────────────┐   ┌────────────────────────────┐   ┌─────────────────────┐
   │  system_addresses │   │  validator_consensus_info  │   │ governance_proposal │
   │   (address utils) │   │     (pure data type)       │   │  (pure data type)   │
   └──────────────────┘   └────────────────────────────┘   └─────────────────────┘
                                       │
                                       │  Note: These are leaf modules with
                                       │  no significant framework dependencies.
                                       ▼
══════════════════════════════════════════════════════════════════════════════════════════════
 LAYER 1: Time + Basic Config
══════════════════════════════════════════════════════════════════════════════════════════════

   ┌──────────────────────────────────────────────────────────────────────────────┐
   │                              timestamp                                        │
   │                                                                               │
   │   • Global wall clock (CurrentTimeMicroseconds resource)                     │
   │   • now_microseconds(), now_seconds()                                        │
   │   • Updated by VM in block prologue                                          │
   └──────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
   ┌──────────────────────────────────────────────────────────────────────────────┐
   │                            staking_config                                     │
   │                                                                               │
   │   • StakingConfig: min/max stake, lockup duration, reward rate               │
   │   • StakingRewardsConfig: reward rate decrease over time                     │
   │   • Reads timestamp for reward period calculations                           │
   └──────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
══════════════════════════════════════════════════════════════════════════════════════════════
 LAYER 2: Reconfiguration State + Generic Voting
══════════════════════════════════════════════════════════════════════════════════════════════

   ┌─────────────────────────────────┐       ┌─────────────────────────────────┐
   │      reconfiguration_state      │       │             voting              │
   │                                 │       │                                 │
   │  • StateInactive / StateActive  │       │  • Generic proposal/vote/resolve│
   │  • is_in_progress()             │       │  • Time-based expirations       │
   │  • on_reconfig_start/finish()   │       │  • Used by governance           │
   │  • Reads timestamp              │       │  • Reads timestamp              │
   └─────────────────────────────────┘       └─────────────────────────────────┘
                    │                                        │
                    └────────────────────┬───────────────────┘
                                         ▼
══════════════════════════════════════════════════════════════════════════════════════════════
 LAYER 3: Stake (THE BIG ONE)
══════════════════════════════════════════════════════════════════════════════════════════════

   ┌──────────────────────────────────────────────────────────────────────────────┐
   │                                 stake                                         │
   │                                                                               │
   │   Resources:                                                                  │
   │     • ValidatorSet (active, pending_active, pending_inactive)                │
   │     • ValidatorConfig, ValidatorInfo, ValidatorPerformance                   │
   │     • StakePool (active, inactive, pending_active, pending_inactive coins)   │
   │     • OwnerCapability                                                        │
   │                                                                               │
   │   Key functions:                                                              │
   │     • initialize_validator(), add_stake(), join_validator_set()              │
   │     • on_new_epoch() — called by reconfiguration                             │
   │     • cur/next_validator_consensus_infos() — used by DKG                     │
   │                                                                               │
   │   Depends on:                                                                 │
   │     • timestamp (lockups, renewals)                                          │
   │     • staking_config (min/max stake, reward rate)                            │
   │     • reconfiguration_state (assert_reconfig_not_in_progress)                │
   └──────────────────────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
══════════════════════════════════════════════════════════════════════════════════════════════
 LAYER 4: Reconfiguration (Epoch Driver)
══════════════════════════════════════════════════════════════════════════════════════════════

   ┌──────────────────────────────────────────────────────────────────────────────┐
   │                            reconfiguration                                    │
   │                                                                               │
   │   Resources:                                                                  │
   │     • Configuration (epoch number, last_reconfiguration_time)                │
   │                                                                               │
   │   Key functions:                                                              │
   │     • reconfigure() — THE epoch transition entry point                       │
   │       1. reconfiguration_state::on_reconfig_start()                          │
   │       2. stake::on_new_epoch()                                               │
   │       3. emit NewEpochEvent                                                  │
   │       4. reconfiguration_state::on_reconfig_finish()                         │
   │     • current_epoch(), last_reconfiguration_time()                           │
   │                                                                               │
   │   Depends on:                                                                 │
   │     • stake (on_new_epoch)                                                   │
   │     • timestamp (current time check)                                         │
   │     • reconfiguration_state                                                  │
   └──────────────────────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
══════════════════════════════════════════════════════════════════════════════════════════════
 LAYER 5: Block + Buffered Configs
══════════════════════════════════════════════════════════════════════════════════════════════

   ┌─────────────────────────────────┐       ┌─────────────────────────────────┐
   │        consensus_config         │       │            block                │
   │          (+ other configs)      │       │                                 │
   │                                 │       │  • block_prologue() — VM entry  │
   │  • set_for_next_epoch()         │       │  • Checks epoch timeout         │
   │  • on_new_epoch() — applies     │       │  • Triggers reconfigure() or    │
   │    buffered config              │       │    reconfiguration_with_dkg     │
   │  • Uses config_buffer pattern   │       │  • Updates timestamp            │
   │                                 │       │  • Records validator performance│
   │  Depends on: reconfiguration    │       │                                 │
   └─────────────────────────────────┘       │  Depends on:                    │
                    │                        │    • timestamp                  │
                    │                        │    • reconfiguration            │
                    │                        │    • stake                      │
                    │                        └─────────────────────────────────┘
                    │                                        │
                    └────────────────────┬───────────────────┘
                                         ▼
══════════════════════════════════════════════════════════════════════════════════════════════
 LAYER 6: DKG + Reconfiguration with DKG
══════════════════════════════════════════════════════════════════════════════════════════════

   ┌─────────────────────────────────┐       ┌─────────────────────────────────┐
   │              dkg                │       │    reconfiguration_with_dkg     │
   │                                 │       │                                 │
   │  • DKG session management       │       │  • try_start() — begins async   │
   │  • start(), finish()            │       │    epoch transition             │
   │  • Uses validator_consensus_    │       │  • finish() — applies buffered  │
   │    info from stake              │       │    configs then reconfigure()   │
   │                                 │       │                                 │
   │  Depends on:                    │       │  Depends on:                    │
   │    • stake (validator infos)    │       │    • dkg                        │
   │    • reconfiguration_state      │       │    • reconfiguration            │
   │    • randomness_config          │       │    • stake                      │
   └─────────────────────────────────┘       │    • consensus_config           │
                                             │    • (many buffered configs)    │
                                             └─────────────────────────────────┘
                                                             │
                                                             ▼
══════════════════════════════════════════════════════════════════════════════════════════════
 LAYER 7: Governance (TOP OF THE STACK)
══════════════════════════════════════════════════════════════════════════════════════════════

   ┌──────────────────────────────────────────────────────────────────────────────┐
   │                            aptos_governance                                   │
   │                                                                               │
   │   Resources:                                                                  │
   │     • GovernanceConfig (voting thresholds, durations)                        │
   │     • VotingRecords, ApprovedExecutionHashes                                 │
   │                                                                               │
   │   Key functions:                                                              │
   │     • create_proposal() — requires min stake + lockup                        │
   │     • vote() — voting power from stake pool                                  │
   │     • resolve() — execute approved proposals                                 │
   │     • reconfigure() — trigger epoch after gov proposal passes                │
   │                                                                               │
   │   Depends on:                                                                 │
   │     • stake (voting power, lockup checks)                                    │
   │     • voting (generic proposal engine)                                       │
   │     • governance_proposal (type indirection)                                 │
   │     • timestamp (proposal expiration)                                        │
   │     • reconfiguration_with_dkg (triggering reconfig)                         │
   └──────────────────────────────────────────────────────────────────────────────┘


══════════════════════════════════════════════════════════════════════════════════════════════
 SUMMARY: Implementation Order Checklist
══════════════════════════════════════════════════════════════════════════════════════════════

   □ Layer 0: system_addresses, validator_consensus_info, governance_proposal
   □ Layer 1: timestamp, staking_config
   □ Layer 2: reconfiguration_state, voting
   □ Layer 3: stake  ←── This is the largest and most complex module
   □ Layer 4: reconfiguration
   □ Layer 5: block, consensus_config (and other buffered configs)
   □ Layer 6: dkg, reconfiguration_with_dkg
   □ Layer 7: aptos_governance

   Total: ~12-15 modules for the core validator/epoch/governance system

══════════════════════════════════════════════════════════════════════════════════════════════
```

**Key insight:** The `stake` module (Layer 3) is the **biggest dependency bottleneck**. Almost everything above it depends on it. If you're re-implementing, expect to spend the most time on `stake`.

### How to read "dependencies" in this doc

Each arrow means at least one of:

- **Cross-module call** (e.g., `reconfiguration::reconfigure()` calling `stake::on_new_epoch()`).
- **Resource coupling** (a module reads/writes a resource another module defines, or relies on its invariants).
- **Epoch boundary semantics** (a module’s state is designed to be applied “at next epoch”, so it depends on the epoch mechanism).

This is intentionally more useful than “just imports”.

### Module roles and key edges (short explanations)

- **`block` → `reconfiguration` (epoch trigger)**:
  - `block::block_prologue` checks whether `timestamp - reconfiguration::last_reconfiguration_time()` exceeds the configured `epoch_interval`.
  - If yes, it triggers an epoch transition via `reconfiguration::reconfigure()` (or starts the DKG flow via `reconfiguration_with_dkg::try_start()`).

- **`reconfiguration` → `stake` (epoch transition work)**:
  - `reconfiguration::reconfigure()` is the “enter new epoch” driver.
  - It calls `stake::on_new_epoch()` to:
    - distribute rewards/fees,
    - move pending stake between buckets (pending_active/pending_inactive),
    - compute the next `ValidatorSet` and validator indices,
    - renew lockups when appropriate.

- **`stake` → `staking_config` (policy parameters)**:
  - `staking_config` defines policy knobs: min/max stake, lockup duration, reward rate, voting power increase limits.
  - `stake` reads these to enforce validator eligibility and to compute rewards/lockups on epoch boundaries.

- **`timestamp` as a global dependency**:
  - `timestamp` is used for:
    - epoch timing (via `block` and `reconfiguration`),
    - stake lockups and renewals (via `stake`),
    - voting / proposal expiration (via `voting` and `aptos_governance`).

- **`aptos_governance` → `stake` (governance voting power)**:
  - Governance derives proposer/voter voting power from the **backing stake pool**.
  - Governance also checks stake lockup duration vs proposal voting duration, so stake lockups become a governance dependency.

- **`aptos_governance` → `voting` (generic voting engine)**:
  - `voting` is a generic proposal/vote/resolve framework.
  - Aptos governance “hosts” a proposal type (via `voting::register`) and uses `voting::create_proposal` / `vote` / `resolve` under the hood.

- **Why `governance_proposal` exists**:
  - `governance_proposal` provides the `GovernanceProposal` type as an indirection layer “to avoid circular dependency” with `stake`.
  - In other words: it’s a dependency-graph hack to keep modules acyclic.

### Where permissions fit (why many calls are “friend” or system-only)

The dependency graph is also enforced by access control:

- `timestamp::update_global_time` can only be invoked by the VM signer (`system_addresses::assert_vm`).
- `reconfiguration::reconfigure` is `public(friend)` and only callable by whitelisted modules (e.g. `block`, config modules, `aptos_governance`, etc.).
- Many “apply on new epoch” functions are `public(friend)` and intended to be invoked only during reconfiguration.

This is why “epoch transition” logic forms a tight core: `block` (VM-driven) → `reconfiguration` (friend-gated) → `stake` (friend-gated).

### A few more modules you’ll likely want in a full “validators” dependency diagram

If you want the “complete” validator/epoch picture beyond the five modules you listed, these are the most relevant additions:

- **`reconfiguration_with_dkg` + `dkg` + `randomness_config*`**: async epoch transitions with DKG/randomness.
- **`execution_config`, `gas_schedule`, `version`, `features`**: buffered configs applied at epoch boundaries (often via `*_::on_new_epoch`).
- **`jwk_consensus_config`, `jwks`, `keyless_account`**: identity/auth-related configs applied on new epoch in the DKG reconfig flow.

If you want, I can extend the diagram to include these modules explicitly (it gets bigger, but can be split into layered subgraphs).



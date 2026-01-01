# Aptos Staking and Governance Deep Dive

This document provides a detailed technical analysis of how Aptos implements staking and governance. It serves as a reference for building similar systems on other blockchains (e.g., EVM chains).

---

## Table of Contents

1. [Staking System](#staking-system)
   - [Overview](#overview)
   - [Core Data Structures](#core-data-structures)
   - [Validator Lifecycle](#validator-lifecycle)
   - [Stake States and Transitions](#stake-states-and-transitions)
   - [Staking Configuration Parameters](#staking-configuration-parameters)
   - [Rewards System](#rewards-system)
   - [Delegation Pools](#delegation-pools)
   - [Epoch and Reconfiguration](#epoch-and-reconfiguration)
2. [Governance System](#governance-system)
   - [Overview](#governance-overview)
   - [Governance Configuration](#governance-configuration)
   - [Proposal Lifecycle](#proposal-lifecycle)
   - [Voting Mechanism](#voting-mechanism)
   - [Proposal Resolution](#proposal-resolution)
   - [Parameter Changes via Governance](#parameter-changes-via-governance)
3. [Key Design Patterns](#key-design-patterns)
4. [Security Considerations](#security-considerations)

---

## Staking System

### Overview

Aptos uses a **Delegated Proof-of-Stake (DPoS)** consensus mechanism where validators stake APT tokens to participate in block production and earn rewards. The system supports:

- Direct staking (validators stake their own tokens)
- Delegation pools (multiple delegators pool stakes to meet minimum requirements)
- Stake lockups with automatic renewal
- Performance-based rewards distribution

### Core Data Structures

#### StakePool

Each validator has a `StakePool` resource that tracks their stake in different states:

```move
struct StakePool has key {
    // Active stake participating in consensus
    active: Coin<AptosCoin>,
    // Inactive stake that can be withdrawn
    inactive: Coin<AptosCoin>,
    // Pending activation for next epoch
    pending_active: Coin<AptosCoin>,
    // Pending deactivation for next epoch
    pending_inactive: Coin<AptosCoin>,
    // Lockup expiration timestamp
    locked_until_secs: u64,
    // Operator who manages validator operations
    operator_address: address,
    // Delegated voter for governance
    delegated_voter: address,
}
```

#### ValidatorSet

Global state tracking all validators:

```move
struct ValidatorSet has copy, key, drop, store {
    consensus_scheme: u8,
    // Active validators for current epoch
    active_validators: vector<ValidatorInfo>,
    // Validators leaving in next epoch (still active now)
    pending_inactive: vector<ValidatorInfo>,
    // Validators joining in next epoch
    pending_active: vector<ValidatorInfo>,
    // Current total voting power
    total_voting_power: u128,
    // Total voting power waiting to join
    total_joining_power: u128,
}
```

#### ValidatorInfo

Individual validator information:

```move
struct ValidatorInfo has copy, store, drop {
    addr: address,
    voting_power: u64,
    config: ValidatorConfig,
}

struct ValidatorConfig has key, copy, store, drop {
    consensus_pubkey: vector<u8>,
    network_addresses: vector<u8>,
    fullnode_addresses: vector<u8>,
    validator_index: u64,
}
```

### Validator Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         VALIDATOR LIFECYCLE                                  │
└─────────────────────────────────────────────────────────────────────────────┘

  1. INITIALIZE                    2. ADD STAKE                  3. JOIN
  ┌──────────────┐                ┌──────────────┐             ┌──────────────┐
  │ initialize_  │                │  add_stake   │             │join_validator│
  │  validator   │───────────────▶│              │────────────▶│    _set      │
  └──────────────┘                └──────────────┘             └──────────────┘
        │                               │                            │
        ▼                               ▼                            ▼
   Create StakePool             Deposit tokens              Move to pending_active
   Create ValidatorConfig        (to active or               (changes effective
   Set operator/voter            pending_active)              next epoch)

  4. VALIDATE                      5. UNLOCK                   6. LEAVE/WITHDRAW
  ┌──────────────┐                ┌──────────────┐             ┌──────────────┐
  │   Earn       │                │   unlock     │             │leave_validator│
  │  Rewards     │───────────────▶│              │────────────▶│   _set       │
  └──────────────┘                └──────────────┘             └──────────────┘
        │                               │                            │
        ▼                               ▼                            ▼
   Auto-renew lockup             Move active to              Move to pending_inactive
   Distribute rewards            pending_inactive            or remove if pending_active
```

#### Key Operations

1. **`initialize_validator`**: Creates `StakePool` and `ValidatorConfig` for a new validator
2. **`add_stake`**: Adds tokens to the stake pool
3. **`join_validator_set`**: Requests to become an active validator (effective next epoch)
4. **`leave_validator_set`**: Requests to leave the validator set
5. **`unlock`**: Moves stake from active to pending_inactive for withdrawal
6. **`withdraw`**: Withdraws inactive stake after lockup expires
7. **`rotate_consensus_key`**: Updates validator's consensus key
8. **`set_operator`**: Changes the operator address
9. **`set_delegated_voter`**: Changes the delegated voter for governance

### Stake States and Transitions

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         STAKE STATE MACHINE                                  │
└─────────────────────────────────────────────────────────────────────────────┘

                              ┌──────────────┐
                     add_stake│              │
            ┌─────────────────┤   ACTIVE     │◄────────────────┐
            │     (if active) │              │                 │
            │                 └──────┬───────┘                 │
            │                        │                         │
            ▼                        │ unlock                  │ reactivate_stake
    ┌──────────────┐                 ▼                         │
    │   PENDING    │          ┌──────────────┐                 │
    │   ACTIVE     │          │   PENDING    │─────────────────┘
    └──────┬───────┘          │  INACTIVE    │
           │                  └──────┬───────┘
           │ on_new_epoch            │
           │                         │ on_new_epoch (if lockup expired)
           ▼                         ▼
    ┌──────────────┐          ┌──────────────┐
    │   ACTIVE     │          │   INACTIVE   │────► withdraw
    └──────────────┘          └──────────────┘

State Transitions by Epoch:
─────────────────────────────
• pending_active → active (at epoch start)
• pending_inactive → inactive (at epoch start, if lockup expired)
```

#### Validator Status States

```move
const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;  // Will become active next epoch
const VALIDATOR_STATUS_ACTIVE: u64 = 2;          // Currently validating
const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;// Will become inactive next epoch
const VALIDATOR_STATUS_INACTIVE: u64 = 4;        // Not in validator set
```

### Staking Configuration Parameters

#### StakingConfig

```move
struct StakingConfig has copy, drop, key {
    // Minimum stake to join validator set
    minimum_stake: u64,
    // Maximum stake allowed per validator
    maximum_stake: u64,
    // Auto-renewal lockup duration
    recurring_lockup_duration_secs: u64,
    // Whether validators can join/leave post-genesis
    allow_validator_set_change: bool,
    // Rewards rate numerator (DEPRECATING)
    rewards_rate: u64,
    // Rewards rate denominator (DEPRECATING)
    rewards_rate_denominator: u64,
    // Max % of voting power that can join per epoch (0-50%)
    voting_power_increase_limit: u64,
}
```

#### StakingRewardsConfig

Advanced rewards configuration with decreasing rate over time:

```move
struct StakingRewardsConfig has copy, drop, key {
    // Target rewards rate per epoch
    rewards_rate: FixedPoint64,
    // Minimum rewards rate floor
    min_rewards_rate: FixedPoint64,
    // Period for rate decrease (typically 1 year)
    rewards_rate_period_in_secs: u64,
    // Start of last rewards period
    last_rewards_rate_period_start_in_secs: u64,
    // Rate of decrease per period (in BPS)
    rewards_rate_decrease_rate: FixedPoint64,
}
```

#### Key Parameters & Limits

| Parameter | Description | Typical Value |
|-----------|-------------|---------------|
| `minimum_stake` | Min stake to be validator | Chain-specific |
| `maximum_stake` | Max stake per validator | Chain-specific |
| `recurring_lockup_duration_secs` | Lockup period | ~30 days |
| `voting_power_increase_limit` | Max % new validators per epoch | 15-50% |
| `MAX_VALIDATOR_SET_SIZE` | Max validators | 65,536 |
| `MAX_REWARDS_RATE` | Max rewards numerator | 1,000,000 |

### Rewards System

#### Reward Calculation

Rewards are distributed at each epoch end based on:
1. **Stake amount**: Active + pending_inactive stake
2. **Performance**: Successful vs failed proposals
3. **Rewards rate**: Configurable rate that can decrease over time

```move
// Simplified reward calculation
fun calculate_rewards_amount(
    stake_amount: u64,
    num_successful_proposals: u64,
    num_total_proposals: u64,
    rewards_rate: u64,
    rewards_rate_denominator: u64,
): u64 {
    // rewards = stake * (successful/total) * (rate/denominator)
    let rewards_numerator = (stake_amount as u128) 
        * (num_successful_proposals as u128) 
        * (rewards_rate as u128);
    let rewards_denominator = (num_total_proposals as u128) 
        * (rewards_rate_denominator as u128);
    ((rewards_numerator / rewards_denominator) as u64)
}
```

#### Reward Distribution Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      REWARD DISTRIBUTION (on_new_epoch)                      │
└─────────────────────────────────────────────────────────────────────────────┘

  1. For each active validator:
     ┌─────────────────────────────────────────────────────────────┐
     │ a) Calculate rewards based on:                              │
     │    - Active stake amount                                    │
     │    - Validator performance (successful/failed proposals)    │
     │    - Current rewards rate                                   │
     │                                                             │
     │ b) Distribute transaction fees collected during epoch       │
     │                                                             │
     │ c) Mint new tokens as rewards                               │
     │                                                             │
     │ d) Add rewards + fees to validator's active stake           │
     └─────────────────────────────────────────────────────────────┘

  2. Process pending stakes:
     ┌─────────────────────────────────────────────────────────────┐
     │ - pending_active → active                                   │
     │ - pending_inactive → inactive (if lockup expired)           │
     └─────────────────────────────────────────────────────────────┘

  3. Update validator set:
     ┌─────────────────────────────────────────────────────────────┐
     │ - Activate pending_active validators                        │
     │ - Remove pending_inactive validators                        │
     │ - Remove validators below minimum stake                     │
     │ - Auto-renew lockups                                        │
     └─────────────────────────────────────────────────────────────┘
```

#### Rewards Rate Decrease

The rewards rate can decrease over time:

```move
// Rate decreases each period (e.g., annually)
new_rate = current_rate * (1 - decrease_rate)
new_rate = max(new_rate, min_rewards_rate)  // Floor protection
```

### Delegation Pools

Delegation pools allow multiple delegators to pool their stakes together to meet validator requirements.

#### Key Features

1. **Shares-based Accounting**: Delegators own shares rather than absolute stakes
2. **Commission**: Operators receive commission from pool rewards
3. **Lockup Cycle Tracking**: Tracks inactive stakes across lockup cycles
4. **Proportional Rewards**: Rewards distributed based on share ownership

#### DelegationPool Structure

```move
struct DelegationPool has key {
    // Shares pool of active + pending_active stake
    active_shares: pool_u64::Pool,
    // Current observed lockup cycle index
    observed_lockup_cycle: ObservedLockupCycle,
    // Shares pools for inactive stake per OLC
    inactive_shares: Table<ObservedLockupCycle, pool_u64::Pool>,
    // Pending withdrawals mapping
    pending_withdrawals: Table<address, ObservedLockupCycle>,
    // Resource account signer capability
    stake_pool_signer_cap: SignerCapability,
    // Total inactive coins
    total_coins_inactive: u64,
    // Operator commission (0-100%)
    operator_commission_percentage: u64,
}
```

#### Delegation Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DELEGATION POOL FLOW                                 │
└─────────────────────────────────────────────────────────────────────────────┘

  Delegator A                    Delegation Pool                  Stake Pool
  ───────────                    ───────────────                  ──────────
       │                               │                               │
       │ add_stake(100 APT)            │                               │
       │──────────────────────────────▶│                               │
       │                               │ stake(100 APT)                │
       │                               │──────────────────────────────▶│
       │                               │                               │
       │   receive shares              │   add to pending_active       │
       │◀──────────────────────────────│                               │
       │                               │                               │
       │                    ┌──────────┴──────────┐                    │
       │                    │ Synchronize at      │                    │
       │                    │ each interaction:   │                    │
       │                    │ - Query stake pool  │                    │
       │                    │ - Calculate rewards │                    │
       │                    │ - Pay commission    │                    │
       │                    │ - Update shares     │                    │
       │                    └──────────┬──────────┘                    │
       │                               │                               │
       │ unlock(50 APT)                │                               │
       │──────────────────────────────▶│                               │
       │                               │ unlock(50 APT)                │
       │                               │──────────────────────────────▶│
       │                               │                               │
       │   shares updated              │                               │
       │◀──────────────────────────────│                               │
```

### Epoch and Reconfiguration

#### Epoch Transition

Epochs represent fixed time periods where the validator set remains constant. At epoch boundaries:

```move
public(friend) fun on_new_epoch() {
    // 1. Distribute rewards to active validators
    for validator in active_validators {
        update_stake_pool(validator);
    }
    
    // 2. Process pending_inactive validators
    for validator in pending_inactive {
        update_stake_pool(validator);
    }
    
    // 3. Activate pending validators
    active_validators.append(pending_active);
    
    // 4. Deactivate leaving validators
    pending_inactive = empty;
    
    // 5. Remove underfunded validators
    // 6. Update validator indices
    // 7. Renew lockups
    // 8. Update rewards rate if needed
}
```

#### Reconfiguration

```move
public(friend) fun reconfigure() {
    // Called when configuration changes (e.g., governance proposals)
    
    reconfiguration_state::on_reconfig_start();
    
    // Process stake changes and distribute rewards
    stake::on_new_epoch();
    storage_gas::on_reconfig();
    
    // Increment epoch
    config.epoch = config.epoch + 1;
    
    // Emit reconfiguration event
    event::emit(NewEpoch { epoch: config.epoch });
    
    reconfiguration_state::on_reconfig_finish();
}
```

---

## Governance System

### Governance Overview

Aptos governance allows on-chain proposal and voting for protocol changes. Key characteristics:

- **Stake-weighted voting**: Voting power derived from staked tokens
- **Lockup requirements**: Voters must have stake locked through proposal expiration
- **Execution scripts**: Proposals contain hashes of scripts to execute upon passing
- **Multi-step proposals**: Support for complex proposals with multiple execution steps

### Governance Configuration

```move
struct GovernanceConfig has key {
    // Minimum votes required to pass a proposal
    min_voting_threshold: u128,
    // Minimum stake required to create a proposal
    required_proposer_stake: u64,
    // Duration of voting period in seconds
    voting_duration_secs: u64,
}
```

### Proposal Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PROPOSAL LIFECYCLE                                   │
└─────────────────────────────────────────────────────────────────────────────┘

  1. CREATE PROPOSAL            2. VOTING PERIOD              3. RESOLUTION
  ┌──────────────┐             ┌──────────────┐             ┌──────────────┐
  │ create_      │             │              │             │   resolve    │
  │ proposal     │────────────▶│    vote()    │────────────▶│              │
  └──────────────┘             └──────────────┘             └──────────────┘
        │                            │                            │
        ▼                            ▼                            ▼
  Requirements:                Voting Power:                Success Criteria:
  - min proposer stake         - From stake pool            - yes > no
  - lockup >= proposal end     - Partial voting allowed     - total >= threshold
  - execution hash provided    - Can vote multiple times    - Can resolve early
                               - lockup >= proposal end       if >50% supply voted

  Proposal States:
  ─────────────────
  PENDING (0)    → Voting still active
  SUCCEEDED (1)  → Ready to execute
  FAILED (3)     → Did not pass
```

#### Proposal Structure

```move
struct Proposal<ProposalType: store> has store {
    proposer: address,
    execution_content: Option<ProposalType>,
    metadata: SimpleMap<String, vector<u8>>,
    creation_time_secs: u64,
    execution_hash: vector<u8>,      // Hash of script to execute
    min_vote_threshold: u128,
    expiration_secs: u64,
    early_resolution_vote_threshold: Option<u128>,
    yes_votes: u128,
    no_votes: u128,
    is_resolved: bool,
    resolution_time_secs: u64,
}
```

### Voting Mechanism

#### Voting Power Calculation

```move
public fun get_voting_power(pool_address: address): u64 {
    if (allow_validator_set_change) {
        // Include all non-inactive stake
        let (active, _, pending_active, pending_inactive) = stake::get_stake(pool_address);
        active + pending_active + pending_inactive
    } else {
        // Only current epoch voting power
        stake::get_current_epoch_voting_power(pool_address)
    }
}
```

#### Voting Rules

1. **Lockup Requirement**: Stake must be locked at least until proposal expiration
2. **Partial Voting**: Can split voting power between yes/no across multiple transactions
3. **Delegation**: Owner can delegate voting to another address
4. **No Double Voting**: Each stake pool tracks used voting power per proposal

#### Vote Implementation

```move
public entry fun vote(
    voter: &signer,
    stake_pool: address,
    proposal_id: u64,
    should_pass: bool,
) {
    // 1. Verify voter is delegated voter for stake pool
    assert!(stake::get_delegated_voter(stake_pool) == voter_address);
    
    // 2. Check lockup is sufficient
    assert!(stake::get_lockup_secs(stake_pool) >= proposal_expiration);
    
    // 3. Get remaining voting power
    let voting_power = get_remaining_voting_power(stake_pool, proposal_id);
    
    // 4. Cast vote
    voting::vote(proposal_id, voting_power, should_pass);
    
    // 5. Record used voting power
    record_vote(stake_pool, proposal_id, voting_power);
    
    // 6. Check for early resolution
    if (proposal_state == SUCCEEDED) {
        add_approved_script_hash(proposal_id);
    }
}
```

#### Partial Voting

```move
struct VotingRecordsV2 has key {
    // Tracks voting power used per (stake_pool, proposal_id)
    votes: SmartTable<RecordKey, u64>
}

public fun get_remaining_voting_power(stake_pool: address, proposal_id: u64): u64 {
    let total_power = get_voting_power(stake_pool);
    let used_power = VotingRecordsV2.votes[(stake_pool, proposal_id)];
    total_power - used_power
}
```

### Proposal Resolution

#### Resolution Conditions

A proposal can be resolved when:
1. Voting period has ended AND yes_votes > no_votes AND total votes >= threshold
2. OR early resolution threshold reached (e.g., >50% of total supply voted yes/no)

```move
public fun get_proposal_state(proposal_id: u64): u64 {
    if (is_voting_closed(proposal_id)) {
        let yes_votes = proposal.yes_votes;
        let no_votes = proposal.no_votes;
        
        if (yes_votes > no_votes && yes_votes + no_votes >= min_threshold) {
            PROPOSAL_STATE_SUCCEEDED  // 1
        } else {
            PROPOSAL_STATE_FAILED     // 3
        }
    } else {
        PROPOSAL_STATE_PENDING        // 0
    }
}

public fun can_be_resolved_early(proposal): bool {
    // Check if early resolution threshold (e.g., 50% of total supply) is met
    if (yes_votes >= early_threshold || no_votes >= early_threshold) {
        return true
    }
    false
}
```

#### Execution Flow

```move
public fun resolve(proposal_id: u64, signer_address: address): signer {
    // 1. Verify proposal succeeded
    assert!(get_proposal_state(proposal_id) == SUCCEEDED);
    
    // 2. Verify not already resolved
    assert!(!proposal.is_resolved);
    
    // 3. Verify execution script hash matches
    assert!(transaction_context::get_script_hash() == proposal.execution_hash);
    
    // 4. Prevent atomic resolution (must be different tx from last vote)
    assert!(timestamp::now_seconds() > resolvable_time);
    
    // 5. Mark as resolved
    proposal.is_resolved = true;
    
    // 6. Return signer capability for framework account
    get_signer(signer_address)  // Usually @aptos_framework (0x1)
}
```

### Parameter Changes via Governance

#### Pattern for Governance-Controlled Parameters

```move
// Example: Updating staking config via governance
public fun update_required_stake(
    aptos_framework: &signer,  // Obtained from resolve()
    minimum_stake: u64,
    maximum_stake: u64,
) {
    // Verify caller is framework account (governance)
    system_addresses::assert_aptos_framework(aptos_framework);
    
    // Update parameters
    let staking_config = borrow_global_mut<StakingConfig>(@aptos_framework);
    staking_config.minimum_stake = minimum_stake;
    staking_config.maximum_stake = maximum_stake;
}
```

#### Full Governance Flow for Parameter Changes

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  GOVERNANCE PARAMETER CHANGE FLOW                            │
└─────────────────────────────────────────────────────────────────────────────┘

  STEP 1: Create Proposal Script
  ──────────────────────────────
  Script that calls parameter update function:
  
    script {
        use aptos_framework::staking_config;
        
        fun main(framework_signer: signer) {
            staking_config::update_required_stake(
                &framework_signer,
                new_min_stake,
                new_max_stake
            );
        }
    }

  STEP 2: Submit Proposal
  ───────────────────────
    aptos_governance::create_proposal(
        proposer,
        stake_pool,
        execution_hash,        // SHA-256 of script bytecode
        metadata_location,     // IPFS/URL to proposal details
        metadata_hash,
    );

  STEP 3: Community Votes
  ───────────────────────
    // Multiple stake pools vote
    aptos_governance::vote(voter, stake_pool, proposal_id, true/false);

  STEP 4: Resolve & Execute
  ─────────────────────────
    // After voting passes, execute the script
    // Script must match execution_hash
    
    script {
        use aptos_framework::aptos_governance;
        
        fun main() {
            // Get framework signer from governance
            let framework_signer = aptos_governance::resolve(
                proposal_id,
                @aptos_framework
            );
            
            // Execute parameter change
            staking_config::update_required_stake(
                &framework_signer,
                new_min_stake,
                new_max_stake
            );
            
            // Trigger reconfiguration if needed
            aptos_governance::reconfigure(&framework_signer);
        }
    }

  STEP 5: Reconfiguration (if needed)
  ───────────────────────────────────
    // Changes take effect at next epoch for most parameters
    // Some changes (like features) require DKG reconfiguration
```

#### Config Buffer Pattern

For parameters that need to be staged before activation:

```move
// Store pending config change
public fun upsert<T: copy + drop + store>(config: T) {
    // Store in buffer, activated on next reconfiguration
    if (exists<PendingConfigs>(@aptos_framework)) {
        let pending = borrow_global_mut<PendingConfigs>(@aptos_framework);
        pending.configs.upsert(type_info::type_name<T>(), any::pack(config));
    }
}

// Extract config during reconfiguration
public fun extract<T: copy + drop + store>(): T {
    let pending = borrow_global_mut<PendingConfigs>(@aptos_framework);
    let config = pending.configs.remove(&type_info::type_name<T>());
    any::unpack<T>(config)
}
```

---

## Key Design Patterns

### 1. Capability Pattern

Aptos uses capabilities to control privileged operations:

```move
struct OwnerCapability has key, store {
    pool_address: address,
}

// Transfer ownership
public fun extract_owner_cap(owner: &signer): OwnerCapability
public fun deposit_owner_cap(owner: &signer, cap: OwnerCapability)

// Use capability for operations
public fun add_stake_with_cap(owner_cap: &OwnerCapability, coins: Coin<AptosCoin>)
```

### 2. Role Separation

Three distinct roles for stake pools:

| Role | Responsibilities |
|------|-----------------|
| **Owner** | Owns stake, can extract/deposit capability, set operator/voter |
| **Operator** | Manages validator operations (join/leave, rotate keys) |
| **Voter** | Casts governance votes using stake pool's voting power |

### 3. Epoch-Based State Transitions

All major state changes are batched at epoch boundaries:
- Validator set changes
- Stake state transitions
- Reward distribution
- Lockup renewals

### 4. Anti-Flash Loan Protection

Governance includes protection against flash loan attacks:

```move
// Record timestamp when vote is cast
let resolvable_time = timestamp::now_seconds();

// Resolution must happen in a different transaction
assert!(timestamp::now_seconds() > resolvable_time);
```

### 5. Execution Hash Verification

Proposals specify execution hash upfront:

```move
// At proposal creation
execution_hash: vector<u8>,  // SHA-256 of script bytecode

// At resolution
assert!(transaction_context::get_script_hash() == execution_hash);
```

---

## Security Considerations

### Staking Security

1. **Minimum Stake**: Prevents Sybil attacks by requiring significant stake
2. **Maximum Stake**: Limits concentration of voting power
3. **Lockup Periods**: Prevents rapid stake churn attacks
4. **Voting Power Increase Limit**: Prevents sudden validator set takeover (max 50% per epoch)
5. **Lockup Expiration Check**: Only unlocked stake can be withdrawn

### Governance Security

1. **Proposer Stake Requirement**: Requires significant stake to create proposals
2. **Lockup Duration**: Proposer/voter stakes must be locked through voting period
3. **Non-Atomic Resolution**: Prevents same-transaction manipulation
4. **Execution Hash**: Ensures only intended code is executed
5. **Early Resolution Threshold**: Typically requires >50% of total supply

### Key Attack Mitigations

| Attack | Mitigation |
|--------|------------|
| Flash loan voting | Non-atomic resolution requirement |
| Validator set takeover | Voting power increase limit |
| Governance spam | Required proposer stake |
| Vote manipulation | Lockup requirements, execution hash |
| Double voting | Per-proposal voting power tracking |

---

## Implementation Notes for EVM Chains

When implementing similar systems on EVM:

### Staking

1. Use `mapping` for stake pools instead of Move resources
2. Implement epoch management via block numbers or timestamps
3. Use ERC-20 for stake token
4. Consider gas costs for reward distribution (may need merkle proofs)

### Governance

1. Use OpenZeppelin's Governor as a starting point
2. Implement custom voting power snapshots based on stake
3. Use timelock for proposal execution
4. Consider using CREATE2 for deterministic execution addresses

### Key Differences

| Aptos | EVM Considerations |
|-------|-------------------|
| Move resources | Solidity structs/mappings |
| Native epoch system | Block-based or timestamp-based epochs |
| Signer capabilities | Access control via modifiers |
| Table storage | Mappings with pagination |
| Events | Solidity events (similar) |

---

## Summary

Aptos implements a sophisticated DPoS system with:

- **4-state stake model**: active, inactive, pending_active, pending_inactive
- **Epoch-based transitions**: All changes batched at epoch boundaries
- **Delegation pools**: Allow small holders to participate
- **Performance rewards**: Based on proposal success rate
- **Stake-weighted governance**: Voting power from locked stake
- **Multi-step proposals**: Support for complex governance actions
- **Execution hash security**: Only pre-approved code can be executed

The design prioritizes security through lockups, capability-based access control, and careful state management across epochs.


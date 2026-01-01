## Aptos staking + governance (deep dive, framework-level)

This document summarizes **how Aptos (Move framework) implements staking and governance/voting**, grounded in the on-chain modules in `aptos-framework/sources/`.

Key idea: Aptos governance voting is **stake-pool-based**, and most “parameter changes” are implemented as **on-chain config resources** that become effective at **epoch boundaries** via **reconfiguration**.

---

### Scope + where to read the code

- **Staking core**: `sources/stake.move`, `sources/configs/staking_config.move`
- **Reconfiguration / epochs**: `sources/reconfiguration.move`, `sources/reconfiguration_with_dkg.move`
- **Governance (Aptos network governance)**: `sources/aptos_governance.move`, `sources/governance_proposal.move`
- **Generic voting primitive**: `sources/voting.move`
- **Delegated/community staking options**:
  - `sources/delegation_pool.move` (multi-delegator pool)
  - `sources/staking_contract.move` (staker/operator commission-sharing)
- **Config buffering pattern (parameter changes for next epoch)**: `sources/configs/config_buffer.move` + per-config modules (e.g. `sources/configs/consensus_config.move`)

Unless stated otherwise, the “system account” for core resources is `@aptos_framework` (Aptos mainnet uses `0x1`).

---

### Part 1 — Staking

## Staking objects (what exists on-chain)

### `aptos_framework::stake::StakePool`

Each validator (more precisely: each **stake pool address**) has a `StakePool` resource that contains:

- **Balances split by state**
  - **`active`**: counts toward current epoch voting power (if validator is active/pending-inactive)
  - **`pending_active`**: will become active at next epoch
  - **`pending_inactive`**: “unlock requested”; may still count in some voting-power paths; becomes inactive after lockup expiry + epoch processing
  - **`inactive`**: fully withdrawable
- **`locked_until_secs`**: lockup expiration timestamp (seconds)
- **Role separation**
  - **`operator_address`**: controls validator operations (keys/addresses, join/leave)
  - **`delegated_voter`**: the address allowed to vote in governance using this pool’s stake
- **Event handles** for the stake lifecycle (initialize, add stake, unlock, withdraw, join/leave set, etc.)

### `aptos_framework::stake::OwnerCapability`

Ownership of a stake pool is represented by a **capability resource**:

- `OwnerCapability { pool_address }`

This allows separation between:

- **owner** (controls funds / can set operator/voter)
- **operator** (runs the node)

### `aptos_framework::stake::ValidatorConfig`

Per stake-pool address (the validator identity), Aptos stores:

- **`consensus_pubkey`**: BLS12-381 public key bytes (with proof-of-possession checks on rotation/initialization)
- **`network_addresses`** and **`fullnode_addresses`**: serialized network address sets
- **`validator_index`**: the index used by consensus for the current epoch (reassigned every epoch)

### `aptos_framework::stake::ValidatorSet`

The canonical validator set is stored under `@aptos_framework` and includes:

- **`active_validators: vector<ValidatorInfo>`**: the current epoch’s active set
- **`pending_active`**: will be activated at next epoch
- **`pending_inactive`**: asked to leave; still considered active for the current epoch
- **`total_voting_power`**: total voting power of the current active set (u128)
- **`total_joining_power`**: cumulative “voting power increase” requested this epoch (joining limit control)

Each `ValidatorInfo` stores `(addr, voting_power, config)`.

### `aptos_framework::stake::ValidatorPerformance`

Rewards depend on validator performance tracked per validator index:

- `successful_proposals`, `failed_proposals`

This vector is **reset each epoch** and updated by the block prologue during the epoch.

### Fees/rewards minting authority

Rewards are minted using a mint capability stored in:

- `aptos_framework::stake::AptosCoinCapabilities` (published under `@aptos_framework` during genesis)

---

## The staking lifecycle (happy path)

The `stake` module documents the intended lifecycle:

- Initialize validator identity + config
- Add stake
- Join validator set (effective next epoch)
- Operate, accrue rewards
- Unlock stake (request) → withdraw later (after lockup expiry + epoch processing)
- Leave validator set (effective next epoch)

In Move entrypoints, the typical flow is:

- **`stake::initialize_validator(account, consensus_pubkey, pop, network_addresses, fullnode_addresses)`**
  - Validates proof-of-possession for the BLS key.
  - Creates `StakePool` + `OwnerCapability` + `ValidatorConfig`.
- **`stake::add_stake(owner, amount)`**
  - Moves `AptosCoin` from owner’s balance into the pool.
  - If the pool is a current-epoch validator, stake goes to `pending_active`; otherwise it goes directly to `active`.
- **`stake::join_validator_set(operator, pool_address)`**
  - Operator-only.
  - Checks min/max stake and pushes validator into `ValidatorSet.pending_active`.
  - Enforces a per-epoch “joining/voting-power increase limit”.
- **`stake::unlock(owner, amount)`**
  - Moves up to `amount` from `active` → `pending_inactive` (this is the “unlock request”).
  - Withdrawal is not immediate; it’s gated by lockup expiration and epoch processing.
- **`stake::withdraw(owner, withdraw_amount)`**
  - Extracts up to `withdraw_amount` from `inactive` and deposits to owner.
  - Contains an edge-case fix: if validator is inactive and lockup expired, pending_inactive can be moved into inactive to prevent funds getting stuck.
- **`stake::leave_validator_set(operator, pool_address)`**
  - If still `pending_active`, it is removed from `pending_active` directly.
  - Otherwise, it is moved from `active_validators` → `pending_inactive` (effective next epoch).

---

## Stake state machine (the 4 buckets)

Aptos explicitly models stake transitions as “queued until epoch boundary”:

- **`active`**
  - Earns rewards (if validator is active / pending-inactive) and participates in consensus voting power rules.
- **`pending_active`**
  - Added stake for current validators waits here, so it only affects voting power starting next epoch.
- **`pending_inactive`**
  - “Unlock requested” stake is moved here immediately.
  - It becomes `inactive` only when the lockup has expired and the epoch transition processes it.
- **`inactive`**
  - Withdrawable stake.

These transitions are applied primarily inside epoch change logic (see below).

---

## Roles: owner vs operator vs delegated voter

### Owner (fund controller)

The account holding `OwnerCapability` can:

- Add stake (`add_stake`)
- Unlock/withdraw stake (`unlock`, `withdraw`)
- Change operator (`set_operator`)
- Change the delegated voter (`set_delegated_voter`)
- Increase lockup (`increase_lockup`) / renew lockup behavior

### Operator (node runner)

The operator can:

- Join/leave validator set (`join_validator_set`, `leave_validator_set`)
- Rotate consensus key (`rotate_consensus_key`)
- Update network and fullnode addresses (`update_network_and_fullnode_addresses`)

### Delegated voter (governance voter)

The `delegated_voter` address is the “identity” allowed to cast governance votes on behalf of the stake pool in `aptos_governance`.

This is a critical separation in Aptos: **governance voting is bound to the stake pool**, and a pool may delegate voting rights to a specific address without transferring stake ownership.

---

## Lockups (recurring lockup model)

Staking is governed by a recurring lockup duration:

- `staking_config::StakingConfig.recurring_lockup_duration_secs`

Each pool has `StakePool.locked_until_secs`.

### How lockups are extended / renewed

- **Manual extension**: `stake::increase_lockup_with_cap` sets:
  - `locked_until_secs = now + recurring_lockup_duration_secs`
  - and asserts it only moves forward.

- **Automatic renewal at epoch boundary**:
  - During `stake::on_new_epoch`, after the active validator set is finalized, Aptos checks each remaining active validator’s `locked_until_secs`.
  - If the lockup is expired as of the reconfiguration start time, it is renewed to `now + recurring_lockup_duration_secs`.

### Unlocking vs withdrawing

- **Unlocking** (`unlock`) is a request: it moves stake into `pending_inactive`.
- **Withdrawing** requires the stake to be in `inactive`.
- `pending_inactive → inactive` happens at epoch boundaries **if** lockup is expired at reconfiguration start.

This is the core “unbonding delay” mechanism: **you can request unlock at any time**, but withdrawal is delayed until lockup expiry and epoch processing.

---

## Epoch boundaries + validator set updates (reconfiguration)

### The “epoch transition” entrypoint

The effective epoch boundary logic is:

- `reconfiguration::reconfigure()` emits the “new epoch” event and increments epoch number
- It calls `stake::on_new_epoch()` as part of reconfiguration

If DKG-based asynchronous reconfiguration is enabled, `aptos_governance::reconfigure()` may:

- start DKG (`reconfiguration_with_dkg::try_start()`), then later
- finish and call `reconfiguration::reconfigure()` once DKG completes (`reconfiguration_with_dkg::finish()`)

### What `stake::on_new_epoch()` does

At a high level:

- **Distribute rewards and transaction fees**
  - For each validator in `active_validators` and `pending_inactive`, update its stake pool:
    - distribute rewards to `active` and `pending_inactive`
    - optionally distribute transaction fees
    - move `pending_active → active`
    - if lockup expired, move `pending_inactive → inactive`
- **Apply validator membership queues**
  - `pending_active` validators become active
  - `pending_inactive` validators are removed
- **Recompute the active validator set**
  - Refresh validator configs (so key/address updates become effective)
  - Drop validators whose refreshed voting power is below minimum stake
  - Recompute `ValidatorSet.total_voting_power`
  - Reset `ValidatorSet.total_joining_power`
- **Reset performance counters**
  - rebuild `ValidatorPerformance.validators` aligned to the new `validator_index` assignment
- **Renew lockups for validators staying in the set**

Key consequence: **membership, voting power, lockup renewal, and rewards are epoch-boundary effects**.

---

## Voting power (staking vs governance)

Aptos uses “voting power” in two related but distinct ways:

- **Consensus validator voting power**: in `stake::ValidatorSet`, per epoch.
- **Governance voting power**: used by `aptos_governance`, derived from stake pools.

### Consensus / epoch voting power (`stake`)

`stake::get_current_epoch_voting_power(pool_address)` returns:

- `active + pending_inactive` **only if** the pool is currently **ACTIVE** or **PENDING_INACTIVE**
- otherwise `0`

This reflects the “still active this epoch” semantics.

### Joining / stake growth limiter

Aptos has an anti-shock mechanism:

- `staking_config::StakingConfig.voting_power_increase_limit` is a percent in (0, 50].
- When a validator joins or increases stake while active/pending-active, Aptos increments `ValidatorSet.total_joining_power`.
- If `total_voting_power > 0`, it enforces:

\[
\texttt{total\_joining\_power} \le \texttt{total\_voting\_power} \times \frac{\texttt{voting\_power\_increase\_limit}}{100}
\]

This throttles how much voting power can be added in a single epoch, to reduce risk from sudden validator-set changes.

---

## Rewards + fees distribution (how stake grows)

### Rewards are epoch-based and performance-weighted

Rewards are computed and minted during `stake::update_stake_pool()` (called from `stake::on_new_epoch()`).

The core reward formula (simplified) is:

\[
\texttt{rewards} =
\left\lfloor
\frac{
\texttt{stake\_amount} \cdot \texttt{rewards\_rate} \cdot \texttt{num\_successful\_proposals}
}{
\texttt{rewards\_rate\_denominator} \cdot \texttt{num\_total\_proposals}
}
\right\rfloor
\]

Notes:

- Rewards are computed separately for **`active`** and **`pending_inactive`** stake.
- Performance counters (`successful_proposals`, `failed_proposals`) are tracked per epoch and reset at epoch boundary.

### Transaction fee distribution (optional feature)

There is a feature-flagged mechanism to distribute transaction fees:

- Pending fees are accumulated in `PendingTransactionFee` indexed by `validator_index`.
- At epoch boundary, if enabled, fees are minted into stake pools and split proportionally between `active` and `pending_inactive` stake.
- A per-epoch-per-pool cap exists via `TransactionFeeConfig`.

---

## Permissions and “permissioned signers”

Many staking entry functions start with:

- `check_stake_permission(signer)`

This permission check is implemented via `permissioned_signer`:

- If the caller is a **normal (master) signer**, it is treated as having all permissions.
- If the caller is a **permissioned signer**, it must have been granted `StakeManagementPermission`.

This is a general pattern in Aptos: permissioned signers are a way to delegate a restricted signer, without changing APIs that accept `&signer`.

---

## Delegation / staking services (beyond “one validator = one owner”)

Aptos provides multiple “multi-party” staking abstractions on top of the core stake pool.

### `delegation_pool` (many delegators → one stake pool)

`aptos_framework::delegation_pool` implements a many-delegator system:

- Delegators hold **shares** (via `aptos_std::pool_u64`) rather than raw coin amounts.
- It maintains internal pools per stake state and per observed lockup cycle, so that “who can withdraw what” stays correct across lockup renewals.
- Before every user action, it **synchronizes** with the underlying `stake::StakePool`:
  - detects new rewards (stake deviations)
  - extracts operator commission
  - maps stake-state transitions into internal share pools

Governance support:

- The module contains a `partial_vote` path that calls into `aptos_governance::partial_vote` on behalf of the pool, and tracks per-delegator used voting power.

### `staking_contract` (staker/operator contract with commission)

`aptos_framework::staking_contract` creates a contract between:

- a **staker** (capital provider) and
- an **operator** (validator runner)

It:

- hosts a stake pool in a resource account controlled by the contract
- tracks operator commission using a principal accounting model
- distributes withdrawals/commissions using pool shares

---

### Part 2 — Governance (voting + parameter changes)

## Architecture: `voting` (generic) + `aptos_governance` (Aptos-specific)

Aptos implements governance in two layers:

- **`aptos_framework::voting`**: a generic, reusable on-chain voting primitive
- **`aptos_framework::aptos_governance`**: Aptos network governance built on top of `voting`

The “proposal type” used by Aptos network governance is:

- `aptos_framework::governance_proposal::GovernanceProposal` (a marker struct used as proof/type binding)

---

## Generic voting (`aptos_framework::voting`)

### Core stored state: `VotingForum<ProposalType>`

A “forum” is a resource published under an address and parameterized by a proposal type.

- It stores proposals in a `Table<u64, Proposal<ProposalType>>`.
- It emits events for register/create/vote/resolve.

### Proposal contents: `Proposal<ProposalType>`

Key fields:

- **`execution_hash: vector<u8>`**: hash of the Move script/module that is allowed to resolve this proposal.
- **`min_vote_threshold: u128`**: minimum total votes cast (yes+no) for success.
- **`expiration_secs: u64`**: proposal “voting period end” timestamp.
- **`early_resolution_vote_threshold: Option<u128>`**: if present, proposal can be resolved early if yes or no hits this threshold.
- **`yes_votes`, `no_votes`**: u128 counters.
- **`metadata`**: includes internal keys such as:
  - `RESOLVABLE_TIME_METADATA_KEY` (forces non-atomic resolution)
  - multi-step flags (`IS_MULTI_STEP_PROPOSAL_KEY`, `IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY`)

### Voting and tally rules

- Voting is allowed while:
  - `now <= expiration_secs`, and
  - proposal is not resolved, and
  - for multi-step proposals, “in execution” is not set to true.

- A proposal is considered **SUCCEEDED** when voting is closed and:
  - `yes_votes > no_votes`, and
  - `(yes_votes + no_votes) >= min_vote_threshold`

Voting is “closed” when:

- the voting period is over (`now > expiration_secs`), **or**
- the early resolution threshold is met (if configured).

### Resolution security gates (very important)

`voting::resolve*` enforces two key constraints:

- **Exact execution code binding**: the current transaction’s `transaction_context::get_script_hash()` must equal the proposal’s `execution_hash`.
- **Non-atomic resolution**: resolution cannot happen in the same transaction as the last vote.
  - Each vote writes the current timestamp into metadata.
  - `resolve` requires `timestamp::now_seconds() > last_vote_timestamp`.

This is explicitly intended to mitigate “flashloan / same-tx” manipulation patterns.

### Multi-step proposals

For multi-step proposals, `resolve_proposal_v2` can:

- mark “in execution” to block further voting, and
- either:
  - finalize the proposal (when `next_execution_hash` is empty), or
  - update `execution_hash` to a new value for the next step.

---

## Aptos network governance (`aptos_framework::aptos_governance`)

### Governance configuration: `GovernanceConfig`

Stored under `@aptos_framework`:

- **`min_voting_threshold: u128`**
- **`required_proposer_stake: u64`** (bond / minimum stake to propose)
- **`voting_duration_secs: u64`**

This config itself can be updated via governance execution (`update_governance_config` requires an `@aptos_framework` signer).

### Who can create a proposal?

To create a proposal with backing `stake_pool`, Aptos requires:

- The proposer must be the stake pool’s delegated voter:
  - `stake::get_delegated_voter(stake_pool) == proposer_address`
- The stake pool must have at least `required_proposer_stake`.
- The stake pool must be locked up at least until proposal expiration:
  - `stake::get_lockup_secs(stake_pool) >= now + voting_duration_secs`

### Voting power in Aptos governance

Aptos governance voting power is derived from the stake pool, but with an important mode switch:

- If `staking_config.allow_validator_set_change == true`:
  - voting power is computed as **non-inactive stake**:
    - `active + pending_active + pending_inactive`
  - This allows even non-current-epoch validators (but still locked) to have governance power.

- If `allow_validator_set_change == false`:
  - voting power is `stake::get_current_epoch_voting_power`, i.e. **only**:
    - `active + pending_inactive` for current-epoch active/pending-inactive validators,
    - otherwise `0`.

### Voting: full and partial voting

`aptos_governance` supports:

- **vote with “all remaining power”** (by passing a large number, capped)
- **partial voting**, where a stake pool can vote multiple times as long as the total used voting power does not exceed its available voting power.

It tracks used voting power in:

- `VotingRecordsV2` (SmartTable keyed by (stake_pool, proposal_id))

and rejects some legacy “already voted entirely before partial voting was enabled” cases via:

- `VotingRecords`

### Approved execution hashes (mempool size bypass)

When a proposal is in the SUCCEEDED state, `aptos_governance` records its execution hash in:

- `ApprovedExecutionHashes`

This allows governance transactions that would otherwise exceed mempool size limits (e.g., large upgrades) to be recognized as approved.

The approved hash is removed after the proposal is resolved (or after the last step of multi-step resolution).

### Executing a proposal: signer capabilities

The generic voting module binds resolution to script hash, but it does not itself grant privileges.

`aptos_governance` bridges this by returning a **privileged signer** when resolving:

- `aptos_governance::resolve(proposal_id, signer_address) -> signer`

It uses `GovernanceResponsbility` (a map of `SignerCapability`s) to create a signer for `signer_address`.

This is how governance proposals can call privileged functions like:

- `staking_config::update_required_stake(&framework_signer, ...)`
- `consensus_config::set_for_next_epoch(&framework_signer, ...)`
- `aptos_governance::reconfigure(&framework_signer)`

In other words: **governance execution is “normal Move code” running with an authorized system signer**.

---

## Parameter changes: the “update config → reconfigure → new epoch” pattern

### Immediate vs next-epoch config application

Many configs in Aptos follow this split:

- **Immediate update**: update the resource and call `reconfiguration::reconfigure()` directly.
- **Next-epoch update**: write into `config_buffer`, then apply it in `X::on_new_epoch()` when entering a new epoch.

Example pattern (e.g. `consensus_config`):

- `consensus_config::set_for_next_epoch(&framework_signer, config_bytes)`
  - stores pending config in `config_buffer`
- On epoch boundary:
  - `reconfiguration_with_dkg::finish(&framework_signer)` calls `consensus_config::on_new_epoch(&framework_signer)`
  - which extracts from `config_buffer` and overwrites the on-chain `ConsensusConfig`

### Forcing the epoch boundary: `aptos_governance::reconfigure`

After a governance execution that changes configs, Aptos typically calls:

- `aptos_governance::reconfigure(&framework_signer)`

### What `aptos_governance::reconfigure` actually does (sync vs async epochs)

`aptos_governance::reconfigure` is the governance-friendly “end the epoch so everyone picks up new config” hook.

- **If DKG-based reconfiguration is NOT enabled/used**:
  - it calls `reconfiguration_with_dkg::finish(&framework_signer)` directly
  - which applies buffered configs and then calls `reconfiguration::reconfigure()`
  - result: **the new epoch begins at the end of the transaction**.

- **If DKG-based reconfiguration IS enabled/used** (when validator transactions are enabled and randomness is enabled):
  - it calls `reconfiguration_with_dkg::try_start()`
  - which starts a DKG session and marks reconfiguration in progress
  - the chain **enters the new epoch later**, after DKG finishes (typically in a block prologue that finalizes DKG and calls `finish`).

Practical implication: “parameter changed” vs “parameter took effect network-wide” can be separated in time when async reconfiguration is enabled.

---

## A canonical governance proposal flow (end-to-end)

This is the typical operational pattern for parameter changes on Aptos:

- **Proposal creation**
  - A proposer calls `aptos_governance::create_proposal(_v2)` with:
    - a backing `stake_pool`
    - an `execution_hash` (hash of the exact resolution script/module)
    - metadata pointers (off-chain description hash/location)
  - Aptos sets:
    - `expiration_secs = now + voting_duration_secs`
    - `min_vote_threshold = GovernanceConfig.min_voting_threshold`
    - `early_resolution_vote_threshold` ≈ **50% + 1** of `AptosCoin` total supply (if supply is available)

- **Voting**
  - A voter calls `aptos_governance::vote` or `partial_vote`.
  - Requirements include:
    - `stake::get_delegated_voter(stake_pool) == voter_address`
    - `stake_pool.locked_until_secs >= proposal_expiration`
    - not expired
    - sufficient remaining voting power

  Important nuance: the generic `voting` module does **not** automatically close voting when early resolution becomes possible; it only blocks voting after `expiration_secs` or when a multi-step proposal is “in execution”.

- **Resolution / execution**
  - After the proposal is resolvable (expiration passed, or early threshold conditions + your policy) and in a **different transaction than the last vote**, the resolution script runs.
  - The script must have the exact hash committed in the proposal (`execution_hash`).
  - The script calls:
    - `aptos_governance::resolve(...)` (or multi-step resolve), to obtain a privileged signer (e.g. for `@aptos_framework`)
    - privileged config mutations (see examples below)
    - `aptos_governance::reconfigure(&framework_signer)` to start/finish reconfiguration and enter a new epoch.

---

## Which parameters can governance change?

### Directly-updated configs (mutate resource under `@aptos_framework`)

These are updated by calling a function that requires `system_addresses::assert_aptos_framework(&signer)` (i.e., the `@aptos_framework` signer created during governance execution).

Examples:

- **Staking parameters** in `staking_config`:
  - `update_required_stake`
  - `update_recurring_lockup_duration_secs`
  - `update_voting_power_increase_limit`
  - `update_rewards_rate` (deprecated path) / `update_rewards_config` (newer path)
- **Governance parameters** in `aptos_governance`:
  - `update_governance_config`

These changes become “true on-chain state” immediately, but validators typically only *synchronize behavior* across the network at the next epoch boundary, so governance scripts conventionally call `reconfigure`.

### Buffered “next epoch” configs (config_buffer pattern)

Many core configs are intended to be staged and applied at epoch boundary:

- `consensus_config::set_for_next_epoch` / `consensus_config::on_new_epoch`
- `execution_config::set_for_next_epoch` / `execution_config::on_new_epoch`
- `gas_schedule` update paths that use `config_buffer` + `gas_schedule::on_new_epoch`
- `version::set_for_next_epoch` / `version::on_new_epoch`
- feature flags, JWK/JWKS/keyless configs, randomness configs, etc.

The common pattern is:

- governance execution sets a “pending config” in `config_buffer`
- epoch change calls the config’s `on_new_epoch` to extract and commit it

When DKG is enabled, these `on_new_epoch` calls happen inside `reconfiguration_with_dkg::finish`.

---

## Concrete “parameter change” examples (what the resolution script does)

### Example A — change staking min/max stake + lockup duration

Inside the governance resolution script (executing with the correct `execution_hash`):

- Call `aptos_governance::resolve(proposal_id, @aptos_framework)` to obtain `framework_signer`.
- Apply changes:
  - `staking_config::update_required_stake(&framework_signer, new_min, new_max)`
  - `staking_config::update_recurring_lockup_duration_secs(&framework_signer, new_lockup_secs)`
  - optionally `staking_config::update_voting_power_increase_limit(&framework_signer, new_limit_pct)`
- Then call:
  - `aptos_governance::reconfigure(&framework_signer)`

This ensures the new epoch begins (immediately or after DKG) so validator nodes converge on the new staking parameters and epoch processing uses them.

### Example B — change consensus config for the next epoch

Inside the governance resolution script:

- Get `framework_signer`.
- Stage the new consensus config:
  - `consensus_config::set_for_next_epoch(&framework_signer, new_config_bytes)`
- Trigger reconfiguration:
  - `aptos_governance::reconfigure(&framework_signer)`

At the next epoch boundary, `consensus_config::on_new_epoch` commits the buffered config.

---

## Design takeaways (useful when designing your EVM chain)

- **Epoch boundary is the “atomic sync point”**:
  - validator set changes
  - stake state transitions (pending→active/inactive)
  - reward distribution
  - config activation (especially buffered configs)

- **Stake-pool-based governance**:
  - voting rights are attached to stake pools (and can be delegated)
  - governance can enforce lockup constraints to prevent short-term stake from influencing long-horizon decisions

- **Governance execution is strongly code-bound**:
  - proposals commit to an `execution_hash`
  - resolution requires the exact code hash, and must occur in a later transaction than the last vote

If you want, next we can extend this doc with: (1) a state diagram for stake buckets and validator-set queues, (2) a deeper walkthrough of `delegation_pool` governance voting, and (3) a “minimal governance module” template for an EVM chain that wants similar properties.



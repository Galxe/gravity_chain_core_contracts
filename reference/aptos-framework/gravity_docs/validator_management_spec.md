## Gravity Validator Management Contract — Specification (final)

Last updated: 2026-01-01

This document specifies a **Validator Management** system contract for **Gravity**, an **EVM L1** that reuses the **Aptos consensus engine**, while intentionally **removing delegation** and simplifying incentives. It is inspired by Aptos framework staking/governance patterns (epoch-boundary transitions, validator set queues, separated roles), but adapted to Gravity’s **KISS** requirements.

---

### Goals

- **Authoritative on-chain validator registry** for the consensus engine to read.
- **Explicit validator lifecycle** (register → bond → activate → exit) with **epoch-boundary effects**.
- **Deterministic epoch transition hook** callable by the system (consensus) to apply queued changes.
- **Key management**: store and rotate validator consensus key material (e.g., BLS pubkey + PoP).
- **No delegation**: a validator’s voting power comes only from its own bonded stake.
- **Rewards aligned with Ethereum fee market**:
  - EIP-1559 base fee behavior is handled at protocol level (not “staking rewards” logic here).
  - Contract focuses on validator set + stake accounting, not “minting rewards”.

### Non-goals

- Delegation pools / share accounting / commission splitting (intentionally excluded).
- A full on-chain governance module (can be added later; this spec focuses on validator management).
- Complex reward curves, performance-weighted inflation, or per-validator fee distribution logic.
- Slashing (optional extension; see “Future extensions”).

---

### Terminology

- **Epoch**: a protocol-defined period during which the validator set is fixed.
- **Active set**: validators participating in consensus for the current epoch.
- **Pending join/leave**: requested membership changes that take effect at the next epoch boundary.
- **Bonded stake**: stake locked as validator collateral and used for voting power.
- **Stake pool address** (`stakePool`): the canonical validator identity (same as Aptos). This can be an EOA or a contract wallet; “staking pool” here is an identity pattern, not a required separate contract implementation.
- **Validator index** (`validatorIndex`): a **per-epoch** index \([0, N)\) assigned to validators in the active set at epoch transition time, used by consensus/performance accounting. Indices can change every epoch.

---

### High-level architecture

Gravity runs an EVM execution layer plus an Aptos-derived consensus layer. The contract defined here is a **system contract** whose state is the canonical validator registry used by consensus.

- **Consensus → EVM (system call)**: at epoch boundary, consensus calls `onNewEpoch(...)` to apply queued changes.
- **EVM users (validators)**: call registration / bond / join / leave / withdraw functions subject to lockups.
- **Consensus reads**: consensus reads the active validator set (and key material) from this contract via a defined view/API (or via a precompile-assisted state read).

---

### Roles and permissions

To keep KISS while preserving operational safety, we support two roles per validator:

- **Owner**: controls funds (bond/unbond/withdraw) and can set operator.
- **Operator**: can change operational metadata (keys, networking) and request join/leave.

If you prefer maximal simplicity, these roles can be collapsed (owner == operator); the data model below supports either.

Permission rules:

- Only **owner** can bond/unbond/withdraw.
- Only **operator** can rotate consensus key and request join/leave.
- Only **system** (consensus) can call `onNewEpoch`.

Additional (governance + fees) roles:

- **Delegated voter**: an address (EOA or contract) authorized to cast **on-chain governance votes** using this validator’s voting power.
- **Fee recipient**: an address (EOA or contract) that receives **block proposer tips / priority fees** for this validator.

---

### Validator state machine

Each validator has stake in 4 “buckets” (mirroring the Aptos mental model, but simplified):

- **activeBond**: stake counting toward voting power for the current epoch (if active).
- **pendingActiveBond**: bonded stake that becomes active next epoch (e.g., stake increases while active).
- **pendingInactiveBond**: unbond requested; becomes withdrawable after lockup + epoch processing.
- **inactiveBond**: withdrawable stake.

Validator membership status:

- **INACTIVE**: not in active set and not pending join.
- **PENDING_ACTIVE**: queued to enter active set next epoch.
- **ACTIVE**: in active set this epoch.
- **PENDING_INACTIVE**: queued to exit active set next epoch (still active for current epoch, depending on consensus rules).

Key property: **membership and stake-bucket transitions are applied at epoch boundaries** by `onNewEpoch`.

---

### Core data model (Solidity-oriented)

#### Global config (set at genesis / system-updatable)

- `minimumStake`: minimum stake to join the validator set. Validators below this are removed at epoch boundaries (Aptos-like).
- `maximumStake`: maximum stake allowed for joining and stake increases (Aptos-like). Note: Aptos **rejects** stake additions that would exceed this maximum; it does not “cap at epoch start” in the core `stake` module.
- `recurringLockupDurationSecs`: recurring lockup window / unbonding delay (Aptos-like).
- `allowValidatorSetChange`: whether validators can join/leave post-genesis, and (Aptos-compatible) whether governance voting power includes non-active bonded stake.
- `maxValidatorSetSize`: **hard cap** on validator set size (Aptos enforces `MAX_VALIDATOR_SET_SIZE`).
- `votingPowerIncreaseLimitPct`: per-epoch cap on total voting power increase (Aptos-style safety throttle; range (0, 50]).
- `epoch`: current epoch number (monotonic).
- `lastReconfigurationTime`: last “epoch transition” timestamp, used to guard “only once per tx/epoch hook” (Aptos-like).

#### Per-validator record

For each `stakePool` (`address`):

- `stakePool` (address) — immutable unique identity (the key for this validator in storage)
- `moniker` (string) — human-readable validator name (see below)
- `owner` (address)
- `operator` (address)
- `status` (enum)
- `lockedUntil` (uint64)
- `activeBond` (uint256)
- `pendingActiveBond` (uint256)
- `pendingInactiveBond` (uint256)
- `inactiveBond` (uint256)
- `consensusPubkey` (bytes) — e.g., BLS12-381 pubkey bytes
- `consensusPop` (bytes32 or bytes) — proof-of-possession bytes (stored only; **no EVM validation**)
- `networkAddresses` (bytes) — serialized addresses (optional)
- `fullnodeAddresses` (bytes) — serialized addresses (optional)
- `delegatedVoter` (address) — governance voting authority (defaults to `owner` at registration)
- `feeRecipient` (address) — proposer fee recipient (defaults to `owner` at registration)
- `pendingFeeRecipient` (address) — staged update (optional, see feeRecipient mutability)
- `validatorIndex` (uint64) — **per-epoch** index (only meaningful when ACTIVE/PENDING_INACTIVE for the current epoch; reassigned at each epoch boundary).

#### Moniker uniqueness (note)

Aptos framework staking does **not** store an on-chain “validator moniker” in the `stake` module (no `moniker` field exists in validator state there). For Gravity:

- `moniker` is a lightweight display string (like a username).
- No uniqueness checks are performed on-chain.
- Enforce a strict max length: **< 32 bytes** (or `<= 31` bytes if you want to reserve a null terminator; pick one and be consistent).

#### Validator set storage

Under contract storage:

- `activeValidators: address[]` (stake pools)
- `pendingActive: address[]` (stake pools)
- `pendingInactive: address[]` (stake pools)
- `totalVotingPower: uint256` (sum of voting power of `activeValidators`)
- `totalJoiningPowerThisEpoch: uint256` (for `votingPowerIncreaseLimitPct`, optional)

Note: consensus ordering is defined by this spec: entries are returned **sorted by `validatorIndex`** (i.e., array order / index order), matching Aptos.

---

### Consensus-facing interface (required view/API surface)

The consensus engine needs a stable, well-defined way to read the active validator set and the data required for consensus voting/signature verification.

Minimum recommended view functions:

- `getEpoch() view returns (uint64)`
- `getActiveValidatorSetPacked() view returns (bytes)` (preferred; avoids index-based enumeration)
- `getValidatorIndex(address stakePool) view returns (uint64)` (per-epoch index, Aptos-like)
- `getValidatorVotingPower(address stakePool) view returns (uint256)`
- `getValidatorConsensusKey(address stakePool) view returns (bytes consensusPubkey, bytes pop)`
- `getValidatorNetworkAddresses(address stakePool) view returns (bytes networkAddresses, bytes fullnodeAddresses)` (optional)
- `getTotalVotingPower() view returns (uint256)`
- `getFeeRecipient(address stakePool) view returns (address)`

Ordering requirement:

- Define the packed encoding order and keep it deterministic across nodes (this spec mandates sorting by `validatorIndex`).

Recommended canonical encoding:

- A length-prefixed list of entries:
  - `(stakePoolAddress, validatorIndex, votingPower, consensusPubkey)`

Canonical ordering:

- `getActiveValidatorSetPacked()` MUST return entries **sorted by `validatorIndex` ascending** (i.e., current-epoch consensus order).

---

### Governance and voting (Aptos-inspired)

Gravity should support **on-chain governance** with **stake-weighted voting** that is tied to validator stake, similar in spirit to Aptos:

- Voting power is derived from **bonded stake** (not delegation pool shares).
- Voting is authorized by a per-validator **`delegatedVoter`** address (EOA or contract).
- Governance enforces **lockup requirements** to prevent short-term stake influencing long-horizon decisions.
- Proposal execution should be **code-bound** (e.g., execution hash) and ideally **non-atomic** with voting (separate transaction) to reduce manipulation risk.

#### Who can vote?

In Aptos, “voting power” is stake-pool based. In practice:

- A stake pool (validator identity) provides voting power.
- The *address allowed to vote* is the pool’s **delegated voter**.
- Delegation pools can provide additional UX, but the underlying authority is still the stake pool.

For Gravity (no built-in delegation), the clean analog is:

- **Only registered validators have voting power**, derived from their bonded stake.
- **Anyone can be the `delegatedVoter`** for a validator (including a delegation contract), meaning validators can implement their own delegation mechanism off-contract and have that contract cast votes.

This keeps the core protocol simple while still enabling richer delegation logic externally.

#### Governance voting power definition (recommended)

Gravity should mirror Aptos and make this **config-driven**, keyed off `allowValidatorSetChange`:

- If `allowValidatorSetChange == true`:
  - governance voting power = **total non-inactive bonded stake**, even if the validator is not currently active:
  - `activeBond + pendingActiveBond + pendingInactiveBond` (exclude `inactiveBond`)
  - Rationale (Aptos): as long as the stake is locked (separately enforced), it should count for governance proposals.

- If `allowValidatorSetChange == false`:
  - governance voting power = **current-epoch voting power**:
  - for ACTIVE or PENDING_INACTIVE validators: `activeBond + pendingInactiveBond`
  - otherwise `0`

#### Governance-facing interface (validator module responsibilities)

To support a separate governance contract/module, the validator management contract should expose:

- `getDelegatedVoter(address stakePool) view returns (address)`
- `setDelegatedVoter(address stakePool, address newDelegatedVoter)` (owner-only)
- `getGovernanceVotingPower(address stakePool) view returns (uint256)`
- `getLockedUntil(address stakePool) view returns (uint64)`
- `assertCanVote(address stakePool, address voter, uint64 proposalExpiration)` (view/revert helper)
  - checks:
    - `voter == delegatedVoter`
    - `lockedUntil >= proposalExpiration`
    - validator exists and is not fully unbonded

Recommended proposer constraints (governance contract enforces):

- proposer must be the validator’s `delegatedVoter`
- validator must have at least `requiredProposerBond`
- lockup must cover `now + votingDuration`

#### Lockup vs proposal expiration (Aptos behavior)

Aptos models stake lockup as an **absolute timestamp** (`locked_until_secs`) per stake pool (validator identity). Governance then enforces:

- To **create a proposal**, the stake pool’s lockup must cover the *entire voting duration*:
  - `stake::get_lockup_secs(stake_pool) >= now + voting_duration_secs`
- To **vote on a proposal**, the stake pool’s lockup must cover the *proposal’s expiration timestamp*:
  - `stake::get_lockup_secs(stake_pool) >= proposal_expiration_secs`

If your lockup ends **before** `proposal_expiration_secs`, you **cannot vote** (Aptos either returns 0 remaining voting power or aborts the vote path). The intended remedy is to **extend lockup first**, then vote.

In Aptos, extending lockup is an owner action:

- `stake::increase_lockup(...)` sets:
  - `locked_until_secs = now + recurring_lockup_duration_secs`
  - and asserts this moves lockup strictly forward.

Gravity should implement the same rule: governance voting should be gated on `lockedUntil >= proposalExpiration`, and validators must extend lockup before voting if needed (by setting `lockedUntil = now + recurringLockupDurationSecs` and asserting it moves forward).

---

### Voting power definition

Consensus voting power is derived from bonded stake:

- **Current-epoch voting power** for an ACTIVE or PENDING_INACTIVE validator:
  - `activeBond + pendingInactiveBond` (still “counts this epoch” during exit queue).
- Otherwise:
  - `0`.

This mirrors the common “still active this epoch while exiting” behavior. If Gravity wants stricter semantics (exiting validators stop counting immediately), change to `activeBond` only and adjust epoch logic accordingly.

---

### Contract entrypoints (external API)

Below is the minimum viable API. Names are indicative.

#### Registration and role management

- `registerValidator(stakePool, moniker, owner, operator, consensusPubkey, pop, networkAddresses, fullnodeAddresses)`
  - Creates validator record.
  - Stores key material as bytes (**no EVM validation**).
  - Initializes status = INACTIVE.
  - Initializes `delegatedVoter = owner` unless specified otherwise.
  - Initializes `feeRecipient = owner` unless specified otherwise.
  - Enforces `bytes(moniker).length < 32`.

- `setOperator(stakePool, newOperator)` (owner-only)

- `setDelegatedVoter(stakePool, newDelegatedVoter)` (owner-only)
  - Sets governance voting authority for the validator (can be an EOA or contract).

#### Bonding / unbonding

This spec assumes a single `bondAsset` configured at genesis: **the native token** (bonding is native-value based).

- `bond(stakePool, amount)` (native token)
  - owner-only.
  - Aptos-like bucket placement:
    - If the stake pool is a **current-epoch validator** (ACTIVE or PENDING_INACTIVE): increment `pendingActiveBond` (stake only counts starting next epoch).
    - Else (INACTIVE or PENDING_ACTIVE): increment `activeBond`.
  - Extends lockup forward: `lockedUntil = max(lockedUntil, now + recurringLockupDurationSecs)`.
  - Aptos-like maximum: after the change, require:
    - `activeBond + pendingActiveBond + pendingInactiveBond <= maximumStake`
    - otherwise revert.

- `requestUnbond(stakePool, amount)`
  - owner-only.
  - Moves `amount` from `activeBond` to `pendingInactiveBond` (bounded by available).
  - Does **not** immediately make funds withdrawable.

- `withdraw(stakePool, amount, to)`
  - owner-only.
  - Withdraws from `inactiveBond` only.
  - Must be safe against reentrancy.
  - Aptos edge-case fix (recommended): if `status == INACTIVE` and `now >= lockedUntil`, first sweep:
    - `inactiveBond += pendingInactiveBond; pendingInactiveBond = 0;`
    - This prevents stake from getting stuck forever when the validator is no longer processed by epoch transitions.

#### Fee recipient management

- `setFeeRecipient(address stakePool, address newRecipient)` (owner-only)
  - Stages a fee recipient update by setting `pendingFeeRecipient = newRecipient`.
  - The update becomes effective during `onNewEpoch` (epoch-boundary activation).

#### Join/leave validator set

- `requestJoin(stakePool)`
  - operator-only.
  - Requires `allowValidatorSetChange == true` (post-genesis set change enabled).
  - Requires validator has `getNextEpochVotingPower(stakePool) >= minimumStake`.
  - Requires validator has `getNextEpochVotingPower(stakePool) <= maximumStake`.
  - Requires `status == INACTIVE`.
  - Enqueues into `pendingActive`, sets `status = PENDING_ACTIVE`.
  - Enforce `maxValidatorSetSize` based on `activeValidators.length + pendingActive.length`.
  - Enforce per-epoch join throttle: update `totalJoiningPowerThisEpoch` and require it under `votingPowerIncreaseLimitPct`.

- `requestLeave(stakePool)`
  - operator-only.
  - Requires `allowValidatorSetChange == true` (post-genesis set change enabled).
  - If `status == PENDING_ACTIVE`: remove from `pendingActive`, set `status = INACTIVE`.
  - Else if `status == ACTIVE`: enqueue into `pendingInactive`, set `status = PENDING_INACTIVE`.
  - Else revert.

#### Operational metadata

- `rotateConsensusKey(stakePool, newPubkey, newPop)` (operator-only)
- `updateNetworkAddresses(stakePool, networkAddresses, fullnodeAddresses)` (operator-only)

Key rotation may be immediate in storage, but consensus should only consume effective keys at epoch boundary (recommended) to avoid mid-epoch surprises.

---

### System entrypoint: epoch transition

#### `onNewEpoch(epochNumber, timestamp, extraData)` (system-only)

This function is called exactly once per epoch transition by the protocol/system. It performs:

Note on `extraData` (BLS key validation without an EVM precompile):

- Since the EVM contract does not verify BLS PoP, `extraData` SHOULD carry consensus-produced validation results for any key changes and for `pendingActive` candidates (e.g., an ordered list of stake pools that passed validation, or a bitmap aligned to `pendingActive` order).
- `onNewEpoch` must apply membership activation using this validation result to avoid consensus/contract divergence.

1. **Finalize stake bucket transitions**
   - For all validators that are ACTIVE or PENDING_INACTIVE:
     - `activeBond += pendingActiveBond; pendingActiveBond = 0;`
     - If `now >= lockedUntil` then:
       - `inactiveBond += pendingInactiveBond; pendingInactiveBond = 0;`
   - Optional KISS optimization: only iterate over validators in `activeValidators` and `pendingInactive`, plus any validator with non-zero `pendingActiveBond/pendingInactiveBond` tracked via an index set.

2. **Apply membership queues**
   - Activate `pendingActive` validators that satisfy next-epoch requirements (Aptos-like):
     - `getNextEpochVotingPower(stakePool) >= minimumStake`
     - `getNextEpochVotingPower(stakePool) <= maximumStake`
     - key material present (at minimum, non-empty pubkey bytes)
     - **consensus-side key validation passed** (no on-chain PoP validation; see “Key validation”)
     - move into `activeValidators`
     - set `status = ACTIVE`
   - Remove all `pendingInactive` validators:
     - remove from `activeValidators`
     - set `status = INACTIVE`

3. **Recompute voting power**
   - Recompute `totalVotingPower` from `activeValidators` using the voting power definition.
   - Reset `totalJoiningPowerThisEpoch = 0`.

4. **Update validator indices (Aptos-style)**
   - Reassign `validatorIndex` for the new `activeValidators` to be `0..N-1` in the canonical consensus order.
   - Reset per-validator performance counters if you keep them (Aptos does this each epoch).

5. **Renew lockups (Aptos-style recurring lockup; required)**
   - For validators that remain ACTIVE, if `lockedUntil <= now`:
     - set `lockedUntil = now + recurringLockupDurationSecs`.
   - Note: this makes “being active” imply you must keep stake locked, which is a common PoS property.

6. **Aptos-like minimum stake enforcement**
   - When rebuilding the active validator set for the next epoch, drop any validator whose refreshed next-epoch voting power is `< minimumStake` (auto-eject).

7. **Only-once guard (Aptos-like)**
   - The epoch transition hook should be guarded so a single transaction cannot emit/process multiple epoch transitions (e.g., by comparing `lastReconfigurationTime` to the current block timestamp).

The epoch transition must be **bounded and predictable**. If you expect many validators, prefer incremental updates or constraints on validator set size.

---

### Fees and rewards (EIP-1559 alignment)

Gravity states rewards match Ethereum’s EIP-1559 model:

- **Base fee** is burned (or otherwise removed from circulation).
- **Priority fee / tip** is paid to the block proposer/validator.

This contract should **not** attempt to implement EIP-1559 itself (it is a protocol-level fee market), but it must integrate cleanly:

- The protocol can pay proposer tips directly to the validator’s `feeRecipient` address.
- Store per-validator `feeRecipient` in this contract (**owner-controlled**, see below).

Recommended addition:

- `getFeeRecipient(stakePool) view returns (address)`

If Gravity later introduces issuance/inflation, it should be handled by protocol or a separate issuance contract; validator management should remain focused on validator set integrity.

#### feeRecipient mutability (careful design)

Gravity wants validators to implement their own delegation/fee distribution mechanisms. The simplest way to enable this is to allow the validator to point fees to an arbitrary **contract** (splitter, vault, delegation module) via `feeRecipient`.

However, mutability must be constrained to avoid:

- operator theft (redirecting fees without owner consent)
- mid-epoch instability (unexpected recipient flips that complicate accounting/monitoring)

Recommended pattern:

- **Authority**: `feeRecipient` is **owner-controlled** (owner-only setter).
  - Rationale: fees are economically equivalent to funds; the owner is the economic principal.
  - Operators can still run infrastructure; if an operator needs fee control, the owner can set `feeRecipient` to an operator-managed contract.

- **Activation timing**: fee recipient changes are **staged** and become effective at the **next epoch boundary**.
  - Storage:
    - `feeRecipient` (current)
    - `pendingFeeRecipient` (staged)
  - API:
    - `setFeeRecipient(address stakePool, address newRecipient)` (owner-only) sets `pendingFeeRecipient`
    - during `onNewEpoch`, apply:
      - `if pendingFeeRecipient != address(0) { feeRecipient = pendingFeeRecipient; pendingFeeRecipient = address(0); }`
  - Rationale: predictable, epoch-synchronized changes align with the overall “epoch is the sync point” design and reduce operational/MEV surprises.

If you want slightly more flexibility without giving operators unilateral control, add an optional two-step operator workflow:

- `proposeFeeRecipient(address stakePool, address newRecipient)` (operator-only) writes `pendingFeeRecipient`
- `approveFeeRecipient(address stakePool)` (owner-only) marks it approved for next epoch

But for KISS, owner-only staging is typically enough.

---

### Events

Emit events for observability and off-chain ops:

- `ValidatorRegistered(stakePool, owner, operator)`
- `OperatorUpdated(stakePool, oldOperator, newOperator)`
- `Bonded(stakePool, amount, targetBucket)`
- `UnbondRequested(stakePool, amount)`
- `Withdrawn(stakePool, to, amount)`
- `JoinRequested(stakePool)`
- `LeaveRequested(stakePool)`
- `Activated(stakePool, epoch)`
- `Deactivated(stakePool, epoch)`
- `ConsensusKeyRotated(stakePool)`
- `NetworkAddressesUpdated(stakePool)`
- `EpochProcessed(epoch, activeCount, totalVotingPower)`

---

### Security considerations

- **System-only epoch hook**: `onNewEpoch` must be restricted to a well-defined system caller (predeploy address or precompile).
- **Reentrancy**: `withdraw` must be non-reentrant (checks-effects-interactions; use `ReentrancyGuard` if desired).
- **DoS via unbounded loops**: epoch processing must not be unbounded. Enforce `maxValidatorSetSize`, keep `pending` queues bounded, or design incremental processing.
- **Key validation**:
  - Gravity does **not** validate BLS PoP on-chain (no EVM precompile).
  - Consensus must validate key material off-chain before using it for signature verification.
  - **Guarantee we can provide without a precompile**: an invalid key behaves like an offline validator (it cannot produce valid consensus signatures), but its voting power may still be counted if you include it in the active set, which reduces effective quorum and can harm liveness.
  - **Recommended operational rule**: only allow a validator to become ACTIVE if its consensus key material passes consensus-side validation; otherwise keep it out of the active set (or require it to rotate keys and re-request join).
- **State invariants**:
  - Stake buckets are non-negative and conserved: total = `activeBond + pendingActiveBond + pendingInactiveBond + inactiveBond`.
  - Membership queues cannot contain duplicates.
  - Status must match membership (ACTIVE must be in `activeValidators`, etc.).

---

### Upgrade / governance hooks (optional)

If Gravity uses a governance or admin mechanism, config updates can be exposed as system-only setters:

- `setMinimumStake`, `setMaximumStake`, `setRecurringLockupDurationSecs`, `setMaxValidatorSetSize`, `setVotingPowerIncreaseLimitPct`

---

### Genesis / bootstrap procedure (recommended)

At chain genesis:

- Deploy the validator management contract at a **well-known system address**.
- Initialize global config parameters.
- Register the initial validator set with their consensus keys and initial bonds.
- Mark the initial validator set as ACTIVE and set `epoch = 0` (or `1`, but specify consistently).
  - Ensure each validator’s `delegatedVoter` and `feeRecipient` are initialized (defaults to owner unless specified).

If genesis wants to avoid running the full queue machinery, provide a one-time, system-only initializer:

- `bootstrapGenesisValidatorSet(validators[], votingPowersOrBonds[], consensusKeys[], ...)`

that can only be called when `epoch == 0` and a `bootstrapped == false` flag is unset.

---

### Future extensions (optional)

These features are explicitly out of scope for the MVP but can be layered on later:

- **Slashing**: define slashable offenses (double-sign, downtime), a reporting path, and penalties
  - penalties might move bonded stake to a burn address or protocol treasury.
- **Jailing**: temporary removal from active set without full exit/unbond.
- **Governance**: on-chain parameter changes with a timelock, plus emergency pause.
- **Stake snapshots**: explicit stake snapshots at epoch boundary for tighter accounting.
- **Multiple bond assets**: support multiple collateral types or LSDs (not recommended for KISS).

---

### References

- `gravity_docs/about_gravity.md` — Gravity design constraints (no delegation, EIP-1559-style incentives).
- `gravity_docs/staking_gov.md` and `gravity_docs/staking_gov_gpt.md` — Aptos staking/governance mental model (stake buckets, epoch transitions, validator set queues).
- Aptos Move framework modules (for conceptual grounding):
  - `aptos_framework::stake`
  - `aptos_framework::reconfiguration`
  - `aptos_framework::aptos_governance`



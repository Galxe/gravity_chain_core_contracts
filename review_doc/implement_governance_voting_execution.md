# implement_governance_voting_execution

- **Agent**: implementation_analyzer
- **Status**: success
- **Duration**: 77558ms
- **Steps**: 1

## Report

Here is the factual implementation summary of the **Governance** contract:

---

## Implementation Summary: Governance Contract

### Files/Contracts Involved

| File | Description |
|------|-------------|
| `src/governance/Governance.sol` | Main governance contract — proposals, voting, resolution, execution |
| `src/governance/IGovernance.sol` | Interface definition with events and function signatures |
| `src/foundation/Types.sol` | `Proposal` struct and `ProposalState` enum |
| `src/foundation/Errors.sol` | All custom error definitions |
| `src/foundation/SystemAddresses.sol` | Compile-time constants for system contract addresses |
| `src/runtime/GovernanceConfig.sol` | Governance parameters (voting threshold, proposer stake, voting duration) |
| `src/staking/Staking.sol` | Staking factory — pool validation, voting power queries, voter lookups |

---

### State Variables

| Variable | Type | Description |
|----------|------|-------------|
| `nextProposalId` | `uint64` | Starts at 1; ID 0 is a sentinel for "not found" |
| `_proposals` | `mapping(uint64 => Proposal)` | Proposal storage by ID |
| `usedVotingPower` | `mapping(address => mapping(uint64 => uint128))` | Pool → proposalId → power already used |
| `executed` | `mapping(uint64 => bool)` | Whether a proposal has been executed |
| `lastVoteTime` | `mapping(uint64 => uint64)` | Timestamp of last vote per proposal (atomicity guard) |
| `_executors` | `EnumerableSet.AddressSet` | Set of authorized executors |

Inherits `Ownable2Step` (two-step ownership transfer from OpenZeppelin). Constructor takes `initialOwner`. `renounceOwnership()` is overridden to always revert.

---

### Key Functions

#### `createProposal(address stakePool, address[] targets, bytes[] datas, string metadataUri) → uint64`
- **Access**: Anyone (must be pool's voter)
- **Checks**: `targets.length == datas.length`, `targets.length > 0`, pool is valid via `_staking().isPool()`, caller == `_staking().getPoolVoter(stakePool)`, `nextProposalId != 0` (defence-in-depth)
- **Voting power check**: Calls `_staking().getPoolVotingPower(stakePool, expirationTime)` — returns 0 if pool's lockup doesn't cover `expirationTime`, so the lockup check is implicit. Must be ≥ `_config().requiredProposerStake()`
- **State changes**: Increments `nextProposalId`, writes new `Proposal` struct to `_proposals[proposalId]` with `expirationTime = now + votingDurationMicros`, `minVoteThreshold` from config, `executionHash = keccak256(abi.encode(targets, datas))`
- **Emits**: `ProposalCreated`

#### `vote(address stakePool, uint64 proposalId, uint128 votingPower, bool support)`
- **Access**: Anyone (must be pool's voter)
- Delegates to `_voteInternal`

#### `batchVote(address[] stakePools, uint64 proposalId, bool support)`
- **Access**: Anyone (must be voter for all pools)
- Loops over `stakePools`, calls `_voteInternal` with `type(uint128).max` for each (uses all remaining power)

#### `batchPartialVote(address[] stakePools, uint64 proposalId, uint128 votingPower, bool support)`
- **Access**: Anyone (must be voter for all pools)
- Loops over `stakePools`, calls `_voteInternal` with the specified `votingPower` for each

#### `_voteInternal(address stakePool, uint64 proposalId, uint128 votingPower, bool support)` (internal)
- **Checks**: Proposal exists (`p.id != 0`), voting period not ended (`now_ < expirationTime`), not already resolved, pool valid, caller is pool's voter
- **Voting power accounting**: Calls `getRemainingVotingPower()` which computes `poolPower - usedVotingPower[pool][proposalId]`, where `poolPower = _staking().getPoolVotingPower(stakePool, p.expirationTime)` clamped to `uint128.max`. If requested `votingPower > remaining`, caps to `remaining`. If 0, silently returns (no revert)
- **State changes**: `usedVotingPower[stakePool][proposalId] += votingPower`, increments `p.yesVotes` or `p.noVotes`, sets `lastVoteTime[proposalId] = now_`
- **Emits**: `VoteCast`

#### `resolve(uint64 proposalId)`
- **Access**: Anyone (permissionless)
- **Checks**: Proposal exists, not already resolved, voting period ended (`now_ >= expirationTime`), **atomicity guard**: `lastVote > 0 && now_ <= lastVote` → reverts with `ResolutionCannotBeAtomic`. This requires resolution to happen in a strictly later timestamp than the last vote
- **State changes**: Sets `p.isResolved = true`, `p.resolutionTime = now_`
- **Emits**: `ProposalResolved` with state from `getProposalState()`

#### `execute(uint64 proposalId, address[] targets, bytes[] datas)`
- **Access**: `onlyExecutor` modifier — requires `_executors.contains(msg.sender)`
- **Checks**: `targets.length == datas.length`, `targets.length > 0`, proposal exists, not already executed, `getProposalState() == SUCCEEDED`, execution hash match: `keccak256(abi.encode(targets, datas)) == _proposals[proposalId].executionHash`
- **CEI pattern**: Sets `executed[proposalId] = true` **before** making external calls
- **External calls**: Loops over `targets[i].call(datas[i])` — low-level calls, reverts with `ExecutionFailed` if any returns `success == false`. Return data is discarded
- **Emits**: `ProposalExecuted`

#### `computeExecutionHash(address[] targets, bytes[] datas) → bytes32` (pure)
- Returns `keccak256(abi.encode(targets, datas))`

#### `addExecutor(address executor)` / `removeExecutor(address executor)`
- **Access**: `onlyOwner` (from Ownable2Step)
- Uses `EnumerableSet.add()` / `.remove()` — returns bool indicating whether the set changed; only emits event if the set actually changed

---

### Proposal State Machine (`getProposalState`)

```
PENDING → (voting period ends) → SUCCEEDED or FAILED → (execute) → EXECUTED
```

State determination logic:
1. If `executed[proposalId]` → `EXECUTED`
2. If `p.isResolved` → check `yesVotes > noVotes && yesVotes + noVotes >= minVoteThreshold` → `SUCCEEDED` or `FAILED`
3. If `now_ < expirationTime` → `PENDING`
4. If voting ended but not resolved → same yes/no check → `SUCCEEDED` or `FAILED`

A proposal is `SUCCEEDED` when: `yesVotes > noVotes` (strict majority) **AND** `yesVotes + noVotes >= minVoteThreshold` (quorum met).

Note: `CANCELLED` state (value 4) exists in the enum but there is no cancel mechanism in the contract.

---

### Flash Loan Protection (Atomicity Guard)

- Every call to `_voteInternal` writes `lastVoteTime[proposalId] = now_` (current microsecond timestamp)
- `resolve()` checks: if `lastVote > 0 && now_ <= lastVote`, it reverts with `ResolutionCannotBeAtomic`
- `canResolve()` returns `false` under the same condition
- This means resolution must occur at a strictly later timestamp than the last vote, preventing vote + resolve in the same block/transaction

---

### External Dependencies

| Contract | Address | Functions Called |
|----------|---------|-----------------|
| `ITimestamp` | `SystemAddresses.TIMESTAMP` | `nowMicroseconds()` |
| `GovernanceConfig` | `SystemAddresses.GOVERNANCE_CONFIG` | `votingDurationMicros()`, `requiredProposerStake()`, `minVotingThreshold()` |
| `IStaking` | `SystemAddresses.STAKING` | `isPool()`, `getPoolVoter()`, `getPoolVotingPower(pool, atTime)` |

All system contract addresses are compile-time constants in `SystemAddresses`.

---

### Ownership Controls

- Inherits `Ownable2Step` — ownership transfer requires `transferOwnership()` then `acceptOwnership()` by the new owner
- `renounceOwnership()` overridden to always revert (`OperationNotSupported`)
- Owner can `addExecutor` and `removeExecutor`
- Owner has **no** direct power over proposals, voting, resolution, or execution

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

task_int | Here is the factual implementation summary of the **Governan | 77558ms |

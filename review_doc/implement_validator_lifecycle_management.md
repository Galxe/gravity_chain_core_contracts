# implement_validator_lifecycle_management

- **Agent**: implementation_analyzer
- **Status**: success
- **Duration**: 134155ms
- **Steps**: 1

## Report

Now I have a complete picture. Here's the implementation analysis:

---

## Implementation Summary: ValidatorManagement

### Files/Contracts Involved

| File | Description |
|---|---|
| `src/staking/ValidatorManagement.sol` | Core contract — registration, lifecycle, epoch processing |
| `src/staking/IValidatorManagement.sol` | Interface definition + `GenesisValidator` struct |
| `src/foundation/Types.sol` | `ValidatorRecord`, `ValidatorStatus` enum, `ValidatorConsensusInfo` |
| `src/Genesis.sol` | Calls `ValidatorManagement.initialize()` with genesis validators |
| `src/staking/Staking.sol` | Factory — delegates `getPoolVotingPower`, `renewPoolLockup`, etc. to StakePool |
| `src/foundation/SystemAddresses.sol` | Hardcoded system addresses (VALIDATOR_MANAGER = `0x1625F2001`) |
| `src/foundation/SystemAccessControl.sol` | `requireAllowed()` — checks `msg.sender` |

### State Variables

| Variable | Type | Purpose |
|---|---|---|
| `_validators` | `mapping(address => ValidatorRecord)` | All validator records by stakePool address |
| `_activeValidators` | `address[]` | Ordered active set (index = validatorIndex) |
| `_pendingActive` | `address[]` | Queue of validators waiting to join |
| `_pendingInactive` | `address[]` | Queue of validators waiting to leave |
| `totalVotingPower` | `uint256` | Snapshotted sum of active voting power |
| `_pubkeyToValidator` | `mapping(bytes32 => address)` | keccak256(pubkey) → stakePool for uniqueness |
| `_initialized` | `bool` | One-time init flag |

### Status Transitions

```
INACTIVE → PENDING_ACTIVE → ACTIVE → PENDING_INACTIVE → INACTIVE
    ↑           │                                            │
    └───────────┘  (revert if bond < min, or leave request)  │
    └────────────────────────────────────────────────────────┘
```

### Key Functions

#### Initialization

**`initialize(GenesisValidator[] calldata)`** (line 115)
- Access: `requireAllowed(GENESIS)` — only Genesis contract
- Guard: `_initialized` must be false
- For each genesis validator: calls `_initializeGenesisValidator()` which:
  - Validates moniker length ≤ 31 bytes
  - Validates pubkey length = 48 bytes (BLS12-381 G1 compressed)
  - Validates PoP is non-empty (but does **NOT** run BLS precompile verification)
  - Creates `ValidatorRecord` with status `ACTIVE`, bond = `votingPower`
  - Registers pubkey in `_pubkeyToValidator` mapping
  - Pushes to `_activeValidators`
- Sets `totalVotingPower` as cumulative sum

#### Registration

**`registerValidator(stakePool, moniker, pubkey, pop, networkAddr, fullnodeAddr)`** (line 234)
- Access: no modifier — checks operator inline in `_validateRegistration`
- Guards: `allowValidatorSetChange` must be true
- `_validateRegistration()` checks:
  1. `stakePool` is a valid pool via `Staking.isPool()`
  2. `msg.sender` is the pool's operator via `Staking.getPoolOperator()`
  3. Validator not already registered (`_validators[stakePool].validator == address(0)`)
  4. `getPoolVotingPower(stakePool, now) >= minimumBond`
  5. Moniker ≤ 31 bytes
- `_createValidatorRecord()`:
  1. Calls `_validateConsensusPubkey()` — staticcall to BLS PoP precompile at `0x1625F5001` with `pubkey || pop` (144 bytes), expects ABI-encoded uint256 = 1
  2. Checks pubkey uniqueness via `_pubkeyToValidator[keccak256(pubkey)]`
  3. Sets status = `INACTIVE`, bond = current voting power
  4. Sets feeRecipient = pool owner (not a parameter — has TODO comment)

#### Lifecycle: Join

**`joinValidatorSet(address stakePool)`** (line 357)
- Modifiers: `validatorExists`, `onlyOperator`, `whenNotReconfiguring`
- Guards:
  1. `allowValidatorSetChange` must be true
  2. Status must be `INACTIVE`
  3. Current voting power ≥ `minimumBond`
  4. `_activeValidators.length + _pendingActive.length < maxValidatorSetSize`
- State change: status → `PENDING_ACTIVE`, push to `_pendingActive`

#### Lifecycle: Leave (voluntary)

**`leaveValidatorSet(address stakePool)`** (line 394)
- Modifiers: `validatorExists`, `onlyOperator`, `whenNotReconfiguring`
- Guards: `allowValidatorSetChange` must be true
- If status == `PENDING_ACTIVE`: removes from `_pendingActive` (swap-and-pop), sets status → `INACTIVE`, returns immediately
- If status == `ACTIVE`: requires `_activeValidators.length > 1` (last validator protection), sets status → `PENDING_INACTIVE`, pushes to `_pendingInactive`
- Reverts if status is anything else

#### Lifecycle: Force Leave (governance)

**`forceLeaveValidatorSet(address stakePool)`** (line 430)
- Modifiers: `validatorExists`, `whenNotReconfiguring`
- Access: `requireAllowed(GOVERNANCE)`
- If `PENDING_ACTIVE`: same as voluntary leave — immediate revert to `INACTIVE`
- If `ACTIVE`: requires `_activeValidators.length > 1` (Note: uses `<=1` not `==1`, same effect), sets → `PENDING_INACTIVE`
- Does NOT check `allowValidatorSetChange` (governance override)

#### Operator: Key Rotation

**`rotateConsensusKey(stakePool, newPubkey, newPop)`** (line 467)
- Modifiers: `validatorExists`, `onlyOperator`, `whenNotReconfiguring`
- Runs full BLS PoP verification via precompile
- Checks new key uniqueness, clears old key from mapping, registers new
- Updates `consensusPubkey` and `consensusPop` — takes effect **immediately** (has TODO questioning this)

#### Operator: Fee Recipient

**`setFeeRecipient(stakePool, newRecipient)`** (line 498)
- Modifiers: `validatorExists`, `onlyOperator`, `whenNotReconfiguring`
- Guard: `newRecipient != address(0)`
- Sets `pendingFeeRecipient` — applied at next epoch boundary

#### Epoch Processing: Auto-Eviction

**`evictUnderperformingValidators()`** (line 584)
- Access: `requireAllowed(RECONFIGURATION)`
- Called BEFORE `onNewEpoch()` during the same reconfiguration transaction
- Reads `autoEvictEnabled` and `autoEvictThreshold` from ValidatorConfig
- Reads performance data from `ValidatorPerformanceTracker.getAllPerformances()`
- If `activeLen != perfLen`: emits `PerformanceLengthMismatch` and returns (no-op)
- Counts `remainingActive` (only ACTIVE status, not already PENDING_INACTIVE)
- For each active validator: if `successfulProposals <= threshold` AND `remainingActive > 1`: sets → `PENDING_INACTIVE`, pushes to `_pendingInactive`, decrements counter
- Result: evicted validators go ACTIVE → PENDING_INACTIVE here, then PENDING_INACTIVE → INACTIVE in `onNewEpoch()` — **same transaction, one epoch transition**

#### Epoch Processing: onNewEpoch

**`onNewEpoch()`** (line 520)
- Access: `requireAllowed(RECONFIGURATION)`
- Steps:
  1. **Compute next set**: `_computeNextEpochValidatorSet()` — single source of truth
  2. **Deactivate**: all `_pendingInactive` → status `INACTIVE`, index cleared to `type(uint64).max`, delete `_pendingInactive`
  3. **Activate**: selected `_pendingActive` → status `ACTIVE`
  4. **Revert inactive**: pending validators below `minimumBond` → status `INACTIVE`
  5. **Update pending**: keep validators that exceeded voting power limit in `_pendingActive`
  6. **Set active validators**: overwrite `_activeValidators` with computed set, update each record's `validatorIndex` and `bond`
  7. **Renew lockups**: calls `Staking.renewPoolLockup(pool)` for each active validator → `StakePool.systemRenewLockup()`
  8. **Apply fee recipients**: if `pendingFeeRecipient != address(0)`, swap to `feeRecipient`, clear pending
  9. **Sync bonds**: re-read voting power for all active validators (post-lockup-renewal)
  10. **Update total**: recalculate `totalVotingPower` from `_getValidatorVotingPower()`

#### Voting Power Calculation

**`_getValidatorVotingPower(stakePool)`** (line 792)
- Calls `Staking.getPoolVotingPower(stakePool, now)` → delegates to `StakePool.getVotingPower(atTime)`
- Caps at `ValidatorConfig.maximumBond()`: `min(power, maxBond)`

#### Compute Next Epoch Validator Set

**`_computeNextEpochValidatorSet()`** (line 809)
- Returns `NextEpochValidatorSet` struct containing transition arrays + final validator set
- Step 1: All `_pendingInactive` → `toDeactivate`
- Step 2: Count staying active (status != PENDING_INACTIVE)
- Step 3: For each `_pendingActive`:
  - If `power < minimumBond` → `toRevertInactive`
  - If `currentTotal > 0 && addedPower + power > maxIncrease` → `toKeepPending` (voting power increase limit: `currentTotal * votingPowerIncreaseLimitPct * 1e4 / (100 * 1e4)`)
  - Otherwise → `toActivate`, accumulate `addedPower`
- Step 4: Build final array: staying active validators first (preserving order), then newly activated, with fresh indices 0, 1, 2, ...

### DKG Support

- **`getCurValidatorConsensusInfos()`**: returns `_activeValidators` as-is (includes PENDING_INACTIVE), using stored `bond` values. For DKG dealers.
- **`getNextValidatorConsensusInfos()`**: calls `_computeNextEpochValidatorSet().validators`. Fresh indices. For DKG targets.

### External Dependencies

| Contract | Calls Made |
|---|---|
| `Staking` (`0x1625F2000`) | `isPool()`, `getPoolOperator()`, `getPoolOwner()`, `getPoolVotingPower()`, `renewPoolLockup()` |
| `ValidatorConfig` (`0x1625F1002`) | `allowValidatorSetChange()`, `minimumBond()`, `maximumBond()`, `maxValidatorSetSize()`, `votingPowerIncreaseLimitPct()`, `autoEvictEnabled()`, `autoEvictThreshold()` |
| `Reconfiguration` (`0x1625F2003`) | `isTransitionInProgress()`, `currentEpoch()` |
| `Timestamp` (`0x1625F1000`) | `nowMicroseconds()` |
| `ValidatorPerformanceTracker` (`0x1625F2005`) | `getAllPerformances()` |
| BLS PoP Precompile (`0x1625F5001`) | `staticcall(pubkey \|\| pop)` → uint256 (1=valid) |

### Access Control Summary

| Function | Caller Restriction |
|---|---|
| `initialize()` | GENESIS contract |
| `registerValidator()` | Pool operator (checked inline) |
| `joinValidatorSet()` | Pool operator (modifier) |
| `leaveValidatorSet()` | Pool operator (modifier) |
| `forceLeaveValidatorSet()` | GOVERNANCE contract |
| `rotateConsensusKey()` | Pool operator (modifier) |
| `setFeeRecipient()` | Pool operator (modifier) |
| `onNewEpoch()` | RECONFIGURATION contract |
| `evictUnderperformingValidators()` | RECONFIGURATION contract |

All lifecycle-modifying functions (except `forceLeaveValidatorSet` and `evictUnderperformingValidators`) also carry the `whenNotReconfiguring` modifier, which blocks calls while `Reconfiguration.isTransitionInProgress()` returns true.

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

task_int | Now I have a complete picture. Here's the implementation ana | 134155ms |

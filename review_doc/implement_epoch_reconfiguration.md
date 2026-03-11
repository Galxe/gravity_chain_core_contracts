# implement_epoch_reconfiguration

- **Agent**: implementation_analyzer
- **Status**: success
- **Duration**: 125920ms
- **Steps**: 1

## Report

Here is the factual implementation summary:

---

# Reconfiguration Contract — Implementation Analysis

## Files/Contracts Involved

| File | Description |
|------|-------------|
| `src/blocker/Reconfiguration.sol` | Central epoch transition orchestrator; the main subject |
| `src/blocker/IReconfiguration.sol` | Interface defining `TransitionState` enum, events, and function signatures |
| `src/blocker/Blocker.sol` | Block prologue; calls `checkAndStartTransition()` every block |
| `src/blocker/IValidatorPerformanceTracker.sol` | Interface for per-epoch validator proposal tracking |
| `src/runtime/DKG.sol` | DKG session lifecycle (start/finish/clear) |
| `src/runtime/EpochConfig.sol` | Stores `epochIntervalMicros`; pending-config pattern |
| `src/runtime/ConsensusConfig.sol` | BCS-serialized consensus params; pending-config pattern |
| `src/runtime/ExecutionConfig.sol` | BCS-serialized execution params; pending-config pattern |
| `src/runtime/ValidatorConfig.sol` | Validator bonding/set-size params; pending-config pattern |
| `src/runtime/VersionConfig.sol` | Single `uint64 majorVersion`; pending-config pattern |
| `src/runtime/GovernanceConfig.sol` | Voting threshold/duration params; pending-config pattern |
| `src/runtime/StakingConfig.sol` | Minimum stake/lockup/unbonding params; pending-config pattern |
| `src/runtime/RandomnessConfig.sol` | DKG threshold config (`Off` or `V2`); pending-config pattern |
| `src/staking/IValidatorManagement.sol` | Validator lifecycle: registration, activation, eviction, epoch rotation |

---

## State Machine

```
TransitionState enum: { Idle, DkgInProgress }
```

| From | To | Trigger |
|------|----|---------|
| `Idle` | `Idle` | `checkAndStartTransition()` when DKG is Off → immediate reconfigure |
| `Idle` | `DkgInProgress` | `checkAndStartTransition()` when DKG is V2 → `_startDkgSession()` |
| `Idle` | `Idle` | `governanceReconfigure()` when DKG is Off → immediate reconfigure |
| `Idle` | `DkgInProgress` | `governanceReconfigure()` when DKG is V2 → `_startDkgSession()` |
| `DkgInProgress` | `Idle` | `finishTransition()` → `_applyReconfiguration()` |

State variables:
- `_transitionState`: current `TransitionState`
- `_transitionStartedAtEpoch`: epoch number when `DkgInProgress` was entered (set in `_startDkgSession`, never read after — stored for future validation use)

---

## Entry Points & Access Control

### 1. `initialize()` — Genesis only
- **Access**: `requireAllowed(SystemAddresses.GENESIS)`
- **Guard**: `_initialized` bool; reverts `AlreadyInitialized` on second call
- **State changes**: `currentEpoch = 1`, `lastReconfigurationTime = now`, `_transitionState = Idle`, `_initialized = true`
- **Events**: `EpochTransitioned(0, lastReconfigurationTime)`

### 2. `checkAndStartTransition()` — Called every block
- **Access**: `requireAllowed(SystemAddresses.BLOCK)` (Blocker contract)
- **Execution path**:
  1. If `_transitionState == DkgInProgress` → return `false` (skip)
  2. Call `_canTransition()`: reads `ITimestamp.nowMicroseconds()` and `EpochConfig.epochIntervalMicros()`, checks `currentTime >= lastReconfigurationTime + epochInterval`. If false → return `false`
  3. Read `RandomnessConfig.getCurrentConfig()`
  4. If `config.variant == Off` → call `_doImmediateReconfigure()`
  5. If `config.variant == V2` → call `_startDkgSession(config)`
  6. Return `true`

### 3. `finishTransition(bytes dkgResult)` — Consensus engine or governance
- **Access**: `requireAllowed(SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE)`
- **Execution path**:
  1. Require `_transitionState == DkgInProgress` (reverts `ReconfigurationNotInProgress`)
  2. If `dkgResult.length > 0` → call `DKG.finish(dkgResult)` (stores transcript, moves session to completed, clears in-progress)
  3. Call `DKG.tryClearIncompleteSession()` (clears any remaining in-progress session — no-op if already cleared by `finish`)
  4. Call `_applyReconfiguration()`

### 4. `governanceReconfigure()` — Emergency governance-forced epoch transition
- **Access**: `requireAllowed(SystemAddresses.GOVERNANCE)`
- **Execution path**:
  1. If `_transitionState == DkgInProgress` → revert `ReconfigurationInProgress` (governance must use `finishTransition()` instead)
  2. Read `RandomnessConfig.getCurrentConfig()`
  3. If `variant == Off` → `_doImmediateReconfigure()`
  4. If `variant == V2` → `_startDkgSession(config)` (requires separate `finishTransition()` call to complete)

---

## Key Internal Functions

### `_canTransition() → bool` (view)
- Reads `ITimestamp(TIMESTAMP).nowMicroseconds()` and `EpochConfig(EPOCH_CONFIG).epochIntervalMicros()`
- Returns `currentTime >= lastReconfigurationTime + epochInterval`

### `_startDkgSession(RandomnessConfigData config)`
1. Calls `ValidatorManagement.getCurValidatorConsensusInfos()` → dealers (current validators)
2. Calls `ValidatorManagement.getNextValidatorConsensusInfos()` → targets (next epoch validators)
3. Calls `DKG.tryClearIncompleteSession()` — clears any stale DKG session
4. Calls `DKG.start(currentEpoch, config, dealers, targets)` — starts new DKG session, emits `DKGStartEvent`
5. Sets `_transitionState = DkgInProgress`, `_transitionStartedAtEpoch = currentEpoch`
6. Emits `EpochTransitionStarted(currentEpoch)`

### `_doImmediateReconfigure()`
1. Calls `DKG.tryClearIncompleteSession()` — clears any stale DKG session
2. Calls `_applyReconfiguration()`

### `_applyReconfiguration()` — Core epoch transition logic
Executes in strict order:

**Step 1 — Apply all 8 pending configs:**
```
RandomnessConfig.applyPendingConfig()
ConsensusConfig.applyPendingConfig()
ExecutionConfig.applyPendingConfig()
ValidatorConfig.applyPendingConfig()
VersionConfig.applyPendingConfig()
GovernanceConfig.applyPendingConfig()
StakingConfig.applyPendingConfig()
EpochConfig.applyPendingConfig()
```
Each config contract: if `hasPendingConfig == true`, copies pending → current and clears pending flag. If no pending config, is a no-op. Access restricted to `RECONFIGURATION` address.

**Step 2 — Auto-evict underperforming validators:**
```
ValidatorManagement.evictUnderperformingValidators()
```
Comment states: happens after config apply (so `autoEvictEnabled` reflects latest governance setting) and before `onNewEpoch()` (so evicted validators are processed in same transition). Evicted validators go `ACTIVE → PENDING_INACTIVE`.

**Step 3 — Notify validator manager:**
```
ValidatorManagement.onNewEpoch()
```
Processes validator set changes (pending joins/leaves). Comment: called before epoch increment (Aptos pattern). Transitions: `PENDING_INACTIVE → INACTIVE`, activates pending validators.

**Step 4 — Reset performance tracker:**
```
ValidatorPerformanceTracker.onNewEpoch(newValidatorCount)
```
Resets per-validator proposal counters for the new epoch. `newValidatorCount` is read from `ValidatorManagement.getActiveValidatorCount()` after `onNewEpoch()` completes.

**Step 5 — Increment epoch:**
```
currentEpoch = currentEpoch + 1
lastReconfigurationTime = ITimestamp.nowMicroseconds()
```

**Step 6 — Reset state machine:**
```
_transitionState = Idle
```

**Step 7 — Read finalized validator set:**
```
ValidatorManagement.getActiveValidators()
ValidatorManagement.getTotalVotingPower()
```

**Step 8 — Emit events:**
```
EpochTransitioned(newEpoch, lastReconfigurationTime)
NewEpochEvent(newEpoch, validatorSet, totalVotingPower, lastReconfigurationTime)
```

---

## Execution Path: Normal Epoch Transition (DKG Enabled)

```
Block N:  Blocker.onBlockStart()
            → updateStatistics(proposer, failedProposers)
            → resolveProposer()
            → Timestamp.updateGlobalTime()
            → Reconfiguration.checkAndStartTransition()
                → _canTransition() returns true (time elapsed)
                → RandomnessConfig.getCurrentConfig() → variant=V2
                → _startDkgSession()
                    → ValidatorManagement.getCurValidatorConsensusInfos()
                    → ValidatorManagement.getNextValidatorConsensusInfos()
                    → DKG.tryClearIncompleteSession()
                    → DKG.start(epoch, config, dealers, targets)
                    → _transitionState = DkgInProgress
                    → emit EpochTransitionStarted

Blocks N+1..M:  Blocker.onBlockStart()
                  → checkAndStartTransition() returns false (DkgInProgress)

After DKG completes off-chain:
          ConsensusEngine → Reconfiguration.finishTransition(dkgResult)
                → DKG.finish(dkgResult)
                → DKG.tryClearIncompleteSession()  // no-op
                → _applyReconfiguration()
                    → [8 config applies]
                    → evictUnderperformingValidators()
                    → ValidatorManagement.onNewEpoch()
                    → PerformanceTracker.onNewEpoch(count)
                    → epoch++, timestamp update
                    → _transitionState = Idle
                    → emit EpochTransitioned, NewEpochEvent
```

---

## Execution Path: Normal Epoch Transition (DKG Disabled)

```
Block N:  Blocker.onBlockStart()
            → Reconfiguration.checkAndStartTransition()
                → _canTransition() returns true
                → RandomnessConfig.getCurrentConfig() → variant=Off
                → _doImmediateReconfigure()
                    → DKG.tryClearIncompleteSession()
                    → _applyReconfiguration()
                        → [full 8-step sequence, epoch++]
```
No async phase; transition is atomic within a single block.

---

## Execution Path: Governance Emergency Reconfigure

**Case A — DKG Off:**
```
Governance → Reconfiguration.governanceReconfigure()
    → require state == Idle
    → RandomnessConfig → Off
    → _doImmediateReconfigure()  // atomic
```

**Case B — DKG On, no existing transition:**
```
Governance → Reconfiguration.governanceReconfigure()
    → require state == Idle
    → RandomnessConfig → V2
    → _startDkgSession()  // state → DkgInProgress

Later: Governance → Reconfiguration.finishTransition(dkgResult)
    → _applyReconfiguration()  // completes transition
```

**Case C — DKG On, transition already in progress:**
```
Governance → Reconfiguration.governanceReconfigure()
    → state == DkgInProgress → revert ReconfigurationInProgress
    // Governance must call finishTransition() directly instead
```

---

## Timing Check Details

- `_canTransition()` compares `ITimestamp.nowMicroseconds() >= lastReconfigurationTime + EpochConfig.epochIntervalMicros()`
- `lastReconfigurationTime` is updated only in `_applyReconfiguration()` (step 5), meaning the timer for the next epoch starts when the current transition *completes*, not when it starts
- `governanceReconfigure()` does **not** check `_canTransition()` — it can force a transition at any time regardless of the epoch timer
- `getRemainingTimeSeconds()` returns `(nextEpochTime - currentTime) / 1_000_000` or `0` if past due

---

## State Changes Summary

| Storage Variable | Written By | When |
|---|---|---|
| `currentEpoch` | `_applyReconfiguration()` | Incremented by 1 at end of transition |
| `lastReconfigurationTime` | `_applyReconfiguration()` | Set to `nowMicroseconds()` at end of transition |
| `_transitionState` | `_startDkgSession()` → `DkgInProgress`; `_applyReconfiguration()` → `Idle` | Start/end of async transition |
| `_transitionStartedAtEpoch` | `_startDkgSession()` | Set to `currentEpoch`; never read in current code |
| `_initialized` | `initialize()` | Set to `true` once |

---

## External Dependencies (calls made by Reconfiguration)

| Contract | Functions Called |
|---|---|
| `ITimestamp(TIMESTAMP)` | `nowMicroseconds()` |
| `EpochConfig(EPOCH_CONFIG)` | `epochIntervalMicros()`, `applyPendingConfig()` |
| `IRandomnessConfig(RANDOMNESS_CONFIG)` | `getCurrentConfig()`, `applyPendingConfig()` |
| `IDKG(DKG)` | `start()`, `finish()`, `tryClearIncompleteSession()` |
| `IValidatorManagement(VALIDATOR_MANAGER)` | `getCurValidatorConsensusInfos()`, `getNextValidatorConsensusInfos()`, `evictUnderperformingValidators()`, `onNewEpoch()`, `getActiveValidatorCount()`, `getActiveValidators()`, `getTotalVotingPower()` |
| `IValidatorPerformanceTracker(PERFORMANCE_TRACKER)` | `onNewEpoch(uint256)` |
| `ConsensusConfig(CONSENSUS_CONFIG)` | `applyPendingConfig()` |
| `ExecutionConfig(EXECUTION_CONFIG)` | `applyPendingConfig()` |
| `ValidatorConfig(VALIDATOR_CONFIG)` | `applyPendingConfig()` |
| `VersionConfig(VERSION_CONFIG)` | `applyPendingConfig()` |
| `GovernanceConfig(GOVERNANCE_CONFIG)` | `applyPendingConfig()` |
| `StakingConfig(STAKE_CONFIG)` | `applyPendingConfig()` |

---

## Notable Implementation Details

1. **`_transitionStartedAtEpoch`** is written in `_startDkgSession()` but never read anywhere in the current codebase. It exists as a validation field for potential future use.

2. **`finishTransition`** calls `DKG.tryClearIncompleteSession()` unconditionally after the conditional `DKG.finish()`. If `dkgResult` is non-empty, `finish()` already clears the in-progress session, so `tryClearIncompleteSession()` becomes a no-op. If `dkgResult` is empty (governance force-end without result), `tryClearIncompleteSession()` clears the stale DKG session.

3. **Config application order**: All 8 config contracts are applied before any validator changes. `EpochConfig` is applied last among configs, meaning a governance change to epoch interval takes effect starting from the *next* epoch boundary after the one where it was applied.

4. **Auto-eviction ordering**: `evictUnderperformingValidators()` is called after config apply (so it uses the latest `autoEvictEnabled` setting) but before `onNewEpoch()` (so evicted `ACTIVE → PENDING_INACTIVE` validators are then transitioned to `INACTIVE` in the same `onNewEpoch()` call).

5. **Performance tracker reset**: `onNewEpoch(newValidatorCount)` is called with the count *after* `ValidatorManagement.onNewEpoch()` completes, ensuring the counter array matches the finalized active set size.

6. **DKG cleanup**: Both `_startDkgSession()` and `_doImmediateReconfigure()` call `DKG.tryClearIncompleteSession()` before proceeding, ensuring stale DKG sessions from previous failed transitions are always cleaned up.

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

task_int | Here is the factual implementation summary:

---

# Reconfig | 125920ms |

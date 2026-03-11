# implement_block_prologue_blocker

- **Agent**: implementation_analyzer
- **Status**: success
- **Duration**: 80997ms
- **Steps**: 1

## Report

I now have all the information needed. Here is the factual implementation summary:

---

## Blocker Contract — Implementation Summary

### Files/Contracts Involved

| File | Description |
|------|-------------|
| `src/blocker/Blocker.sol` | Block prologue entry point; called by VM at start of each block |
| `src/blocker/ValidatorPerformanceTracker.sol` | Tracks per-validator successful/failed proposal counts per epoch |
| `src/blocker/IValidatorPerformanceTracker.sol` | Interface defining `IndividualPerformance` struct and tracker functions |
| `src/blocker/IReconfiguration.sol` | Interface for epoch transition lifecycle (check, start, finish) |
| `src/runtime/ITimestampWriter.sol` | Interface for updating on-chain global timestamp |
| `src/staking/IValidatorManagement.sol` | Interface for querying active validator set by index |
| `src/foundation/SystemAddresses.sol` | Compile-time constants for all system contract addresses |
| `src/foundation/SystemAccessControl.sol` | `requireAllowed()` free functions that revert if `msg.sender` doesn't match |
| `src/foundation/Types.sol` | `ValidatorConsensusInfo` struct (contains `.validator` address field) |

---

### Execution Path: `Blocker.onBlockStart()`

**Access control:** `requireAllowed(SystemAddresses.SYSTEM_CALLER)` — only the VM runtime (`0x…1625F0000`) can call this.

**Parameters:** `uint64 proposerIndex`, `uint64[] calldata failedProposerIndices`, `uint64 timestampMicros`

**Step-by-step call chain:**

1. **Performance tracking** (`Blocker.sol:95-96`)
   - Calls `IValidatorPerformanceTracker(PERFORMANCE_TRACKER).updateStatistics(proposerIndex, failedProposerIndices)`
   - This happens **before** epoch transition check (the comment on line 93-94 explicitly states this ordering: performance scores must be updated before epoch transition because the block that triggers transition is the last block of the previous epoch)

2. **Proposer resolution** (`Blocker.sol:101`, calls `_resolveProposer`)
   - If `proposerIndex == NIL_PROPOSER_INDEX` (`type(uint64).max` = `2^64 - 1`): returns `SystemAddresses.SYSTEM_CALLER`
   - Otherwise: calls `IValidatorManagement(VALIDATOR_MANAGER).getActiveValidatorByIndex(proposerIndex)` and returns `.validator` field from the `ValidatorConsensusInfo` struct

3. **Timestamp update** (`Blocker.sol:106`)
   - Calls `ITimestampWriter(TIMESTAMP).updateGlobalTime(validatorAddress, timestampMicros)`
   - Per the `ITimestampWriter` interface doc: normal blocks (proposer ≠ SYSTEM_CALLER) require timestamp to strictly advance; NIL blocks (proposer == SYSTEM_CALLER) require timestamp to equal current

4. **Epoch transition check** (`Blocker.sol:111`)
   - Calls `IReconfiguration(RECONFIGURATION).checkAndStartTransition()`
   - Returns `bool started` (return value is discarded by Blocker)

5. **Read current epoch** (`Blocker.sol:114`)
   - Calls `IReconfiguration(RECONFIGURATION).currentEpoch()` to get epoch for event

6. **Emit event** (`Blocker.sol:117`)
   - Emits `BlockStarted(block.number, epoch, validatorAddress, timestampMicros)`

---

### Execution Path: `Blocker.initialize()`

**Access control:** `requireAllowed(SystemAddresses.GENESIS)` — only the Genesis contract can call.

**Steps:**
1. Checks `_initialized` is false (reverts `AlreadyInitialized` otherwise)
2. Sets `_initialized = true`
3. Calls `ITimestampWriter(TIMESTAMP).updateGlobalTime(SYSTEM_CALLER, 0)` — initializes timestamp to 0
4. Emits `BlockStarted(0, 0, SYSTEM_CALLER, 0)`

---

### ValidatorPerformanceTracker — Key Functions

#### `initialize(uint256 activeValidatorCount)`
- **Access:** `GENESIS` only
- **Guard:** `_initialized` must be false
- Sets `_initialized = true`, then pushes `activeValidatorCount` zero-initialized `IndividualPerformance` structs into `_validators[]`

#### `updateStatistics(uint64 proposerIndex, uint64[] calldata failedProposerIndices)`
- **Access:** `SystemAddresses.BLOCK` only (i.e., the Blocker contract at `0x…1625F2004`)
- **Successful proposal:** If `proposerIndex != type(uint64).max` AND `proposerIndex < _validators.length`, increments `_validators[proposerIndex].successfulProposals`
- **Failed proposals:** Iterates `failedProposerIndices`; for each index < `_validators.length`, increments `_validators[index].failedProposals`
- **Out-of-bounds handling:** Silently skips (no revert) — matches Aptos pattern
- Emits `PerformanceUpdated(proposerIndex, failedLen)`

#### `onNewEpoch(uint256 activeValidatorCount)`
- **Access:** `SystemAddresses.RECONFIGURATION` only
- Pops all elements from `_validators[]` (loop from `oldLen` down to 0)
- Pushes `activeValidatorCount` fresh zero-initialized structs
- (Note: does NOT emit `PerformanceReset` event despite it being declared in the interface)

#### View functions
- `getPerformance(uint64 validatorIndex)` → returns `(successfulProposals, failedProposals)` or `(0,0)` if out of bounds
- `getAllPerformances()` → returns memory copy of entire `_validators[]` array
- `getTrackedValidatorCount()` → returns `_validators.length`
- `isInitialized()` → returns `_initialized`

---

### State Changes Summary

| Contract | Storage Variable | Modified By | What Changes |
|----------|-----------------|-------------|--------------|
| `Blocker` | `_initialized` | `initialize()` | Set to `true` once at genesis |
| `ValidatorPerformanceTracker` | `_initialized` | `initialize()` | Set to `true` once at genesis |
| `ValidatorPerformanceTracker` | `_validators[]` | `updateStatistics()` | Increments `successfulProposals` / `failedProposals` per validator index |
| `ValidatorPerformanceTracker` | `_validators[]` | `onNewEpoch()` | Array cleared and re-initialized with zeros |
| `Timestamp` (external) | global time | `onBlockStart()` → `updateGlobalTime()` | Updated every block |
| `Reconfiguration` (external) | epoch state | `onBlockStart()` → `checkAndStartTransition()` | May start epoch transition |

---

### External Dependencies (outgoing calls from Blocker)

| Target Address Constant | Interface | Function Called | From |
|------------------------|-----------|----------------|------|
| `PERFORMANCE_TRACKER` (`0x…2005`) | `IValidatorPerformanceTracker` | `updateStatistics()` | `onBlockStart` step 1 |
| `VALIDATOR_MANAGER` (`0x…2001`) | `IValidatorManagement` | `getActiveValidatorByIndex()` | `_resolveProposer` (non-NIL) |
| `TIMESTAMP` (`0x…1000`) | `ITimestampWriter` | `updateGlobalTime()` | `onBlockStart` step 3, `initialize` |
| `RECONFIGURATION` (`0x…2003`) | `IReconfiguration` | `checkAndStartTransition()` | `onBlockStart` step 4 |
| `RECONFIGURATION` (`0x…2003`) | `IReconfiguration` | `currentEpoch()` | `onBlockStart` step 5 |

---

### Access Control Map

| Function | Required `msg.sender` |
|----------|----------------------|
| `Blocker.initialize()` | `GENESIS` (`0x…F0001`) |
| `Blocker.onBlockStart()` | `SYSTEM_CALLER` (`0x…F0000`) |
| `ValidatorPerformanceTracker.initialize()` | `GENESIS` (`0x…F0001`) |
| `ValidatorPerformanceTracker.updateStatistics()` | `BLOCK` (`0x…F2004`) — the Blocker contract |
| `ValidatorPerformanceTracker.onNewEpoch()` | `RECONFIGURATION` (`0x…F2003`) |

---

### NIL Block Handling

- `NIL_PROPOSER_INDEX` is defined as `type(uint64).max` (constant `2^64 - 1`)
- In `updateStatistics`: the `proposerIndex != type(uint64).max` check skips incrementing `successfulProposals` for NIL blocks
- In `_resolveProposer`: NIL index maps to `SYSTEM_CALLER` address
- In `updateGlobalTime`: when proposer is `SYSTEM_CALLER`, timestamp must equal current (no advancement) per the `ITimestampWriter` interface contract

### `IndividualPerformance` Struct

```solidity
struct IndividualPerformance {
    uint64 successfulProposals;
    uint64 failedProposals;
}
```

### Constants

| Constant | Value | Location |
|----------|-------|----------|
| `NIL_PROPOSER_INDEX` | `type(uint64).max` (18446744073709551615) | `Blocker.sol:25` |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

task_int | I now have all the information needed. Here is the factual i | 80997ms |

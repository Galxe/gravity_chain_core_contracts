# attack_block_prologue_blocker

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 98594ms
- **Steps**: 1

## Report

# Blocker Contract — Red Team Attack Findings

## Critical

*No critical vulnerabilities found.*

## High

### H-01: Missing `PerformanceReset` Event Emission in `onNewEpoch()`

**File:** `ValidatorPerformanceTracker.sol:88-109`

The interface `IValidatorPerformanceTracker` declares:
```solidity
event PerformanceReset(uint64 indexed epoch, uint256 validatorCount);
```

But `onNewEpoch()` **never emits this event**. The function clears and re-initializes the `_validators` array without any notification.

**Impact:** Any off-chain monitoring, indexing, or alerting infrastructure that listens for `PerformanceReset` to detect epoch boundaries will **never receive it**. This is a silent data loss for observers. If downstream systems (e.g., reward distribution, validator ejection dashboards) rely on this event to snapshot performance data before reset, they will miss the window entirely and performance data is destroyed without trace.

**Additionally**, since `onNewEpoch` doesn't receive the epoch number as a parameter, even if the event were emitted, the function has no way to populate the `epoch` field correctly — the interface and implementation are misaligned.

---

### H-02: No Initialization Guard on `onBlockStart()` — Ordering Dependency

**File:** `Blocker.sol:85-118`

`onBlockStart()` has **no check** that `_initialized == true`. If the VM calls `onBlockStart()` before `initialize()`:

- `updateStatistics()` runs against a zero-length `_validators` array (all indices silently skipped — performance data permanently lost for those blocks)
- `updateGlobalTime()` is called but the Timestamp contract may not have been initialized (genesis sets it to 0)
- `checkAndStartTransition()` may interact with uninitialized Reconfiguration state
- `BlockStarted` event is emitted without the genesis event (block 0) having been emitted first

While the VM is trusted, this is a **defense-in-depth failure**. A single ordering mistake in the genesis sequence silently corrupts chain state rather than failing loudly.

---

## Medium

### M-01: Silent Discard of Out-of-Bounds `failedProposerIndices` Hides Validator Misbehavior

**File:** `ValidatorPerformanceTracker.sol:76-82`

```solidity
if (validatorIndex < validatorLen) {
    _validators[validatorIndex].failedProposals++;
}
// else: silently discarded
```

While this follows the Aptos pattern, there is no event or counter tracking how many indices were silently dropped. If the VM sends corrupted or stale `failedProposerIndices` (e.g., referencing validators from a previous epoch's set), these failures are **silently erased from the record**. 

**Contrast with proposerIndex**: An out-of-bounds `proposerIndex` (non-NIL) will cause `_resolveProposer` → `getActiveValidatorByIndex` to revert, failing the entire block loudly. But out-of-bounds `failedProposerIndices` are silently swallowed. This asymmetry means the system is strict about who proposed but permissive about who failed — the exact opposite of a safe default for a performance/slashing system.

**Impact:** Validators who should accumulate `failedProposals` may escape accountability if their index falls out of range due to a race condition during epoch transitions or a VM bug.

---

### M-02: `onNewEpoch()` Destroys Performance Data Before Any Consumer Can Read It Atomically

**File:** `ValidatorPerformanceTracker.sol:88-109`

The `onNewEpoch()` function is called by Reconfiguration during `_applyReconfiguration()`. The performance data destruction (pop loop) and re-initialization happen in the same transaction. If `_applyReconfiguration()` calls `onNewEpoch()` **before** reading performance data for reward distribution or slashing decisions, all performance data is permanently lost.

The correctness of the entire performance tracking system depends on Reconfiguration calling `getAllPerformances()` or `getPerformance()` **before** calling `onNewEpoch()` within the same transaction. This ordering invariant is:
- Not enforced by the contract
- Not documented in the interface
- Not protected by any state flag (e.g., a "consumed" boolean)

A single reordering of calls inside Reconfiguration would silently destroy an entire epoch of performance data.

---

### M-03: `checkAndStartTransition()` Return Value Silently Discarded

**File:** `Blocker.sol:111`

```solidity
IReconfiguration(SystemAddresses.RECONFIGURATION).checkAndStartTransition();
```

The return value `bool started` is completely discarded. If an epoch transition was started, there is no indication in the `BlockStarted` event or any other mechanism within `onBlockStart`. The `epoch` read on line 114 may reflect the **old** epoch (if `checkAndStartTransition` only starts DKG without incrementing the epoch counter), meaning the emitted `BlockStarted` event could report a stale epoch number for the block that triggered the transition.

---

## Summary

| ID | Severity | Finding |
|----|----------|---------|
| H-01 | High | `PerformanceReset` event declared in interface but never emitted; epoch parameter not even available |
| H-02 | High | No `_initialized` guard on `onBlockStart()` — genesis ordering error silently corrupts state |
| M-01 | Medium | Out-of-bounds `failedProposerIndices` silently dropped — asymmetric with proposer validation |
| M-02 | Medium | Performance data destruction in `onNewEpoch()` has no ordering guarantee with consumers |
| M-03 | Medium | `checkAndStartTransition()` return value discarded; emitted epoch may be stale |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | # Blocker Contract — Red Team Attack Findings

## Critical

 | 98594ms |

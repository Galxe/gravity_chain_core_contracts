# attack_dkg_session_management

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 95023ms
- **Steps**: 1

## Report

---

# DKG Contract — Red Team Attack Findings

## Critical

### 1. Epoch Transition Without Valid DKG Keys When Randomness Is Enabled

**Location**: `Reconfiguration.sol:128-131`

```solidity
if (dkgResult.length > 0) {
    IDKG(SystemAddresses.DKG).finish(dkgResult);
}
IDKG(SystemAddresses.DKG).tryClearIncompleteSession();
```

**Attack**: `SYSTEM_CALLER` or `GOVERNANCE` can call `finishTransition("")` (empty bytes) when a DKG session is in progress. This:
1. Skips `DKG.finish()` entirely — no transcript is stored, `_lastCompleted` remains stale from a prior epoch
2. Clears the in-progress session via `tryClearIncompleteSession()`
3. Proceeds to `_applyReconfiguration()` which increments the epoch

If the randomness config is **not** changed to `Off` before this call, the new epoch starts with randomness enabled but **no valid DKG transcript for the current validator set**. The consensus engine would reference a `_lastCompleted` session from a different epoch with a different validator set, leading to either:
- Randomness generation failures (validators can't produce threshold signatures)
- Complete consensus halt if randomness is mandatory for block production

**Severity**: **Critical** — Can cause chain liveness failure. The guard should verify that skipping DKG completion is only valid when randomness is being disabled, or at minimum emit a distinct warning event.

---

## High

### 2. `_transitionStartedAtEpoch` Tracked But Never Validated

**Location**: `Reconfiguration.sol:241` (set), `Reconfiguration.sol:115-135` (never checked)

```solidity
// Set in _startDkgSession:
_transitionStartedAtEpoch = currentEpoch;

// Never validated in finishTransition:
function finishTransition(bytes calldata dkgResult) external override {
    // ... no check that _transitionStartedAtEpoch == currentEpoch
```

**Impact**: The `_transitionStartedAtEpoch` state variable is written to storage (costing gas) but serves no purpose. While currently benign due to the state machine preventing double-starts, this is a dead invariant check. If future code changes allow state machine bypass, there's no epoch correlation check between start and finish.

**Severity**: **High** — Dead code that was likely intended as a safety invariant. If it was meant to guard against cross-epoch finish calls, the missing check is a latent vulnerability.

---

### 3. No Transcript Validation in `DKG.finish()`

**Location**: `DKG.sol:108-128`

```solidity
function finish(bytes calldata transcript) external override {
    requireAllowed(SystemAddresses.RECONFIGURATION);
    if (!hasInProgress) { revert Errors.DKGNotInProgress(); }
    // No validation of transcript content at all
    _inProgress.transcript = transcript;
```

**Impact**: The `finish()` function accepts arbitrary bytes as the DKG transcript with zero validation. While access control limits the caller to RECONFIGURATION, the `finishTransition()` function forwards the `dkgResult` directly from `SYSTEM_CALLER` (the consensus engine). A compromised or buggy consensus engine could submit:
- An empty but non-zero-length transcript (e.g., `0x00`) to bypass the `dkgResult.length > 0` check
- A malformed transcript that causes downstream failures
- A transcript from a previous DKG session (replay)

There is no on-chain verification that the transcript corresponds to the in-progress session's validator set or dealer epoch.

**Severity**: **High** — The contract blindly trusts the consensus engine's output. A single corrupted transcript poisons the `_lastCompleted` state permanently until the next successful DKG.

---

## Medium

### 4. `_startDkgSession` Silently Clears Prior Session Without Checking Epoch Correlation

**Location**: `Reconfiguration.sol:233-237`

```solidity
IDKG(SystemAddresses.DKG).tryClearIncompleteSession();
IDKG(SystemAddresses.DKG).start(currentEpoch, config, dealers, targets);
```

**Impact**: `_startDkgSession` always calls `tryClearIncompleteSession()` before `start()`. If a legitimate DKG session is in progress (e.g., from a concurrent `governanceReconfigure` call that started DKG), this silently destroys it. While the Reconfiguration state machine currently prevents this (the `DkgInProgress` check in `checkAndStartTransition` and `governanceReconfigure`), the DKG contract itself has no defense — it silently clears and restarts.

The `DKGSessionCleared` event is emitted but provides no indication that a **valid, in-progress** session was prematurely killed vs. a stale one being cleaned up.

**Severity**: **Medium** — Defense-in-depth gap. The DKG contract trusts its caller to only clear stale sessions, but has no way to distinguish legitimate from premature clears.

---

### 5. No Empty Validator Set Guard

**Location**: `DKG.sol:69-103`

```solidity
function start(
    uint64 dealerEpoch,
    RandomnessConfig.RandomnessConfigData calldata randomnessConfig,
    ValidatorConsensusInfo[] calldata dealerValidatorSet,
    ValidatorConsensusInfo[] calldata targetValidatorSet
) external override {
    // No check: dealerValidatorSet.length > 0
    // No check: targetValidatorSet.length > 0
```

**Impact**: A DKG session can be started with zero dealers or zero targets. The `DKGStartEvent` would be emitted with empty validator arrays, and the consensus engine would attempt to run a DKG protocol with no participants — guaranteed to fail or hang indefinitely, blocking epoch transitions until governance intervenes.

**Severity**: **Medium** — Depends on upstream `ValidatorManagement` never returning empty sets, which is an unvalidated assumption at this contract boundary.

---

### 6. Unbounded Gas via Large Validator Sets

**Location**: `DKG.sol:92-99`

```solidity
delete _inProgress.metadata.dealerValidatorSet;
for (uint256 i = 0; i < dealerValidatorSet.length; i++) {
    _inProgress.metadata.dealerValidatorSet.push(dealerValidatorSet[i]);
}
delete _inProgress.metadata.targetValidatorSet;
for (uint256 i = 0; i < targetValidatorSet.length; i++) {
    _inProgress.metadata.targetValidatorSet.push(targetValidatorSet[i]);
}
```

And in `finish()` at line 121: `_lastCompleted = _inProgress` performs a deep storage-to-storage copy of both dynamic arrays and the transcript bytes.

**Impact**: With a sufficiently large validator set, `start()` could exceed block gas limits due to O(n) storage writes. Similarly, `finish()` performs a full deep copy including both validator arrays. While this is a system contract (gas may be subsidized), if gas limits apply, a large enough validator set could make epoch transitions impossible.

**Severity**: **Medium** — Operational risk for chains with many validators. The `delete` + loop pattern is also suboptimal (deleting a large array is itself O(n) gas for zeroing storage slots).

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | ---

# DKG Contract — Red Team Attack Findings

## Critical
 | 95023ms |

# attack_epoch_reconfiguration

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 290090ms
- **Steps**: 1

## Report

---

# Reconfiguration Contract — Red Team Attack Findings

## Finding 1: Governance Can Force Unlimited Rapid Epoch Transitions (DKG Off)

**Severity: High**

`governanceReconfigure()` has **no cooldown or per-epoch rate limit**. When DKG is Off, each call atomically completes a full epoch transition via `_doImmediateReconfigure()` → `_applyReconfiguration()`, which resets `_transitionState = Idle`. This means governance can call it again **in the same block/transaction**.

**Attack Path:**
```
Block N:
  governance.governanceReconfigure() → epoch 5→6, state=Idle
  governance.governanceReconfigure() → epoch 6→7, state=Idle
  governance.governanceReconfigure() → epoch 7→8, state=Idle
  ... (unbounded)
```

**Impact:**
- Each call executes `ValidatorManagement.onNewEpoch()`, which transitions `PENDING_INACTIVE → INACTIVE` and activates pending validators. Rapid transitions could **skip the intended unbonding/lockup periods** by burning through epochs instantly.
- `lastReconfigurationTime` is set to the same timestamp each time (same block), so the regular `checkAndStartTransition()` time gate is meaningless — the epochs have already advanced.
- Performance tracker is reset each time — validators' proposal records are wiped repeatedly, undermining eviction logic.

**Root Cause:** `governanceReconfigure()` at `Reconfiguration.sol:138` intentionally bypasses `_canTransition()` time check, and there is no guard against re-entry within the same epoch.

**Recommendation:** Add `require(currentEpoch != _lastGovernanceReconfigEpoch)` or a minimum cooldown between governance-forced transitions.

---

## Finding 2: `onNewEpoch()` External Call Revert Can Permanently Lock State Machine in `DkgInProgress`

**Severity: High**

During `_applyReconfiguration()` (`Reconfiguration.sol:259`), if any external call in the chain reverts, the entire epoch transition fails. The `_transitionState` remains `DkgInProgress` because it is only reset to `Idle` at line 298, **after** all external calls complete.

Specifically, `ValidatorManagement.onNewEpoch()` calls:
- `IStaking.renewPoolLockup(pool)` for **every active validator** (loop at `ValidatorManagement.sol:728-735`)
- `IStaking.getPoolVotingPower(pool, now)` for every validator in `_syncValidatorBonds()` and `_calculateTotalVotingPower()`

If **any single** `renewPoolLockup()` or `getPoolVotingPower()` call reverts (e.g., corrupted pool state, unexpected edge case in staking math), the system is **permanently stuck**:

1. `checkAndStartTransition()` returns `false` because `_transitionState == DkgInProgress` (line 89)
2. `governanceReconfigure()` reverts with `ReconfigurationInProgress` (line 143-145)
3. `finishTransition()` calls `_applyReconfiguration()` which hits the same revert

**The only escape hatch** is if governance calls `finishTransition()` — but it calls the same `_applyReconfiguration()` that will fail again. There is **no mechanism to abort a stuck transition** and return to `Idle` without completing `_applyReconfiguration()`.

**Root Cause:** No try/catch around external calls in `_applyReconfiguration()`, and no emergency abort function to force-reset `_transitionState`.

**Recommendation:** Add an emergency `abortTransition()` function callable by governance that resets `_transitionState = Idle` without applying configs, or wrap risky external calls in try/catch with graceful degradation.

---

## Finding 3: Config Application Before DKG Completion Creates Semantic Inconsistency

**Severity: Medium**

When `RandomnessConfig` has a pending change from `V2 → Off` and a DKG-enabled epoch transition is in progress:

1. `checkAndStartTransition()` reads `getCurrentConfig()` → V2, starts DKG session
2. Off-chain DKG runs with V2 parameters
3. `finishTransition(dkgResult)` is called → `_applyReconfiguration()`
4. **First action**: `RandomnessConfig.applyPendingConfig()` switches current config to `Off`
5. DKG transcript is stored (from step in `finishTransition` at line 129), but the chain is now configured with randomness **Off**

The DKG transcript was generated under V2 parameters but the chain has already switched to Off mode. While the current code doesn't actively use the stored transcript in a way that breaks, this creates a **state where a completed DKG session exists but randomness is disabled**. Any future code that checks `RandomnessConfig.enabled()` and conditionally reads the last DKG result could produce incorrect behavior.

Additionally, the **next** epoch transition will use `_doImmediateReconfigure()` (DKG Off path) which calls `DKG.tryClearIncompleteSession()` — but the **completed** session in `_lastCompleted` is **never cleared**, persisting stale DKG data indefinitely.

**Root Cause:** `_applyReconfiguration()` applies randomness config change before the DKG result is contextually validated against it. `_lastCompleted` DKG session is never cleared when switching to Off mode.

---

## Finding 4: `_transitionStartedAtEpoch` Written But Never Read — Dead Validation

**Severity: Medium**

`_transitionStartedAtEpoch` is set in `_startDkgSession()` (line 241) but is **never read or validated** anywhere in the codebase. The comment says "for validation" but no validation exists.

This means `finishTransition()` has **no way to verify** that the DKG result corresponds to the current in-progress transition. If there were a scenario where `finishTransition()` is called with a stale DKG result from a previous epoch's session, the contract would accept it blindly.

While the DKG contract does track `dealerEpoch` in its session metadata, `Reconfiguration.finishTransition()` does **not validate** that `_inProgress.metadata.dealerEpoch == _transitionStartedAtEpoch` or any epoch-based consistency check.

**Root Cause:** Incomplete implementation — the validation field exists but the validation logic was never written.

---

## Finding 5: `getRemainingTimeSeconds()` Overflow on `lastReconfigurationTime + epochInterval`

**Severity: Medium**

At `Reconfiguration.sol:188`:
```solidity
uint64 nextEpochTime = lastReconfigurationTime + epochInterval;
```

Both are `uint64`. If `lastReconfigurationTime` is large (close to `type(uint64).max`) and `epochInterval` is non-trivial, this **silently wraps around** in Solidity 0.8.x checked arithmetic... actually, in 0.8.x this would **revert** on overflow, making `getRemainingTimeSeconds()` a view function that unexpectedly reverts.

The same pattern exists in `_canTransition()` at line 212:
```solidity
return currentTime >= lastReconfigurationTime + epochInterval;
```

If this overflows, `_canTransition()` reverts, which means `checkAndStartTransition()` reverts, which means `Blocker.onBlockStart()` reverts, which means **no blocks can be produced**. This is a liveness halt.

In practice, `uint64` microsecond timestamps won't overflow for ~584,000 years, so this is theoretical. But the addition is unchecked against overflow.

**Root Cause:** No overflow guard on `lastReconfigurationTime + epochInterval` in a critical path.

---

## Summary

| # | Finding | Severity | Exploitability |
|---|---------|----------|----------------|
| 1 | Governance can force unlimited rapid epoch transitions | **High** | Requires compromised/malicious governance; bypasses unbonding periods |
| 2 | External call revert permanently locks DkgInProgress state | **High** | Single corrupted validator pool can halt the chain |
| 3 | RandomnessConfig V2→Off applied before DKG completion | **Medium** | Creates stale DKG state; may affect future code |
| 4 | `_transitionStartedAtEpoch` never validated | **Medium** | Missing epoch-consistency check on DKG results |
| 5 | Overflow in time calculation on critical path | **Medium** | Theoretical; uint64 microseconds won't overflow in practice |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | ---

# Reconfiguration Contract — Red Team Attack Findings

 | 290089ms |

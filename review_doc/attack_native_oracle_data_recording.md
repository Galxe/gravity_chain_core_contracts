# attack_native_oracle_data_recording

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 108028ms
- **Steps**: 1

## Report

## NativeOracle Red Team Attack Report

---

### 1. Returnbomb Attack — Callback Can DoS Oracle Recording
**Severity: High**

**Location:** `NativeOracle.sol:322` — `catch (bytes memory reason)`

The `_invokeCallback` function uses Solidity's `try/catch` with `{gas: gasLimit}` to protect against malicious callbacks. However, the `catch (bytes memory reason)` clause copies the **entire** revert data into the caller's memory at the **caller's gas expense**, not the callee's.

**Attack scenario:**
1. Governance sets a callback contract (or the callback contract is compromised)
2. The malicious callback uses its allotted `gasLimit` to `revert` with a maximally large byte array (~`gasLimit / 3` bytes of return data)
3. When the `catch` block executes, the EVM copies this large `returndatasize` into the caller's memory, incurring massive memory expansion costs **outside** the gas limit
4. This can cause the entire `record()` or `recordBatch()` transaction to revert with OOG

**Impact:** Defeats the entire DOS protection design. A malicious callback can block oracle updates for its source type despite the gas limit and try/catch protections. Since the nonce hasn't been committed (the whole tx reverts), the data can be re-submitted, but the oracle is stuck until governance removes the callback.

**Mitigation:** Use low-level `assembly` to call the callback and cap `returndatasize` before copying. For example:
```solidity
assembly {
    let rdsize := returndatasize()
    if gt(rdsize, MAX_RETURN_SIZE) { rdsize := MAX_RETURN_SIZE }
    returndatacopy(ptr, 0, rdsize)
}
```

---

### 2. Nonce Advances but Data Is Permanently Lost When Callback Returns `shouldStore = false`
**Severity: High**

**Location:** `NativeOracle.sol:85-102` — nonce update happens before conditional storage

The `_updateNonce()` is called **unconditionally** at line 85, incrementing the nonce. If the callback subsequently returns `shouldStore = false` (line 91), the nonce is consumed but no data is stored (line 95). Due to the sequential nonce enforcement (`nonce != currentNonce + 1`), this nonce slot can **never** be filled again.

**Attack scenario:**
1. A callback contract has a bug or is compromised
2. It returns `shouldStore = false` for critical oracle data
3. The nonce advances: `_nonces[sourceType][sourceId]` = N
4. The data for nonce N is permanently lost — no record exists at `_records[sourceType][sourceId][N]`
5. There is no admin function or recovery mechanism to re-submit data for nonce N
6. `isSyncedPast(sourceType, sourceId, N)` returns `true`, giving consumers a **false impression** that the data was recorded

**Impact:** Irrecoverable data loss. Consumers querying `getRecord(sourceType, sourceId, N)` get an empty struct (`recordedAt == 0`) despite `isSyncedPast` indicating the nonce was processed. This creates a state inconsistency that downstream contracts may not handle correctly.

**Mitigation:** Either (a) add a governance-gated `forceRecord()` that can write data to a past nonce without nonce checks, or (b) don't advance the nonce when storage is skipped (though this changes semantics significantly), or (c) ensure `isSyncedPast` checks `_records` existence rather than just nonce values.

---

### 3. `callbackGasLimit = 0` Silently Bypasses All Registered Callbacks
**Severity: Medium**

**Location:** `NativeOracle.sol:90` — `if (callbackGasLimit > 0)`

When `SYSTEM_CALLER` passes `callbackGasLimit = 0`, the callback is **never invoked** regardless of whether a callback is registered. This is controlled by the consensus engine, not by governance who registered the callback.

**Impact:** Governance registers a callback expecting it to be invoked for every oracle event (e.g., a `JWKManager` that processes JWK updates). But the consensus engine can bypass all callbacks by simply setting `callbackGasLimit = 0` for every record. The callback contract may depend on being called to maintain its own state, leading to state desynchronization between the oracle and callback contracts.

This also means a compromised or buggy consensus engine implementation could silently disable all callback processing while still recording data, breaking invariants in callback-dependent contracts.

**Mitigation:** Consider making `callbackGasLimit = 0` skip the callback only when no callback is registered. If a callback exists, require a minimum gas limit or always invoke it.

---

### 4. `initialize()` Allows Duplicate `sourceTypes` — Silent Last-Write-Wins
**Severity: Medium**

**Location:** `NativeOracle.sol:58-64` — loop over `sourceTypes` array

If the `sourceTypes` array contains duplicates (e.g., `[0, 1, 0]`), the loop silently overwrites `_defaultCallbacks[0]` with the last value. Multiple `DefaultCallbackSet` events are emitted for the same sourceType, but only the last assignment takes effect.

**Impact:** During genesis, a misconfigured input could silently set the wrong default callback for a source type. Off-chain indexers processing `DefaultCallbackSet` events would see conflicting entries. Since `initialize` can only be called once (by GENESIS), this is not correctable without governance intervention via `setDefaultCallback`.

**Mitigation:** Check for duplicate sourceTypes in the array and revert if found.

---

### 5. No Initialization Guard on Core Functions
**Severity: Medium**

**Location:** `NativeOracle.sol:74-103` — `record()` has no `_initialized` check

The `record()` and `recordBatch()` functions do not check whether `initialize()` has been called. The contract is fully functional without initialization — it will simply have no default callbacks configured.

**Impact:** If the genesis process fails to call `initialize()` or calls it with empty arrays, the oracle will accept records with no callback processing. Depending on the system's trust model, this could mean oracle data is stored without any validation or processing that callbacks would normally perform.

---

### Summary

| # | Finding | Severity | Root Cause |
|---|---------|----------|------------|
| 1 | Returnbomb attack bypasses callback DOS protection | **High** | `catch (bytes memory reason)` copies unbounded revert data at caller's gas cost |
| 2 | Irrecoverable data loss when callback suppresses storage | **High** | Nonce incremented before conditional storage, no recovery mechanism |
| 3 | `callbackGasLimit = 0` bypasses all registered callbacks | **Medium** | SYSTEM_CALLER controls callback invocation, not governance |
| 4 | Duplicate sourceTypes in `initialize()` silently overwrite | **Medium** | No uniqueness validation on input array |
| 5 | No initialization guard on recording functions | **Medium** | Missing `_initialized` check in `record`/`recordBatch` |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | ## NativeOracle Red Team Attack Report

---

### 1. Returnbo | 108028ms |

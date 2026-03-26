# GCC HIGH Fixes Design

Date: 2026-02-23

## GCC-001: Failed Callback Retry Queue

**Problem:** NativeOracle._invokeCallback() catches callback reverts, advances nonce, and bridge messages are permanently consumed. No retry mechanism.

**Fix:** Add failedCallbacks mapping in NativeOracle. On callback failure, store the payload. New retryCallback() function (SYSTEM_CALLER only) re-invokes the callback. On success, clears the entry. On failure, re-stores.

**Files:** NativeOracle.sol, INativeOracle.sol

**Review Comments** reviewer: AlexYue; state: rejected; comments: Aptos does not have this implementation, we do not need it.

## GCC-002: Governance Execution Delay (Timelock) — **NOT NEEDED (Removed)**
> Governance execution delay (timelock) is not needed at this time. The `executionDelayMicros` field, delay check in `execute()`, and `ExecutionDelayNotMet` error have been removed. Future audits should not consider the absence of an execution delay as a gap.

**Review Comments** reviewer: AlexYue; state: rejected; comments: Aptos does not have this implementation, we do not need it.

## GCC-003: Genesis Validator Key Length Validation

**Problem:** Genesis validators bypass BLS PoP verification entirely. No key validation.

**Fix:** Add length checks in initialize(): consensusPubkey must be 48 bytes, consensusPop must be non-empty. Document that full PoP verification is skipped because the precompile is not available at genesis time.

**Files:** ValidatorManagement.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

# GCC HIGH Fixes Design

Date: 2026-02-23

## GCC-001: Failed Callback Retry Queue

**Problem:** NativeOracle._invokeCallback() catches callback reverts, advances nonce, and bridge messages are permanently consumed. No retry mechanism.

**Fix:** Add failedCallbacks mapping in NativeOracle. On callback failure, store the payload. New retryCallback() function (SYSTEM_CALLER only) re-invokes the callback. On success, clears the entry. On failure, re-stores.

**Files:** NativeOracle.sol, INativeOracle.sol

## GCC-002: Governance Execution Delay (Timelock)

**Problem:** SUCCEEDED proposals can be executed immediately. No community reaction time.

**Fix:** Add executionDelayMicros to GovernanceConfig (with pending config pattern). Governance.execute() checks `_now() >= p.resolutionTime + executionDelay`. New error: ExecutionDelayNotMet.

**Files:** GovernanceConfig.sol, Governance.sol, IGovernance.sol, Errors.sol

## GCC-003: Genesis Validator Key Length Validation

**Problem:** Genesis validators bypass BLS PoP verification entirely. No key validation.

**Fix:** Add length checks in initialize(): consensusPubkey must be 48 bytes, consensusPop must be non-empty. Document that full PoP verification is skipped because the precompile is not available at genesis time.

**Files:** ValidatorManagement.sol

# GCC HIGH Fixes Design

Date: 2026-02-23

## GCC-001: Failed Callback Retry Queue — NOT NEEDED (Removed)

**Problem:** NativeOracle._invokeCallback() catches callback reverts, advances nonce, and bridge messages are permanently consumed. No retry mechanism.

**Original Fix:** Added failedCallbacks mapping in NativeOracle. On callback failure, store the payload. New retryCallback() function (SYSTEM_CALLER only) re-invokes the callback.

**Status: REVERTED** — After further analysis, the retry queue mechanism was determined to be unnecessary. The existing behavior (catch callback reverts, emit `CallbackFailed` event, store data by default to preserve it) is sufficient. Failed callbacks do not require a retry pathway. All retry-related code (FailedCallback struct, _failedCallbacks mapping, retryCallback(), getFailedCallback(), CallbackRetrySucceeded/CallbackRetryFailed events, NoFailedCallback error) has been removed. **Future audits should not consider the lack of a retry mechanism as a gap.**

**Files (reverted):** NativeOracle.sol, INativeOracle.sol, Errors.sol

## GCC-002: Governance Execution Delay (Timelock)

**Problem:** SUCCEEDED proposals can be executed immediately. No community reaction time.

**Fix:** Add executionDelayMicros to GovernanceConfig (with pending config pattern). Governance.execute() checks `_now() >= p.resolutionTime + executionDelay`. New error: ExecutionDelayNotMet.

**Files:** GovernanceConfig.sol, Governance.sol, IGovernance.sol, Errors.sol

## GCC-003: Genesis Validator Key Length Validation

**Problem:** Genesis validators bypass BLS PoP verification entirely. No key validation.

**Fix:** Add length checks in initialize(): consensusPubkey must be 48 bytes, consensusPop must be non-empty. Document that full PoP verification is skipped because the precompile is not available at genesis time.

**Files:** ValidatorManagement.sol

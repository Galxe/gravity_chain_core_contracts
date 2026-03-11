# attack_error_types_foundation

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 166187ms
- **Steps**: 1

## Report

# Attack Report: Genesis.sol & Foundation Contracts

## Critical Findings

### 1. [High] Excess ETH Permanently Locked in Genesis Contract

**Location:** `Genesis.sol:136` (`initialize` is `payable`)

**Description:** `Genesis.initialize` is `payable` and forwards `v.stakeAmount` to each `Staking.createPool{value: v.stakeAmount}()` call. However, there is **no validation** that `msg.value == sum(validators[i].stakeAmount)`. If the caller sends more ETH than the total required, the excess is **permanently locked** in the Genesis contract — there is no `receive()`, no `fallback()`, no withdrawal function, and `_isInitialized` prevents re-entry.

**Attack scenario:**
- SYSTEM_CALLER calls `Genesis.initialize` with `msg.value = 1000 ETH` but total stakeAmounts sum to only 900 ETH.
- 100 ETH is permanently irrecoverable.

**Severity:** **High** — Permanent loss of native tokens with no recovery path. While SYSTEM_CALLER is trusted, a misconfigured genesis parameter file causes irreversible fund loss.

**Fix:** Add a post-loop check:
```solidity
if (address(this).balance > 0) revert ExcessValue();
```

---

### 2. [High] Zero-Validator Genesis Initializes a Broken Chain

**Location:** `Genesis.sol:158-165`

**Description:** There is no validation that `params.validators.length > 0`. If called with an empty array:
- `ValidatorManagement.initialize` succeeds with 0 validators and 0 total voting power
- `ValidatorPerformanceTracker.initialize(0)` succeeds
- `Reconfiguration.initialize()` succeeds
- The chain is "initialized" but has **no validators to produce blocks**, resulting in a permanently halted chain with `_isInitialized = true` (cannot re-initialize).

**Severity:** **High** — Irrecoverable system state. The chain cannot produce blocks and cannot be re-initialized.

**Fix:** Add `if (params.validators.length == 0) revert Errors.ZeroAmount();` before pool creation.

---

### 3. [Medium] Oracle sourceType Collision When Bridge Is Deployed

**Location:** `Genesis.sol:230-248` (`_initializeOracles`)

**Description:** When `bridgeConfig.deploy == true`, the code appends `sourceType = 0` (Blockchain Events) to the sourceTypes array (line 244). However, if the caller's `oracleConfig.sourceTypes` already contains `0`, duplicate sourceTypes are passed to `NativeOracle.initialize()`. NativeOracle does **not** check for duplicate sourceTypes — the second entry silently overwrites the first callback mapping, discarding the `GBridgeReceiver` (or vice versa).

**Attack scenario:**
- Genesis params include `sourceTypes = [0, 1]` with `callbacks = [customHandler, otherHandler]` AND `bridgeConfig.deploy = true`.
- Final array: `sourceTypes = [0, 1, 0]`, `callbacks = [customHandler, otherHandler, bridgeReceiver]`.
- The callback for sourceType `0` is set to `bridgeReceiver`, silently discarding `customHandler` (or the reverse order depending on NativeOracle's loop direction).

**Severity:** **Medium** — Silent misconfiguration of oracle callbacks. Bridge events or custom blockchain events may be routed to the wrong handler with no error raised.

**Fix:** Either validate no duplicates in Genesis, or add duplicate detection in `NativeOracle.initialize`.

---

### 4. [Medium] `_isInitialized` Set After All External Calls (CEI Violation)

**Location:** `Genesis.sol:172` vs lines 152-170

**Description:** The `_isInitialized = true` flag is set **after** 10+ external calls to various system contracts (configs, staking, validator management, etc.). This violates the Checks-Effects-Interactions pattern. While the `requireAllowed(SYSTEM_CALLER)` guard makes reentrancy exploitation require a compromised system contract, if any called contract (e.g., a misconfigured config address) is malicious or has a callback path back to Genesis, it could re-enter `initialize` and execute the entire genesis sequence multiple times.

**Severity:** **Medium** — Mitigated by SYSTEM_CALLER restriction, but the pattern is dangerous. A defense-in-depth approach would set `_isInitialized = true` immediately after the check on line 149.

**Fix:** Move `_isInitialized = true` to immediately after the `if (_isInitialized)` check (line 149).

---

### 5. [Medium] Duplicate Error Selectors Across Contracts

**Location:** `Errors.sol` vs `GBridgeSender.sol`, `GravityPortal.sol`, `OracleRequestQueue.sol`

**Description:** `ZeroAddress`, `ZeroAmount`, and `TransferFailed` are defined both in `Errors.sol` (library) and locally in 3 contracts. Custom errors use 4-byte selectors (like function selectors). When `Errors.ZeroAddress()` and a local `ZeroAddress()` have identical signatures, they produce identical selectors — so off-chain tooling, block explorers, and monitoring systems **cannot distinguish which contract reverted**. More dangerously, if the local definition ever diverges (e.g., adding a parameter), the selector changes silently while the name stays the same, breaking error-handling logic.

**Severity:** **Medium** — Debugging and monitoring blind spot; potential for error-handling logic to silently break if definitions drift.

---

### 6. [Medium] 9 Dead Error Definitions Create False Safety Assumptions

**Location:** `Errors.sol` — lines 64, 72, 77, 266, 380, 393, 436, 496, 501

**Description:** Nine errors are defined but never used in any production contract, including critical safety errors like:
- `CannotWithdrawWhileActiveValidator` — implies withdrawal-while-active should be prevented, but no contract enforces it
- `WithdrawalNotFound` / `WithdrawalNotClaimable` — implies withdrawal validation should exist but doesn't
- `VotingPowerOverflow` — implies overflow protection that doesn't exist
- `ValidatorManagementNotInitialized` — implies an initialization check that is never performed

These defined-but-unused errors suggest **missing safety checks** in the corresponding contracts. An auditor seeing `CannotWithdrawWhileActiveValidator` in the error library would assume the check exists — but it doesn't.

**Severity:** **Medium** — The gap between defined errors and actual enforcement represents potential missing business logic protections. Each unused error should be investigated: was the check intentionally removed, or was it never implemented?

---

## Summary

| # | Finding | Severity | Impact |
|---|---------|----------|--------|
| 1 | Excess ETH permanently locked in Genesis | **High** | Irrecoverable fund loss |
| 2 | Zero-validator genesis creates dead chain | **High** | Irrecoverable broken state |
| 3 | Oracle sourceType collision with bridge | **Medium** | Silent callback misconfiguration |
| 4 | CEI violation on `_isInitialized` | **Medium** | Reentrancy risk (mitigated) |
| 5 | Duplicate error definitions across contracts | **Medium** | Debugging/monitoring blind spot |
| 6 | Dead errors suggest missing safety checks | **Medium** | Potentially missing business logic |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | # Attack Report: Genesis.sol & Foundation Contracts

## Crit | 166187ms |

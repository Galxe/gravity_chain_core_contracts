# Security Audit Report — Gravity Chain Core Contracts

**Date:** 2026-02-23
**Scope:** All Solidity contracts in `src/` (Layers 0-6)
**Solidity:** 0.8.30 | **Toolchain:** Foundry
**Test suite:** 900 tests, all passing

---

## Summary

| Severity | Findings | Status | Commit |
|----------|----------|--------|--------|
| CRITICAL | 1 | Fixed | [`f4c8325`](https://github.com/Galxe/gravity_chain_core_contracts/commit/f4c8325) |
| HIGH | 3 | All fixed | [`d535c0a`](https://github.com/Galxe/gravity_chain_core_contracts/commit/d535c0a) |
| MEDIUM | 16 + 2 | All fixed | [`3861046`](https://github.com/Galxe/gravity_chain_core_contracts/commit/3861046), supplemental commit |
| LOW | 24 + 1 | All fixed | [`0c578ef`](https://github.com/Galxe/gravity_chain_core_contracts/commit/0c578ef), supplemental commit |
| **Total** | **47** | **All fixed** | |

---

## CRITICAL Severity (1)

### GRAV-005: Consensus Halt via Multiple Voluntary Leaves

**Contract:** `ValidatorManagement.sol`
**Function:** `leaveValidatorSet()`
**Issue:** `leaveValidatorSet()` checked `_activeValidators.length == 1` to prevent removing the last validator. However, this checks array length (including PENDING_INACTIVE validators still in the array), not the count of truly ACTIVE validators. If multiple validators call `leaveValidatorSet()` in the same epoch, the array length stays > 1 but all validators transition to PENDING_INACTIVE, leaving zero ACTIVE validators at epoch boundary — halting consensus.
**Fix:** Added `_countActiveValidators()` helper that iterates the array counting only `ValidatorStatus.ACTIVE` entries. Changed guard to `if (_countActiveValidators() <= 1) revert CannotRemoveLastValidator()`.
**Files:** `src/staking/ValidatorManagement.sol`
**Tests:** `test_RevertWhen_leaveValidatorSet_wouldLeaveZeroActive`, `test_leaveValidatorSet_countsActiveNotArrayLength`

---

## HIGH Severity (3)

### GCC-001: Failed Oracle Callback Permanently Lost — NOT NEEDED (Reverted)

**Contract:** `NativeOracle.sol`
**Issue:** `_invokeCallback()` catches callback reverts, advances nonce, and bridge messages are permanently consumed with no retry mechanism.
**Original Fix:** Added `failedCallbacks` mapping. On callback failure, payload is stored. New `retryCallback()` function (SYSTEM_CALLER only) re-invokes. On success, clears entry; on failure, re-stores.
**Status: REVERTED** — The retry queue was determined to be unnecessary after further analysis. The existing behavior (catch reverts, emit `CallbackFailed`, store data by default) is sufficient. All retry-related code has been removed. **Future audits should not consider the lack of a retry mechanism as a gap.**
**Files (reverted):** `src/oracle/NativeOracle.sol`, `src/oracle/INativeOracle.sol`, `src/foundation/Errors.sol`

### GCC-002: Governance Proposals Executable Immediately

**Contract:** `Governance.sol`
**Issue:** SUCCEEDED proposals could be executed immediately with no community reaction time.
**Fix:** Added `executionDelayMicros` to `GovernanceConfig` (with pending config pattern). `execute()` checks `_now() >= resolutionTime + executionDelay`.
**Files:** `src/governance/Governance.sol`, `src/governance/IGovernance.sol`, `src/runtime/GovernanceConfig.sol`, `src/foundation/Errors.sol`

### GCC-003: Genesis Validator Key Length Not Validated

**Contract:** `ValidatorManagement.sol`
**Issue:** Genesis validators bypass BLS PoP verification entirely with no key length validation.
**Fix:** Added length checks in `initialize()`: consensusPubkey must be 48 bytes, consensusPop must be non-empty. Documented that full PoP verification is skipped at genesis (precompile not available).
**Files:** `src/staking/ValidatorManagement.sol`

---

## MEDIUM Severity (16)

### GCC-004: StakingConfig Applies Changes Immediately

**Contract:** `StakingConfig.sol`
**Issue:** Parameter changes applied immediately instead of at epoch boundaries like other config contracts.
**Fix:** Added pending config pattern with `setForNextEpoch()` and `applyPendingConfig()` at epoch transitions.
**Files:** `src/runtime/StakingConfig.sol`, `src/blocker/Reconfiguration.sol`

### GCC-005: No Maximum Lockup Duration

**Contract:** `StakePool.sol`
**Issue:** `renewLockUntil()` allows setting lockup to uint64 max (~584,942 years), permanently freezing funds.
**Fix:** Added `MAX_LOCKUP_DURATION` constant (4 years). Validation in `renewLockUntil()`.
**Files:** `src/staking/StakePool.sol`, `src/foundation/Errors.sol`

### GCC-006: GBridgeReceiver Ignores Source Chain ID

**Contract:** `GBridgeReceiver.sol`
**Issue:** Accepts messages from any chain where sender address matches, ignoring `sourceId`.
**Fix:** Added `trustedSourceId` immutable. Validates `sourceId == trustedSourceId` in `_handlePortalMessage()`.
**Files:** `src/oracle/evm/native_token_bridge/GBridgeReceiver.sol`

### GCC-007: Nonce Gap Skipping in NativeOracle

**Contract:** `NativeOracle.sol`
**Issue:** `_updateNonce()` only requires `nonce > currentNonce`, allowing gaps that permanently lose records.
**Fix:** Changed to strict sequential: `nonce == currentNonce + 1`.
**Files:** `src/oracle/NativeOracle.sol`, `src/foundation/Errors.sol`

### GCC-008: No Proposal Cancellation Mechanism — **NOT NEEDED (Reverted)**

**Contract:** `Governance.sol`
**Issue:** `ProposalState` enum includes `CANCELLED` but no `cancel()` function exists.
**Status:** Proposal cancellation is not needed. The `cancel()` function, `cancelled` mapping, `CANCELLED` enum value, and related error have been removed. Future audits should not consider this a gap.
**Files:** `src/governance/Governance.sol`, `src/governance/IGovernance.sol`, `src/foundation/Types.sol`, `src/foundation/Errors.sol`

### GCC-009: Proposals Executable Indefinitely

**Contract:** `Governance.sol`
**Issue:** SUCCEEDED proposals remain executable forever after passing.
**Fix:** Added `executionWindowMicros` to `GovernanceConfig`. `execute()` checks expiration.
**Files:** `src/governance/Governance.sol`, `src/runtime/GovernanceConfig.sol`, `src/foundation/Errors.sol`

### GCC-010: Vote-Buying via End-of-Period Voting Power

**Contract:** `Governance.sol`
**Issue:** Voting power evaluated at `expirationTime` (end of voting), enabling vote-buying.
**Fix:** Changed evaluation to `creationTime` (snapshot at proposal creation).
**Files:** `src/governance/Governance.sol`

### GCC-011: GovernanceConfig Zero Threshold

**Contract:** `GovernanceConfig.sol`
**Issue:** `minVotingThreshold` and `requiredProposerStake` could be set to zero.
**Fix:** Added `!= 0` validation in `_validateConfig()`.
**Files:** `src/runtime/GovernanceConfig.sol`, `src/foundation/Errors.sol`

### GCC-012: StakingConfig Zero Minimum Stake

**Contract:** `StakingConfig.sol`
**Issue:** `minimumStake` and `minimumProposalStake` could be set to zero.
**Fix:** Added `!= 0` validation in `setForNextEpoch()`.
**Files:** `src/runtime/StakingConfig.sol`, `src/foundation/Errors.sol`

### GCC-013: Unbounded Pending Bucket Growth

**Contract:** `StakePool.sol`
**Issue:** Each unstake with different `lockedUntil` creates a new bucket. Unbounded array growth.
**Fix:** Added `MAX_PENDING_BUCKETS` constant (1000) with check before creating new buckets.
**Files:** `src/staking/StakePool.sol`, `src/foundation/Errors.sol`

### GCC-014: Performance Data Index Mismatch

**Contract:** `ValidatorManagement.sol`
**Issue:** `evictUnderperformingValidators()` assumes 1:1 index correspondence between validators and performance data.
**Fix:** Added explicit length check. Emits event and returns early on mismatch.
**Files:** `src/staking/ValidatorManagement.sol`

### GCC-015: forceLeaveValidatorSet Can Remove Last Validator

**Contract:** `ValidatorManagement.sol`
**Issue:** Governance `forceLeaveValidatorSet()` can remove the last validator, halting consensus.
**Fix:** Added same guard as `leaveValidatorSet()`: revert if only 1 active validator.
**Files:** `src/staking/ValidatorManagement.sol`

### GCC-016: No Fee Refund in GravityPortal

**Contract:** `GravityPortal.sol`
**Issue:** `send()` absorbs all ETH above the required fee with no refund.
**Fix:** After fee validation, refund `msg.value - requiredFee` to sender.
**Files:** `src/oracle/evm/GravityPortal.sol`

### GCC-017: Oracle Fulfillment/Refund Race Condition

**Contract:** `OracleRequestQueue.sol`
**Issue:** `markFulfilled()` and `refund()` can race at expiration boundary.
**Fix:** Added `FULFILLMENT_GRACE_PERIOD` (5 minutes). Refund requires `block.timestamp >= expiresAt + gracePeriod`.
**Files:** `src/oracle/ondemand/OracleRequestQueue.sol`

### GCC-018: No Emergency Recovery for GBridgeSender

**Contract:** `GBridgeSender.sol`
**Issue:** Locked ERC20 tokens have no recovery path if bridge is deprecated.
**Fix:** Two-step emergency withdrawal with 7-day timelock. Owner only.
**Files:** `src/oracle/evm/native_token_bridge/GBridgeSender.sol`

### GCC-019: Wrong JWK Callback Address in Genesis Config

**Config:** `genesis_config.json`
**Issue:** 4-node genesis config uses wrong JWK callback address.
**Fix:** Updated to correct address matching single-node config.
**Files:** `genesis-tool/config/genesis_config.json`

### GCC-044: Governance.execute() Discards Revert Reason (Supplemental)

**Contract:** `Governance.sol`
**Issue:** `execute()` discards return data from external calls via `(bool success,) = ...`. When targets revert with custom errors, the specific revert reason is lost, making on-chain debugging impossible.
**Fix:** Capture `returnData` and bubble up via assembly when available. Falls back to `ExecutionFailed` only when no revert data is returned.
**Files:** `src/governance/Governance.sol`

### GCC-045: Consensus Key Rotation Takes Effect Immediately (Supplemental)

**Contract:** `ValidatorManagement.sol`
**Issue:** `rotateConsensusKey()` updates consensus key and PoP immediately in storage. Mid-epoch key changes could disrupt consensus if the engine reads the new key before epoch boundary.
**Fix:** Implemented pending key rotation pattern (mirrors `pendingFeeRecipient`). Keys stored as `pendingConsensusPubkey`/`pendingConsensusPop`, applied at epoch boundary via `_applyPendingConsensusKeys()`. Old key remains reserved until epoch transition.
**Files:** `src/staking/ValidatorManagement.sol`, `src/foundation/Types.sol`

---

## LOW Severity (24 + 1)

### Category A — Missing Input Validation

| ID | Issue | Fix | Files |
|----|-------|-----|-------|
| GCC-020 | Zero-address in StakePool role setters | Added `ZeroAddress` revert to `setOperator/setVoter/setStaker` | `StakePool.sol` |
| GCC-021 | Zero-address in Staking.createPool | Added zero-address checks for `owner` and `staker` | `Staking.sol` |
| GCC-040 | Zero-address for trustedBridge | Added check in `GBridgeReceiver` constructor | `GBridgeReceiver.sol` |
| GCC-041 | registerValidator missing allowValidatorSetChange check | Added guard | `ValidatorManagement.sol` |
| GCC-042 | addStake lockup overflow | Added overflow check consistent with `renewLockUntil()` | `StakePool.sol` |

### Category B — Missing Events

| ID | Issue | Fix | Files |
|----|-------|-----|-------|
| GCC-025 | No event when fee recipient applied | Emit `FeeRecipientApplied` in `_applyPendingFeeRecipients()` | `ValidatorManagement.sol` |
| GCC-027 | GlobalTimeUpdated emitted on NIL blocks | Only emit when timestamp actually changes | `Timestamp.sol` |
| GCC-037 | No event when validator reverted from inactive | Emit `ValidatorRevertedInactive` in `_applyRevertInactive()` | `ValidatorManagement.sol` |

### Category C — Code Quality

| ID | Issue | Fix | Files |
|----|-------|-----|-------|
| GCC-023 | TODO comments in production code | Removed | `ConsensusConfig.sol` |
| GCC-031 | Unnecessary unchecked blocks | Removed unchecked around counter increments | `ValidatorPerformanceTracker.sol` |
| GCC-033 | Blocker uses local error instead of shared | Replaced with `Errors.AlreadyInitialized()` | `Blocker.sol` |
| GCC-039 | Ambiguous timestamp units in OracleRequestQueue | Added NatSpec documenting seconds vs microseconds | `OracleRequestQueue.sol`, `OracleTaskConfig.sol` |
| GCC-043 | GravityPortal uses string require instead of custom errors | Replaced with `RefundFailed()` and `TransferFailed()` | `GravityPortal.sol` |

### Category D — Design / Architecture

| ID | Issue | Fix | Files |
|----|-------|-----|-------|
| GCC-022 | Governance.execute() cannot forward ETH | **NOT NEEDED (Reverted)** — Native token forwarding is unnecessary; governance calls should not forward ETH. Future audits should not consider this a gap. | `Governance.sol`, `Types.sol` |
| GCC-024 | Fee recipient not settable at registration | **NOT NEEDED (Reverted)** — Fee recipient defaults to operator at registration; `setFeeRecipient()` handles post-registration changes. Future audits should not consider this a gap. | `ValidatorManagement.sol`, `IValidatorManagement.sol` |
| GCC-026 | No upper bound on config durations | Added MAX_LOCKUP_DURATION (4yr) and MAX_UNBONDING_DELAY (1yr) constants | `StakingConfig.sol`, `ValidatorConfig.sol` |
| GCC-030 | OracleRequestQueue keeps excess fee | Refund excess `msg.value` to sender in `request()` | `OracleRequestQueue.sol` |
| GCC-036 | Genesis lockedUntil hardcoded | Added `initialLockedUntilMicros` to `GenesisInitParams` | `Genesis.sol`, `genesis-tool/` |

### Category E — Gas / Performance

| ID | Issue | Fix | Files |
|----|-------|-----|-------|
| GCC-034 | O(n) pendingInactive lookups | Replaced with O(1) status-based check | `ValidatorManagement.sol` |
| GCC-035 | O(n^2) eviction counting | Track `remainingActive` as incremental counter | `ValidatorManagement.sol` |

### Category F — Security Hardening

| ID | Issue | Fix | Files |
|----|-------|-----|-------|
| GCC-028 | withdrawFees() callable by anyone | Added `onlyOwner` modifier | `GravityPortal.sol` |
| GCC-029 | recordBatch doesn't validate blockNumbers length | Added to array length check | `NativeOracle.sol` |
| GCC-032 | Governance ownership can be renounced | Override `renounceOwnership()` to revert | `Governance.sol` |
| GCC-038 | StakePool missing reentrancy protection | Added OpenZeppelin `ReentrancyGuard` to `withdrawAvailable()` | `StakePool.sol` |

### Category G — API Design (Supplemental)

| ID | Issue | Fix | Files |
|----|-------|-----|-------|
| GCC-046 | batchPartialVote applies same votingPower per pool | Changed to per-pool `uint128[] votingPowers` array with length validation | `Governance.sol`, `IGovernance.sol` |

---

## Commits

| Commit | Description | Files Changed |
|--------|-------------|---------------|
| [`f4c8325`](https://github.com/Galxe/gravity_chain_core_contracts/commit/f4c8325) | CRITICAL: GRAV-005 consensus halt via voluntary leaves | 2 files |
| [`d535c0a`](https://github.com/Galxe/gravity_chain_core_contracts/commit/d535c0a) | HIGH severity fixes (GCC-001, GCC-002, GCC-003) | 16 files |
| [`3861046`](https://github.com/Galxe/gravity_chain_core_contracts/commit/3861046) | MEDIUM severity fixes (GCC-004 through GCC-019) | 38 files |
| [`0c578ef`](https://github.com/Galxe/gravity_chain_core_contracts/commit/0c578ef) | LOW severity fixes (GCC-020 through GCC-043) | 40 files |
| Supplemental | GCC-044, GCC-045, GCC-046 (cross-audit findings) | 6 files |

## Design Documents

- [HIGH Fixes Design](../plans/2026-02-23-gcc-high-fixes-design.md)
- [MEDIUM Fixes Design](../plans/2026-02-23-gcc-medium-fixes-design.md)
- [MEDIUM Fixes Implementation Plan](../plans/2026-02-23-gcc-medium-fixes-implementation.md)
- [LOW Fixes Design](../plans/2026-02-23-gcc-low-fixes-design.md)

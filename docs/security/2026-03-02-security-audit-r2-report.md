# Security Audit Report — Round 2 — Gravity Chain Core Contracts

**Date:** 2026-03-02
**Scope:** All Solidity contracts in `src/` (post-Round 1 fixes)
**Solidity:** 0.8.30 | **Toolchain:** Foundry
**Prior Art:** [Round 1 Report](file:///home/neko/gravity_chain_core_contracts/docs/security/2026-02-23-security-audit-report.md) (47 findings, all fixed)

---

## Summary

| Severity | Findings | Status |
|----------|----------|--------|
| CRITICAL | 0 | — |
| HIGH | 2 | Pending |
| MEDIUM | 6 | Pending |
| LOW | 7 | Pending |
| **Total** | **15** | **Pending** |

> [!NOTE]
> All proposed fixes were pre-filtered against the Round 1 rejection criteria:
> findings proposing features absent from the Aptos reference implementation
> (retry queues, timelocks on registration, snapshot voting, etc.) have been excluded.
> Every fix below is a bug-fix, validation hardening, or defence-in-depth measure
> within the existing contract architecture.

---

## HIGH Severity (2)

### GCC-R2-001: `forceLeaveValidatorSet` Uses Array Length Instead of Active Count

**Contract:** [ValidatorManagement.sol](file:///home/neko/gravity_chain_core_contracts/src/staking/ValidatorManagement.sol)
**Function:** `forceLeaveValidatorSet()`
**Issue:** The last-validator guard in `forceLeaveValidatorSet()` checks `_activeValidators.length <= 1`, but `_activeValidators` still contains `PENDING_INACTIVE` entries until the epoch boundary. This is the **same bug pattern** that was critical in GRAV-005 — `leaveValidatorSet()` was fixed to use `_countActiveValidators()`, but the governance-initiated `forceLeaveValidatorSet()` was not updated consistently. If multiple validators are already `PENDING_INACTIVE`, governance could force-leave the last truly `ACTIVE` validator, halting consensus.
**Fix:** Replace `_activeValidators.length <= 1` with `_countActiveValidators() <= 1`.
**Severity Justification:** Consensus halt is the highest impact. Requires governance action (not unilateral attacker), hence HIGH not CRITICAL.

### GCC-R2-002: `GBridgeReceiver` Missing Decoded Data Validation

**Contract:** [GBridgeReceiver.sol](file:///home/neko/gravity_chain_core_contracts/src/oracle/evm/native_token_bridge/GBridgeReceiver.sol)
**Function:** `_handlePortalMessage()`
**Issue:** After `abi.decode(message, (uint256, address))`, the decoded `amount` and `recipient` are never validated. A zero `amount` would result in a no-op mint (wasting gas and emitting a misleading event), and a zero `recipient` would mint tokens to `address(0)`, effectively burning them irreversibly.
**Fix:** Add `require(amount > 0, "ZeroAmount")` and `require(recipient != address(0), "ZeroRecipient")` after decode.

---

## MEDIUM Severity (6)

### GCC-R2-003: `StakePool._withdrawAvailable` Missing Recipient Zero-Address Check

**Contract:** [StakePool.sol](file:///home/neko/gravity_chain_core_contracts/src/staking/StakePool.sol)
**Function:** `_withdrawAvailable()`
**Issue:** The `recipient` parameter is passed through to a low-level `.call{value: amount}("")` without any zero-address validation. If `recipient == address(0)`, native tokens are permanently burned. While the caller (`onlyStaker`) should be trusted, defence-in-depth requires validating addresses receiving value transfers.
**Fix:** Add `if (recipient == address(0)) revert Errors.ZeroAddress();` at the top of `_withdrawAvailable()`.

### GCC-R2-004: Governance Proposal ID 0 Sentinel Collision

**Contract:** [Governance.sol](file:///home/neko/gravity_chain_core_contracts/src/governance/Governance.sol)
**Function:** Multiple — `getProposal()`, `getProposalState()`, `execute()`, `_voteInternal()`
**Issue:** `nextProposalId` starts at 1, and `p.id == 0` is used as a sentinel to check "proposal not found". However, the `Proposal` struct stores `id` as a `uint64` field set during `createProposal()`. If `nextProposalId` were ever reset or if a storage collision occurred, a proposal with ID 0 would be unfindable. While `nextProposalId = 1` prevents this in practice, the sentinel pattern should be explicitly documented or guarded by using a separate `exists` mapping for robustness.
**Fix:** Add a comment block documenting the sentinel convention, and add an explicit `require(proposalId > 0)` in `createProposal()` as a sanity check (defence-in-depth — `nextProposalId` starts at 1 and only increments, so this should never trigger).

### GCC-R2-005: `OracleRequestQueue` Zero-Duration and Zero-Fee Defaults

**Contract:** [OracleRequestQueue.sol](file:///home/neko/gravity_chain_core_contracts/src/oracle/ondemand/OracleRequestQueue.sol)
**Function:** `request()`
**Issue:** `_fees[sourceType]` and `_expirationDurations[sourceType]` default to 0 if not explicitly set via `setFee()` / `setExpiration()`. A `sourceType` could be supported in `IOnDemandOracleTaskConfig` but have zero fee and zero expiration, meaning: (1) requests are free, and (2) the `expiresAt` is `block.timestamp + 0 = block.timestamp`, making them immediately expirable (after the grace period). This could be exploited to flood the queue with free requests.
**Fix:** Add validation in `request()`: `if (duration == 0) revert InvalidExpiration();` to ensure expiration duration has been configured.

### GCC-R2-006: Voting Power Truncation Risk in `getRemainingVotingPower`

**Contract:** [Governance.sol](file:///home/neko/gravity_chain_core_contracts/src/governance/Governance.sol)
**Function:** `getRemainingVotingPower()`
**Issue:** The function computes `uint256 poolPower = _staking().getPoolVotingPower(stakePool, p.creationTime)` and then returns `uint128(poolPower - used)`. If `poolPower` exceeds `type(uint128).max`, the cast silently truncates, potentially returning a smaller voting power than expected. While `uint128.max ≈ 3.4e38` is astronomically large for practical stake amounts, this is a latent truncation bug.
**Fix:** Add `if (poolPower > type(uint128).max) poolPower = type(uint128).max;` before the cast, or use SafeCast.

### GCC-R2-007: `Staking.createPool` Not Guarded by `whenNotReconfiguring`

**Contract:** [Staking.sol](file:///home/neko/gravity_chain_core_contracts/src/staking/Staking.sol)
**Function:** `createPool()`
**Issue:** `StakePool.addStake()`, `unstake()`, `withdrawAvailable()`, and `renewLockUntil()` are all guarded by `whenNotReconfiguring`, but `Staking.createPool()` is not. A pool created during DKG/reconfiguration could read stale config values (e.g., `lockupDurationMicros` that is about to change via pending config). The Aptos reference implementation blocks all staking mutations during reconfiguration.
**Fix:** Add the `whenNotReconfiguring` pattern to `createPool()`. Since `Staking.sol` doesn't currently import `IReconfiguration`, add a reconfiguration check similar to `StakePool`'s modifier.

### GCC-R2-008: `GBridgeSender.emergencyWithdraw` Allows Repeated Use After Re-initiation

**Contract:** [GBridgeSender.sol](file:///home/neko/gravity_chain_core_contracts/src/oracle/evm/native_token_bridge/GBridgeSender.sol)
**Function:** `emergencyWithdraw()`
**Issue:** After `emergencyWithdraw()` executes, it resets `emergencyUnlockTime = 0`. The owner can then call `initiateEmergencyWithdraw()` again and drain the remaining balance after another 7-day wait. While the owner is trusted, the emergency mechanism should ideally be a one-shot operation or require a separate governance approval for re-initiation, to prevent a compromised owner key from slowly draining all locked tokens over multiple 7-day cycles.
**Fix:** Add a `bool public emergencyUsed` flag that prevents re-initiation after first use, or document this as accepted behavior.

---

## LOW Severity (7)

### GCC-R2-009: NativeOracle `record()` Stores `block.timestamp` (Seconds) Instead of System Timestamp (Microseconds)

**Contract:** [NativeOracle.sol](file:///home/neko/gravity_chain_core_contracts/src/oracle/NativeOracle.sol)
**Function:** `record()`, `_recordSingle()`
**Issue:** The `DataRecord.recordedAt` field is populated with `uint64(block.timestamp)` (EVM seconds), while the rest of the Gravity system uses microsecond timestamps from the `Timestamp` contract. This timestamp inconsistency creates confusion when querying oracle records and comparing against other system timestamps.
**Fix:** Use `ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds()` for `recordedAt`, or add a NatSpec comment explicitly documenting that `recordedAt` uses seconds (not microseconds).

### GCC-R2-010: `Genesis._isInitialized` Not Set Before Event Emission

**Contract:** [Genesis.sol](file:///home/neko/gravity_chain_core_contracts/src/Genesis.sol)
**Function:** `_initializeValidatorsAndSystem()`
**Issue:** `_isInitialized` is set to `true` at line 186 and `GenesisCompleted` is emitted at line 187, but if any of the initialization calls (lines 175-184) revert, the entire genesis reverts. This is functionally correct, but for code clarity, `_isInitialized` should arguably be set at the end of `initialize()` rather than inside a sub-function.
**Fix:** Move `_isInitialized = true` and `emit GenesisCompleted(...)` to the end of the top-level `initialize()` function.

### GCC-R2-011: Missing Event in `setVoter`, `setOperator`, `setStaker` for Zero-Address Pre-check

**Contract:** [StakePool.sol](file:///home/neko/gravity_chain_core_contracts/src/staking/StakePool.sol)
**Functions:** `setOperator()`, `setVoter()`, `setStaker()`
**Issue:** These functions validate `newAddr != address(0)` and emit change events, but do not check whether `newAddr == oldAddr` (no-op change). This leads to spurious events that could confuse off-chain indexers.
**Fix:** Add `if (newAddr == oldAddr) return;` before the state change and event emission.

### GCC-R2-012: `_pendingBuckets` Array Never Compacted

**Contract:** [StakePool.sol](file:///home/neko/gravity_chain_core_contracts/src/staking/StakePool.sol)
**Issue:** The `_pendingBuckets` array grows monotonically. Even after all buckets are fully claimed via `claimedAmount`, the array is never compacted. Over the lifecycle of an active staker with many unstake/withdraw cycles, the array could grow large, increasing gas costs for `_getCumulativeAmountAtTime()` binary search and storage costs.
**Fix:** Document this as a known limitation with a TODO comment. The `MAX_PENDING_BUCKETS = 1000` cap mitigates unbounded growth but does not address the compaction concern for long-lived pools.

### GCC-R2-013: `ValidatorManagement.setFeeRecipient` Allows `address(0)`

**Contract:** [ValidatorManagement.sol](file:///home/neko/gravity_chain_core_contracts/src/staking/ValidatorManagement.sol)
**Function:** `setFeeRecipient()`
**Issue:** `setFeeRecipient()` does not validate that `newRecipient != address(0)`. Setting the fee recipient to zero would cause fees to be sent to `address(0)`, burning them. The pending pattern applies it at epoch boundary, so there's time to catch and override, but it should be validated at setter time.
**Fix:** Add `if (newRecipient == address(0)) revert Errors.ZeroAddress();`.

### GCC-R2-014: `GravityPortal.withdrawFees` Sends Entire Balance Including Pending Refunds

**Contract:** [GravityPortal.sol](file:///home/neko/gravity_chain_core_contracts/src/oracle/evm/GravityPortal.sol)
**Function:** `withdrawFees()`
**Issue:** `withdrawFees()` sends `address(this).balance` to the fee recipient. However, `send()` now refunds excess fees inline (Round 1 fix GCC-016). If a `send()` call and `withdrawFees()` are processed in the same block, there's no accounting mismatch since refunds are immediate. However, if the refund `.call` in `send()` fails (recipient is a contract that reverts), the excess stays in the portal balance and could be withdrawn by the owner as fees. This is a minor edge case — the fee payer's contract refusing the refund.
**Fix:** Document this as accepted behavior. The refund failure case means the sender's contract cannot receive ETH; the excess stays as "unclaimed fees."

### GCC-R2-015: `Governance.execute` Allows ETH-Less Calls to Payable Targets

**Contract:** [Governance.sol](file:///home/neko/gravity_chain_core_contracts/src/governance/Governance.sol)
**Function:** `execute()`
**Issue:** The `execute()` function calls `targets[i].call(datas[i])` without forwarding any ETH value. If a governance proposal targets a payable function that requires ETH (e.g., `Staking.createPool`), the execution will fail at the target level. This is not a vulnerability per se, but it limits what governance proposals can do. The contract is not `payable` and has no mechanism to receive or forward ETH during execution.
**Fix:** Document as a known limitation. Governance proposals requiring ETH value must use a wrapper contract pattern.

---

## Filtering Notes (Round 1 Rejection Criteria Applied)

The following categories of findings were **excluded** from Round 2, consistent with the reviewer's guidance that Aptos reference parity is required:

- ❌ Retry / failure queue mechanisms (rejected in GCC-001)
- ❌ Proposal cancellation mechanisms (rejected in GCC-008)
- ❌ Snapshot-based voting power (rejected in GCC-010)
- ❌ ETH forwarding in governance execution (rejected in GCC-022)
- ❌ Fee recipient specification at registration (rejected in GCC-024)
- ❌ Any new feature additions beyond current contract scope

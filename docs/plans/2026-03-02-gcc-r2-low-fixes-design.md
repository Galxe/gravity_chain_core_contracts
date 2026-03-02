# GCC Round 2 LOW Fixes Design

Date: 2026-03-02

## Category A — Timestamp / Documentation (2 fixes)

### GCC-R2-009: NativeOracle recordedAt Uses Seconds Instead of System Microseconds

**Problem:** `DataRecord.recordedAt` is populated with `uint64(block.timestamp)` (EVM seconds), while the rest of the Gravity system uses microsecond timestamps from the `Timestamp` contract. This inconsistency creates confusion when comparing oracle records against system timestamps.

**Fix:** Add inline NatSpec comment clarifying that `recordedAt` uses EVM `block.timestamp` (seconds), not Gravity microseconds. Keep using `block.timestamp` since `record()` is called by `SYSTEM_CALLER` and consistent with `OracleRequestQueue`'s use of seconds.

**Files:** NativeOracle.sol

**Review Comments** reviewer: ; state: ; comments: 

### GCC-R2-010: Genesis._isInitialized Set Inside Sub-function

**Problem:** `_isInitialized` is set to `true` and `GenesisCompleted` event is emitted inside `_initializeValidatorsAndSystem()` rather than at the end of the top-level `initialize()`. While functionally correct (reverts on sub-call failure roll everything back), it reduces code clarity and makes the initialization boundary harder to reason about.

**Fix:** Move `_isInitialized = true` and `emit GenesisCompleted(...)` to the end of `initialize()` function body.

**Files:** Genesis.sol

**Review Comments** reviewer: ; state: ; comments: 

## Category B — Spurious Events (1 fix)

### GCC-R2-011: StakePool Role Setters Emit Events on No-Op Changes

**Problem:** `setOperator()`, `setVoter()`, and `setStaker()` emit change events even when `newAddr == oldAddr`. This produces spurious events that confuse off-chain indexers.

**Fix:** Add `if (newAddr == currentAddr) return;` before state change and event emission in all three setters.

**Files:** StakePool.sol

**Review Comments** reviewer: ; state: ; comments: 

## Category C — Data Structure (1 fix)

### GCC-R2-012: _pendingBuckets Array Never Compacted

**Problem:** The `_pendingBuckets` array grows monotonically. Even after all buckets are fully claimed via `claimedAmount`, the array is never compacted. Over the lifecycle of a long-lived pool, gas costs for binary search increase.

**Fix:** Document as a known limitation via NatSpec comment. The `MAX_PENDING_BUCKETS = 1000` cap from GCC-013 mitigates unbounded growth. Full compaction would require significant refactoring.

**Files:** StakePool.sol

**Review Comments** reviewer: ; state: ; comments: 

## Category D — Missing Input Validation (1 fix)

### GCC-R2-013: ValidatorManagement.setFeeRecipient Allows address(0)

**Problem:** `setFeeRecipient()` does not validate `newRecipient != address(0)`. Setting fee recipient to zero burns all validator fees. The pending pattern delays application to epoch boundary, but the invalid value should be caught at setter time.

**Fix:** Add `if (newRecipient == address(0)) revert Errors.ZeroAddress();` at the top of `setFeeRecipient()`.

**Files:** ValidatorManagement.sol

**Review Comments** reviewer: ; state: ; comments: 

## Category E — Edge Cases (2 fixes)

### GCC-R2-014: GravityPortal.withdrawFees Sends Entire Balance Including Failed Refunds

**Problem:** `withdrawFees()` sends `address(this).balance` to fee recipient. If a `send()` caller's refund `.call` fails (recipient contract reverts), the unclaimed excess stays in the portal and gets withdrawn as fees. This is a minor edge case where the sender's own contract cannot accept ETH.

**Fix:** Document as accepted behavior via NatSpec comment. The fee payer's inability to receive ETH refunds is their own limitation.

**Files:** GravityPortal.sol

**Review Comments** reviewer: ; state: ; comments: 

### GCC-R2-015: Governance.execute Cannot Forward ETH

**Problem:** `execute()` calls `targets[i].call(datas[i])` without forwarding ETH. Governance proposals targeting payable functions requiring ETH (e.g., `Staking.createPool`) will fail. The contract is not `payable` and has no mechanism to hold or forward ETH.

**Fix:** Document as known limitation via NatSpec comment. Governance proposals requiring ETH value must use a wrapper contract pattern. (Note: GCC-022 in Round 1 proposed native token support and was rejected as not present in Aptos reference.)

**Files:** Governance.sol

**Review Comments** reviewer: ; state: ; comments: 

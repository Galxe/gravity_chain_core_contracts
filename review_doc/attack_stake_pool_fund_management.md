# attack_stake_pool_fund_management

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 165359ms
- **Steps**: 1

## Report

# StakePool Red Team Attack Report

## Finding 1: Permanent Pending Bucket DoS (Irreversible State Lockout)
**Severity: HIGH**

**Location:** `StakePool.sol:466-494` (`_addToPendingBucket`) + `StakePool.sol:382-395` (`systemRenewLockup`)

**Description:** The `_pendingBuckets` array only grows and is **never pruned**. The `claimedAmount` pointer allows claiming without deleting entries, but the array length is permanently monotonic. Once `_pendingBuckets.length` reaches `MAX_PENDING_BUCKETS` (1000), any `_unstake` call that requires a **new bucket** (i.e., `lockedUntil` differs from the last bucket's) will permanently revert.

**Attack Path:**
1. For active validators, `systemRenewLockup()` is called by the factory each epoch, incrementing `lockedUntil`.
2. Each time the staker calls `unstake()` after a lockup renewal, `lockedUntil` has changed, so a **new bucket** is appended (line 487).
3. After 1000 epochs with at least one unstake each, the array is full.
4. Even if the staker later withdraws **all** pending funds (via `withdrawAvailable`), `claimedAmount` increases but `_pendingBuckets.length` remains 1000.
5. Any future unstake with a new `lockedUntil` reverts with `TooManyPendingBuckets` — **permanently**.

**Impact:** The pool becomes permanently unable to unstake, effectively bricking the staker's fund management. The only recourse is to withdraw everything and create an entirely new pool (losing the validator seat, requiring re-registration, etc.).

---

## Finding 2: Missing `nonReentrant` on `unstakeAndWithdraw`
**Severity: MEDIUM**

**Location:** `StakePool.sol:322-331`

**Description:** `unstakeAndWithdraw` calls `_withdrawAvailable` (which performs an external ETH `call`) but does **not** carry the `nonReentrant` modifier. In contrast, the standalone `withdrawAvailable` wrapper at line 315-319 **does** have `nonReentrant`.

During the external `call` in `_withdrawAvailable`, the ReentrancyGuard lock is **not engaged**. This means a malicious `recipient` contract can re-enter:
- `withdrawRewards()` — normally `nonReentrant`-protected, but the lock isn't held here
- `unstakeAndWithdraw()` again (recursive)
- `withdrawAvailable()` — the `nonReentrant` guard would succeed because it was never locked

**Mitigation by CEI:** The `_withdrawAvailable` function updates `claimedAmount` before the external call (CEI pattern), so double-withdraw of the same claimable amount is prevented. Similarly, `_getRewardBalance()` is derived from `address(this).balance` which already reflects the in-flight transfer. **No concrete exploit path was found** with the current code.

**Why still Medium:** This is a defense-in-depth violation. Any future modification that introduces state dependencies between `withdrawRewards` and withdrawal accounting could become exploitable. The inconsistency between `withdrawAvailable` (has `nonReentrant`) and `unstakeAndWithdraw` (doesn't) is a red flag for maintainability.

---

## Finding 3: `withdrawRewards` Has No State-Variable Accounting
**Severity: MEDIUM**

**Location:** `StakePool.sol:362-375`

**Description:** `withdrawRewards` calculates rewards as `address(this).balance - activeStake - unclaimedPending`, then sends ETH. There is **no state variable** recording how much reward has been withdrawn — the balance decrease from the transfer IS the "state change."

This means:
- If ETH arrives at the contract between `_getRewardBalance()` (line 365) and the `call` (line 373) — e.g., via a coinbase transaction in the same block — the extra ETH is not captured by this withdrawal but would be available in the next call. This is benign but worth noting.
- More critically: **the event `RewardsWithdrawn` is emitted before the transfer** (line 370). If an off-chain system uses this event to track rewards and the transfer fails (recipient reverts), the entire transaction reverts including the event — so this is safe. But the pattern invites mistakes in future modifications.

**The real risk:** If another function is ever added that modifies `activeStake` or pending state without proper balance tracking, the reward calculation silently absorbs or hides the discrepancy, since it's a residual calculation (`balance - everything_tracked`). There's no independent invariant check.

---

## Finding 4: `renewLockUntil` Missing Overflow Check on `now_ + minLockup`
**Severity: LOW-MEDIUM**

**Location:** `StakePool.sol:351`

**Description:** `renewLockUntil` validates `newLockedUntil < now_ + minLockup`, but unlike `addStake` (which explicitly checks `now_ > type(uint64).max - minLockup` at line 295), this function relies on Solidity's checked arithmetic to revert on overflow. If `now_ + minLockup` overflows `uint64`, the transaction panics with a generic error rather than a descriptive custom error. This is a consistency issue — `addStake` guards against this explicitly while `renewLockUntil` does not.

---

## Summary

| # | Finding | Severity | Exploitable Now? |
|---|---------|----------|-----------------|
| 1 | Permanent bucket array DoS — irreversible after 1000 distinct `lockedUntil` unstakes | **HIGH** | Yes — inevitable for active validators who periodically unstake |
| 2 | Missing `nonReentrant` on `unstakeAndWithdraw` | **MEDIUM** | No concrete path found, but guard inconsistency is dangerous |
| 3 | Reward tracking via balance residual with no state variable | **MEDIUM** | No direct exploit, but fragile design |
| 4 | Inconsistent overflow handling in `renewLockUntil` | **LOW-MEDIUM** | Only causes a generic panic instead of descriptive revert |

**Recommendation priority:** Finding #1 is the most critical — it represents a permanent, irreversible denial-of-service on core staking functionality. Consider adding a bucket cleanup mechanism (e.g., shift/compact fully-claimed buckets when the array grows beyond a threshold, or allow the `claimedAmount` pointer to trigger pruning of prefix entries).

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | # StakePool Red Team Attack Report

## Finding 1: Permanent  | 165359ms |

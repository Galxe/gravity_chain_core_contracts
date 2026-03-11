# attack_staking_factory_pool_creation

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 134545ms
- **Steps**: 1

## Report

# Red Team Attack Report: Staking Factory & StakePool

## Finding 1 — `unstakeAndWithdraw` Missing Reentrancy Guard

**Severity: Medium**

**Location:** `src/staking/StakePool.sol:322-331`

```solidity
function unstakeAndWithdraw(
    uint256 amount,
    address recipient
) external onlyStaker whenNotReconfiguring returns (uint256 withdrawn) {
    _unstake(amount);
    withdrawn = _withdrawAvailable(recipient); // sends ETH, no nonReentrant
}
```

`withdrawAvailable()` (line 315-319) has `nonReentrant`, but `unstakeAndWithdraw()` does **not**. Both call `_withdrawAvailable()` which sends ETH via low-level `.call{value}`. 

If `recipient` is a malicious contract, it can reenter during the ETH transfer. The reentrancy guard is **not** engaged because the outer function doesn't set it. This means:

- Reentrant calls to `withdrawAvailable()` would succeed (guard not held) — but CEI on `claimedAmount` prevents double-claiming.
- Reentrant calls to `withdrawRewards()` would also succeed — but the math (`balance - trackedBalance`) remains consistent since both numerator and denominator decrease by the same transfer amount.
- Reentrant calls to `unstakeAndWithdraw()` itself — `_unstake` would further reduce `activeStake`, `_withdrawAvailable` would return 0 (claimable already claimed).

**Current exploitability**: Low, because `_withdrawAvailable` follows CEI (updates `claimedAmount` before transfer). However, this is a defense-in-depth violation — any future refactor that breaks the CEI ordering would immediately become exploitable for fund theft.

**Recommendation:** Add `nonReentrant` to `unstakeAndWithdraw`.

---

## Finding 2 — `operator` and `voter` Accept Zero Address at Pool Creation

**Severity: Medium**

**Location:** `src/staking/Staking.sol:190-192`, `src/staking/StakePool.sol:115-138`

The factory validates `owner != address(0)` and `staker != address(0)`, but **does not check** `operator` or `voter`. The StakePool constructor also has no validation for these fields.

Meanwhile, `setOperator()` (line 249) and `setVoter()` (line 260) both explicitly reject `address(0)`:

```solidity
if (newOperator == address(0)) revert Errors.ZeroAddress();
```

This creates an **irreparable state**: a pool created with `operator = address(0)` or `voter = address(0)` is stuck — these values cannot be changed to zero (blocked by setter), and they cannot be "fixed" from zero because `setOperator(address(0))` reverts. However, the zero-address `operator`/`voter` will be **consumed by downstream contracts** (validator management, governance) potentially causing unexpected behavior (e.g., governance votes attributed to `address(0)`, operator checks against a null address).

Actually, correction: the setters reject zero and also skip no-ops (`if (newOperator == operator) return`). So if `operator == address(0)`, calling `setOperator(someRealAddress)` would work fine since the new value is non-zero and different from current. The issue is only that a pool can exist with `operator = address(0)` and downstream contracts may not handle this correctly.

**Recommendation:** Validate `operator != address(0)` and `voter != address(0)` in `createPool()` or in the StakePool constructor.

---

## Finding 3 — Pool Registry Is Append-Only (No Deregistration)

**Severity: Medium**

**Location:** `src/staking/Staking.sol:207-209`

```solidity
_allPools.push(pool);
_isPool[pool] = true;
```

There is **no function** to set `_isPool[pool] = false` or remove a pool from `_allPools`. Once created, a pool is permanently registered. This means:

1. **Zombie pools**: A pool that has fully unstaked and withdrawn all funds remains a "valid pool" forever. Any system component that iterates over `getAllPools()` (e.g., for voting power aggregation) will waste gas on empty pools.
2. **Unbounded array growth**: `_allPools` grows monotonically. `getAllPools()` returns the entire array. With thousands of pools, off-chain consumers and any on-chain iteration (in future contracts) become DoS-susceptible.
3. **No pool lifecycle management**: If a pool's owner loses their keys, the pool is a permanent dead entry — it cannot be cleaned up by anyone, including governance.

**Recommendation:** Consider adding a governance-gated or owner-gated deregistration function that sets `_isPool[pool] = false` when a pool is fully drained.

---

## Finding 4 — `_getClaimableAmount` Threshold Off-by-One Semantics

**Severity: Medium**

**Location:** `src/staking/StakePool.sol:587-613`

```solidity
uint64 threshold = now_ - unbondingDelay;
uint256 claimableCumulative = _getCumulativeAmountAtTime(threshold);
```

`_getCumulativeAmountAtTime(threshold)` returns cumulative amount where `lockedUntil < threshold` (strict less-than, line 573). The threshold is `now - unbondingDelay`. So a bucket is claimable when:

```
lockedUntil < now - unbondingDelay
```

Which means: `now > lockedUntil + unbondingDelay` (strict greater-than). The IStakePool interface documentation (line 157) states:

> Returns pending stake where (now > lockedUntil + unbondingDelay)

This is consistent. However, the **boundary case** is that a bucket with `lockedUntil` exactly equal to `now - unbondingDelay` is **not** claimable. This strict inequality means a user must wait at least 1 microsecond beyond the unbonding deadline. While this is technically correct per the docs, it's a subtle edge case that could surprise integrators expecting `>=` semantics. Not directly exploitable, but worth documenting explicitly.

---

## Finding 5 — `withdrawRewards` Not Blocked During Reconfiguration

**Severity: Low**

**Location:** `src/staking/StakePool.sol:362-375`

```solidity
function withdrawRewards(address recipient) external onlyStaker nonReentrant returns (uint256 amount) {
```

All other staker fund operations (`addStake`, `unstake`, `withdrawAvailable`, `unstakeAndWithdraw`, `renewLockUntil`) include `whenNotReconfiguring`. `withdrawRewards` does **not**. This means rewards can be drained during epoch transitions while all other staking operations are frozen.

If rewards are derived from validator performance during the current epoch, withdrawing them mid-reconfiguration could create accounting inconsistencies with the reward distribution system, depending on how rewards are credited at epoch boundaries.

**Likely intentional** (rewards don't affect validator set state), but the asymmetry should be explicitly documented.

---

## Summary

| # | Finding | Severity | Exploitable Now? |
|---|---------|----------|-----------------|
| 1 | `unstakeAndWithdraw` missing `nonReentrant` | **Medium** | No (CEI mitigates), but fragile |
| 2 | `operator`/`voter` zero-address at creation | **Medium** | Depends on downstream consumers |
| 3 | No pool deregistration mechanism | **Medium** | Long-term DoS / governance concern |
| 4 | Claimable threshold strict-less-than edge case | **Medium** | No, but may confuse integrators |
| 5 | `withdrawRewards` allowed during reconfiguration | **Low** | Depends on reward crediting mechanism |

No **Critical** severity issues found. The CEI pattern in `_withdrawAvailable` and the validator bond check in `_unstake` are correctly implemented. The CREATE2 deployment, nonce management, and factory trust model are sound.

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | # Red Team Attack Report: Staking Factory & StakePool

## Fi | 134544ms |

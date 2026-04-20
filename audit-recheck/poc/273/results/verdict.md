# Verdict — gravity-audit #273

**Issue**: [Critical] `renewLockUntil` has no upper-bound cap — compromised staker key permanently locks all pool funds

**Labeled status** (human triage): `status: fixed-on-main`

## A/B dynamic test

| Commit | `forge test` result | Meaning |
|---|---|---|
| `27b22c3` (tag `gravity-testnet-v1.0.0`, pre-fix) | **PASS** | `renewLockUntil(uint64.max - lockedUntil - 1)` succeeds. Post-state `lockedUntil = 18446744073709551614` ≈ uint64.max → funds locked for **584,910 years**. Attack confirmed reproducible. |
| `a623eab` (main HEAD, post-fix) | **FAIL** | Call reverts with `ExcessiveLockupDuration(1.844e19, 1.261e14)` — the new `MAX_LOCKUP_DURATION = 4 years` ceiling (`1.261e14` micros) rejects the oversize duration. Attack blocked. |

## Verdict

- **Issue was valid (not a false positive)** — exploit reproduces on pre-fix code with a single transaction.
- **Fix on `main` is effective** for the exact exploit path described.
- **Dynamic confidence**: HIGH — binary on-chain assertion, not inference.

## Fix locator (for the audit)

The guard is in `src/staking/StakePool.sol:461-463` (main, `a623eab`):

```solidity
if (durationMicros > MAX_LOCKUP_DURATION) {
    revert Errors.ExcessiveLockupDuration(durationMicros, MAX_LOCKUP_DURATION);
}
```

`MAX_LOCKUP_DURATION` is declared as a contract constant equal to 4 years in microseconds.

## Residual concerns not covered by this PoC

The PoC only validates the upper-bound check. It does **not** exercise:
- Interaction with `_unstake` creating pending buckets that inherit `lockedUntil` — theoretically orthogonal to the cap, but worth a dedicated regression if the cap is ever raised.
- The `setStaker` + rotate-key recovery path mentioned in the issue — out of scope here.

## Files

- `test/POC_273.t.sol` — self-contained PoC
- `results/old_27b22c3.txt` — run log on vulnerable commit
- `results/new_a623eab.txt` — run log on fixed main

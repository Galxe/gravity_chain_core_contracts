# Verdict — gravity-audit #476

**Issue**: [Critical] `EpochConfig.setForNextEpoch` no upper bound — `epochIntervalMicros = type(uint64).max` causes `_canTransition()` checked-arithmetic overflow → permanent chain halt

**Labeled status** (human triage): `OPEN`, no `status:` label

## Dynamic test on main (`a623eab`)

| Step | Action | Observed |
|---|---|---|
| 1 | `Governance → EpochConfig.setForNextEpoch(type(uint64).max)` | **accepted** (only `!= 0` check) |
| 2 | `Reconfiguration → EpochConfig.applyPendingConfig()` | `epochIntervalMicros == uint64.max` confirmed in state |
| 3 | `BLOCK → Reconfiguration.checkAndStartTransition()` | **reverted with `Panic(0x11)`** (arithmetic overflow in `_canTransition`'s `lastReconfigurationTime + epochInterval`) |

`forge test` result: **PASS** — all assertions including `vm.expectRevert(stdError.arithmeticError)` satisfied.

## Verdict

- **Issue is a live true positive on `main`** — exploit reproduces end-to-end with a clean, minimal PoC.
- **No fix appears to have landed** — `setForNextEpoch` (`src/runtime/EpochConfig.sol:99-113`) still only rejects zero; `_canTransition` (`src/blocker/Reconfiguration.sol:215-218`) still does unchecked `lastReconfigurationTime + epochInterval`.
- **Dynamic confidence**: HIGH — the chain-halt primitive is directly observed, not inferred from code inspection alone.

## Recommended mitigation (for the triage team)

Two independent places can hold the line — ideally both:

1. **Input-side**: `EpochConfig.setForNextEpoch` (and `initialize`) should reject values exceeding a protocol ceiling — e.g. `MAX_EPOCH_INTERVAL = 7 days * 1_000_000`. This is the same pattern Coacker's team already applied to `StakingConfig._validateConfig` for `lockupDurationMicros` (see #403 fix — `MAX_LOCKUP_DURATION` check added).
2. **Consumption-side**: `Reconfiguration._canTransition` should use saturating arithmetic or early-return when the addition would overflow — so even a pathological config in storage cannot brick block prologue. Defense in depth.

## Related issues cluster

This is one of **three near-duplicates** all reporting the same chain-halt primitive:

- `#476` — `setForNextEpoch no upper bound → chain halt` (this one)
- `#472` — same title, same exploit chain
- `#452` — same (slight wording variation)

Triage recommendation: keep one as the canonical issue, mark the others as duplicates. The fix will close all three.

## Files

- `test/POC_476.t.sol` — self-contained PoC, 80 lines
- `results/main_a623eab.txt` — run log on current `main` (PASS)

## Notes on the PoC setup

- The exploit does **not** require a full Blocker/ValidatorManagement cascade. The revert happens inside `_canTransition` before `checkAndStartTransition` reaches `evictUnderperformingValidators`, so no mocks beyond `Timestamp`/`EpochConfig`/`Reconfiguration` were needed.
- Timestamp had to be primed with a nonzero value *before* `Reconfiguration.initialize()` was called — otherwise `lastReconfigurationTime = 0` and `0 + uint64.max = uint64.max` does not overflow.

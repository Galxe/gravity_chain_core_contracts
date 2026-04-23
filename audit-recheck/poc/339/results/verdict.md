# PoC Verdict — Issue #339 (cluster: #339, #462, #473, #357)

## Setup summary

Independent foundry project at `.audit-recheck/poc/339/` with symlinks into
`external/gravity_core` (commit `a623eab` on `main`).

`POC_339.t.sol`:

1. Etches every relevant system contract at its canonical `SystemAddresses.*`:
   `Timestamp`, `EpochConfig`, `StakingConfig`, `ValidatorConfig`,
   `RandomnessConfig` (variant `Off`), `ConsensusConfig`, `ExecutionConfig`,
   `GovernanceConfig`, `VersionConfig`, `DKG`, `Reconfiguration`,
   `ValidatorPerformanceTracker`, `ValidatorManagement`.
2. Etches a `MockStaking` at `SystemAddresses.STAKING` (real `Staking` +
   `StakePool` deploy is unnecessary because the eviction path only reads
   `getPoolVotingPower` and calls `renewPoolLockup` (the latter inside a
   `try/catch`)). Storage slot 0 (`defaultVotingPower`) is seeded via
   `vm.store` so the etched code returns `POOL_POWER = 100 ether` for any
   pool — well above `minimumBond = 10 ether`, so the underbond Phase-1
   eviction path never fires.
3. Initializes all configs from `SystemAddresses.GENESIS`. Crucially,
   `ValidatorConfig.initialize` is called with `autoEvictEnabled = true`,
   `autoEvictThresholdPct = 50`, `allowValidatorSetChange = true`.
4. Bootstraps **N=4** validators directly into `ACTIVE` via
   `ValidatorManagement.initialize(GenesisValidator[])` — the genesis path
   skips the BLS PoP precompile, so no precompile mock is needed.
5. Initializes `PerformanceTracker` with 4 zero-valued slots, then
   `Reconfiguration.initialize()` (which sets `currentEpoch = 1`).

The attack itself is just two pranked calls from `SystemAddresses.GOVERNANCE`:

```solidity
vm.prank(SystemAddresses.GOVERNANCE);
reconfiguration.governanceReconfigure();   // call #1: epoch 1 → 2, perf reset to (0,0)
vm.prank(SystemAddresses.GOVERNANCE);
reconfiguration.governanceReconfigure();   // call #2: evicts all-but-one
```

## Forge result

```
Ran 1 test for test/POC_339.t.sol:POC_339
[PASS] test_attackSucceedsIfVulnerable() (gas: 540585)
Suite result: ok. 1 passed; 0 failed; 0 skipped
```

Full output: `results/main_a623eab.txt`. **PoC PASSES on current main
`a623eab`** — the exploit is live.

Post-exploit invariants observed:
- `getActiveValidatorCount() == 1` (collapsed from 4).
- 3 of 4 validators sit at `INACTIVE`; 1 at `ACTIVE`.
- `getTotalVotingPower() == POOL_POWER` (100 ether — the surviving
  validator's power; the other 300 ether of voting power is gone in one tx).

## Cluster issues confirmed

- **#339** — Direct hit. The two-call governance batch reproduces the
  zero-perf mass-eviction. **CONFIRMED EXISTS on main.**
- **#462, #473, #357** — All point at the same root cause: `governanceReconfigure`
  has no per-tx / per-block / per-epoch dedup or cooldown beyond the
  `DkgInProgress` state-machine guard, and the same-tx replay primitive used
  by the PoC is exactly the missing-guard symptom each of those issues
  describes. The PoC therefore **also confirms the existence of the missing
  guard** that #462/#473/#357 each highlight, even though their proposed
  exploit narratives differ in framing (rate-limit, dedup, batch idempotency).

## Step-by-step trace through the exploit

1. **Pre-state** (post-`setUp`): 4 ACTIVE validators with perf = (0, 0)
   (genesis perf init is zero), `currentEpoch = 1`, `_transitionState = Idle`.
2. **Call #1** (`governanceReconfigure()` from GOVERNANCE):
   - `evictUnderperformingValidators()` runs; `closingEpoch = 1`, so
     `closingEpoch <= 1` skip-guard fires — **no evictions** in call #1.
     This matches the static-verdict reasoning.
   - `_doImmediateReconfigure → _applyReconfiguration` runs:
     `applyPendingConfig` for all configs (no-op — no pending configs);
     `ValidatorManagement.onNewEpoch()` (no pending join/leave, no-op);
     `PerformanceTracker.onNewEpoch(4)` — pops all entries and pushes 4 fresh
     zeros; `currentEpoch ← 2`; `_transitionState ← Idle`.
3. **Call #2** (`governanceReconfigure()` from GOVERNANCE):
   - `_transitionState == Idle` → guard passes.
   - `evictUnderperformingValidators()` runs; `closingEpoch = 2`, so the
     `<=1` skip-guard is bypassed. Phase-1 (underbond) does nothing
     (`POOL_POWER >= minimumBond`). Phase-2 reads `getAllPerformances()` —
     length matches `_activeValidators.length == 4`, all entries `(0,0)`.
     `total == 0` branch unconditionally evicts every validator except the
     last (liveness guard at line 712-715).
   - `_applyReconfiguration → onNewEpoch → _applyDeactivations` then promotes
     all 3 PENDING_INACTIVE validators to INACTIVE — **active set collapses
     to 1 in a single tx**.

## Residual uncertainties

- The PoC routes the two `governanceReconfigure()` calls through `vm.prank`
  rather than through `Governance.execute(...)`. This is intentional and
  faithful: the auditor's static verdict explicitly notes that
  `Governance.execute` is a naive `for`-loop with no dedup
  (`Governance.sol:527-535`), so the only thing that loop does relative to
  the PoC is `(target, data).call(...)` against `SystemAddresses.RECONFIGURATION`
  — exactly what `vm.prank(GOVERNANCE)` simulates without dragging in the
  full proposal/voting/staking fixture. This narrows the test to the
  contract-level claim ("`governanceReconfigure` is replayable in one tx
  with destructive side-effects") and avoids needing to bootstrap a quorum.
- `MockStaking` returns a constant voting power for every pool and a
  no-op `renewPoolLockup`. This is sufficient to test the eviction path
  because (a) Phase-1 underbond eviction needs a non-zero power above
  `minimumBond`, and (b) `_renewActiveValidatorLockups` wraps the call in
  `try/catch`. Real `Staking + StakePool` would not behave differently for
  the eviction logic.
- The attack as demonstrated needs `autoEvictEnabled == true` *on-chain*
  (which the PoC sets at genesis via `ValidatorConfig.initialize`). The
  three-target variant described in the issue (where the proposal *also*
  contains a `ValidatorConfig.setPendingConfig(autoEvictEnabled=true,…)`
  target) is not reproduced here, but the static verdict already confirms
  that variant is intact (and it's strictly weaker than this two-call
  proof — the toggle just removes the prerequisite).

## Disposition

`dynamic_status = DYNAMIC_PASS`. The exploit is reproducible end-to-end on
the current `main` (`a623eab`). #339 is a **live, exploitable** bug, and the
underlying missing-guard primitive shared with #462, #473, #357 is also
live.

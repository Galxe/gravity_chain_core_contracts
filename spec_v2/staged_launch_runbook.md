# Staged Launch Runbook

Guided rollout of the Gravity L1 with **7 validators**, starting **permissioned**
and with **low initial stakes**, so every mainnet-bound code path (stake up/down,
lifecycle, DKG, auto-evict, governance, reconfiguration) is exercised on-chain
before the permissionless flip.

> **Principle:** 凡是要上主网的路径，都得在测试阶段 exercise 一次。

## Pre-launch invariants

| Setting | Value | Where |
|---|---|---|
| Validator set size | 7 (genesis) | `genesis_config.json → validators[]` |
| `allowValidatorSetChange` | `true` | `validatorConfig` |
| `autoEvictEnabled` | `true` | `validatorConfig` (kill-switch via `setForNextEpoch`) |
| `randomnessConfig.variant` | `1` (V2 / DKG ENABLED) | `randomnessConfig` |
| `ValidatorManagement._permissionlessJoinEnabled` | `false` | defaults at genesis |
| Whitelist seed | the 7 genesis pools | auto-populated in `initialize()` |
| `initialLockedUntilMicros` | launch +1y | `genesis_config.json` |
| `minimumBond`, `minimumStake` | LOW but not permissive | governance-tunable |

## Stage 0 — pre-flight (off-chain)

1. Replace every `PLACEHOLDER` in `genesis-tool/config/genesis_config.json`
   (validator-5/6/7 operator/consensus keys, `initialLockedUntilMicros`,
   `minimumBond`, `minimumStake`, `autoEvictThresholdPct`).
2. Re-run `cargo run -p genesis-tool -- <args>` to produce the genesis payload.
3. Sanity: `forge test` (the submodule test suite) must be green on the
   branch before cutting the release tag.

## Stage 1 — cold start

1. Boot the 7 genesis validators.
2. Wait one epoch; confirm via `ValidatorManagement.getActiveValidators()` that
   all 7 are `ACTIVE` and voting power equals the sum of seeded bonds.
3. Spot check: `isPermissionlessJoinEnabled() == false` and
   `isValidatorPoolAllowed(pool_i) == true` for i in 1..=7.

Abort if any of the 7 fails to come up — the whitelist is now the only path
into the set, so re-keying must happen via governance add/remove.

## Stage 2 — stake-movement drills (permissioned)

Run the `script/stage2_stake_moves.sh` driver (see `scripts/` section below).
It performs, per validator:

- `addStake` → verify bond rises next epoch; voting power re-weighted.
- `unlockStake` + `withdrawStake` after `lockedUntil + unbondingDelay` →
  verify path, epoch-boundary apply, and that auto-evict Phase-1 triggers
  when any validator drops below `minimumBond`.
- `requestLockupExtension` to confirm lockup renewal logic.

Exit criteria: every validator has demonstrated both +Δ and −Δ at least once.

## Stage 3 — lifecycle drills (permissioned)

For 1 or 2 validators at a time (never quorum-breaking):

1. `leaveValidatorSet(pool)` → status → `PENDING_INACTIVE` → next epoch → `INACTIVE`.
2. `joinValidatorSet(pool)` → `PENDING_ACTIVE` → `ACTIVE`.
3. Intentionally starve one validator to trip **auto-evict Phase-2** (low
   success rate): confirm `evictUnderperformingValidators` eventually removes
   it and that the remaining set still clears BFT quorum.
4. Re-join the evicted validator — the whitelist still lists them, so this
   should succeed. (If de-listed, `PoolNotWhitelisted` is expected; re-list
   via governance before re-join.)

## Stage 4 — reconfiguration / DKG drills

DKG V2 is **enabled**. At each epoch boundary the chain must:

- Complete the DKG ceremony within the expected window.
- Produce a new `TranscriptEvent` before `onNewEpoch` fires.
- Survive a simulated dealer dropout (stop one validator during DKG, confirm
  the reconfiguration either completes with the remaining set or is
  force-ended via governance using `Reconfiguration.forceEnd`).

This exercises the reconfiguration freeze, the `whenNotReconfiguring`
modifiers on `registerValidator` / `joinValidatorSet`, and the
`ValidatorPerformanceTracker` reset on epoch transition.

## Stage 5 — governance parameter drills

Use the new single-field setters on `StakingConfig` and the combined setter on
`ValidatorConfig` to rehearse proposals. Each must show a pending config on
submit, apply at the next epoch, then clear:

- `StakingConfig.setMinimumStakeForNextEpoch(newMin)`
- `StakingConfig.setLockupDurationForNextEpoch(newLockup)`
- `StakingConfig.setUnbondingDelayForNextEpoch(newUnbonding)`
- `ValidatorConfig.setForNextEpoch(...)` to lower `minimumBond` or toggle
  `autoEvictEnabled`.

Confirm observers (`hasPendingConfig`, `getPendingConfig`) expose the queued
changes and that the governance audit trail (`PendingStakingConfigSet` →
`StakingConfigUpdated` → `PendingStakingConfigCleared`) emits cleanly.

## Stage 6 — permissioned → permissionless flip

Exit condition for this stage is a clean record from Stages 1–5 (every planned
exercise executed successfully at least once).

1. Pass a governance proposal whose call data is
   `ValidatorManagement.setPermissionlessJoinEnabled(true)`.
2. On execution, `PermissionlessJoinEnabledUpdated(true)` is emitted.
3. From this point on, `registerValidator` and `joinValidatorSet` ignore the
   whitelist. The whitelist mapping itself is retained (harmlessly) for
   auditability; no migration is required.
4. (Optional) the GOVERNANCE role may still add/remove entries later, but
   none of the gating logic consults the mapping while the flag is on.

## Rollback levers

If a post-launch incident appears before Stage 6:

- **Freeze the validator set:** governance sets
  `ValidatorConfig.allowValidatorSetChange = false`. Blocks register/join/leave
  and eviction.
- **Block a specific pool:** governance calls
  `setValidatorPoolAllowed(pool, false)`. Blocks future register/join for that
  pool; currently-active pools continue running until they leave or are evicted.
- **Tighten minimums live:** governance uses the StakingConfig single-field
  setters to ratchet `minimumStake` / `minimumBond` upward; changes apply at
  the next epoch.

After Stage 6 flips, the per-pool whitelist lever is disabled by design — the
freeze lever and minimum-bond tightening remain.

## Contract surface touched for this launch

- `src/staking/ValidatorManagement.sol` — whitelist (`_allowedPools`,
  `_permissionlessJoinEnabled`), auto-seeded from genesis validators, gated in
  `_validateRegistration` and `joinValidatorSet`.
- `src/staking/IValidatorManagement.sol` — whitelist setters/views + events.
- `src/runtime/StakingConfig.sol` — three single-field setters
  (`setMinimumStakeForNextEpoch`, `setLockupDurationForNextEpoch`,
  `setUnbondingDelayForNextEpoch`) that overlay on any existing pending
  config.
- `src/runtime/IStakingConfig.sol` — exposes the three setters.
- `src/foundation/Errors.sol` — `PoolNotWhitelisted(address)`.
- `genesis-tool/config/genesis_config.json` — 7-validator staged template.

## Test coverage

- `test/unit/staking/ValidatorWhitelist.t.sol` — 18 tests: register/join
  gating, governance access control, events, genesis auto-populate.
- `test/unit/runtime/StakingConfig.t.sol` — covers each single-field setter:
  field preservation, pending overlay, epoch apply, validation, access.
- `test/unit/staking/ValidatorManagement.t.sol` — unchanged behavior on the
  main lifecycle; `setUp()` flips `permissionlessJoinEnabled = true` because
  these tests pre-date the whitelist.
- `test/unit/integration/ConsensusEngineFlow.t.sol` — same `setUp()` flip.

All suites green: **967 tests pass** after the changes.

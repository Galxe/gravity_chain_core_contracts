# Security Audit Report — Gravity Core Contracts (Deep Audit)

**Date:** 2026-03-05
**Scope:** All contracts in `src/` (52 .sol files)
**Solidity:** 0.8.30 | **Toolchain:** Foundry
**Repository:** `Galxe/gravity_chain_core_contracts` (branch: `security-audit-fixes`)
**Prior Audits:** [Round 1 — 2026-02-23](./2026-02-23-security-audit-report.md) (47 findings), [Round 2 — 2026-03-02](./2026-03-02-security-audit-r2-report.md) (15 findings)

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| HIGH | 5 |
| MEDIUM | 8 |
| LOW | 4 |
| INFO | 5 |
| **Total** | **25** |

> [!NOTE]
> This deep audit was performed as part of the cross-repository security review.
> It includes re-examination of previously fixed areas, cross-module analysis with gravity-reth/gravity-sdk/gravity-aptos,
> and new findings in governance, staking, bridge, and oracle contracts.

---

## CRITICAL (3)

### GCORE-001: Governance Execution Has No Timelock

**File:** `Governance.sol:493-499`

Once a proposal succeeds and is resolved, `execute()` can be called immediately. A 51% staking attack can immediately reconfigure all chain parameters, force-evict validators, change consensus configs, and modify oracle callbacks. No delay buffer for the community to react.

**Fix:** Introduce `minExecutionDelay` in `GovernanceConfig`.

### GCORE-002: Governance Owner Has Executor Veto Power

**File:** `Governance.sol:520-536`

The owner (via `Ownable2Step`) controls executors via `addExecutor()`/`removeExecutor()`. The owner can block any proposal execution or selectively execute only favorable proposals. This undermines decentralized governance.

**Fix:** Make execution permissionless (anyone executes succeeded proposals) or require governance proposals to change executor set.

### GCORE-003: StakePool Reentrancy via ETH Transfer

**File:** `StakePool.sol:397-414`

`_withdrawAvailable` sends ETH to `recipient` via low-level `.call{value:}`. The `recipient` can re-enter `unstakeAndWithdraw()` since it lacks `nonReentrant`. While `claimedAmount` is updated, the `_pendingBuckets` state is not compacted, and a reentrant `_unstake` + `_withdrawAvailable` could extract additional funds.

**Fix:** Add `ReentrancyGuard` to all state-changing functions.

---

## HIGH (5)

### GCORE-004: StakingConfig Changes Take Effect Immediately

**File:** `StakingConfig.sol:86-149`

Unlike all other config contracts (ValidatorConfig, EpochConfig, GovernanceConfig, ConsensusConfig, RandomnessConfig), StakingConfig applies governance changes **immediately** rather than at epoch boundaries. TODO comment on line 13 acknowledges this. Immediate `lockupDurationMicros` changes retroactively affect existing pools.

### GCORE-005: Voting Power Increase — PRECISION_FACTOR Self-Cancellation

**File:** `ValidatorManagement.sol:795`

`maxIncrease = (currentTotal * limitPct * PRECISION_FACTOR) / (100 * PRECISION_FACTOR)` — the PRECISION_FACTOR cancels out. Misleading code that could overflow in extreme cases.

### GCORE-006: Epoch Transition O(n²) Complexity

**File:** `ValidatorManagement.sol:572-602`

`evictUnderperformingValidators()` has nested O(n) loops. `_isInPendingInactive()` is O(n) called within O(n) loops. With MAX_VALIDATOR_SET_SIZE = 65536, epoch transitions could exceed block gas limit.

**Fix:** Use mapping for pending-inactive lookup. Maintain active count.

### GCORE-007: GBridgeReceiver Has No Pause Mechanism

**File:** `GBridgeReceiver.sol:20`

`trustedBridge` is `immutable`. If the Ethereum-side bridge is compromised, there's no way to pause the Gravity-side bridge except through governance (requires voting period). During the window, attacker can mint arbitrary native tokens.

### GCORE-008: GravityPortal Excess Fees Not Refunded

**File:** `GravityPortal.sol:113-124`

`send()` requires `msg.value >= fee` but does not refund excess. `withdrawFees()` has no access control — anyone can trigger it.

---

## MEDIUM (8)

### GCORE-009: Consensus Key Rotation Takes Effect Immediately

**File:** `ValidatorManagement.sol:457-464`

`rotateConsensusKey()` updates the key in storage immediately (TODO comment acknowledges it should wait for next epoch). Mid-epoch key rotation could cause consensus failures.

### GCORE-010: Flash Loan Protection at Block Granularity Only

**File:** `Governance.sol:436-441`

Atomicity guard checks `now_ <= lastVote` but Gravity's timestamp only advances per block, not per transaction. Protection works at block level, not transaction level.

### GCORE-011: Genesis Hardcodes Future Date for lockedUntil

**File:** `Genesis.sol:284`

`initialLockedUntil = uint64(1798761600 * 1_000_000) + lockupDuration` — hardcoded to Jan 1, 2027 in microseconds.

### GCORE-012: _pendingBuckets Array Grows Unboundedly

**File:** `StakePool.sol:57,420-445`

Append-only array with MAX_PENDING_BUCKETS=1000 cap but no compaction. Long-lived pools with frequent unstakes hit the cap, permanently blocking further unstake operations.

### GCORE-013: forceLeaveValidatorSet Allows Removing Last Validator

**File:** `ValidatorManagement.sol:401-429`

Documented as intentional for "emergency scenarios" but removing the last validator permanently halts consensus with no recovery mechanism.

### GCORE-014: NativeOracle Callback Gas Limit Unilaterally Controlled

**File:** `NativeOracle.sol:80-100`

`callbackGasLimit` set by SYSTEM_CALLER, not governed on-chain. Consensus engine has unilateral control over callback success.

### GCORE-015: ValidatorPerformanceTracker Unchecked Increment

**File:** `ValidatorPerformanceTracker.sol:70-84`

uint64 counters in `unchecked` blocks. Unnecessary risk removal for negligible gas savings.

### GCORE-016: GovernanceConfig Missing Threshold Validation

**File:** `GovernanceConfig.sol:69-90,119-138`

`_validateConfig()` doesn't validate `minVotingThreshold > 0` or `requiredProposerStake > 0`. Governance could set these to 0, enabling trivial attacks.

---

## LOW (4)

### GCORE-017: Missing Pubkey Length Validation

`ValidatorManagement.sol:271-280` — `BLS12381_PUBKEY_LENGTH = 48` defined but never used in validation.

### GCORE-018: Genesis Skips BLS PoP Verification

`ValidatorManagement.sol:115-164` — Genesis validators bypass all security checks. Mitigated by trusted genesis setup.

### GCORE-019: renewLockUntil Missing Overlock Protection

`StakePool.sol:307-329` — TODO comment acknowledges missing cap. Staker could lock funds for ~584,942 years.

### GCORE-020: Fee Recipient Defaults to Owner, Not Configurable at Registration

`ValidatorManagement.sol:302` — TODO: "fee recipient should be a parameter."

---

## INFO (5)

### GCORE-021: Spec Addresses Diverge from Code Addresses

Spec uses `0x...1625F2xxx` pattern, code uses different prefix ranges.

### GCORE-022: recordBatch blockNumbers Length Not Validated

`NativeOracle.sol:103-129` — Array length mismatch could cause revert.

### GCORE-023: No Pool Creation Limit

`Staking.sol:177` — Unlimited pool creation if `minimumStake` set to 0.

### GCORE-024: StakePool Constructor Doesn't Validate Zero Addresses

`StakePool.sol:104-127` — Zero `_staker` makes funds irrecoverable.

### GCORE-025: No Validator Deregistration Mechanism

`ValidatorManagement.sol` — Registered validators persist forever. Pubkey namespace pollution over time.

---

## Cross-Module Findings

| Finding | Cross-Repo Impact |
|---------|-------------------|
| GCORE-004 (StakingConfig immediate) | Rust consensus reads staking config at epoch boundary — mismatch with immediate Solidity apply |
| GCORE-006 (O(n²) epoch) | gravity-sdk `block_buffer_manager` has no timeout for epoch transition syscall |
| GCORE-007 (no bridge pause) | gravity-reth relayer feeds bridge data with no circuit breaker either |
| GCORE-009 (key rotation timing) | gravity-aptos consensus uses cached keys — mid-epoch rotation causes signature mismatch |
| GCORE-016 (zero thresholds) | A zero `requiredProposerStake` combined with GCORE-001 enables instant hostile governance |

---

## Cumulative Statistics (Rounds 1-3)

| Severity | R1 | R2 | Deep | Total |
|----------|----|----|------|-------|
| CRITICAL | 0 | 0 | 3 | 3 |
| HIGH | 3 | 2 | 5 | 10 |
| MEDIUM | 16 | 6 | 8 | 30 |
| LOW | 24 | 7 | 4 | 35 |
| INFO | 4 | 0 | 5 | 9 |
| **Total** | **47** | **15** | **25** | **~87** |

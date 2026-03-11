# attack_runtime_config_contracts

- **Agent**: intention_attacker
- **Status**: success
- **Duration**: 146101ms
- **Steps**: 1

## Report

Now I have all the code. Here is my red team attack analysis:

---

# Red Team Attack Report: Runtime Configuration Contracts

## Critical Findings

### CRITICAL-01: GovernanceConfig Self-Modification — Governance Can Neuter Itself or Lock Out All Proposals

**File**: `src/runtime/GovernanceConfig.sol:177-191`

**Attack**: The GOVERNANCE contract can call `setForNextEpoch()` to set `minVotingThreshold` to `type(uint128).max` or `requiredProposerStake` to `type(uint256).max`. The only validation is `!= 0`. Once applied at epoch boundary, **no future governance proposal can ever meet quorum or be created**, permanently bricking the governance system.

Similarly, `votingDurationMicros` can be set to `1` (1 microsecond), making it practically impossible for validators to vote before the window closes.

**Impact**: Permanent, irreversible loss of governance. No mechanism exists to override or reset these configs outside governance. The chain would need a hard fork to recover.

**Severity**: **Critical**

---

### CRITICAL-02: VersionConfig Pending Overwrite Bypasses Monotonicity on Second `setForNextEpoch`

**File**: `src/runtime/VersionConfig.sol:97-112`

**Attack**: `setForNextEpoch` validates `_majorVersion > majorVersion` (the **current active** version), NOT against the **pending** version. Scenario:
1. Governance sets pending version to `5` (current is `1`).  
2. Before epoch boundary, governance sets pending version to `2` (still `> 1`).
3. At epoch boundary, version `2` is applied instead of `5`.

This effectively allows a **downgrade** from a previously-committed pending version. While the final applied value is still `> majorVersion`, this breaks the user expectation that version strictly increases through pending configs. A governance attacker who loses control mid-epoch can force a lower version than what the community agreed to.

**Severity**: **High** (downgrades relative to pending intent, though not below current active)

---

### CRITICAL-03: EpochConfig — No Upper Bound Allows Epoch Freeze or Instant Epochs

**File**: `src/runtime/EpochConfig.sol:99-113`

**Attack**: `setForNextEpoch` only checks `_epochIntervalMicros != 0`. Two extremes:
- **Set to 1 microsecond**: Epochs transition on every block, causing massive gas overhead for reconfiguration calls, potentially DoS-ing the chain or making governance proposals expire instantly.
- **Set to `type(uint64).max`** (~584,942 years): Effectively freezes epoch transitions forever. No pending configs will ever be applied again, including governance fixes.

**Impact**: Chain operational disruption or permanent freeze of the config update mechanism.

**Severity**: **High**

---

## High Findings

### HIGH-01: RandomnessConfig — `fastPathSecrecyThreshold` Completely Unvalidated

**File**: `src/runtime/RandomnessConfig.sol:221-231`

**Attack**: For V2 variant, `_validateConfig` only checks `reconstructionThreshold >= secrecyThreshold`. The `fastPathSecrecyThreshold` has **zero validation**:
- Can be `0` — potentially disabling the fast path safety guarantee
- Can be `> reconstructionThreshold` — semantically nonsensical (fast path harder than full path)
- Can be `type(uint128).max` — making fast path unreachable

If the runtime trusts this value for DKG fast-path execution, an attacker (via governance) can set it to break the randomness protocol's liveness or security guarantees.

**Severity**: **High**

---

### HIGH-02: ValidatorConfig — `autoEvictThreshold` Unbounded Can Evict All Validators

**File**: `src/runtime/ValidatorConfig.sol:254-283`

**Attack**: `_validateConfig` does NOT validate `autoEvictThreshold`. Combined with `autoEvictEnabled = true`:
- Setting `autoEvictThreshold = type(uint256).max` would mean **every validator** fails the threshold check (`successfulProposals <= threshold` is always true), triggering mass eviction of the entire validator set at epoch boundary.
- This could halt the chain if no validators remain.

The `autoEvictThreshold` and `autoEvictEnabled` parameters are passed through to storage without any bounds check (lines 137-138).

**Severity**: **High**

---

### HIGH-03: Genesis ETH Accounting — No Validation That `msg.value` Matches Total Stake

**File**: `src/Genesis.sol:134-174, 267-312`

**Attack**: `Genesis.initialize` is `payable` and distributes ETH to validator stake pools via `Staking.createPool{value: v.stakeAmount}()`. However, there is **no check** that `msg.value == sum(validators[i].stakeAmount)`.

- If `msg.value < total`: The transaction reverts due to insufficient balance (safe but undiagnosable).
- If `msg.value > total`: **Excess ETH is permanently trapped** in the Genesis contract. There is no `withdraw()`, no `receive()`, and no fallback. The surplus is unrecoverable.

**Severity**: **High** (irrecoverable fund loss at chain genesis)

---

### HIGH-04: Pending Config Silent Overwrite Across All Config Contracts

**Files**: All 8 config contracts' `setForNextEpoch()` functions.

**Attack**: Every config contract allows `setForNextEpoch()` to be called multiple times before `applyPendingConfig()`. Each call **silently overwrites** the previous pending config with no event indicating the overwrite and no record of the previous value.

Attack scenario: In a governance system where proposals execute sequentially:
1. Proposal A passes: sets `minimumBond = 100 ETH` as pending.
2. Proposal B passes before epoch boundary: silently overwrites to `minimumBond = 1 wei`.
3. At epoch boundary, only Proposal B's values take effect. Voters who approved Proposal A have no indication their config was overwritten.

This is particularly dangerous because the events (`PendingValidatorConfigSet`, etc.) don't include the old values — there's no on-chain record that an overwrite occurred.

**Severity**: **High**

---

## Medium Findings

### MEDIUM-01: ConsensusConfig / ExecutionConfig — No Size Limit on Opaque Bytes

**Files**: `src/runtime/ConsensusConfig.sol`, `src/runtime/ExecutionConfig.sol`

**Attack**: Both contracts accept arbitrary `bytes` with only a `length > 0` check. A governance attacker could submit megabytes of data, causing:
- Excessive storage costs borne by the chain
- Potential DoS if consumers of these configs iterate over the bytes
- No semantic validation means malformed BCS data could crash runtime consumers

**Severity**: **Medium**

---

### MEDIUM-02: Timestamp Has No Initialization Guard — First Block Sets Arbitrary Time Origin

**File**: `src/runtime/Timestamp.sol:67-89`

Unlike all other contracts, `Timestamp` has no `_initialized` flag and no `initialize()` function. The `microseconds` storage starts at `0`. The first `updateGlobalTime()` call with a normal block can set time to any value `> 0`. If the BLOCK contract sends a timestamp far in the future or near zero, this establishes a potentially incorrect time origin for the entire chain, affecting all time-dependent logic (lockups, unbonding, voting durations).

**Severity**: **Medium** (mitigated by BLOCK being a trusted system contract, but no defense-in-depth)

---

### MEDIUM-03: StakingConfig — No Cross-Validation Between `minimumProposalStake` and `minimumStake`

**File**: `src/runtime/StakingConfig.sol`

`minimumProposalStake` can be set lower than `minimumStake`, or `minimumStake` can be raised above `minimumProposalStake` in a subsequent epoch. This means a user could create governance proposals with stake below the minimum staking requirement — a semantic inconsistency that could be exploited depending on how the Governance contract interprets these values.

**Severity**: **Medium**

---

### Summary

| ID | Severity | Finding | Root Cause |
|----|----------|---------|------------|
| CRITICAL-01 | Critical | Governance can permanently brick itself via extreme config values | No upper bounds on GovernanceConfig parameters |
| CRITICAL-02 | High | Version pending overwrite allows effective downgrade | Monotonicity checked against active, not pending |
| CRITICAL-03 | High | Epoch interval extremes can freeze or DoS the chain | No upper/lower bounds on epoch interval |
| HIGH-01 | High | `fastPathSecrecyThreshold` completely unvalidated | Missing validation in `_validateConfig` |
| HIGH-02 | High | `autoEvictThreshold` can evict all validators | Missing bounds check |
| HIGH-03 | High | Excess ETH trapped in Genesis forever | No `msg.value` sum validation or recovery |
| HIGH-04 | High | Silent pending config overwrites across all contracts | No overwrite protection or audit trail |
| MEDIUM-01 | Medium | Unbounded opaque bytes in Consensus/ExecutionConfig | No size limit on bytes input |
| MEDIUM-02 | Medium | Timestamp lacks initialization guard | No `_initialized` pattern |
| MEDIUM-03 | Medium | Cross-config parameter inconsistency possible | No inter-contract validation |

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

--- impl | Now I have all the code. Here is my red team attack analysis | 146101ms |

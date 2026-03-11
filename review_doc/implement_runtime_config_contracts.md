# implement_runtime_config_contracts

- **Agent**: implementation_analyzer
- **Status**: success
- **Duration**: 174028ms
- **Steps**: 1

## Report

Now I have all the code. Here is the complete factual implementation summary:

---

## Implementation Summary: Runtime Configuration Contracts

### Files/Contracts Involved

| File | Contract | Description |
|------|----------|-------------|
| `src/Genesis.sol` | `Genesis` | Single entry point that initializes all 8 config contracts at chain genesis |
| `src/runtime/ValidatorConfig.sol` | `ValidatorConfig` | Validator bonding, set size, auto-eviction parameters |
| `src/runtime/StakingConfig.sol` | `StakingConfig` | Governance staking parameters (lockup, unbonding, minimums) |
| `src/runtime/EpochConfig.sol` | `EpochConfig` | Epoch interval duration |
| `src/runtime/ConsensusConfig.sol` | `ConsensusConfig` | Opaque BCS-serialized consensus parameters |
| `src/runtime/ExecutionConfig.sol` | `ExecutionConfig` | Opaque BCS-serialized VM execution parameters |
| `src/runtime/GovernanceConfig.sol` | `GovernanceConfig` | Governance voting thresholds and durations |
| `src/runtime/VersionConfig.sol` | `VersionConfig` | Protocol major version (monotonic increase) |
| `src/runtime/RandomnessConfig.sol` | `RandomnessConfig` | DKG randomness thresholds (Off/V2 variant) |
| `src/runtime/Timestamp.sol` | `Timestamp` | On-chain microsecond-precision time oracle |
| `src/foundation/SystemAccessControl.sol` | (free functions) | `requireAllowed()` — checks `msg.sender` against allowed address(es) |
| `src/foundation/SystemAddresses.sol` | `SystemAddresses` | Library of compile-time constant system addresses |

---

### Execution Path

#### 1. Genesis Initialization (`Genesis.initialize`)

**Caller restriction**: `requireAllowed(SystemAddresses.SYSTEM_CALLER)` — only `0x...1625F0000` can call.

**Guard**: `_isInitialized` bool prevents re-initialization.

**Sequence**:
1. `_initializeConfigs(params)` — calls `initialize()` on all 8 config contracts
2. `_initializeOracles(...)` — sets up NativeOracle, JWKManager, GBridgeReceiver, OracleTaskConfig
3. `_createPoolsAndValidators(...)` — creates stake pools via `Staking.createPool{value}()`, returns `GenesisValidator[]`
4. `ValidatorManagement.initialize(genesisValidators)`
5. `ValidatorPerformanceTracker.initialize(validatorCount)`
6. `Reconfiguration.initialize()`
7. `Blocker.initialize()`
8. Sets `_isInitialized = true`, emits `GenesisCompleted`

Each config contract's `initialize()` checks `requireAllowed(SystemAddresses.GENESIS)` — meaning `msg.sender` must be the Genesis contract address (`0x...1625F0001`). Since `Genesis._initializeConfigs` calls these contracts directly, `msg.sender` will be the Genesis contract.

---

### Pending Config Pattern (Common to All 8 Config Contracts)

All config contracts follow a uniform 3-function lifecycle:

| Function | Access Control | Purpose |
|----------|---------------|---------|
| `initialize(...)` | `GENESIS` only, once (`_initialized` guard) | Set initial values at chain start |
| `setForNextEpoch(...)` | `GOVERNANCE` only | Queue new config as pending |
| `applyPendingConfig()` | `RECONFIGURATION` only | Apply pending config at epoch boundary |

**Detailed flow**:
- `setForNextEpoch()`: Validates parameters → writes to `_pendingConfig` storage → sets `hasPendingConfig = true` → emits pending event
- `applyPendingConfig()`: If `!hasPendingConfig`, returns (no-op). Otherwise: copies pending values to active state → sets `hasPendingConfig = false` → deletes `_pendingConfig` → emits updated + cleared events

---

### Key Functions Per Contract

#### ValidatorConfig

**`initialize(uint256 _minimumBond, uint256 _maximumBond, uint64 _unbondingDelayMicros, bool _allowValidatorSetChange, uint64 _votingPowerIncreaseLimitPct, uint256 _maxValidatorSetSize, bool _autoEvictEnabled, uint256 _autoEvictThreshold)`**
- Access: `GENESIS`
- Guard: `_initialized` must be false
- Calls `_validateConfig()` then writes all 8 fields

**`setForNextEpoch(...)` — same params**
- Access: `GOVERNANCE`
- Guard: `_requireInitialized()`
- Calls `_validateConfig()`, writes to `_pendingConfig` struct

**`_validateConfig()`** validates:
- `minimumBond > 0`
- `maximumBond >= minimumBond`
- `unbondingDelayMicros > 0` and `<= MAX_UNBONDING_DELAY` (365 days in µs)
- `votingPowerIncreaseLimitPct` in range `[1, 50]`
- `maxValidatorSetSize` in range `[1, 65536]`

**Not validated**: `autoEvictEnabled` and `autoEvictThreshold` — no range checks on these parameters.

#### StakingConfig

**`_validateConfig()`** validates:
- `minimumStake > 0`
- `lockupDurationMicros > 0` and `<= MAX_LOCKUP_DURATION` (4 years in µs)
- `unbondingDelayMicros > 0` and `<= MAX_UNBONDING_DELAY` (1 year in µs)
- `minimumProposalStake > 0`

#### EpochConfig

**`initialize(uint64 _epochIntervalMicros)`**
- Validates: `_epochIntervalMicros > 0`
- No upper bound check on epoch interval

**`setForNextEpoch(uint64 _epochIntervalMicros)`**
- Validates: `_epochIntervalMicros > 0`
- No upper bound check

**`applyPendingConfig()`** — copies `_pendingEpochIntervalMicros` to `epochIntervalMicros`, zeros the pending value, emits `EpochIntervalUpdated(oldValue, newValue)`

#### ConsensusConfig

**`initialize(bytes calldata config)`**
- Validates: `config.length > 0` (non-empty)
- No content validation — opaque bytes stored as-is

**`setForNextEpoch(bytes calldata newConfig)`**
- Validates: `newConfig.length > 0`
- No content validation

#### ExecutionConfig

Identical pattern to ConsensusConfig:
- Validates non-empty bytes only
- No content validation

#### GovernanceConfig

**`_validateConfig()`** validates:
- `minVotingThreshold > 0`
- `requiredProposerStake > 0`
- `votingDurationMicros > 0`
- No upper bounds on any parameter

#### VersionConfig

**`initialize(uint64 _majorVersion)`**
- No validation on initial version value (can be 0)
- Emits `VersionUpdated(0, _majorVersion)`

**`setForNextEpoch(uint64 _majorVersion)`**
- Validates: `_majorVersion > majorVersion` (strictly monotonic increase)
- Emits `PendingVersionSet`

**`applyPendingConfig()`** — copies pending to active, zeros pending, emits `VersionUpdated(old, new)` and `PendingVersionCleared`

#### RandomnessConfig

**Types**: `ConfigVariant` enum (`Off`, `V2`); `ConfigV2Data` struct with 3 `uint128` thresholds; `RandomnessConfigData` wrapping variant + configV2.

**`_validateConfig()`**:
- If variant is `V2`: `reconstructionThreshold >= secrecyThreshold` (otherwise reverts)
- If variant is `Off`: no validation
- `fastPathSecrecyThreshold` is not validated against the other thresholds

**Pure builder functions**: `newOff()` and `newV2(...)` return pre-configured `RandomnessConfigData` structs.

---

### Timestamp Contract (Separate Pattern)

**Not a config contract** — does not use pending config pattern.

**`updateGlobalTime(address proposer, uint64 timestamp)`**
- Access: `SystemAddresses.BLOCK` only
- Two modes based on proposer:
  - **Normal block** (`proposer != SYSTEM_CALLER`): requires `timestamp > current` (strictly advancing). Updates `microseconds` storage. Emits `GlobalTimeUpdated`.
  - **NIL block** (`proposer == SYSTEM_CALLER`): requires `timestamp == current`. No state change, no event.

**View functions**: `nowMicroseconds()` returns raw µs, `nowSeconds()` returns `microseconds / 1_000_000`.

---

### State Changes Summary

| Contract | Storage Written by `initialize` | Storage Written by `setForNextEpoch` | Storage Written by `applyPendingConfig` |
|----------|---|----|-----|
| ValidatorConfig | 8 config fields + `_initialized` | `_pendingConfig` struct + `hasPendingConfig` | 8 config fields, clears `_pendingConfig` + `hasPendingConfig` |
| StakingConfig | 4 config fields + `_initialized` | `_pendingConfig` struct + `hasPendingConfig` | 4 config fields, clears pending |
| EpochConfig | `epochIntervalMicros` + `_initialized` | `_pendingEpochIntervalMicros` + `hasPendingConfig` | `epochIntervalMicros`, zeros pending |
| ConsensusConfig | `_currentConfig` bytes + `_initialized` | `_pendingConfig` bytes + `hasPendingConfig` | `_currentConfig`, deletes pending |
| ExecutionConfig | `_currentConfig` bytes + `_initialized` | `_pendingConfig` bytes + `hasPendingConfig` | `_currentConfig`, deletes pending |
| GovernanceConfig | 3 config fields + `_initialized` | `_pendingConfig` struct + `hasPendingConfig` | 3 config fields, clears pending |
| VersionConfig | `majorVersion` + `_initialized` | `_pendingMajorVersion` + `hasPendingConfig` | `majorVersion`, zeros pending |
| RandomnessConfig | `_currentConfig` struct + `_initialized` | `_pendingConfig` struct + `hasPendingConfig` | `_currentConfig`, deletes pending |
| Timestamp | `microseconds` (on each normal block) | N/A | N/A |

---

### Access Control Map

| Caller Address | Role | Can Call |
|---|---|---|
| `SYSTEM_CALLER` (0x...F0000) | VM/runtime | `Genesis.initialize()` |
| `GENESIS` (0x...F0001) | Genesis contract | All config `initialize()` functions |
| `GOVERNANCE` (0x...F3000) | Governance contract | All config `setForNextEpoch()` functions |
| `RECONFIGURATION` (0x...F2003) | Reconfiguration contract | All config `applyPendingConfig()` functions |
| `BLOCK` (0x...F2004) | Block handler | `Timestamp.updateGlobalTime()` |

The `requireAllowed()` function (free function in `SystemAccessControl.sol`) performs a direct `msg.sender` equality check against the allowed address, reverting with `NotAllowed(caller, allowed)` on mismatch.

---

### External Dependencies

- All contracts import from `foundation/SystemAddresses.sol`, `foundation/SystemAccessControl.sol`, `foundation/Errors.sol`
- `Timestamp` additionally implements `ITimestamp` and `ITimestampWriter` interfaces
- `Genesis` imports and calls into: `Staking`, `ValidatorManagement`, `Reconfiguration`, `Blocker`, `ValidatorPerformanceTracker`, `NativeOracle`, `JWKManager`, `OracleTaskConfig`, `GBridgeReceiver`
- `Genesis._createPoolsAndValidators` sends ETH via `Staking.createPool{value: v.stakeAmount}()`

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

task_int | Now I have all the code. Here is the complete factual implem | 174028ms |

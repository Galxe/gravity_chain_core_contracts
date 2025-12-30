---
status: drafting
owner: @changliang
---

# Randomness Specification

## References

1. Add Aptos's Move contract github link to this spec.
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/dkg.spec.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/reconfiguration_with_dkg.spec.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/configs/randomness_config.spec.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/dkg.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/reconfiguration_with_dkg.move
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/configs/randomness_config.move

2. Governance contract should be able to manage randomness config.
- https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/aptos-release-builder/data/proposals/enable_randomness.move

## Overview

The Randomness module provides secure, verifiable random number generation for the Gravity blockchain using Distributed
Key Generation (DKG). This enables applications to access unpredictable, bias-resistant random values.

**Key Design**: Both `DKG` and `RandomnessConfig` are **pure service contracts** that are orchestrated by `EpochManager`.
They do not contain transition logic themselves - they provide functions that EpochManager calls during epoch transitions.

## Design Goals

1. **Unpredictability**: No party can predict random values before they're revealed
2. **Verifiability**: Anyone can verify randomness was generated correctly
3. **Bias Resistance**: No party can manipulate the random output
4. **Availability**: System remains available even if some validators are offline

---

## TODO: On/Off Support

> **Note**: If we actually want to support turning DKG and randomness off, we will need a holistic design:
>
> 1. **On/Off is an on-chain config** - Can be turned on and off by Governance via `setForNextEpoch()` with `ConfigVariant.Off`
> 2. **EpochManager behavior changes when off** - When randomness is disabled, EpochManager's epoch transition flow must skip DKG-related operations:
>    - Skip calling `DKG.startSession()`
>    - Skip waiting for DKG completion
>    - Skip calling `DKG.finishSession()`
>    - Epoch transitions become simpler (no off-chain DKG coordination needed)
>
> This requires coordination between `RandomnessConfig`, `DKG`, and `EpochManager` contracts.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           Randomness Module                                   │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│                          ┌─────────────────┐                                  │
│                          │  EpochManager   │                                  │
│                          │ (Orchestrator)  │                                  │
│                          └────────┬────────┘                                  │
│                                   │                                           │
│               ┌───────────────────┴───────────────────┐                      │
│               │                                       │                      │
│               ▼                                       ▼                      │
│   ┌───────────────────────────────┐     ┌───────────────────────────────┐   │
│   │       RandomnessConfig        │     │            DKG                │   │
│   │        (Pure Service)         │     │       (Pure Service)          │   │
│   │                               │     │                               │   │
│   │  ┌─────────────┐              │     │  ┌─────────────────┐          │   │
│   │  │   Current   │              │     │  │   In-Progress   │          │   │
│   │  │   Config    │              │     │  │     Session     │          │   │
│   │  └─────────────┘              │     │  └─────────────────┘          │   │
│   │                               │     │                               │   │
│   │  ┌─────────────────────┐      │     │  ┌─────────────────────────┐  │   │
│   │  │      Pending        │      │     │  │    Last Completed       │  │   │
│   │  │ (next epoch config) │      │     │  │       Session           │  │   │
│   │  └─────────────────────┘      │     │  └─────────────────────────┘  │   │
│   │                               │     │                               │   │
│   │  Called by EpochManager:      │     │  Called by EpochManager:      │   │
│   │  - getCurrentConfig()         │     │  - startSession()             │   │
│   │  - applyPendingConfig()       │     │  - finishSession()            │   │
│   │                               │     │  - tryClearIncompleteSession()│   │
│   │  Called by Governance:        │     │  - isInProgress()             │   │
│   │  - setForNextEpoch()          │     │                               │   │
│   └───────────────────────────────┘     └───────────────────────────────┘   │
│                                                                               │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Contract: `RandomnessConfig`

Stores configuration parameters for the randomness system. This is a **pure service contract** - it holds state and
provides functions, but does not orchestrate any transitions.

### Configuration

```solidity
enum ConfigVariant {
    Off,    // Randomness disabled
    V2      // Active configuration with fast path threshold
}

struct ConfigV2 {
    FixedPoint64 secrecyThreshold;
    FixedPoint64 reconstructionThreshold;
    FixedPoint64 fastPathSecrecyThreshold;  // For optimistic path
}

struct RandomnessConfigData {
    ConfigVariant variant;
    ConfigV2 configV2;
}
```

### Threshold Meaning

| Threshold         | Purpose                  | Typical Value |
| ----------------- | ------------------------ | ------------- |
| Secrecy           | Min stake to keep secret | 50% + 1       |
| Reconstruction    | Min stake to reveal      | 50% + 1       |
| Fast Path Secrecy | For optimistic execution | 66%           |

### Interface

```solidity
interface IRandomnessConfig {
    // ========== Queries ==========

    /// @notice Check if randomness is enabled
    function enabled() external view returns (bool);

    /// @notice Get current config (called by EpochManager)
    function getCurrentConfig() external view returns (RandomnessConfigData memory);

    /// @notice Get pending config for next epoch
    function getPendingConfig() external view returns (bool hasPending, RandomnessConfigData memory config);

    /// @notice Check if initialized
    function isInitialized() external view returns (bool);

    // ========== Config Updates (Governance) ==========

    /// @notice Set config for next epoch (governance only)
    /// @dev Config will be applied at next epoch transition
    function setForNextEpoch(RandomnessConfigData memory newConfig) external;

    // ========== Epoch Transition (EpochManager Only) ==========

    /// @notice Apply pending config (called by EpochManager during transition)
    /// @dev Moves pending config to current config
    function applyPendingConfig() external;

    // ========== Initialization ==========

    /// @notice Initialize with config (genesis only)
    function initialize(RandomnessConfigData memory config) external;

    // ========== Config Builders (Pure Functions) ==========

    /// @notice Create a V2 config
    function newV2(
        FixedPoint64 memory secrecyThreshold,
        FixedPoint64 memory reconstructionThreshold,
        FixedPoint64 memory fastPathSecrecyThreshold
    ) external pure returns (RandomnessConfigData memory);
}
```

### Events

```solidity
/// @notice Emitted when config is applied (at epoch transition)
event ConfigUpdated(
    RandomnessConfigData oldConfig,
    RandomnessConfigData newConfig
);

/// @notice Emitted when pending config is set (by governance)
event PendingConfigSet(
    RandomnessConfigData config
);
```

### Errors

```solidity
error NotInitialized();
error AlreadyInitialized();
error InvalidConfigVariant();
error NotAuthorized(address caller);
error NoPendingConfig();
```

### Implementation Notes

```solidity
function applyPendingConfig() external onlyEpochManager {
    if (!hasPendingConfig) {
        // No pending config, nothing to apply
        return;
    }

    RandomnessConfigData memory oldConfig = currentConfig;
    currentConfig = pendingConfig;
    hasPendingConfig = false;

    emit ConfigUpdated(oldConfig, currentConfig);
}
```

---

## Contract: `DKG`

Manages Distributed Key Generation sessions. This is a **pure service contract** that provides DKG operations,
orchestrated by `EpochManager`.

### DKG Session Lifecycle

```
                        startSession()
                        (called by EpochManager)
┌──────────────┐ ─────────────────────────────────────▶ ┌──────────────┐
│   No Active  │                                        │  In Progress │
│   Session    │                                        │              │
└──────────────┘                                        └──────┬───────┘
       ▲                                                       │
       │                                      finishSession(transcript)
       │                                      (called by EpochManager)
       │                                                       │
       │         tryClearIncompleteSession()                   ▼
       └──────────────────────────────────────────────  ┌──────────────┐
                                                        │  Completed   │
                                                        └──────────────┘
```

### Data Structures

```solidity
struct FixedPoint64 {
    uint128 value;    // Fixed-point representation (value / 2^64)
}

struct ValidatorConsensusInfo {
    bytes validatorAddress;   // Validator identifier
    bytes pkBytes;            // Public key bytes
    uint64 votingPower;       // Voting power
}

struct DKGSessionMetadata {
    uint64 dealerEpoch;                              // Epoch running DKG
    RandomnessConfigData randomnessConfig;           // Config for this session
    ValidatorConsensusInfo[] dealerValidatorSet;     // Current validators (dealers)
    ValidatorConsensusInfo[] targetValidatorSet;     // Next epoch validators (targets)
}

struct DKGSessionState {
    DKGSessionMetadata metadata;
    uint64 startTimeUs;           // Start timestamp (microseconds)
    bytes transcript;             // DKG transcript (set on completion)
}

struct DKGState {
    DKGSessionState inProgress;     // Current session if any
    DKGSessionState lastCompleted;  // Last completed session
    bool hasInProgress;
    bool hasLastCompleted;
}
```

### Interface

```solidity
interface IDKG {
    // ========== Session Management (Called by EpochManager) ==========

    /// @notice Start a new DKG session
    /// @dev Called by EpochManager.checkAndStartTransition()
    /// @param dealerEpoch Current epoch number
    /// @param randomnessConfig Randomness configuration for this session
    /// @param dealerValidatorSet Current validators who will run DKG
    /// @param targetValidatorSet Next epoch validators who will receive keys
    function startSession(
        uint64 dealerEpoch,
        RandomnessConfigData memory randomnessConfig,
        ValidatorConsensusInfo[] memory dealerValidatorSet,
        ValidatorConsensusInfo[] memory targetValidatorSet
    ) external;

    /// @notice Complete a DKG session with the generated transcript
    /// @dev Called by EpochManager.finishTransition()
    /// @param transcript The DKG transcript from consensus engine
    function finishSession(bytes memory transcript) external;

    /// @notice Clear an incomplete session
    /// @dev Called by EpochManager to clean up stale sessions
    function tryClearIncompleteSession() external;

    // ========== Queries ==========

    /// @notice Check if DKG is in progress
    function isInProgress() external view returns (bool);

    /// @notice Get the incomplete session if any
    function getIncompleteSession() external view returns (bool hasSession, DKGSessionState memory session);

    /// @notice Get the last completed session
    function getLastCompletedSession() external view returns (bool hasSession, DKGSessionState memory session);

    /// @notice Get dealer epoch from a session
    function sessionDealerEpoch(DKGSessionState memory session) external pure returns (uint64);

    // ========== Initialization ==========

    /// @notice Initialize the DKG contract (genesis only)
    function initialize() external;
}
```

### Events

```solidity
/// @notice Emitted when DKG session starts
/// @dev Consensus engine listens for this event to start off-chain DKG
event DKGStartEvent(
    DKGSessionMetadata metadata,
    uint64 startTimeUs
);

/// @notice Emitted when DKG session completes
event DKGCompleted(
    uint64 indexed dealerEpoch,
    bytes32 transcriptHash
);

/// @notice Emitted when incomplete session is cleared
event DKGSessionCleared(
    uint64 indexed dealerEpoch
);
```

### Errors

```solidity
error DKGInProgress();
error DKGNotInProgress();
error DKGNotInitialized();
error NotAuthorized(address caller);
error InvalidTranscript();
```

### Implementation Notes

```solidity
function startSession(
    uint64 dealerEpoch,
    RandomnessConfigData memory randomnessConfig,
    ValidatorConsensusInfo[] memory dealerValidatorSet,
    ValidatorConsensusInfo[] memory targetValidatorSet
) external onlyEpochManager {
    // Cannot start if already in progress
    if (state.hasInProgress) {
        revert DKGInProgress();
    }

    // Create session metadata
    DKGSessionMetadata memory metadata = DKGSessionMetadata({
        dealerEpoch: dealerEpoch,
        randomnessConfig: randomnessConfig,
        dealerValidatorSet: dealerValidatorSet,
        targetValidatorSet: targetValidatorSet
    });

    // Create session state
    uint64 startTime = uint64(ITimestamp(TIMESTAMP_ADDR).nowMicros());
    state.inProgress = DKGSessionState({
        metadata: metadata,
        startTimeUs: startTime,
        transcript: ""
    });
    state.hasInProgress = true;

    // Emit event for consensus engine to listen
    emit DKGStartEvent(metadata, startTime);
}

function finishSession(bytes memory transcript) external onlyEpochManager {
    if (!state.hasInProgress) {
        revert DKGNotInProgress();
    }

    // Store transcript
    state.inProgress.transcript = transcript;

    // Move to completed
    state.lastCompleted = state.inProgress;
    state.hasLastCompleted = true;

    uint64 dealerEpoch = state.inProgress.metadata.dealerEpoch;

    // Clear in-progress
    delete state.inProgress;
    state.hasInProgress = false;

    emit DKGCompleted(dealerEpoch, keccak256(transcript));
}

function tryClearIncompleteSession() external onlyEpochManager {
    if (!state.hasInProgress) {
        return; // Nothing to clear
    }

    uint64 dealerEpoch = state.inProgress.metadata.dealerEpoch;

    delete state.inProgress;
    state.hasInProgress = false;

    emit DKGSessionCleared(dealerEpoch);
}
```

---

## Coordination Flow with EpochManager

The `DKG` and `RandomnessConfig` contracts are coordinated by `EpochManager` during epoch transitions:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    EPOCH TRANSITION COORDINATION                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   Blocker.onBlockStart()                                                     │
│         │                                                                    │
│         └─► EpochManager.checkAndStartTransition()                          │
│                    │                                                         │
│                    │  1. Check time elapsed && state == Idle                │
│                    │                                                         │
│                    ├─► RandomnessConfig.getCurrentConfig()                  │
│                    │   └─► Returns current randomness configuration         │
│                    │                                                         │
│                    ├─► ValidatorManager.getCurrentConsensusInfos()          │
│                    ├─► ValidatorManager.getNextConsensusInfos()             │
│                    │                                                         │
│                    ├─► DKG.tryClearIncompleteSession()                      │
│                    │   └─► Clears any stale session                         │
│                    │                                                         │
│                    └─► DKG.startSession(epoch, config, dealers, targets)    │
│                        └─► Emits DKGStartEvent for consensus engine         │
│                                                                              │
│   [OFF-CHAIN: Consensus engine performs DKG]                                 │
│                                                                              │
│   Consensus Engine calls:                                                    │
│   EpochManager.finishTransition(dkgResult)                                  │
│                    │                                                         │
│                    ├─► DKG.finishSession(dkgResult)                         │
│                    │   └─► Stores transcript, emits DKGCompleted            │
│                    │                                                         │
│                    ├─► DKG.tryClearIncompleteSession()                      │
│                    │                                                         │
│                    ├─► RandomnessConfig.applyPendingConfig()                │
│                    │   └─► Moves pending config to current                  │
│                    │                                                         │
│                    ├─► currentEpoch++                                       │
│                    │                                                         │
│                    └─► ValidatorManager.onNewEpoch()                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Access Control

### RandomnessConfig

| Function              | Caller        | Rationale                              |
| --------------------- | ------------- | -------------------------------------- |
| `initialize()`        | Genesis       | One-time initialization                |
| `getCurrentConfig()`  | Anyone        | Read-only                              |
| `getPendingConfig()`  | Anyone        | Read-only                              |
| `enabled()`           | Anyone        | Read-only                              |
| `setForNextEpoch()`   | Governance    | Config changes require governance      |
| `applyPendingConfig()`| EpochManager  | Only during epoch transition           |

### DKG

| Function                      | Caller        | Rationale                              |
| ----------------------------- | ------------- | -------------------------------------- |
| `initialize()`                | Genesis       | One-time initialization                |
| `startSession()`              | EpochManager  | Only during epoch transition start     |
| `finishSession()`             | EpochManager  | Only during epoch transition finish    |
| `tryClearIncompleteSession()` | EpochManager  | Only EpochManager manages sessions     |
| `isInProgress()`              | Anyone        | Read-only                              |
| `getIncompleteSession()`      | Anyone        | Read-only                              |
| `getLastCompletedSession()`   | Anyone        | Read-only                              |

---

## Security Considerations

1. **Threshold Security**: Thresholds must be > 50% to prevent single-party control
2. **Session Isolation**: Only one DKG session at a time
3. **Epoch Binding**: Sessions are bound to specific epochs
4. **Validator Verification**: Only registered validators participate
5. **Transcript Verification**: Transcripts verified before acceptance
6. **Single Orchestrator**: Only EpochManager can manage DKG sessions

---

## Invariants

1. At most one DKG session in progress at any time
2. `reconstructionThreshold >= secrecyThreshold`
3. DKG sessions cannot span multiple epochs
4. Completed sessions have non-empty transcripts
5. Config changes only take effect at epoch boundaries
6. Only EpochManager can start/finish DKG sessions

---

## Testing Requirements

### Unit Tests

- Config creation and validation
- Config variant handling (V2, Off)
- DKG session lifecycle (start → finish)
- DKG session clearing
- Pending config management

### Integration Tests

- Full DKG flow with epoch transitions
- Config updates across epochs
- Validator set changes during DKG

### Fuzz Tests

- Random threshold values
- Random session timing
- Random config variants

### Invariant Tests

- Session uniqueness (only one in progress)
- Threshold ordering (reconstruction >= secrecy)
- Epoch binding (session epoch matches current)
- Config application timing

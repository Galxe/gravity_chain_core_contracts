---
status: drafting
owner: @yxia
---

# Epoch Manager Specification

## Overview

The Epoch Manager is the **central orchestrator** for the epoch lifecycle of the Gravity consensus algorithm. An epoch
is a fixed time period during which the validator set remains stable. At epoch boundaries, the validator set can change
and accumulated state transitions occur.

**Key Principle**: EpochManager owns the entire epoch transition lifecycle, coordinating DKG, configuration updates,
and validator set changes. Other contracts (DKG, ValidatorManager, RandomnessConfig) provide supporting functions.

## Design Goals

1. **Single Orchestrator**: EpochManager owns all epoch transition logic
2. **Time-based Epochs**: Epochs are defined by duration, not block count
3. **Explicit State Machine**: Clear transition states (Idle, DkgInProgress)
4. **DKG Synchronization**: Epoch transitions are gated by DKG completion
5. **Configurable Duration**: Epoch length can be adjusted via governance

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         EPOCH MANAGER ARCHITECTURE                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                            ┌─────────────┐                                  │
│                            │   Blocker   │                                  │
│                            │ (Entry Point)│                                 │
│                            └──────┬──────┘                                  │
│                                   │                                         │
│                                   │ checkAndStartTransition()               │
│                                   │ (single entry point)                    │
│                                   │                                         │
│                                   ▼                                         │
│           ┌────────────────────────────────────────────┐                    │
│           │              EpochManager                   │                   │
│           │         (Central Orchestrator)              │                   │
│           │                                             │                   │
│           │  State:                                     │                   │
│           │    - currentEpoch                           │                   │
│           │    - lastEpochTransitionTime                │                   │
│           │    - epochIntervalMicros                    │                   │
│           │    - transitionState                        │                   │
│           │                                             │                   │
│           │  Entry Points:                              │                   │
│           │    - checkAndStartTransition() ← Blocker   │                    │
│           │    - finishTransition()        ← Consensus │                    │
│           └───────────────────┬────────────────────────┘                    │
│                               │                                             │
│          ┌────────────────────┼────────────────────┐                        │
│          │                    │                    │                        │
│          ▼                    ▼                    ▼                        │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐              │
│   │     DKG      │    │ Validator    │    │  Randomness      │              │
│   │  (Service)   │    │   Manager    │    │    Config        │              │
│   │              │    │  (Service)   │    │   (Service)      │              │
│   │ startSession │    │ getConsensus │    │ getCurrentConfig │              │
│   │ finishSession│    │   Infos()    │    │ applyPending     │              │
│   │ isInProgress │    │ onNewEpoch() │    │   Config()       │              │
│   └──────────────┘    └──────────────┘    └──────────────────┘              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Transition State Machine

EpochManager owns an explicit transition state machine:

```
                    checkAndStartTransition()
                    (time elapsed, state == Idle)
┌─────────────┐ ─────────────────────────────────────▶ ┌──────────────────┐
│             │                                         │                  │
│    IDLE     │                                         │  DKG_IN_PROGRESS │
│             │                                         │                  │
│ (waiting    │ ◀───────────────────────────────────── │ (waiting for     │
│  for time)  │       finishTransition()                │  consensus)      │
└─────────────┘                                         └──────────────────┘
```

**States:**
- **Idle**: No transition in progress. Waiting for epoch interval to elapse.
- **DkgInProgress**: DKG has been started. Waiting for consensus engine to complete DKG and call `finishTransition()`.

---

## End-to-End Flow

### Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        EPOCH TRANSITION LIFECYCLE                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ PHASE 1: DETECTION & DKG START (Single Call from Blocker)           │    │
│  │                                                                      │    │
│  │   Blocker.onBlockStart()                                             │    │
│  │     │                                                                │    │
│  │     ├── Update timestamp                                             │    │
│  │     ├── Update performance                                           │    │
│  │     │                                                                │    │
│  │     └── EpochManager.checkAndStartTransition()                      │    │
│  │              │                                                       │    │
│  │              ├── Check: canTransition() && state == Idle?           │    │
│  │              │     └── If NO → return false                         │    │
│  │              │                                                       │    │
│  │              ├── ValidatorManager.getCurrentConsensusInfos()        │    │
│  │              ├── ValidatorManager.getNextConsensusInfos()           │    │
│  │              ├── RandomnessConfig.getCurrentConfig()                 │    │
│  │              │                                                       │    │
│  │              ├── DKG.tryClearIncompleteSession()                    │    │
│  │              ├── DKG.startSession(epoch, config, dealers, targets)  │    │
│  │              │     └── Emits DKGStartEvent                          │    │
│  │              │                                                       │    │
│  │              ├── transitionState = DkgInProgress                    │    │
│  │              └── Emit EpochTransitionStarted                        │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                         [OFF-CHAIN: Consensus Engine runs DKG]               │
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ PHASE 2: FINISH TRANSITION (Single Call from Consensus Engine)       │    │
│  │                                                                      │    │
│  │   EpochManager.finishTransition(dkgResult)                          │    │
│  │              │                                                       │    │
│  │              ├── Validate: state == DkgInProgress                   │    │
│  │              │                                                       │    │
│  │              ├── DKG.finishSession(dkgResult) (if result provided)  │    │
│  │              ├── DKG.tryClearIncompleteSession()                    │    │
│  │              │                                                       │    │
│  │              ├── RandomnessConfig.applyPendingConfig()              │    │
│  │              │                                                       │    │
│  │              ├── ValidatorManager.onNewEpoch()                      │    │
│  │              │     ├── Process stake transitions                    │    │
│  │              │     ├── Activate pending validators                  │    │
│  │              │     ├── Remove inactive validators                   │    │
│  │              │     ├── Recalculate validator set                    │    │
│  │              │     └── Emit ValidatorSetUpdated                     │    │
│  │              │                                                       │    │
│  │              ├── currentEpoch++                                     │    │
│  │              ├── lastEpochTransitionTime = nowSeconds()             │    │
│  │              │                                                       │    │
│  │              ├── transitionState = Idle                             │    │
│  │              └── Emit EpochTransitioned                             │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Sequence Diagram

```
    Block N (epoch boundary)                        Block N+1 (new epoch)
    ─────────────────────────                       ─────────────────────
           │                                               │
    ┌──────┴──────┐                                 ┌──────┴──────┐
    │   Blocker   │                                 │   Blocker   │
    └──────┬──────┘                                 └──────┬──────┘
           │                                               │
           │ onBlockStart()                                │ onBlockStart()
           │                                               │
           ├─► Timestamp.updateGlobalTime()                ├─► Timestamp.updateGlobalTime()
           ├─► PerformanceTracker.update()                 ├─► PerformanceTracker.update()
           │                                               │
           └─► EpochManager.checkAndStartTransition()      └─► EpochManager.checkAndStartTransition()
                     │                                               │
                     │ (time elapsed, starts DKG)                    │ (returns false, in progress)
                     │                                               │
                     ├─► DKG.startSession()                          │
                     │   └─► Emit DKGStartEvent                      │
                     │                                               │
                     │   [Consensus engine runs DKG off-chain]       │
                     │                                               │
                     └─► [DKG completes]                             │
                               │                                     │
                               ▼                                     │
                     EpochManager.finishTransition(result)           │
                               │                                     │
                               ├─► RandomnessConfig.applyPending()   │
                               ├─► ValidatorManager.onNewEpoch()     │
                               │         │                           │
                               │         └─► Emit ValidatorSetUpdated│
                               └─► currentEpoch++                    │
```

---

## Contract: `EpochManager`

### State Variables

```solidity
/// @notice Transition states
enum TransitionState {
    Idle,           // No transition in progress, waiting for time
    DkgInProgress   // DKG started, waiting for completion
}

/// @notice Current epoch number (starts at 0)
uint256 public currentEpoch;

/// @notice Epoch interval in microseconds
uint256 public epochIntervalMicros;

/// @notice Timestamp of last epoch transition (in seconds)
uint256 public lastEpochTransitionTime;

/// @notice Current transition state
TransitionState public transitionState;

/// @notice Epoch when transition was started (for validation)
uint256 public transitionStartedAtEpoch;
```

### Default Configuration

| Parameter             | Default Value       | Description       |
| --------------------- | ------------------- | ----------------- |
| `epochIntervalMicros` | 2 hours × 1,000,000 | Epoch duration    |
| `currentEpoch`        | 0                   | Starting epoch    |
| `transitionState`     | Idle                | Initial state     |

### Interface

```solidity
interface IEpochManager {
    // ========== Epoch Queries ==========

    /// @notice Get current epoch number
    function currentEpoch() external view returns (uint256);

    /// @notice Get current epoch info
    /// @return epoch Current epoch number
    /// @return lastTransitionTime Timestamp of last transition
    /// @return interval Epoch interval in microseconds
    function getCurrentEpochInfo() external view returns (
        uint256 epoch,
        uint256 lastTransitionTime,
        uint256 interval
    );

    /// @notice Get remaining time until next epoch
    /// @return remainingTime Seconds until next epoch (0 if ready to transition)
    function getRemainingTime() external view returns (uint256);

    /// @notice Check if epoch transition can be triggered (time-based)
    /// @return True if current time >= next epoch boundary
    function canTriggerEpochTransition() external view returns (bool);

    /// @notice Check if transition is in progress
    function isTransitionInProgress() external view returns (bool);

    /// @notice Get current transition state
    function getTransitionState() external view returns (TransitionState);

    // ========== Transition Control ==========

    /// @notice Check and start epoch transition if conditions are met
    /// @dev Called by Blocker at each block. Starts DKG if time has elapsed.
    /// @return started True if DKG was started
    function checkAndStartTransition() external returns (bool started);

    /// @notice Finish epoch transition after DKG completes
    /// @dev Called by consensus engine (system caller) after DKG completes
    /// @param dkgResult The DKG transcript (empty bytes if DKG disabled)
    function finishTransition(bytes calldata dkgResult) external;

    // ========== Initialization ==========

    /// @notice Initialize the contract (genesis only)
    function initialize() external;

    // ========== Configuration ==========

    /// @notice Update epoch parameters (governance only)
    /// @param key Parameter key (use predefined constants)
    /// @param value New value (abi encoded)
    function updateParam(bytes32 key, bytes calldata value) external;
}
```

### Events

```solidity
/// @notice Emitted when epoch transition starts (DKG initiated)
event EpochTransitionStarted(
    uint256 indexed epoch
);

/// @notice Emitted when epoch transition completes
event EpochTransitioned(
    uint256 indexed newEpoch,
    uint256 transitionTime
);

/// @notice Emitted when epoch duration is updated
event EpochDurationUpdated(
    uint256 oldDuration,
    uint256 newDuration
);

/// @notice Emitted when a module notification fails (non-fatal)
event ModuleNotificationFailed(
    address indexed module,
    bytes reason
);
```

### Errors

```solidity
/// @notice Epoch transition not ready yet (time not elapsed)
error EpochTransitionNotReady();

/// @notice Invalid epoch duration (must be > 0)
error InvalidEpochDuration();

/// @notice Transition already in progress
error TransitionAlreadyInProgress();

/// @notice No transition in progress to finish
error NoTransitionInProgress();

/// @notice Epoch mismatch (transition started in different epoch)
error EpochMismatch(uint256 expected, uint256 actual);

/// @notice Not authorized to call this function
error NotAuthorized(address caller);

/// @notice Unknown parameter
error ParameterNotFound(bytes32 key);
```

---

## Implementation

### checkAndStartTransition

Called by Blocker every block. Orchestrates the start of epoch transition.

```solidity
function checkAndStartTransition() external onlyBlocker returns (bool started) {
    // 1. Skip if already in progress
    if (transitionState == TransitionState.DkgInProgress) {
        return false;
    }

    // 2. Check if time has elapsed
    if (!_canTransition()) {
        return false;
    }

    // 3. Get validator consensus infos from ValidatorManager
    ValidatorConsensusInfo[] memory currentVals =
        IValidatorManager(VALIDATOR_MANAGER_ADDR).getCurrentConsensusInfos();
    ValidatorConsensusInfo[] memory nextVals =
        IValidatorManager(VALIDATOR_MANAGER_ADDR).getNextConsensusInfos();

    // 4. Get randomness config
    RandomnessConfigData memory config =
        IRandomnessConfig(RANDOMNESS_CONFIG_ADDR).getCurrentConfig();

    // 5. Clear any stale DKG session
    IDKG(DKG_ADDR).tryClearIncompleteSession();

    // 6. Start DKG session - emits DKGStartEvent for consensus engine
    IDKG(DKG_ADDR).startSession(
        uint64(currentEpoch),
        config,
        currentVals,
        nextVals
    );

    // 7. Update state
    transitionState = TransitionState.DkgInProgress;
    transitionStartedAtEpoch = currentEpoch;

    emit EpochTransitionStarted(currentEpoch);
    return true;
}
```

### finishTransition

Called by consensus engine when DKG completes off-chain.

```solidity
function finishTransition(bytes calldata dkgResult) external onlySystemCaller {
    // 1. Validate state
    if (transitionState != TransitionState.DkgInProgress) {
        revert NoTransitionInProgress();
    }
    if (transitionStartedAtEpoch != currentEpoch) {
        revert EpochMismatch(currentEpoch, transitionStartedAtEpoch);
    }

    // 2. Finish DKG session if result provided
    if (dkgResult.length > 0) {
        IDKG(DKG_ADDR).finishSession(dkgResult);
    }
    IDKG(DKG_ADDR).tryClearIncompleteSession();

    // 3. Apply pending configs BEFORE incrementing epoch
    //    This ensures new configs are active for the new epoch's first block
    IRandomnessConfig(RANDOMNESS_CONFIG_ADDR).applyPendingConfig();

    // 4. Notify validator manager to apply changes BEFORE incrementing epoch
    //    ValidatorManager needs to process based on current epoch state
    _safeNotifyModule(VALIDATOR_MANAGER_ADDR);

    // 5. Increment epoch
    uint256 newEpoch = currentEpoch + 1;
    currentEpoch = newEpoch;
    lastEpochTransitionTime = ITimestamp(TIMESTAMP_ADDR).nowSeconds();

    // 6. Reset state
    transitionState = TransitionState.Idle;

    // 7. Emit transition event
    emit EpochTransitioned(newEpoch, lastEpochTransitionTime);
}
```

### Internal Helpers

```solidity
function _canTransition() internal view returns (bool) {
    uint256 currentTime = ITimestamp(TIMESTAMP_ADDR).nowSeconds();
    uint256 epochIntervalSeconds = epochIntervalMicros / 1_000_000;
    return currentTime >= lastEpochTransitionTime + epochIntervalSeconds;
}

function _safeNotifyModule(address moduleAddress) internal {
    if (moduleAddress != address(0)) {
        try IReconfigurableModule(moduleAddress).onNewEpoch() {
            // Success
        } catch Error(string memory reason) {
            emit ModuleNotificationFailed(moduleAddress, bytes(reason));
        } catch (bytes memory lowLevelData) {
            emit ModuleNotificationFailed(moduleAddress, lowLevelData);
        }
    }
}
```

---

## Supporting Contract Interfaces

EpochManager coordinates with these contracts, which provide pure service functions:

### DKG Interface (Called by EpochManager)

```solidity
interface IDKG {
    /// @notice Start a new DKG session
    function startSession(
        uint64 dealerEpoch,
        RandomnessConfigData memory config,
        ValidatorConsensusInfo[] memory dealers,
        ValidatorConsensusInfo[] memory targets
    ) external;

    /// @notice Finish DKG session with transcript
    function finishSession(bytes memory transcript) external;

    /// @notice Clear any incomplete session
    function tryClearIncompleteSession() external;

    /// @notice Check if DKG is in progress
    function isInProgress() external view returns (bool);
}
```

### ValidatorManager Interface (Called by EpochManager)

```solidity
interface IValidatorManager {
    /// @notice Get current validator consensus infos for DKG dealers
    function getCurrentConsensusInfos() external view returns (ValidatorConsensusInfo[] memory);

    /// @notice Get next epoch validator consensus infos for DKG targets
    function getNextConsensusInfos() external view returns (ValidatorConsensusInfo[] memory);

    /// @notice Apply epoch transition - process pending validators
    function onNewEpoch() external;
}
```

### RandomnessConfig Interface (Called by EpochManager)

```solidity
interface IRandomnessConfig {
    /// @notice Get current randomness config
    function getCurrentConfig() external view returns (RandomnessConfigData memory);

    /// @notice Apply pending config for new epoch
    function applyPendingConfig() external;
}
```

### IReconfigurableModule Interface

```solidity
interface IReconfigurableModule {
    /// @notice Called when a new epoch begins
    function onNewEpoch() external;
}
```

---

## Access Control

| Function                      | Caller        | Rationale                                    |
| ----------------------------- | ------------- | -------------------------------------------- |
| `initialize()`                | Genesis only  | One-time initialization                      |
| `currentEpoch()`              | Anyone        | Read-only                                    |
| `getCurrentEpochInfo()`       | Anyone        | Read-only                                    |
| `getRemainingTime()`          | Anyone        | Read-only                                    |
| `canTriggerEpochTransition()` | Anyone        | Read-only                                    |
| `isTransitionInProgress()`    | Anyone        | Read-only                                    |
| `getTransitionState()`        | Anyone        | Read-only                                    |
| `checkAndStartTransition()`   | Blocker only  | Called every block, starts DKG if ready      |
| `finishTransition()`          | System Caller | Called by consensus engine after DKG         |
| `updateParam()`               | Governance    | Parameter changes require governance         |

---

## Configuration Parameters

| Parameter             | Type    | Constraints | Default                 |
| --------------------- | ------- | ----------- | ----------------------- |
| `epochIntervalMicros` | uint256 | > 0         | 7,200,000,000 (2 hours) |

### Parameter Constants

```solidity
bytes32 public constant PARAM_EPOCH_INTERVAL_MICROS = keccak256("epochIntervalMicros");
```

### Parameter Update Implementation

```solidity
function updateParam(bytes32 key, bytes calldata value) external onlyGovernance {
    if (key == PARAM_EPOCH_INTERVAL_MICROS) {
        uint256 newInterval = abi.decode(value, (uint256));
        if (newInterval == 0) revert InvalidEpochDuration();

        uint256 oldInterval = epochIntervalMicros;
        epochIntervalMicros = newInterval;

        emit EpochDurationUpdated(oldInterval, newInterval);
    } else {
        revert ParameterNotFound(key);
    }
}
```

---

## Initialization

At genesis:

```solidity
function initialize() external onlyGenesis {
    currentEpoch = 0;
    epochIntervalMicros = 2 hours * 1_000_000;  // 7,200,000,000 microseconds
    lastEpochTransitionTime = ITimestamp(TIMESTAMP_ADDR).nowSeconds();
    transitionState = TransitionState.Idle;
    transitionStartedAtEpoch = 0;
}
```

---

## ValidatorManager.onNewEpoch() Details

When EpochManager calls `ValidatorManager.onNewEpoch()`, the following operations occur:

```solidity
function onNewEpoch() external onlyEpochManager {
    uint64 epoch = uint64(IEpochManager(EPOCH_MANAGER_ADDR).currentEpoch());
    uint256 minStakeRequired = IStakeConfig(STAKE_CONFIG_ADDR).minValidatorStake();

    // 1. Process all StakeCredit status transitions
    //    - pending_active → active
    _processAllStakeCreditsNewEpoch();

    // 2. Activate pending_active validators
    //    - Based on updated stake data after step 1
    _activatePendingValidators(epoch);

    // 3. Remove pending_inactive validators
    //    - Validators that requested to leave
    _removePendingInactiveValidators(epoch);

    // 4. Recalculate validator set
    //    - Recompute voting powers based on current stakes
    //    - Apply minimum stake requirement
    _recalculateValidatorSet(minStakeRequired, epoch);

    // 5. Notify performance tracker
    IValidatorPerformanceTracker(VALIDATOR_PERFORMANCE_TRACKER_ADDR).onNewEpoch();

    // 6. Reset joining power for new epoch
    validatorSetData.totalJoiningPower = 0;

    // 7. Emit event with new validator set info
    emit ValidatorSetUpdated(
        epoch + 1,
        activeValidators.length(),
        pendingActive.length(),
        pendingInactive.length(),
        validatorSetData.totalVotingPower
    );
}
```

---

## Security Considerations

1. **Single Orchestrator**: Only EpochManager controls epoch transitions
2. **Two Entry Points**: Only Blocker (start) and SystemCaller (finish) can trigger transitions
3. **DKG-Gated**: Cannot complete transition without DKG completion
4. **Explicit State Machine**: TransitionState prevents invalid state changes
5. **Fail-safe Notifications**: Module failures don't block transitions
6. **Time-based**: Uses on-chain timestamp, not manipulable block numbers
7. **Atomic State Updates**: Epoch counter and timestamp update atomically

---

## Chain Downtime Handling

**Question**: What happens when the chain is down for extended periods spanning multiple epochs?

Since epochs are time-based (not block-based), if the chain goes down for a long time:

1. When the chain resumes, `canTriggerEpochTransition()` returns true immediately
2. Only **one** epoch transition occurs, even if multiple epochs worth of time passed
3. `lastEpochTransitionTime` is set to current time, "skipping" missed epochs
4. `currentEpoch` may not accurately reflect actual time passed

**Behavior**: Skip missed epochs, resume from current time. This is acceptable since the chain was down anyway.

---

## Invariants

1. **Monotonic Epoch**: `currentEpoch` only increases
2. **Timestamp Update**: `lastEpochTransitionTime` updates only on transitions
3. **Minimum Interval**: Epoch transitions occur at least `epochIntervalMicros` apart
4. **State Consistency**: `transitionState` is always valid (Idle or DkgInProgress)
5. **DKG Synchronization**: Transition only completes after DKG completes
6. **Notification Guarantee**: `ValidatorManager.onNewEpoch()` is called for every completed transition

---

## Event Emission Order

For a complete epoch transition, events are emitted in this order:

1. `EpochTransitionStarted` (from EpochManager.checkAndStartTransition())
2. `DKGStartEvent` (from DKG.startSession())
3. `DKGCompleted` (from DKG.finishSession(), if transcript provided)
4. `EpochTransitioned` (from EpochManager.finishTransition())
5. `ValidatorSetUpdated` (from ValidatorManager.onNewEpoch())

---

## Testing Requirements

### Unit Tests

- Transition state machine (Idle → DkgInProgress → Idle)
- Time-based transition condition
- Parameter updates (valid/invalid values)
- Access control (unauthorized callers)
- Error conditions (NoTransitionInProgress, TransitionAlreadyInProgress)

### Integration Tests

- Full epoch lifecycle (detection → DKG → transition → validator update)
- Validator set changes across epochs
- Config application timing (before epoch increment)
- Multiple consecutive epoch transitions

### Fuzz Tests

- Random time advances
- Random epoch intervals
- Concurrent calls (should be handled by state machine)

### Invariant Tests

- Epoch monotonicity
- Timing constraints (interval enforcement)
- State consistency
- Notification guarantee

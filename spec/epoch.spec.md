---
status: drafting
owner: @yxia
---

# Epoch Manager Specification

## Overview

The Epoch Manager controls the epoch lifecycle of the Gravity consensus algorithm. An epoch is a fixed time period
during which the validator set remains stable. At epoch boundaries, the validator set can change and accumulated state
transitions occur.

## Design Goals

1. **Time-based Epochs**: Epochs are defined by duration, not block count
2. **Predictable Transitions**: Clear rules for when transitions occur
3. **Coordinated Updates**: Notify all dependent contracts on transition
4. **Configurable Duration**: Epoch length can be adjusted via governance
5. **DKG Synchronization**: Epoch transitions are gated by DKG completion

---

## End-to-End Epoch Transition Flow

The epoch transition is a coordinated process spanning multiple contracts. Understanding this flow is critical
for implementing and debugging the system.

### Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        EPOCH TRANSITION LIFECYCLE                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ PHASE 1: DETECTION (Every Block)                                    │    │
│  │                                                                     │    │
│  │   Blocker.onBlockStart()                                            │    │
│  │     │                                                               │    │
│  │     ├── 1. Update global timestamp                                  │    │
│  │     ├── 2. Update validator performance statistics                  │    │
│  │     └── 3. Check: EpochManager.canTriggerEpochTransition()?        │    │
│  │              │                                                      │    │
│  │              └── If TRUE → ReconfigurationWithDKG.tryStart()       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ PHASE 2: DKG INITIATION                                              │    │
│  │                                                                      │    │
│  │   ReconfigurationWithDKG.tryStart()                                 │    │
│  │     │                                                               │    │
│  │     ├── 1. Check for incomplete DKG session                        │    │
│  │     │     ├── If same epoch → return (already running)             │    │
│  │     │     └── If different epoch → clear old session               │    │
│  │     │                                                               │    │
│  │     ├── 2. Collect validator consensus infos                       │    │
│  │     │     ├── Current validators (dealers)                         │    │
│  │     │     └── Next validators (targets)                            │    │
│  │     │                                                               │    │
│  │     └── 3. DKG.start(epoch, config, currentVals, nextVals)        │    │
│  │              └── Emits DKGStartEvent (signals consensus engine)    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                         [OFF-CHAIN: Consensus Engine runs DKG]               │
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ PHASE 3: DKG COMPLETION                                              │    │
│  │                                                                      │    │
│  │   ReconfigurationWithDKG.finish() / finishWithDkgResult()           │    │
│  │     │                                                               │    │
│  │     ├── 1. DKG.tryClearIncompleteSession()                         │    │
│  │     │                                                               │    │
│  │     ├── 2. _applyOnNewEpochConfigs()                               │    │
│  │     │     └── Apply buffered on-chain configuration changes         │    │
│  │     │                                                               │    │
│  │     └── 3. EpochManager.triggerEpochTransition()                   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ PHASE 4: EPOCH STATE UPDATE                                          │    │
│  │                                                                      │    │
│  │   EpochManager.triggerEpochTransition()                             │    │
│  │     │                                                               │    │
│  │     ├── 1. currentEpoch++                                          │    │
│  │     │                                                               │    │
│  │     ├── 2. lastEpochTransitionTime = nowSeconds()                  │    │
│  │     │                                                               │    │
│  │     ├── 3. _notifySystemModules()                                  │    │
│  │     │     └── ValidatorManager.onNewEpoch()                        │    │
│  │     │                                                               │    │
│  │     └── 4. Emit EpochTransitioned(newEpoch, transitionTime)        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ PHASE 5: VALIDATOR SET RECONFIGURATION                               │    │
│  │                                                                      │    │
│  │   ValidatorManager.onNewEpoch()                                     │    │
│  │     │                                                               │    │
│  │     ├── 1. Process all StakeCredit status transitions              │    │
│  │     │     └── pending_active stakes → active                       │    │
│  │     │                                                               │    │
│  │     ├── 2. Activate pending_active validators                      │    │
│  │     │     └── Based on updated stake data                          │    │
│  │     │                                                               │    │
│  │     ├── 3. Remove pending_inactive validators                      │    │
│  │     │                                                               │    │
│  │     ├── 4. Recalculate validator set                               │    │
│  │     │     └── Based on latest stake data & min stake required      │    │
│  │     │                                                               │    │
│  │     ├── 5. ValidatorPerformanceTracker.onNewEpoch()                │    │
│  │     │                                                               │    │
│  │     ├── 6. Reset totalJoiningPower to 0                            │    │
│  │     │                                                               │    │
│  │     └── 7. Emit ValidatorSetUpdated(...)                           │    │
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
           │                                               │
           ├─► ValidatorPerformanceTracker                 ├─► ValidatorPerformanceTracker
           │   .updatePerformanceStatistics()              │   .updatePerformanceStatistics()
           │                                               │
           ├─► EpochManager.canTriggerEpochTransition()    ├─► EpochManager.canTriggerEpochTransition()
           │   └─► returns TRUE (time elapsed)             │   └─► returns FALSE (recently transitioned)
           │                                               │
           └─► ReconfigurationWithDKG.tryStart()           └─► [no action]
                     │
                     ├─► DKG.start()
                     │   └─► Emit DKGStartEvent
                     │
                     │   [Consensus engine receives event,
                     │    performs DKG off-chain]
                     │
                     └─► [DKG completes off-chain]
                               │
                               ▼
                     ReconfigurationWithDKG.finish()
                               │
                               ├─► _applyOnNewEpochConfigs()
                               │
                               └─► EpochManager.triggerEpochTransition()
                                         │
                                         ├─► currentEpoch = 1
                                         ├─► lastEpochTransitionTime = now
                                         └─► ValidatorManager.onNewEpoch()
                                                   │
                                                   └─► Emit ValidatorSetUpdated()
```

---

## Contract Responsibilities

### Responsibility Matrix

| Contract                 | Detection | DKG Coord | Config Apply | State Update | Val Update |
| ------------------------ | --------- | --------- | ------------ | ------------ | ---------- |
| Blocker                  | ✓         |           |              |              |            |
| ReconfigurationWithDKG   |           | ✓         | ✓            |              |            |
| EpochManager             |           |           |              | ✓            |            |
| ValidatorManager         |           |           |              |              | ✓          |

### Key Design Decision: Config Application Location

> **IMPORTANT**: Configuration changes (like RandomnessConfig updates) are applied in `ReconfigurationWithDKG._applyOnNewEpochConfigs()`, NOT by EpochManager's module notification.

This design means:
- EpochManager only notifies ValidatorManager
- Other configs are applied BEFORE the epoch counter increments
- This ensures new configs are active for the new epoch's first block

---

## Contract: `EpochManager`

### State Variables

```solidity
/// @notice Current epoch number (starts at 0)
uint256 public currentEpoch;

/// @notice Epoch interval in microseconds
uint256 public epochIntervalMicros;

/// @notice Timestamp of last epoch transition (in seconds)
uint256 public lastEpochTransitionTime;
```

### Default Configuration

| Parameter             | Default Value       | Description    |
| --------------------- | ------------------- | -------------- |
| `epochIntervalMicros` | 2 hours × 1,000,000 | Epoch duration |
| `currentEpoch`        | 0                   | Starting epoch |

### Interface

```solidity
interface IEpochManager {
    // ========== Epoch Queries ==========

    /// @notice Get current epoch number
    /// @return Current epoch
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

    /// @notice Check if epoch transition can be triggered
    /// @return True if current time >= next epoch boundary
    function canTriggerEpochTransition() external view returns (bool);

    // ========== State Transitions ==========

    /// @notice Initialize the contract (genesis only)
    function initialize() external;

    /// @notice Trigger epoch transition (authorized callers only)
    function triggerEpochTransition() external;

    // ========== Configuration ==========

    /// @notice Update epoch parameters (governance only)
    /// @param key Parameter key (use predefined constants, e.g., PARAM_EPOCH_INTERVAL_MICROS)
    /// @param value New value
    function updateParam(bytes32 key, bytes calldata value) external;
}
```

### Events

```solidity
/// @notice Emitted when epoch transitions
event EpochTransitioned(
    uint256 indexed newEpoch,
    uint256 transitionTime
);

/// @notice Emitted when epoch duration is updated
event EpochDurationUpdated(
    uint256 oldDuration,
    uint256 newDuration
);

/// @notice Emitted when a module notification fails
event ModuleNotificationFailed(
    address indexed module,
    bytes reason
);
```

### Errors

```solidity
/// @notice Epoch transition not ready yet
error EpochTransitionNotReady();

/// @notice Invalid epoch duration (must be > 0)
error InvalidEpochDuration();

/// @notice Not authorized to trigger transition
error NotAuthorized(address caller);

/// @notice Unknown parameter
error ParameterNotFound(bytes32 key);
```

---

## Epoch Transition Logic

### Transition Condition

```solidity
function canTriggerEpochTransition() external view returns (bool) {
    uint256 currentTime = ITimestamp(TIMESTAMP_ADDR).nowSeconds();
    uint256 epochIntervalSeconds = epochIntervalMicros / 1_000_000;
    return currentTime >= lastEpochTransitionTime + epochIntervalSeconds;
}
```

### Implementation

```solidity
function triggerEpochTransition() external onlyAuthorizedCallers {
    // 1. Increment epoch
    uint256 newEpoch = currentEpoch + 1;
    currentEpoch = newEpoch;

    // 2. Update timestamp
    lastEpochTransitionTime = ITimestamp(TIMESTAMP_ADDR).nowSeconds();

    // 3. Notify system modules
    _notifySystemModules();

    // 4. Emit transition event
    emit EpochTransitioned(newEpoch, lastEpochTransitionTime);
}

/**
 * @dev Notify all system contracts of epoch transition
 * Only notifies ValidatorManager - other configs are applied by ReconfigurationWithDKG
 */
function _notifySystemModules() internal {
    _safeNotifyModule(VALIDATOR_MANAGER_ADDR);
}

/**
 * @dev Safely notify a single module with error handling
 */
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

## Module Notification

### IReconfigurableModule Interface

```solidity
interface IReconfigurableModule {
    /// @notice Called when a new epoch begins
    function onNewEpoch() external;
}
```

### Notified Modules

| Module              | Action on `onNewEpoch()`                            |
| ------------------- | --------------------------------------------------- |
| ValidatorManager    | Process stake transitions, activate/deactivate validators, recalculate set |

> **CLARIFICATION**: Based on the reference implementation, only `ValidatorManager` is notified via `onNewEpoch()`. The `RandomnessConfig` is applied earlier in the flow by `ReconfigurationWithDKG._applyOnNewEpochConfigs()`.

### ValidatorManager.onNewEpoch() Details

```solidity
function onNewEpoch() external onlyEpochManager {
    uint64 currentEpoch = uint64(IEpochManager(EPOCH_MANAGER_ADDR).currentEpoch());
    uint256 minStakeRequired = IStakeConfig(STAKE_CONFIG_ADDR).minValidatorStake();

    // 1. Process all StakeCredit status transitions
    //    - pending_active → active
    _processAllStakeCreditsNewEpoch();

    // 2. Activate pending_active validators
    //    - Based on updated stake data after step 1
    _activatePendingValidators(currentEpoch);

    // 3. Remove pending_inactive validators
    //    - Validators that requested to leave
    _removePendingInactiveValidators(currentEpoch);

    // 4. Recalculate validator set
    //    - Recompute voting powers based on current stakes
    //    - Apply minimum stake requirement
    _recalculateValidatorSet(minStakeRequired, currentEpoch);

    // 5. Notify performance tracker
    IValidatorPerformanceTracker(VALIDATOR_PERFORMANCE_TRACKER_ADDR).onNewEpoch();

    // 6. Reset joining power for new epoch
    validatorSetData.totalJoiningPower = 0;

    // 7. Emit event with new validator set info
    emit ValidatorSetUpdated(
        currentEpoch + 1,  // This will be effective for next epoch
        activeValidators.length(),
        pendingActive.length(),
        pendingInactive.length(),
        validatorSetData.totalVotingPower
    );
}
```

---

## Access Control

### Simplified Access Model

| Function                      | Caller                  | Rationale                                    |
| ----------------------------- | ----------------------- | -------------------------------------------- |
| `initialize()`                | Genesis only            | One-time initialization                      |
| `currentEpoch()`              | Anyone                  | Read-only                                    |
| `getCurrentEpochInfo()`       | Anyone                  | Read-only                                    |
| `getRemainingTime()`          | Anyone                  | Read-only                                    |
| `canTriggerEpochTransition()` | Anyone                  | Read-only                                    |
| `triggerEpochTransition()`    | ReconfigurationWithDKG  | Single authorized caller for DKG sync        |
| `updateParam()`               | Governance only         | Parameter changes require governance         |

> **DESIGN DECISION**: `triggerEpochTransition()` should ONLY be callable by `ReconfigurationWithDKG`. This ensures:
> 1. DKG must complete before epoch transition
> 2. Configs are applied in correct order
> 3. No race conditions between callers
>
> The original implementation allowing multiple callers (System Caller, Blocker, Genesis, ReconfigurationWithDKG) was overly permissive. The consolidated design uses `ReconfigurationWithDKG` as the single orchestrator.

---

## DKG Coordination

### Why DKG Gates Epoch Transitions

Epoch transitions require new cryptographic keys for randomness:
1. Each epoch has validators generate shared keys via DKG
2. The new keys are needed for the new epoch's randomness
3. Therefore, DKG MUST complete before epoch transition

### Timing Diagram

```
Time:     T0          T1              T2              T3
          │           │               │               │
Epoch N:  ├───────────┤               │               │
          │           │               │               │
          │           ▼               │               │
          │    canTransition = true   │               │
          │           │               │               │
DKG:      │           ├───────────────┤               │
          │           │ DKG in progress               │
          │           │ (off-chain)   │               │
          │           │               ▼               │
          │           │        DKG complete           │
          │           │               │               │
Epoch N+1:│           │               ├───────────────┤
          │           │               │ New epoch     │
          │           │               │ (new keys)    │
```

### ReconfigurationWithDKG Flow

```solidity
// Called by Blocker when canTriggerEpochTransition() returns true
function tryStart() external onlyAuthorizedCallers {
    uint256 currentEpoch = IEpochManager(EPOCH_MANAGER_ADDR).currentEpoch();

    // Check for incomplete DKG session
    (bool hasIncomplete, DKGSessionState memory session) = IDKG(DKG_ADDR).incompleteSession();

    if (hasIncomplete) {
        uint64 sessionDealerEpoch = IDKG(DKG_ADDR).sessionDealerEpoch(session);

        // If session is for current epoch, already running - return
        if (sessionDealerEpoch == currentEpoch) {
            return;
        }

        // Clear old session from previous epoch
        IDKG(DKG_ADDR).tryClearIncompleteSession();
    }

    // Gather data for DKG
    ValidatorConsensusInfo[] memory currentValidators = _getCurrentValidatorConsensusInfos();
    ValidatorConsensusInfo[] memory nextValidators = _getNextValidatorConsensusInfos();
    RandomnessConfigData memory randomnessConfig = _getCurrentRandomnessConfig();

    // Start DKG - this emits DKGStartEvent
    IDKG(DKG_ADDR).start(uint64(currentEpoch), randomnessConfig, currentValidators, nextValidators);
}

// Called by consensus engine after DKG completes
function finish() external onlyAuthorizedCallers {
    _finishReconfiguration();
}

function _finishReconfiguration() internal {
    // 1. Clear incomplete DKG session
    IDKG(DKG_ADDR).tryClearIncompleteSession();

    // 2. Apply buffered configs (RandomnessConfig, etc.)
    _applyOnNewEpochConfigs();

    // 3. Trigger the actual epoch transition
    IEpochManager(EPOCH_MANAGER_ADDR).triggerEpochTransition();
}
```

---

## Configuration Parameters

| Parameter             | Type    | Constraints | Default                 |
| --------------------- | ------- | ----------- | ----------------------- |
| `epochIntervalMicros` | uint256 | > 0         | 7,200,000,000 (2 hours) |

### Parameter Update Implementation

> ⚠️ **IMPLEMENTATION RULE**: Use predefined constants for parameter keys, NOT string comparison.

```solidity
bytes32 public constant PARAM_EPOCH_INTERVAL_MICROS = keccak256("epochIntervalMicros");

function updateParam(bytes32 key, bytes calldata value) external onlyGov {
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
}
```

---

## Security Considerations

1. **Single Orchestrator**: Only `ReconfigurationWithDKG` triggers transitions, preventing race conditions
2. **DKG-Gated**: Cannot transition without DKG completion, ensuring cryptographic integrity
3. **Time-based**: Uses on-chain timestamp, not manipulable block numbers
4. **Fail-safe Notifications**: Module failures don't block transitions
5. **No Manual Override**: Cannot force epoch transition before time
6. **Atomic State Updates**: Epoch counter and timestamp update atomically

---

## Open Questions

### Chain Downtime Handling

**Question**: What happens when the chain is down for extended periods spanning multiple epochs?

Since epochs are time-based (not block-based), if the chain goes down for a long time:

1. When the chain resumes, `canTriggerEpochTransition()` returns true immediately
2. Only **one** epoch transition occurs, even if multiple epochs worth of time passed
3. `lastEpochTransitionTime` is set to current time, "skipping" missed epochs
4. `currentEpoch` may not accurately reflect actual time passed

**Current Behavior**: Skip missed epochs, resume from current time.

**Implications**:
- Validator rewards/slashing may need adjustment for downtime
- DKG keys for skipped epochs are never generated
- This is likely acceptable since the chain was down anyway

**Status**: Document as intentional behavior.

---

## Invariants

1. **Monotonic Epoch**: `currentEpoch` only increases
2. **Timestamp Update**: `lastEpochTransitionTime` updates only on transitions
3. **Minimum Interval**: Epoch transitions occur at least `epochIntervalMicros` apart
4. **DKG Synchronization**: Transition only occurs after DKG completes (or is explicitly skipped)
5. **Notification Guarantee**: `ValidatorManager.onNewEpoch()` is called for every transition

---

## Testing Requirements

### Unit Tests

- Epoch transition timing (boundary conditions)
- Parameter updates (valid/invalid values)
- Module notification (success/failure handling)
- Access control (unauthorized callers)

### Integration Tests

- Full epoch lifecycle (detection → DKG → transition → validator update)
- Validator set changes across epochs
- DKG coordination timing
- Config application order

### Fuzz Tests

- Random time advances
- Concurrent transition attempts (should be blocked by design)
- Random epoch intervals

### Invariant Tests

- Epoch monotonicity
- Timing constraints (interval enforcement)
- Notification guarantee

---

## Contract Dependencies

```
                        ┌─────────────────┐
                        │    Blocker      │
                        │ (Entry Point)   │
                        └────────┬────────┘
                                 │
                                 │ 1. Checks canTriggerEpochTransition()
                                 │ 2. Calls tryStart() if true
                                 │
              ┌──────────────────┴───────────────────┐
              │                                      │
              ▼                                      ▼
     ┌────────────────┐                    ┌─────────────────────┐
     │  EpochManager  │◄───────────────────│ ReconfigurationWithDKG │
     │  (State)       │  triggerEpochTransition()  │ (Orchestrator)      │
     └────────┬───────┘                    └──────────┬──────────┘
              │                                       │
              │ onNewEpoch()                          │ start()/finish()
              │                                       │
              ▼                                       ▼
     ┌────────────────┐                    ┌─────────────────┐
     │ ValidatorManager│                    │       DKG       │
     │ (Validator Set) │                    │ (Key Generation)│
     └────────────────┘                    └─────────────────┘
```

---

## Appendix: Event Emission Order

For a complete epoch transition, events are emitted in this order:

1. `DKGStartEvent` (from DKG.start())
2. `DKGCompleted` (from DKG.finish(), if using finishWithDkgResult)
3. `EpochTransitioned` (from EpochManager.triggerEpochTransition())
4. `ValidatorSetUpdated` (from ValidatorManager.onNewEpoch())

This order allows external systems to track the complete transition lifecycle.

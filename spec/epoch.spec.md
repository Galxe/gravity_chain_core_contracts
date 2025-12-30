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

/// @notice Emitted with new validator set after epoch transition
event ValidatorSetUpdated(
    uint256 indexed epoch,
    ValidatorInfo[] validators
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

## Epoch Transition Logic

### Transition Condition

```solidity
function canTriggerEpochTransition() external view returns (bool) {
    uint256 currentTime = ITimestamp(TIMESTAMP).nowSeconds();
    uint256 epochIntervalSeconds = epochIntervalMicros / 1_000_000;
    return currentTime >= lastEpochTransitionTime + epochIntervalSeconds;
}
```

### Transition Process

```
┌─────────────────────────────────────────────────────────┐
│               triggerEpochTransition()                   │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  1. Increment epoch counter                              │
│     └── currentEpoch++                                   │
│                                                          │
│  2. Update transition timestamp                          │
│     └── lastEpochTransitionTime = nowSeconds()          │
│                                                          │
│  3. Notify dependent modules                             │
│     ├── ValidatorManager.onNewEpoch()                   │
│     ├── RandomnessConfig.onNewEpoch()                   │
│     └── (other modules...)                              │
│                                                          │
│  4. Emit ValidatorSetUpdated event                       │
│                                                          │
│  5. Emit EpochTransitioned event                         │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Implementation

```solidity
function triggerEpochTransition() external onlyAuthorizedCallers {
    // 1. Increment epoch
    uint256 newEpoch = currentEpoch + 1;
    currentEpoch = newEpoch;

    // 2. Update timestamp
    lastEpochTransitionTime = ITimestamp(TIMESTAMP).nowSeconds();

    // 3. Notify modules
    _notifyModules();

    // 4. Get and emit new validator set
    ValidatorSet memory validators = IValidatorManager(VALIDATOR_MANAGER).getValidatorSet();
    emit ValidatorSetUpdated(newEpoch, validators);

    // 5. Emit transition event
    emit EpochTransitioned(newEpoch, lastEpochTransitionTime);
}
```

## Module Notification

The epoch manager notifies dependent contracts of epoch transitions:

```solidity
interface IReconfigurableModule {
    /// @notice Called when a new epoch begins
    function onNewEpoch() external;
}
```

### Notified Modules

| Module           | Action on New Epoch                   |
| ---------------- | ------------------------------------- |
| ValidatorManager | Apply pending validator changes       |
| RandomnessConfig | Apply pending config changes          |
| StakeConfig      | Apply pending stake parameter changes |

> ⚠️ **PENDING VERIFICATION**: The reference implementation only notifies `ValidatorManager`. Need to verify if `RandomnessConfig` and `StakeConfig` are actually being notified in the implementation code. Update this table to match actual behavior.

### Safe Notification

Notifications are wrapped to prevent one module from blocking the transition:

```solidity
function _safeNotifyModule(address module) internal {
    try IReconfigurableModule(module).onNewEpoch() {
        // Success
    } catch (bytes memory reason) {
        emit ModuleNotificationFailed(module, reason);
    }
}
```

## Access Control

| Function                      | Caller                                                  |
| ----------------------------- | ------------------------------------------------------- |
| `initialize()`                | Genesis only                                            |
| `currentEpoch()`              | Anyone                                                  |
| `getCurrentEpochInfo()`       | Anyone                                                  |
| `getRemainingTime()`          | Anyone                                                  |
| `canTriggerEpochTransition()` | Anyone                                                  |
| `triggerEpochTransition()`    | System Caller, Blocker, Genesis, ReconfigurationWithDKG |
| `updateParam()`               | Governance only                                         |

> ⚠️ **PENDING**: Why are there so many callers authorized to trigger epoch transition? This seems overly permissive and needs review:
> - **System Caller**: Expected for automated transitions
> - **Blocker**: Why? What scenario requires this?
> - **Genesis**: Understandable for initialization
> - **ReconfigurationWithDKG**: For DKG coordination
>
> **Action**: Review and justify each caller or consolidate to minimal required set.

## Configuration Parameters

| Parameter             | Type    | Constraints | Default                 |
| --------------------- | ------- | ----------- | ----------------------- |
| `epochIntervalMicros` | uint256 | > 0         | 7,200,000,000 (2 hours) |

### Updating Parameters

> ⚠️ **IMPLEMENTATION RULE**: Do NOT use string comparison like `keccak256(bytes(key)) == keccak256("epochIntervalMicros")`. Use predefined constants instead for gas efficiency and type safety:
> ```solidity
> bytes32 public constant PARAM_EPOCH_INTERVAL_MICROS = keccak256("epochIntervalMicros");
> ```

```solidity
// CORRECT implementation using constants:
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

## Relationship with DKG

When DKG is enabled, epoch transitions are coordinated with DKG sessions:

```
┌────────────────┐     ┌────────────────┐     ┌────────────────┐
│ Epoch N        │────▶│ DKG for N+1    │────▶│ Epoch N+1      │
│                │     │ (in progress)  │     │ (new keys)     │
└────────────────┘     └────────────────┘     └────────────────┘
```

The `ReconfigurationWithDKG` contract coordinates:

1. Start DKG when epoch transition is due
2. Wait for DKG to complete
3. Then trigger epoch transition

## Initialization

At genesis:

```solidity
function initialize() external onlyGenesis {
    currentEpoch = 0;
    epochIntervalMicros = 2 hours * 1_000_000;
    lastEpochTransitionTime = ITimestamp(TIMESTAMP).nowSeconds();
}
```

## Security Considerations

1. **Time-based**: Uses on-chain timestamp, not block numbers
2. **Authorized Triggers**: Only specific contracts can trigger transitions
3. **Fail-safe Notifications**: Module failures don't block transitions
4. **No Manual Override**: Cannot force epoch transition before time

## Open Questions

### ⚠️ PENDING: Chain Downtime Handling

**Question**: What happens when the chain is down for extended periods spanning multiple epochs?

Since epochs are time-based (not block-based), if the chain goes down for a long time (e.g., spanning 1, 2, or more epoch intervals), several issues arise:

1. When the chain resumes, `canTriggerEpochTransition()` will return true immediately
2. But only **one** epoch transition will occur, even if multiple epochs worth of time has passed
3. The `lastEpochTransitionTime` will be set to the current time, effectively "skipping" the missed epochs
4. This means `currentEpoch` may not accurately reflect the actual time passed

**Potential concerns**:
- Should we allow catching up multiple epochs?
- Should we emit events for skipped epochs?
- How does this affect validator rewards/slashing calculations?
- How does this affect DKG coordination?

**Status**: Needs design decision and documentation.

## Invariants

1. `currentEpoch` only increases
2. `lastEpochTransitionTime` is updated only on transitions
3. Epoch transitions occur at least `epochIntervalMicros` apart

## Testing Requirements

1. **Unit Tests**:

   - Epoch transition timing
   - Parameter updates
   - Module notification

2. **Integration Tests**:

   - Full epoch lifecycle
   - Validator set changes across epochs
   - DKG coordination

3. **Fuzz Tests**:

   - Random time advances
   - Concurrent transition attempts

4. **Invariant Tests**:
   - Epoch monotonicity
   - Timing constraints

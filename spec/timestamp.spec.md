# Timestamp Specification

## Overview

The Timestamp contract provides on-chain time management with microsecond precision. It serves as the single source of
truth for the current blockchain time and is updated exclusively by the block producer during block prologue.

## Design Goals

1. **Microsecond Precision**: Time is stored in microseconds for high precision
2. **Monotonic**: Time can only advance forward (except for NIL blocks)
3. **Protected Updates**: Only the Blocker contract can update time
4. **Simple Interface**: Easy to query current time

## Contract: `Timestamp`

### State Variables

```solidity
/// @notice Current time in microseconds since epoch
uint64 public microseconds;

/// @notice Conversion factor from seconds to microseconds
uint64 public constant MICRO_CONVERSION_FACTOR = 1_000_000;
```

### Interface

```solidity
interface ITimestamp {
    // ========== Time Queries ==========

    /// @notice Get current time in microseconds
    /// @return Current timestamp in microseconds
    function nowMicroseconds() external view returns (uint64);

    /// @notice Get current time in seconds
    /// @return Current timestamp in seconds
    function nowSeconds() external view returns (uint64);

    /// @notice Get detailed time information
    /// @return currentMicroseconds Current time in microseconds
    /// @return currentSeconds Current time in seconds
    /// @return blockTimestamp EVM block.timestamp for reference
    function getTimeInfo() external view returns (
        uint64 currentMicroseconds,
        uint64 currentSeconds,
        uint256 blockTimestamp
    );

    /// @notice Check if a timestamp is >= current time
    /// @param timestamp Timestamp to check (in microseconds)
    /// @return True if timestamp >= current time
    function isGreaterThanOrEqualCurrentTimestamp(uint64 timestamp) external view returns (bool);

    // ========== Protected Functions ==========

    /// @notice Initialize the contract (genesis only)
    function initialize() external;

    /// @notice Update the global time (Blocker only)
    /// @param proposer The block proposer address
    /// @param timestamp New timestamp in microseconds
    function updateGlobalTime(address proposer, uint64 timestamp) external;
}
```

### Events

```solidity
/// @notice Emitted when global time is updated
/// @param proposer Block proposer address
/// @param oldTimestamp Previous timestamp
/// @param newTimestamp New timestamp
/// @param isNilBlock True if this is a NIL block (no time advance)
event GlobalTimeUpdated(
    address indexed proposer,
    uint64 oldTimestamp,
    uint64 newTimestamp,
    bool isNilBlock
);
```

### Errors

```solidity
/// @notice Timestamp must advance for normal blocks
error TimestampMustAdvance(uint64 proposed, uint64 current);

/// @notice Timestamp must equal current for NIL blocks
error TimestampMustEqual(uint64 proposed, uint64 current);

/// @notice Only Blocker can call this function
error OnlyBlocker();

/// @notice Only genesis can initialize
error OnlyGenesis();
```

## Time Update Rules

### Normal Blocks

For normal blocks (proposer ≠ SYSTEM_CALLER):

- New timestamp MUST be > current timestamp
- Time must always advance forward

```solidity
function updateGlobalTime(address proposer, uint64 timestamp) external onlyBlocker {
    if (proposer != SYSTEM_CALLER) {
        // Normal block: time must advance
        if (timestamp <= microseconds) {
            revert TimestampMustAdvance(timestamp, microseconds);
        }
        microseconds = timestamp;
    }
}
```

### NIL Blocks

For NIL blocks (proposer == SYSTEM_CALLER):

- New timestamp MUST equal current timestamp
- No time advancement

```solidity
if (proposer == SYSTEM_CALLER) {
    // NIL block: time must stay the same
    if (timestamp != microseconds) {
        revert TimestampMustEqual(timestamp, microseconds);
    }
    // No state change needed
}
```

## Access Control

| Function                                 | Caller       |
| ---------------------------------------- | ------------ |
| `initialize()`                           | Genesis only |
| `updateGlobalTime()`                     | Blocker only |
| `nowMicroseconds()`                      | Anyone       |
| `nowSeconds()`                           | Anyone       |
| `getTimeInfo()`                          | Anyone       |
| `isGreaterThanOrEqualCurrentTimestamp()` | Anyone       |

## Initialization

At genesis, time is initialized to 0:

```solidity
function initialize() external onlyGenesis {
    microseconds = 0;
}
```

The first real block will set the actual timestamp.

## Usage Examples

### Getting Current Time

```solidity
// Get time in seconds for common operations
uint64 currentSeconds = ITimestamp(TIMESTAMP_ADDR).nowSeconds();

// Get microsecond precision for high-resolution timing
uint64 currentMicros = ITimestamp(TIMESTAMP_ADDR).nowMicroseconds();
```

### Time-based Conditions

```solidity
// Check if an operation has expired
function isExpired(uint64 expiryMicroseconds) public view returns (bool) {
    return ITimestamp(TIMESTAMP_ADDR).nowMicroseconds() > expiryMicroseconds;
}

// Check if enough time has passed
function hasElapsed(uint64 startTime, uint64 durationSeconds) public view returns (bool) {
    uint64 elapsed = ITimestamp(TIMESTAMP_ADDR).nowSeconds() - startTime;
    return elapsed >= durationSeconds;
}
```

## Relationship with EVM block.timestamp

The Gravity timestamp is independent of EVM's `block.timestamp`:

| Aspect    | `block.timestamp` | `Timestamp.nowSeconds()` |
| --------- | ----------------- | ------------------------ |
| Precision | Seconds           | Microseconds (converted) |
| Source    | EVM runtime       | Gravity consensus        |
| Updater   | Automatic         | Explicit (Blocker)       |
| Use case  | EVM compatibility | Gravity-specific logic   |

**Recommendation**: Use `Timestamp.nowSeconds()` for Gravity-specific logic and `block.timestamp` only for EVM
compatibility.

## Security Considerations

1. **Protected Updates**: Only the Blocker contract can update time
2. **Monotonic Guarantee**: Time can only advance (for normal blocks)
3. **No Overflow**: uint64 microseconds won't overflow until year 586912
4. **Atomic Updates**: Time update is atomic within a transaction

## Invariants

1. `microseconds` can only increase (for normal blocks)
2. `nowSeconds() == nowMicroseconds() / 1_000_000`
3. After any `updateGlobalTime`, the timestamp reflects the block's consensus time

## Testing Requirements

1. **Unit Tests**:

   - Test normal block time advancement
   - Test NIL block time equality
   - Test time query functions
   - Test initialization

2. **Fuzz Tests**:

   - Fuzz timestamp values for advancement
   - Fuzz conversion accuracy

3. **Integration Tests**:

   - Test with Blocker contract
   - Test epoch transitions using timestamp

4. **Invariant Tests**:
   - Time monotonicity
   - Conversion accuracy

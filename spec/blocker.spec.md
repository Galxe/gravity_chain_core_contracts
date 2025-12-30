---
status: drafting
owner: @yxia
---

# Blocker Specification

## Overview

The Blocker contract is the entry point for blockchain runtime to interact with system contracts during block
production. It is called once at the beginning of each block to update on-chain state based on the block's metadata.

## Design Goals

1. **Single Entry Point**: One function called per block by the blockchain runtime
2. **Minimal Logic**: Keep logic simple, delegate to specialized contracts
3. **Fault Tolerance**: Handle failures gracefully without breaking block production
4. **Thin Orchestrator**: Pass control to EpochManager for epoch transition logic

---

## Contract: `Blocker`

### Interface

```solidity
interface IBlocker {
    // ========== Block Prologue ==========

    /// @notice Called by blockchain runtime at the start of each block
    /// @param proposer The block proposer's public key (32 bytes, fixed size)
    /// @param failedProposers Addresses of validators who failed to propose
    /// @param timestampMicros Block timestamp in microseconds
    function onBlockStart(
        bytes32 proposer,
        bytes32[] calldata failedProposers,
        uint64 timestampMicros
    ) external;

    // ========== Initialization ==========

    /// @notice Initialize the contract (genesis only)
    function initialize() external;
}
```

### Events

```solidity
/// @notice Emitted at the start of each block
event BlockStarted(
    uint256 indexed blockHeight,
    uint64 indexed epoch,
    address proposer,
    uint64 timestamp
);

/// @notice Emitted when a component update fails (non-fatal)
event ComponentUpdateFailed(
    address indexed component,
    bytes reason
);
```

### Errors

```solidity
/// @notice Only blockchain runtime can call this
error OnlySystemCaller();

/// @notice Only genesis can initialize
error OnlyGenesis();
```

---

## Block Prologue Flow

The `onBlockStart` function executes the following steps in order:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           onBlockStart()                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. Resolve proposer                                                         │
│     ├── If VM reserved (32 zeros) → SYSTEM_CALLER                            │
│     └── Else → ValidatorManager.getValidatorByConsensusAddress(proposer)    │
│                                                                              │
│  2. Update Timestamp                                                         │
│     └── Timestamp.updateGlobalTime(proposerAddr, timestampMicros)           │
│                                                                              │
│  3. Update Performance Tracker                                               │
│     └── PerformanceTracker.updatePerformanceStatistics(...)                 │
│                                                                              │
│  4. Check and Start Epoch Transition (if needed)                             │
│     └── EpochManager.checkAndStartTransition()                              │
│         └── Returns true if DKG was started                                 │
│                                                                              │
│  5. Emit BlockStarted event                                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Implementation

```solidity
function onBlockStart(
    bytes32 proposer,
    bytes32[] calldata failedProposers,
    uint64 timestampMicros
) external onlySystemCaller {
    // 1. Resolve proposer address
    address validatorAddress;

    if (_isVmReservedProposer(proposer)) {
        // VM reserved address (NIL block)
        validatorAddress = SYSTEM_CALLER;
    } else {
        // Get validator address from ValidatorManager
        validatorAddress =
            IValidatorManager(VALIDATOR_MANAGER_ADDR).getValidatorByConsensusAddress(proposer);
    }

    // 2. Update global timestamp
    ITimestamp(TIMESTAMP_ADDR).updateGlobalTime(validatorAddress, timestampMicros);

    // 3. Update validator performance statistics
    IValidatorPerformanceTracker(VALIDATOR_PERFORMANCE_TRACKER_ADDR)
        .updatePerformanceStatistics(proposer, failedProposers);

    // 4. Check and start epoch transition if needed
    //    EpochManager handles all transition logic internally
    IEpochManager(EPOCH_MANAGER_ADDR).checkAndStartTransition();

    // 5. Emit event
    emit BlockStarted(
        block.number,
        uint64(IEpochManager(EPOCH_MANAGER_ADDR).currentEpoch()),
        validatorAddress,
        timestampMicros
    );
}
```

---

## VM Reserved Proposer

A VM reserved proposer (NIL block) is identified by 32 bytes of zeros:

```solidity
function _isVmReservedProposer(bytes32 proposer) internal pure returns (bool) {
    return proposer == bytes32(0);
}
```

NIL blocks are special blocks where:

- No real proposer (system-generated block)
- Proposer consensus address is `bytes32(0)`
- Performance tracking still occurs (to record failed proposers)

---

## Relationship with EpochManager

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    BLOCKER → EPOCH MANAGER INTERACTION                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   Blocker                          EpochManager                              │
│   ───────                          ────────────                              │
│      │                                  │                                    │
│      │  checkAndStartTransition()       │                                    │
│      │─────────────────────────────────►│                                    │
│      │                                  │                                    │
│      │                                  ├─► Check time elapsed               │
│      │                                  ├─► Check state == Idle              │
│      │                                  │                                    │
│      │                                  │   [If conditions met:]             │
│      │                                  ├─► Get validator infos              │
│      │                                  ├─► Get randomness config            │
│      │                                  ├─► DKG.startSession()               │
│      │                                  ├─► transitionState = DkgInProgress  │
│      │                                  │                                    │
│      │◄─────────────────────────────────│  returns bool (started)            │
│      │                                  │                                    │
│                                                                              │
│   Key Point: Blocker does NOT need to check canTriggerEpochTransition()     │
│   separately. EpochManager.checkAndStartTransition() handles everything.     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Previous Design (Deprecated)**:

```solidity
// OLD - Do not use
if (IEpochManager(EPOCH_MANAGER).canTriggerEpochTransition()) {
    IReconfigurationWithDKG(RECONFIG).tryStart();
}
```

**New Design**:

```solidity
// NEW - Single call to EpochManager
IEpochManager(EPOCH_MANAGER_ADDR).checkAndStartTransition();
```

---

## Access Control

| Function         | Caller                                  |
| ---------------- | --------------------------------------- |
| `initialize()`   | Genesis only                            |
| `onBlockStart()` | System Caller (blockchain runtime) only |

---

## Fault Handling

Non-critical operations should not fail the block:

```solidity
function _safeRecordPerformance(
    bytes32 proposer,
    bytes32[] calldata failedProposers
) internal {
    try IValidatorPerformanceTracker(VALIDATOR_PERFORMANCE_TRACKER_ADDR)
        .updatePerformanceStatistics(proposer, failedProposers) {
        // Success
    } catch (bytes memory reason) {
        // Log failure but don't revert
        emit ComponentUpdateFailed(VALIDATOR_PERFORMANCE_TRACKER_ADDR, reason);
    }
}
```

**Critical operations that MUST succeed:**

- Timestamp update
- Epoch transition check (checkAndStartTransition)

**Non-critical operations (can fail gracefully):**

- Performance tracking
- Metrics collection

---

## Genesis Block Handling

The first block after genesis is special:

```solidity
function initialize() external onlyGenesis {
    // Emit genesis block event
    emit BlockStarted(0, 0, SYSTEM_CALLER, 0);

    // Initialize timestamp to 0
    ITimestamp(TIMESTAMP_ADDR).updateGlobalTime(SYSTEM_CALLER, 0);
}
```

---

## Contract Dependencies

```
                         ┌─────────────────┐
                         │     Blocker     │
                         │  (Entry Point)  │
                         └────────┬────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
┌───────────────┐         ┌──────────────┐         ┌─────────────────────┐
│   Timestamp   │         │ EpochManager │         │ ValidatorPerformance│
│               │         │              │         │      Tracker        │
│ updateGlobal  │         │ checkAnd     │         │                     │
│   Time()      │         │ StartTrans   │         │ updatePerformance   │
│               │         │   ition()    │         │   Statistics()      │
└───────────────┘         └──────────────┘         └─────────────────────┘
                                  │
                                  │ (internally calls)
                                  │
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
             ┌──────────┐  ┌──────────┐  ┌──────────────┐
             │   DKG    │  │Validator │  │ Randomness   │
             │          │  │ Manager  │  │   Config     │
             └──────────┘  └──────────┘  └──────────────┘
```

---

## Security Considerations

1. **Caller Restriction**: Only blockchain runtime can call `onBlockStart`
2. **Atomic Execution**: All updates within a single transaction
3. **Fail-safe**: Non-critical failures don't break block production
4. **No External Calls to Untrusted Contracts**: Only calls system contracts
5. **Delegate Complex Logic**: Epoch transition logic delegated to EpochManager

---

## Gas Considerations

Block prologue is executed every block, so gas efficiency matters:

- Minimize storage reads/writes
- Use calldata for input parameters
- Avoid loops over unbounded arrays
- Cache frequently accessed addresses
- Single call to EpochManager instead of multiple checks

---

## Testing Requirements

### Unit Tests

- Normal block processing
- NIL block handling (bytes32(0) proposer)
- Epoch transition triggering via checkAndStartTransition
- Failed proposers recording

### Integration Tests

- Full block prologue flow
- Multi-block sequences
- Epoch boundary crossing
- Transition state changes across blocks

### Fuzz Tests

- Random proposer consensus address (bytes32)
- Random failed proposer consensus addresses (bytes32[])
- Random failure scenarios

### Gas Tests

- Measure gas per block type
- Ensure bounded gas consumption
- Compare gas with/without epoch transition start

# Blocker Specification

## Overview

The Blocker contract is the entry point for blockchain runtime to interact with system contracts during block
production. It is called once at the beginning of each block to update on-chain state based on the block's metadata.

## Design Goals

1. **Single Entry Point**: One function called per block by the blockchain runtime
2. **Orchestrator Role**: Coordinates updates across multiple system contracts
3. **Minimal Logic**: Keep logic simple, delegate to specialized contracts
4. **Fault Tolerance**: Handle failures gracefully without breaking block production

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
        address[] calldata failedProposers,
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

## Block Prologue Flow

The `onBlockStart` function executes the following steps in order:

```
┌─────────────────────────────────────────────────────────┐
│                    onBlockStart()                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  1. Resolve proposer address                             │
│     ├── If VM reserved (32 zeros) → SYSTEM_CALLER       │
│     └── Else → TBD (see pending items)                  │
│                                                          │
│  2. Update Timestamp                                     │
│     └── timestamp.updateGlobalTime(proposer, time)      │
│                                                          │
│  3. Update Performance Tracker (optional)                │
│     └── tracker.recordProposerStats(...)                │
│                                                          │
│  4. Check Epoch Transition                               │
│     └── If epochManager.canTransition() → trigger        │
│                                                          │
│  5. Emit BlockStarted event                              │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Implementation

```solidity
function onBlockStart(
    bytes32 proposer,
    address[] calldata failedProposers,
    uint64 timestampMicros
) external onlySystemCaller {
    // 1. Resolve proposer address
    // TODO: Pending design decision - since addresses are passed directly,
    // we may not need to lookup the proposer. See "Pending Items" section.
    address proposerAddr;
    if (_isVmReservedProposer(proposer)) {
        proposerAddr = SYSTEM_CALLER;
    } else {
        // TBD: May receive address directly from runtime instead of pubkey lookup
        proposerAddr = IValidatorManager(VALIDATOR_MANAGER).getValidatorByPubkey(proposer);
    }

    // 2. Update timestamp
    ITimestamp(TIMESTAMP).updateGlobalTime(proposerAddr, timestampMicros);

    // 3. Record performance (optional, non-critical)
    _safeRecordPerformance(proposerAddr, failedProposers);

    // 4. Check and trigger epoch transition
    if (IEpochManager(EPOCH_MANAGER).canTriggerEpochTransition()) {
        IEpochManager(EPOCH_MANAGER).triggerEpochTransition();
    }

    // 5. Emit event
    emit BlockStarted(
        block.number,
        IEpochManager(EPOCH_MANAGER).currentEpoch(),
        proposerAddr,
        timestampMicros
    );
}
```

## VM Reserved Proposer

A VM reserved proposer (NIL block) is identified by 32 bytes of zeros:

```solidity
function _isVmReservedProposer(bytes32 proposer) internal pure returns (bool) {
    return proposer == bytes32(0);
}
```

NIL blocks are special blocks where:

- No real proposer
- Timestamp doesn't advance
- No performance tracking

## Access Control

| Function         | Caller                                  |
| ---------------- | --------------------------------------- |
| `initialize()`   | Genesis only                            |
| `onBlockStart()` | System Caller (blockchain runtime) only |

## Fault Handling

Non-critical operations should not fail the block:

```solidity
function _safeRecordPerformance(
    address proposer,
    address[] calldata failedProposers
) internal {
    try IPerformanceTracker(TRACKER).record(proposer, failedProposers) {
        // Success
    } catch (bytes memory reason) {
        // Log failure but don't revert
        emit ComponentUpdateFailed(TRACKER, reason);
    }
}
```

**Critical operations that MUST succeed:**

- Timestamp update
- Epoch transition (if triggered)

**Non-critical operations (can fail gracefully):**

- Performance tracking
- Metrics collection

## Genesis Block Handling

The first block after genesis is special:

```solidity
function initialize() external onlyGenesis {
    // Emit genesis block event
    emit BlockStarted(0, 0, SYSTEM_CALLER, 0);

    // Initialize timestamp to 0
    ITimestamp(TIMESTAMP).updateGlobalTime(SYSTEM_CALLER, 0);
}
```

## Relationship with Other Contracts

```
                    ┌─────────────┐
                    │   Blocker   │
                    └──────┬──────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
┌───────────────┐  ┌──────────────┐  ┌─────────────────┐
│   Timestamp   │  │ EpochManager │  │ ValidatorManager│
└───────────────┘  └──────────────┘  └─────────────────┘
```

- **Timestamp**: Blocker updates time every block
- **EpochManager**: Blocker checks and triggers epoch transitions
- **ValidatorManager**: Blocker looks up proposer info

## Pending Items

> **TODO**: Design decision needed with the team.

1. **Proposer Resolution**: Since `failedProposers` are now passed as addresses directly from the runtime, should the `proposer` parameter also be passed as an `address` instead of `bytes32` (public key)?
   - If yes, we can eliminate the `getValidatorByPubkey` lookup entirely
   - The interface would become: `onBlockStart(address proposer, address[] calldata failedProposers, uint64 timestampMicros)`
   - This simplifies the contract and reduces gas costs

## Security Considerations

1. **Caller Restriction**: Only blockchain runtime can call `onBlockStart`
2. **Atomic Execution**: All updates within a single transaction
3. **Fail-safe**: Non-critical failures don't break block production
4. **No External Calls to Untrusted Contracts**: Only calls system contracts

## Gas Considerations

Block prologue is executed every block, so gas efficiency matters:

- Minimize storage reads/writes
- Use calldata for input parameters
- Avoid loops over unbounded arrays
- Cache frequently accessed addresses

## Testing Requirements

1. **Unit Tests**:

   - Normal block processing
   - NIL block handling (bytes32(0) proposer)
   - Epoch transition triggering
   - Failed proposers recording

2. **Integration Tests**:

   - Full block prologue flow
   - Multi-block sequences
   - Epoch boundary crossing

3. **Fuzz Tests**:

   - Random proposer data (bytes32)
   - Random failed proposer addresses
   - Random failure scenarios

4. **Gas Tests**:
   - Measure gas per block type
   - Ensure bounded gas consumption

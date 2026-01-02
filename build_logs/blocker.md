# Blocker Layer Build Log

## Overview

Implementation of the Blocker layer containing `Reconfiguration.sol` and `Blocker.sol` for epoch lifecycle management.

## Files Created

| File | Purpose |
|------|---------|
| `src/blocker/IReconfiguration.sol` | Interface for Reconfiguration contract |
| `src/blocker/Reconfiguration.sol` | Epoch lifecycle management with DKG coordination |
| `src/blocker/Blocker.sol` | Block prologue entry point |
| `spec_v2/blocker.spec.md` | Layer specification document |

## Files Modified

| File | Change |
|------|--------|
| `src/foundation/Errors.sol` | Added `InvalidEpochInterval()` and `ReconfigurationNotInitialized()` errors |
| `src/staking/IValidatorManagement.sol` | Changed `onNewEpoch()` to `onNewEpoch(uint64 newEpoch)` |
| `src/staking/ValidatorManagement.sol` | Updated to accept epoch parameter from Reconfiguration |
| `test/unit/staking/ValidatorManagement.t.sol` | Updated tests for new `onNewEpoch(uint64)` signature |

## Design Decisions

### Contract Naming
- Used `Reconfiguration.sol` (Aptos-style naming) instead of `EpochManager.sol`

### Epoch Ownership
- Both `Reconfiguration` and `ValidatorManagement` track `currentEpoch`
- Reconfiguration passes the new epoch number to `ValidatorManagement.onNewEpoch(uint64)`
- This keeps contracts in sync while allowing each to maintain its own state

### Access Control for `finishTransition()`
- Callable by SYSTEM_CALLER (consensus engine) for normal transitions
- Callable by TIMELOCK (governance) for force-ending stuck epochs
- Provides escape hatch if DKG is stuck

### ValidatorManagement Interface
- Changed `onNewEpoch()` to `onNewEpoch(uint64 newEpoch)`
- ValidatorManagement now receives epoch from Reconfiguration
- Removes internal epoch increment logic

### Performance Tracker
- Skipped for initial implementation (does not exist yet)
- `failedProposers` parameter in `onBlockStart()` is unused but retained for future use

## Architecture

```
VM Runtime ─────► Blocker.onBlockStart()
                      │
                      ├─► Timestamp.updateGlobalTime()
                      │
                      └─► Reconfiguration.checkAndStartTransition()
                                │
                                ├─► DKG.start()
                                └─► [Emits DKGStartEvent]

Consensus Engine ───► Reconfiguration.finishTransition()
                           │
                           ├─► DKG.finish()
                           ├─► RandomnessConfig.applyPendingConfig()
                           ├─► ValidatorManagement.onNewEpoch(newEpoch)
                           └─► [Emits EpochTransitioned]
```

## State Machine

```
    IDLE ──────────────────────────────────► DKG_IN_PROGRESS
          checkAndStartTransition()               │
          (time elapsed)                          │
     ▲                                            │
     │            finishTransition()              │
     └────────────────────────────────────────────┘
```

## Key Implementation Details

### Time Calculations
- All timestamps in microseconds (consistent with Timestamp contract)
- Default epoch interval: 2 hours (7,200,000,000 microseconds)
- Epoch transitions are time-based, not block-based

### NIL Block Handling
- NIL blocks have `proposer == bytes32(0)`
- Resolved to `SYSTEM_CALLER` address
- Timestamp must stay the same (enforced by Timestamp contract)

### Proposer Resolution
- Currently uses simple conversion: `address(uint160(uint256(proposer)))`
- TODO: Query ValidatorManagement for proper consensus key lookup

## Testing Status

- [x] Contracts compile successfully
- [x] Existing ValidatorManagement tests updated for new interface
- [ ] Unit tests for Reconfiguration (pending)
- [ ] Unit tests for Blocker (pending)
- [ ] Integration tests (pending)

## Build Verification

```bash
cd /home/yxia/gravity/gravity_chain_core_contracts
forge build --force
# Compiler run successful with warnings
```

## Next Steps

1. Write unit tests for Reconfiguration contract
2. Write unit tests for Blocker contract
3. Implement ValidatorPerformanceTracker (uses `failedProposers` parameter)
4. Implement proper consensus key lookup in `_resolveProposer()`
5. Integration tests for full epoch lifecycle

## Related Documents

- [spec_v2/blocker.spec.md](../spec_v2/blocker.spec.md) - Full specification
- [spec/epoch.spec.md](../spec/epoch.spec.md) - Original epoch spec (reference)
- [spec/blocker.spec.md](../spec/blocker.spec.md) - Original blocker spec (reference)


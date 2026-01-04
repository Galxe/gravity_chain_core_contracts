# Randomness Layer Build Log

## Summary

Added randomness configuration and DKG session management contracts to support on-chain randomness and epoch transitions for Gravity blockchain.

## Date

2026-01-02

## Changes Made

### 1. Foundation Layer

**SystemAddresses.sol**
- Added `RANDOMNESS_CONFIG = 0x0000000000000000000000000001625F2024`
- Added `DKG = 0x0000000000000000000000000001625F2025`

**Errors.sol**
- Added randomness errors: `RandomnessNotInitialized`, `RandomnessAlreadyInitialized`, `InvalidRandomnessConfig`, `NoPendingRandomnessConfig`
- Added DKG errors: `DKGInProgress`, `DKGNotInProgress`, `DKGNotInitialized`

### 2. Runtime Layer

**RandomnessConfig.sol** (new)
- Configuration for DKG thresholds (secrecy, reconstruction, fast path)
- Two variants: `Off` (disabled) and `V2` (enabled with thresholds)
- Pending config pattern for epoch-boundary application
- Fixed-point thresholds (value / 2^64)

Key functions:
- `initialize(config)` - Genesis only
- `getCurrentConfig()` - Get active config
- `setForNextEpoch(config)` - Governance sets pending
- `applyPendingConfig()` - Reconfiguration applies at boundary

**DKG.sol** (new)
- DKG session lifecycle management
- Tracks in-progress and last-completed sessions via `DKGSessionInfo`
- Emits `DKGStartEvent` with full `DKGSessionMetadata` for consensus engine
- Full validator arrays only in events (not stored) to avoid dynamic array storage issues

Key functions:
- `initialize()` - Genesis only
- `start(epoch, config, dealers, targets)` - Start DKG session, emits full metadata
- `finish(transcript)` - Complete session
- `tryClearIncompleteSession()` - Clear stale session

### 3. Tests

**RandomnessConfig.t.sol** (new)
- 25+ test cases covering:
  - Initialization (Off, V2, double init, invalid config)
  - View functions (enabled, getCurrentConfig, getPendingConfig)
  - Governance updates (setForNextEpoch, overwrite pending)
  - Epoch transition (applyPendingConfig)
  - Config builders (newOff, newV2)
  - Access control
  - Events
  - Fuzz tests

**DKG.t.sol** (new)
- 20+ test cases covering:
  - Initialization
  - Session lifecycle (start, finish, clear)
  - View functions
  - Multi-session scenarios
  - Access control
  - Events
  - Fuzz tests

### 4. Documentation

**spec_v2/randomness.spec.md** (new)
- Complete specification for RandomnessConfig and DKG
- Architecture diagrams
- Type definitions
- Interface documentation
- Access control tables
- Security considerations
- Testing requirements

## Design Decisions

1. **Pending Config Pattern**: Config changes are queued and applied at epoch boundaries (not immediately). This ensures predictable behavior during epoch transitions.

2. **ConfigVariant Enum**: Support for Off/V2 variants allows disabling randomness via governance.

3. **Fixed-Point Thresholds**: Using `uint64` with value/2^64 representation for precise stake ratios.

4. **Separate Contracts**: RandomnessConfig (config storage) and DKG (session management) are separate for clean separation of concerns.

5. **Event-Driven**: `DKGStartEvent` emitted for consensus engine to listen and begin off-chain DKG.

6. **Event-Based Metadata**: Full validator arrays are emitted in events only (`DKGSessionMetadata`), not stored in contract state. This avoids Solidity storage limitations with dynamic arrays containing nested structs. Essential info (`DKGSessionInfo`) is stored for state tracking.

## File List

| File | Action | Lines |
|------|--------|-------|
| `src/foundation/SystemAddresses.sol` | Modified | +8 |
| `src/foundation/Errors.sol` | Modified | +24 |
| `src/runtime/RandomnessConfig.sol` | Created | ~215 |
| `src/runtime/DKG.sol` | Created | ~250 |
| `test/unit/runtime/RandomnessConfig.t.sol` | Created | ~300 |
| `test/unit/runtime/DKG.t.sol` | Created | ~330 |
| `spec_v2/randomness.spec.md` | Created | ~350 |

## Integration Points

These contracts will be called by `Reconfiguration` (future):

```
Reconfiguration.checkAndStartTransition()
    ├─► RandomnessConfig.getCurrentConfig()
    ├─► DKG.tryClearIncompleteSession()
    └─► DKG.start()

Reconfiguration.finishTransition()
    ├─► DKG.finish()
    └─► RandomnessConfig.applyPendingConfig()
```

## Testing

Run tests:
```bash
forge test --match-contract RandomnessConfigTest -vvv
forge test --match-contract DKGTest -vvv
```

## Next Steps

1. **Reconfiguration**: Implement reconfiguration to orchestrate these contracts
2. **PerBlockRandomness**: Add per-block seed storage (updated in block prologue)
3. **Randomness API**: Add random number generation functions (u64_range, etc.)
4. **Integration Tests**: Full epoch transition flow tests


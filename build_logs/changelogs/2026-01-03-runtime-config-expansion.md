# Runtime Config Expansion

**Date**: 2026-01-03  
**Author**: AI Assistant  
**Layer**: Runtime

## Summary

Added 4 new configuration contracts to the Runtime layer based on Aptos on-chain parameters documentation. Also updated the runtime specification to include all 9 contracts (including previously undocumented RandomnessConfig and DKG).

## Changes

### New Contracts

| Contract | Description | Aptos Reference |
|----------|-------------|-----------------|
| `EpochConfig.sol` | Epoch interval configuration | Section 9 |
| `VersionConfig.sol` | Protocol version (monotonic) | Section 4 |
| `ConsensusConfig.sol` | Consensus parameters (opaque bytes) | Section 2 |
| `ExecutionConfig.sol` | VM execution parameters (opaque bytes) | Section 3 |

### New System Addresses

Added to `src/foundation/SystemAddresses.sol`:

```solidity
EPOCH_CONFIG     = 0x0000000000000000000000000001625F2027
VERSION_CONFIG   = 0x0000000000000000000000000001625F2028
CONSENSUS_CONFIG = 0x0000000000000000000000000001625F2029
EXECUTION_CONFIG = 0x0000000000000000000000000001625F202A
```

### New Errors

Added to `src/foundation/Errors.sol`:

- `VersionMustIncrease(uint64 current, uint64 proposed)`
- `VersionNotInitialized()`
- `VersionAlreadyInitialized()`
- `EpochConfigNotInitialized()`
- `EpochConfigAlreadyInitialized()`
- `ConsensusConfigNotInitialized()`
- `ConsensusConfigAlreadyInitialized()`
- `ExecutionConfigNotInitialized()`
- `ExecutionConfigAlreadyInitialized()`
- `EmptyConfig()`

### Design Patterns

**Simple Config Pattern** (EpochConfig, VersionConfig):
- Initialize at genesis via GENESIS
- Update via GOVERNANCE
- Immediate application

**Pending Config Pattern** (ConsensusConfig, ExecutionConfig):
- Stage changes via `setForNextEpoch()` (GOVERNANCE)
- Apply at epoch boundary via `applyPendingConfig()` (RECONFIGURATION)
- No-op if no pending config exists

### Test Coverage

| New Contract | Tests |
|--------------|-------|
| EpochConfig | 15 |
| VersionConfig | 19 |
| ConsensusConfig | 27 |
| ExecutionConfig | 27 |
| **Subtotal** | **88** |

**Total Runtime Tests**: 242 (was 154)

## Files Changed

### Created
- `src/runtime/EpochConfig.sol`
- `src/runtime/VersionConfig.sol`
- `src/runtime/ConsensusConfig.sol`
- `src/runtime/ExecutionConfig.sol`
- `test/unit/runtime/EpochConfig.t.sol`
- `test/unit/runtime/VersionConfig.t.sol`
- `test/unit/runtime/ConsensusConfig.t.sol`
- `test/unit/runtime/ExecutionConfig.t.sol`

### Modified
- `src/foundation/SystemAddresses.sol` - Added 4 new addresses
- `src/foundation/Errors.sol` - Added 10 new errors
- `spec_v2/runtime.spec.md` - Complete rewrite with all 9 contracts

## Aptos Alignment

These additions align Gravity's runtime layer with Aptos on-chain parameters:

| Aptos Module | Gravity Contract | Notes |
|--------------|------------------|-------|
| `block::BlockResource.epoch_interval` | `EpochConfig` | Same purpose |
| `version::Version.major` | `VersionConfig` | Monotonic increase enforced |
| `consensus_config::ConsensusConfig` | `ConsensusConfig` | Opaque bytes, pending pattern |
| `execution_config::ExecutionConfig` | `ExecutionConfig` | Opaque bytes, pending pattern |

## Breaking Changes

None. All new contracts are additive.

## Migration

No migration required. New contracts will be deployed at genesis.


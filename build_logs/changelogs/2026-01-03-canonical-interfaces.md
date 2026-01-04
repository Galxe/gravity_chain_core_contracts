# Canonical Interfaces for Runtime Config Contracts

**Date:** 2026-01-03  
**Author:** @yxia  
**Status:** Completed

## Summary

Refactored staking layer contracts to use canonical interfaces defined by runtime config contracts instead of ad-hoc inline interface definitions.

## Motivation

Previously, downstream contracts (StakePool, Staking, ValidatorManagement) defined their own ad-hoc interfaces for consuming runtime config contracts:

```solidity
// Before: Ad-hoc interface in StakePool.sol
interface ITimestampPool {
    function nowMicroseconds() external view returns (uint64);
}

// Before: Ad-hoc interface in Staking.sol
interface IStakingConfigFactory {
    function minimumStake() external view returns (uint256);
}

// Before: Ad-hoc interface in ValidatorManagement.sol
interface IValidatorConfigVM {
    function minimumBond() external view returns (uint256);
    function maximumBond() external view returns (uint256);
    // ...
}
```

This approach had several issues:
1. **Code duplication**: Multiple interface definitions for the same contract
2. **Maintenance burden**: Changes to contract ABI required updates in multiple places
3. **Inconsistency risk**: Ad-hoc interfaces might miss methods or have wrong signatures
4. **Unclear dependencies**: Hard to trace which contracts depend on which

## Changes

### New Interface Files

Created canonical read-only interfaces under `src/runtime/`:

1. **`IStakingConfig.sol`** — Interface for StakingConfig
   - `minimumStake() → uint256`
   - `lockupDurationMicros() → uint64`
   - `minimumProposalStake() → uint256`

2. **`IValidatorConfig.sol`** — Interface for ValidatorConfig
   - `minimumBond() → uint256`
   - `maximumBond() → uint256`
   - `unbondingDelayMicros() → uint64`
   - `allowValidatorSetChange() → bool`
   - `votingPowerIncreaseLimitPct() → uint64`
   - `maxValidatorSetSize() → uint256`
   - `MAX_VOTING_POWER_INCREASE_LIMIT() → uint64`
   - `MAX_VALIDATOR_SET_SIZE() → uint256`

Note: `ITimestamp.sol` and `ITimestampWriter.sol` already existed.

### Updated Contracts

1. **`StakePool.sol`**
   - Removed: `ITimestampPool` (ad-hoc interface)
   - Removed: `IStakingConfigPool` (ad-hoc interface)
   - Added: `import { ITimestamp } from "../runtime/ITimestamp.sol"`
   - Added: `import { IStakingConfig } from "../runtime/IStakingConfig.sol"`

2. **`Staking.sol`**
   - Removed: `IStakingConfigFactory` (ad-hoc interface)
   - Added: `import { IStakingConfig } from "../runtime/IStakingConfig.sol"`

3. **`ValidatorManagement.sol`**
   - Removed: `IValidatorConfigVM` (ad-hoc interface)
   - Added: `import { IValidatorConfig } from "../runtime/IValidatorConfig.sol"`

### Documentation Updates

Updated `spec_v2/runtime.spec.md`:
- Added interface documentation for `ITimestamp`, `IStakingConfig`, `IValidatorConfig`
- Added "Interface Design Principle" section in Design Patterns
- Updated architecture diagram to include interface files

## Design Principle

**Rule: Use canonical interfaces defined by the contract, not ad-hoc interfaces.**

Each runtime contract that needs to be consumed by downstream contracts defines its own read-only interface:

| Contract | Interface | Consumers |
|----------|-----------|-----------|
| `Timestamp.sol` | `ITimestamp` | StakePool, DKG, Governance |
| `StakingConfig.sol` | `IStakingConfig` | Staking, StakePool |
| `ValidatorConfig.sol` | `IValidatorConfig` | ValidatorManagement |

## Files Changed

- `src/runtime/IStakingConfig.sol` (new)
- `src/runtime/IValidatorConfig.sol` (new)
- `src/staking/StakePool.sol`
- `src/staking/Staking.sol`
- `src/staking/ValidatorManagement.sol`
- `spec_v2/runtime.spec.md`

## Testing

All existing tests pass. No behavioral changes, only import refactoring.


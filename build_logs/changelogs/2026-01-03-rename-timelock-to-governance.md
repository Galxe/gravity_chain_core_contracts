# Rename TIMELOCK to GOVERNANCE

**Date**: 2026-01-03  
**Type**: Breaking Change

## Summary

Renamed `TIMELOCK` system address to `GOVERNANCE` and removed the separate `VOTING` address. The Governance contract itself executes proposals - there is no separate Timelock controller contract.

## Rationale

The original design assumed a separate Timelock contract for enforcing delays on governance proposals. However, the Governance contract directly executes approved proposals via `execute()`. The `TIMELOCK` name was misleading since no timelock functionality exists.

## Changes

### SystemAddresses.sol

| Before | After |
|--------|-------|
| `VOTING` (0x2014) | `GOVERNANCE` (0x2014) |
| `TIMELOCK` (0x201F) | Removed |

### Source Files

| File | Change |
|------|--------|
| `src/foundation/SystemAddresses.sol` | Renamed VOTING→GOVERNANCE, removed TIMELOCK |
| `src/governance/GovernanceConfig.sol` | TIMELOCK→GOVERNANCE in access control |
| `src/oracle/NativeOracle.sol` | TIMELOCK→GOVERNANCE in setCallback() |
| `src/oracle/INativeOracle.sol` | Updated NatSpec comments |
| `src/blocker/Reconfiguration.sol` | TIMELOCK→GOVERNANCE in finishTransition(), setEpochIntervalMicros() |
| `src/blocker/IReconfiguration.sol` | Updated NatSpec comments |
| `src/runtime/RandomnessConfig.sol` | TIMELOCK→GOVERNANCE in setForNextEpoch() |
| `src/runtime/ValidatorConfig.sol` | TIMELOCK→GOVERNANCE in all setters |
| `src/runtime/StakingConfig.sol` | TIMELOCK→GOVERNANCE in all setters |

### Test Files

| File | Change |
|------|--------|
| `test/unit/foundation/SystemAddresses.t.sol` | Updated address tests, added missing addresses |
| `test/unit/governance/GovernanceConfig.t.sol` | TIMELOCK→GOVERNANCE |
| `test/unit/governance/Governance.t.sol` | VOTING→GOVERNANCE |
| `test/unit/oracle/NativeOracle.t.sol` | TIMELOCK→GOVERNANCE |
| `test/unit/blocker/Reconfiguration.t.sol` | TIMELOCK→GOVERNANCE |
| `test/unit/runtime/RandomnessConfig.t.sol` | TIMELOCK→GOVERNANCE |
| `test/unit/runtime/ValidatorConfig.t.sol` | TIMELOCK→GOVERNANCE |
| `test/unit/runtime/StakingConfig.t.sol` | TIMELOCK→GOVERNANCE |
| `test/unit/runtime/Timestamp.t.sol` | TIMELOCK→GOVERNANCE |
| `test/unit/staking/ValidatorManagement.t.sol` | TIMELOCK→GOVERNANCE |

### Spec Files

| File | Change |
|------|--------|
| `spec_v2/foundation.spec.md` | Updated address table and examples |
| `spec_v2/blocker.spec.md` | TIMELOCK→GOVERNANCE in access control |
| `spec_v2/oracle.spec.md` | TIMELOCK→GOVERNANCE |
| `spec_v2/governance.spec.md` | VOTING→GOVERNANCE, TIMELOCK→GOVERNANCE |

### Build Logs

| File | Change |
|------|--------|
| `build_logs/blocker.md` | TIMELOCK→GOVERNANCE |
| `build_logs/oracle.md` | TIMELOCK→GOVERNANCE |

## Migration Notes

Any code referencing `SystemAddresses.TIMELOCK` must be updated to `SystemAddresses.GOVERNANCE`.

Any code referencing `SystemAddresses.VOTING` must be updated to `SystemAddresses.GOVERNANCE`.

## Access Control Summary

| Operation | Caller |
|-----------|--------|
| Execute governance proposals | Governance contract (0x2014) |
| Update config parameters | Governance contract (0x2014) |
| Force-end stuck epochs | Governance contract (0x2014) |
| Register oracle callbacks | Governance contract (0x2014) |


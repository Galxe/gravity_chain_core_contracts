# Validator Management Security Parity with Aptos

**Date**: 2026-01-03  
**Component**: ValidatorManagement  
**Status**: Implemented

## Summary

Added security checks to `ValidatorManagement.sol` to match Aptos's `stake.move` validator management patterns.

## Changes

### 1. Reconfiguration Guard (High Priority)

Added `whenNotReconfiguring` modifier that blocks operations during epoch transitions.

**Implementation:**
- Uses `IReconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress()`
- Mirrors Aptos's `assert_reconfig_not_in_progress()` pattern
- Blocks during entire DKG period (from `checkAndStartTransition` to `finishTransition`)

**Applied to:**
- `joinValidatorSet()`
- `leaveValidatorSet()`
- `rotateConsensusKey()`
- `setFeeRecipient()`

### 2. Last Validator Protection (High Priority)

Added check to prevent removing the last active validator.

**Rationale:** Removing the last validator would halt consensus.

**Implementation:**
```solidity
if (_activeValidators.length == 1) {
    revert Errors.CannotRemoveLastValidator();
}
```

### 3. Leave from PENDING_ACTIVE State (Medium Priority)

Extended `leaveValidatorSet()` to allow canceling join requests.

**Aptos behavior:** `leave_validator_set` handles both:
1. If `PENDING_ACTIVE`: Remove from queue, revert to INACTIVE
2. If `ACTIVE`: Move to PENDING_INACTIVE

**Implementation:**
- Check for PENDING_ACTIVE status first
- Remove from `_pendingActive` array using new `_removeFromPendingActive()` helper
- Revert status to INACTIVE
- Emit `ValidatorLeaveRequested` event

### 4. allowValidatorSetChange for Leave (Low Priority)

Added `allowValidatorSetChange` check to `leaveValidatorSet()`.

**Rationale:** Aptos gates both join AND leave with this config flag.

## Files Modified

| File | Changes |
|------|---------|
| `src/staking/ValidatorManagement.sol` | Added modifier, checks, and helper function |
| `src/foundation/Errors.sol` | Added `CannotRemoveLastValidator` error |
| `test/unit/staking/ValidatorManagement.t.sol` | Added mock, fixed tests, added security tests |
| `spec_v2/validator_management.spec.md` | Updated spec with new behavior |

## New Tests

- `test_RevertWhen_leaveValidatorSet_lastValidator()`
- `test_leaveValidatorSet_fromPendingActive()`
- `test_RevertWhen_joinValidatorSet_duringReconfiguration()`
- `test_RevertWhen_leaveValidatorSet_duringReconfiguration()`
- `test_RevertWhen_rotateConsensusKey_duringReconfiguration()`
- `test_RevertWhen_setFeeRecipient_duringReconfiguration()`
- `test_RevertWhen_leaveValidatorSet_setChangesDisabled()`

## Test Results

All 45 tests pass.

## Security Comparison with Aptos

| Check | Aptos | Gravity (After) |
|-------|-------|-----------------|
| Reconfig-in-progress guard | ✅ | ✅ |
| Last validator protection | ✅ | ✅ |
| Leave from PENDING_ACTIVE | ✅ | ✅ |
| allowValidatorSetChange for leave | ✅ | ✅ |
| BLS PoP validation | ✅ (on-chain) | ❌ (by design) |
| Maximum stake at join | ✅ | ❌ (caps at epoch) |
| Voting power limit at join | ✅ | ❌ (at epoch) |


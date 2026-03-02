# GCC Round 2 HIGH Fixes Design

Date: 2026-03-02

## GCC-R2-001: forceLeaveValidatorSet Uses Array Length Instead of Active Count

**Problem:** `forceLeaveValidatorSet()` checks `_activeValidators.length <= 1` to prevent removing the last validator. However `_activeValidators` contains `PENDING_INACTIVE` entries until epoch boundary. This is the same bug pattern as GRAV-005 — `leaveValidatorSet()` was fixed to use `_countActiveValidators()`, but `forceLeaveValidatorSet()` was not updated consistently. If multiple validators are already `PENDING_INACTIVE`, governance could force-leave the last truly `ACTIVE` validator, halting consensus.

**Fix:** Replace `_activeValidators.length <= 1` with `_countActiveValidators() <= 1` in `forceLeaveValidatorSet()`, consistent with the GRAV-005 fix applied to `leaveValidatorSet()`.

**Files:** ValidatorManagement.sol

**Review Comments** reviewer: ; state: ; comments: 

## GCC-R2-002: GBridgeReceiver Missing Decoded Data Validation

**Problem:** In `_handlePortalMessage()`, after `abi.decode(message, (uint256, address))`, the decoded `amount` and `recipient` are never validated. A zero `amount` results in a no-op mint (wasting gas, emitting misleading `NativeMinted` event). A zero `recipient` mints tokens to `address(0)`, effectively burning them irreversibly.

**Fix:** Add `if (amount == 0) revert Errors.ZeroAmount();` and `if (recipient == address(0)) revert Errors.ZeroAddress();` after the `abi.decode` call and before the nonce is marked as processed.

**Files:** GBridgeReceiver.sol

**Review Comments** reviewer: ; state: ; comments: 

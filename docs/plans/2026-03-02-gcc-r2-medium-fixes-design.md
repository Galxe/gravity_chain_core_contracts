# GCC Round 2 MEDIUM Fixes Design

Date: 2026-03-02

## Group A: Input Validation

### GCC-R2-003: StakePool._withdrawAvailable Missing Recipient Zero-Address Check

**Problem:** The `recipient` parameter in `_withdrawAvailable()` is passed to a low-level `.call{value: amount}("")` without zero-address validation. If `recipient == address(0)`, native tokens are permanently burned. While `onlyStaker` modifier limits callers, defence-in-depth requires validating addresses receiving value transfers.

**Fix:** Add `if (recipient == address(0)) revert Errors.ZeroAddress();` at the top of `_withdrawAvailable()`.

**Files:** StakePool.sol

**Review Comments** reviewer: ; state: ; comments: 

### GCC-R2-005: OracleRequestQueue Zero-Duration and Zero-Fee Defaults

**Problem:** `_fees[sourceType]` and `_expirationDurations[sourceType]` default to 0 if not explicitly set via `setFee()` / `setExpiration()`. A `sourceType` could be supported in `IOnDemandOracleTaskConfig` but have zero fee and zero expiration, meaning: requests are free and `expiresAt = block.timestamp`, making them immediately expirable after the grace period. This could be exploited to flood the queue with free requests.

**Fix:** Add validation in `request()`: `if (duration == 0) revert ExpirationNotConfigured(sourceType);` to ensure expiration has been properly configured before accepting requests.

**Files:** OracleRequestQueue.sol

**Review Comments** reviewer: ; state: ; comments: 

## Group B: Governance

### GCC-R2-004: Governance Proposal ID 0 Sentinel Collision

**Problem:** `nextProposalId` starts at 1, and `p.id == 0` is used as a sentinel for "proposal not found" throughout the contract. While `nextProposalId` only increments and never produces 0, this sentinel convention is implicit, undocumented, and fragile. A storage collision or improper upgrade could break the invariant.

**Fix:** Add a comment block documenting the sentinel convention at the `nextProposalId` declaration. Optionally add a defence-in-depth assertion in `createProposal()`.

**Files:** Governance.sol

**Review Comments** reviewer: ; state: ; comments: 

### GCC-R2-006: Voting Power Truncation Risk in getRemainingVotingPower

**Problem:** `getRemainingVotingPower()` computes `uint256 poolPower` from the staking contract and casts it to `uint128` via `uint128(poolPower - used)`. If `poolPower` exceeds `type(uint128).max`, the cast silently truncates. While `uint128.max ≈ 3.4e38` is astronomically large for practical stake amounts, this is a latent truncation bug.

**Fix:** Add `if (poolPower > type(uint128).max) poolPower = type(uint128).max;` before the cast.

**Files:** Governance.sol

**Review Comments** reviewer: ; state: ; comments: 

## Group C: System Consistency

### GCC-R2-007: Staking.createPool Not Guarded by whenNotReconfiguring

**Problem:** `StakePool.addStake()`, `unstake()`, `withdrawAvailable()`, and `renewLockUntil()` are all guarded by `whenNotReconfiguring`, but `Staking.createPool()` is not. A pool created during DKG/reconfiguration could read stale config values (e.g., `lockupDurationMicros` that is about to change via pending config). The Aptos reference blocks all staking mutations during reconfiguration.

**Fix:** Add reconfiguration guard to `createPool()`. Since `Staking.sol` doesn't currently import `IReconfiguration`, add the import and inline the check: `if (IReconfiguration(SystemAddresses.RECONFIGURATION).isTransitionInProgress()) revert Errors.ReconfigurationInProgress();`.

**Files:** Staking.sol

**Review Comments** reviewer: ; state: ; comments: 

### GCC-R2-008: GBridgeSender.emergencyWithdraw Allows Repeated Use After Re-initiation

**Problem:** After `emergencyWithdraw()` executes, it resets `emergencyUnlockTime = 0`. The owner can then call `initiateEmergencyWithdraw()` again and drain remaining tokens after another 7-day wait. While the owner is trusted, a compromised owner key could slowly drain all locked bridge tokens across multiple 7-day cycles.

**Fix:** Add `bool public emergencyUsed` flag. Check in `initiateEmergencyWithdraw()` and set in `emergencyWithdraw()` to make it a one-shot mechanism.

**Files:** GBridgeSender.sol

**Review Comments** reviewer: ; state: ; comments: 

# GCC MEDIUM Fixes Design

Date: 2026-02-23

## Group A: Config Validation

### GCC-004: StakingConfig Pending Config Pattern

**Problem:** StakingConfig applies governance parameter changes immediately, unlike other config contracts that use epoch-boundary pending config pattern.

**Fix:** Add `PendingConfig` struct and `hasPendingConfig` flag. Convert 4 setters (`setMinimumStake`, `setLockupDurationMicros`, `setUnbondingDelayMicros`, `setMinimumProposalStake`) to `setForNextEpoch()`. Add `applyPendingConfig()` callable by RECONFIGURATION at epoch boundaries. Mirror GovernanceConfig pattern.

**Files:** StakingConfig.sol, Reconfiguration.sol (call applyPendingConfig), Genesis.sol (if needed)

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-011: GovernanceConfig Zero Threshold Validation

**Problem:** `minVotingThreshold` and `requiredProposerStake` can be set to zero, allowing proposals to pass with 1 vote or enabling spam.

**Fix:** Add `!= 0` validation for both fields in `_validateConfig()`.

**Files:** GovernanceConfig.sol, Errors.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-012: StakingConfig Zero Minimum Validation

**Problem:** `minimumStake` and `minimumProposalStake` can be set to zero, removing gatekeeping.

**Fix:** Add `!= 0` validation in `setForNextEpoch()` (after GCC-004 conversion).

**Files:** StakingConfig.sol, Errors.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

## Group B: Governance

### GCC-008: Proposal Cancellation Mechanism — **NOT NEEDED (Removed)**
> Proposal cancellation is not needed at this time. The `cancel()` function, `cancelled` mapping, `CANCELLED` enum value, and `NotAuthorizedToCancel` error have been removed. Future audits should not consider the absence of proposal cancellation as a gap.

**Review Comments** reviewer: AlexYue; state: rejected; comments: Aptos does not have this implementation, we do not need it.

### GCC-009: Execution Expiration Window — **NOT NEEDED (Removed)**
> Execution expiration window is not needed at this time. The `executionWindowMicros` field, expiration check in `execute()`, and `ProposalExecutionExpired` error have been removed. Future audits should not consider the absence of an execution expiration window as a gap.

**Review Comments** reviewer: AlexYue; state: rejected; comments: Aptos does not have this implementation, we do not need it.

### GCC-010: Snapshot-Based Voting Power — **NOT NEEDED (Removed)**
> Snapshot-based voting power is not needed at this time. Voting power continues to be evaluated at `expirationTime`. Future audits should not consider the evaluation timing as a gap.

**Review Comments** reviewer: AlexYue; state: rejected; comments: Aptos does not have this implementation, we do not need it.

## Group C: Staking Safety

### GCC-005: Max Lockup Protection

**Problem:** `renewLockUntil()` allows setting lockup to uint64 max (~584,942 years), permanently freezing funds.

**Fix:** Add `MAX_LOCKUP_DURATION` constant (4 years in microseconds = `4 * 365 days * 1_000_000`). Check in `renewLockUntil()`. New error: `ExcessiveLockupDuration`.

**Files:** StakePool.sol, IStakePool.sol, Errors.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-013: Bounded Pending Buckets

**Problem:** Each unstake with different `lockedUntil` creates new bucket. Unbounded array growth causes gas issues.

**Fix:** Add `MAX_PENDING_BUCKETS` constant (1000). Check in `_addToPendingBucket()` before creating new bucket. New error: `TooManyPendingBuckets`.

**Files:** StakePool.sol, Errors.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-014: Performance Data Index Verification

**Problem:** `evictUnderperformingValidators()` assumes 1:1 index correspondence between `_activeValidators` and performance data. Mismatch would evict wrong validators.

**Fix:** Add explicit `if (activeLen != perfLen)` check. Emit `PerformanceLengthMismatch` event and return early (no evictions).

**Files:** ValidatorManagement.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-015: Minimum Validator Floor for Governance

**Problem:** `forceLeaveValidatorSet()` can remove last validator, causing consensus halt.

**Fix:** Add same check as `leaveValidatorSet()`: `if (_activeValidators.length <= 1) revert CannotRemoveLastValidator()`.

**Files:** ValidatorManagement.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

## Group D: Oracle & Bridge

### GCC-006: Source Chain ID Validation

**Problem:** GBridgeReceiver ignores `sourceId`, accepting messages from any chain where sender address matches.

**Fix:** Add `uint256 public immutable trustedSourceId` to constructor. Validate `sourceId == trustedSourceId` in `_handlePortalMessage()`. New error: `InvalidSourceChain`.

**Files:** GBridgeReceiver.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-007: Sequential Nonce Enforcement

**Problem:** `_updateNonce()` only requires `nonce > currentNonce`, allowing gap skipping and permanently lost records.

**Fix:** Change to `nonce == currentNonce + 1`. Update error from `NonceNotIncreasing` to `NonceNotSequential`.

**Files:** NativeOracle.sol, Errors.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-016: Fee Refund for Excess Payment

**Problem:** GravityPortal `send()` absorbs all ETH above required fee with no refund.

**Fix:** After fee validation, refund `msg.value - requiredFee` to `msg.sender` via low-level call.

**Files:** GravityPortal.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-017: Oracle Refund Race Condition

**Problem:** `markFulfilled()` and `refund()` can race at expiration boundary, potentially double-spending the fee.

**Fix:** Add `fulfillmentGracePeriod` (5 minutes) to OracleRequestQueue. In `refund()`, require `block.timestamp >= req.expiresAt + fulfillmentGracePeriod`.

**Files:** OracleRequestQueue.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-018: GBridgeSender Emergency Withdrawal

**Problem:** Locked ERC20 tokens have no recovery path if bridge is deprecated or Gravity halts.

**Fix:** Two-step emergency withdrawal: `initiateEmergencyWithdraw()` starts 7-day timer, `emergencyWithdraw(recipient, amount)` transfers after delay. Owner only.

**Files:** GBridgeSender.sol

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

## Group E: Genesis Config

### GCC-019: JWK Callback Address Fix

**Problem:** 4-node genesis config uses wrong JWK callback address `0x...1625F2018` instead of `0x...1625F4001`.

**Fix:** Update `genesis_config.json` callback address to match single-node config.

**Files:** genesis-tool/config/genesis_config.json

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A


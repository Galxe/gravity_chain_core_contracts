# GCC MEDIUM Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all 16 MEDIUM severity security vulnerabilities (GCC-004 through GCC-019).

**Architecture:** Five groups of changes targeting config validation, governance, staking safety, oracle/bridge, and genesis. Each group is independent and can be implemented in parallel.

**Tech Stack:** Solidity 0.8.30, Foundry (forge build/test/fmt), microsecond timestamps.

---

### Task 1: GCC-019 — Fix JWK Callback Address in Genesis Config

**Files:**
- Modify: `genesis-tool/config/genesis_config.json:47`

**Step 1: Fix the address**

In `genesis-tool/config/genesis_config.json`, change the JWK callback address from `0x00000000000000000000000000000001625F2018` to `0x00000000000000000000000000000001625F4001` (the correct JWK_MANAGER system address, matching `genesis_config_single.json`).

**Step 2: Verify**

Run: `/home/zz/.foundry/bin/forge build --force`
Expected: Compilation succeeds.

---

### Task 2: GCC-007 — Enforce Sequential Nonces in NativeOracle

**Files:**
- Modify: `src/oracle/NativeOracle.sol:301-314` (_updateNonce)
- Modify: `src/foundation/Errors.sol` (add NonceNotSequential error)

**Step 1: Add the new error to Errors.sol**

In the NATIVE ORACLE ERRORS section, add:
```solidity
error NonceNotSequential(uint32 sourceType, uint256 sourceId, uint128 expectedNonce, uint128 providedNonce);
```

**Step 2: Update _updateNonce in NativeOracle.sol**

Change the validation from `nonce <= currentNonce` to `nonce != currentNonce + 1`:
```solidity
function _updateNonce(uint32 sourceType, uint256 sourceId, uint128 nonce) internal {
    uint128 currentNonce = _nonces[sourceType][sourceId];
    if (nonce != currentNonce + 1) {
        revert Errors.NonceNotSequential(sourceType, sourceId, currentNonce + 1, nonce);
    }
    _nonces[sourceType][sourceId] = nonce;
}
```

**Step 3: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 3: GCC-011 — Add Zero Threshold Validation to GovernanceConfig

**Files:**
- Modify: `src/runtime/GovernanceConfig.sol:187-197` (_validateConfig)
- Modify: `src/foundation/Errors.sol` (add errors)

**Step 1: Add errors**

In the GOVERNANCE ERRORS section of Errors.sol, add:
```solidity
error InvalidVotingThreshold();
error InvalidProposerStake();
```

**Step 2: Update _validateConfig in GovernanceConfig.sol**

Add the `_minVotingThreshold` and `_requiredProposerStake` parameters and checks:
```solidity
function _validateConfig(
    uint128 _minVotingThreshold,
    uint256 _requiredProposerStake,
    uint64 _votingDurationMicros,
    uint64 _executionDelayMicros
) internal pure {
    if (_votingDurationMicros == 0) revert Errors.InvalidVotingDuration();
    if (_executionDelayMicros == 0) revert Errors.InvalidExecutionDelay();
    if (_minVotingThreshold == 0) revert Errors.InvalidVotingThreshold();
    if (_requiredProposerStake == 0) revert Errors.InvalidProposerStake();
}
```

Update both call sites (`initialize` and `setForNextEpoch`) to pass all 4 parameters.

**Step 3: Update tests**

Update GovernanceConfig tests to ensure they pass non-zero values for threshold/stake. Add test cases for zero-value rejection.

**Step 4: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 4: GCC-004 + GCC-012 — StakingConfig Pending Config Pattern + Zero Validation

**Files:**
- Modify: `src/runtime/StakingConfig.sol` (major rewrite)
- Modify: `src/blocker/Reconfiguration.sol:258-267` (add StakingConfig.applyPendingConfig call)
- Modify: `src/foundation/Errors.sol` (add errors)
- Modify: test files that use StakingConfig setters

**Step 1: Add errors to Errors.sol**

In STAKING CONFIG section, add:
```solidity
error StakingConfigNotInitialized();
error InvalidMinimumStake();
error InvalidMinimumProposalStake();
```

**Step 2: Rewrite StakingConfig.sol**

Replace the 4 immediate setters with the pending config pattern (mirroring GovernanceConfig):

1. Add `PendingConfig` struct with all 4 fields
2. Add `_pendingConfig`, `hasPendingConfig` state variables
3. Replace `setMinimumStake`, `setLockupDurationMicros`, `setUnbondingDelayMicros`, `setMinimumProposalStake` with a single `setForNextEpoch(uint256, uint64, uint64, uint256)` function (GOVERNANCE only)
4. Add `applyPendingConfig()` function (RECONFIGURATION only)
5. Add `getPendingConfig()` view function
6. Add `_validateConfig()` internal with non-zero checks for all 4 params (GCC-012)
7. Update `initialize()` to also validate minimumStake and minimumProposalStake != 0
8. Add events: `StakingConfigUpdated`, `PendingStakingConfigSet`, `PendingStakingConfigCleared`

**Step 3: Update Reconfiguration.sol**

Add import for StakingConfig and call `StakingConfig(SystemAddresses.STAKE_CONFIG).applyPendingConfig()` in `_applyReconfiguration()` alongside other config applies (line ~267).

**Step 4: Update tests**

Update any tests that call `setMinimumStake()` etc. to use `setForNextEpoch()` + `applyPendingConfig()` pattern. Update Genesis.sol if it calls StakingConfig setters.

**Step 5: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 5: GCC-005 — Max Lockup Protection in StakePool

**Files:**
- Modify: `src/staking/StakePool.sol:307-329` (renewLockUntil)
- Modify: `src/foundation/Errors.sol`

**Step 1: Add error**

```solidity
error ExcessiveLockupDuration(uint64 provided, uint64 maximum);
```

**Step 2: Add constant and check in StakePool.sol**

Add at contract level:
```solidity
uint64 public constant MAX_LOCKUP_DURATION = 4 * 365 days * 1_000_000; // 4 years in microseconds
```

In `renewLockUntil()`, add check before the overflow check:
```solidity
if (durationMicros > MAX_LOCKUP_DURATION) {
    revert Errors.ExcessiveLockupDuration(durationMicros, MAX_LOCKUP_DURATION);
}
```

**Step 3: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 6: GCC-013 — Bound Pending Bucket Growth in StakePool

**Files:**
- Modify: `src/staking/StakePool.sol:420-445` (_addToPendingBucket)
- Modify: `src/foundation/Errors.sol`

**Step 1: Add error**

```solidity
error TooManyPendingBuckets(uint256 current, uint256 maximum);
```

**Step 2: Add constant and check in StakePool.sol**

Add at contract level:
```solidity
uint256 public constant MAX_PENDING_BUCKETS = 1000;
```

In `_addToPendingBucket()`, when about to push a new bucket (the `else if` branch at line 435), add:
```solidity
if (len >= MAX_PENDING_BUCKETS) {
    revert Errors.TooManyPendingBuckets(len, MAX_PENDING_BUCKETS);
}
```

**Step 3: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 7: GCC-014 — Performance Data Index Verification

**Files:**
- Modify: `src/staking/ValidatorManagement.sol:574-627` (evictUnderperformingValidators)

**Step 1: Add event and strict length check**

Replace the `min(activeLen, perfLen)` safety check with a strict equality check:
```solidity
uint256 activeLen = _activeValidators.length;
uint256 perfLen = perfs.length;
if (activeLen != perfLen) {
    emit PerformanceLengthMismatch(activeLen, perfLen);
    return;
}
```

Add the event to the contract:
```solidity
event PerformanceLengthMismatch(uint256 activeCount, uint256 perfCount);
```

**Step 2: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 8: GCC-015 — Minimum Validator Floor for Force Leave

**Files:**
- Modify: `src/staking/ValidatorManagement.sol:425-453` (forceLeaveValidatorSet)

**Step 1: Add last-validator check**

In `forceLeaveValidatorSet()`, after the ACTIVE status check (line 443), add:
```solidity
if (_activeValidators.length <= 1) {
    revert Errors.CannotRemoveLastValidator();
}
```

Remove the comment about governance being able to remove the last validator.

**Step 2: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 9: GCC-010 — Snapshot-Based Voting Power

**Files:**
- Modify: `src/governance/Governance.sol:157-174,284-294,362-421`

**Step 1: Change voting power evaluation time**

In `getRemainingVotingPower()` (line 167), change:
```solidity
// Before: uint256 poolPower = _staking().getPoolVotingPower(stakePool, p.expirationTime);
uint256 poolPower = _staking().getPoolVotingPower(stakePool, p.creationTime);
```

In `createProposal()` (line 290), change:
```solidity
// Before: uint256 votingPower = _staking().getPoolVotingPower(stakePool, expirationTime);
uint256 votingPower = _staking().getPoolVotingPower(stakePool, now_);
```

**Step 2: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 10: GCC-008 — Proposal Cancellation

**Files:**
- Modify: `src/governance/Governance.sol` (add cancel function)
- Modify: `src/governance/IGovernance.sol` (add cancel signature + event)
- Modify: `src/foundation/Errors.sol`

**Step 1: Add error**

```solidity
error NotAuthorizedToCancel(address caller);
```

**Step 2: Add cancelled mapping and event to Governance.sol**

```solidity
mapping(uint64 => bool) public cancelled;
```

Add event to IGovernance.sol:
```solidity
event ProposalCancelled(uint64 indexed proposalId);
```

**Step 3: Add cancel function**

```solidity
function cancel(uint64 proposalId) external {
    Proposal storage p = _proposals[proposalId];
    if (p.id == 0) revert Errors.ProposalNotFound(proposalId);
    if (p.isResolved) revert Errors.ProposalAlreadyResolved(proposalId);
    if (executed[proposalId]) revert Errors.ProposalAlreadyExecuted(proposalId);
    if (msg.sender != p.proposer) revert Errors.NotAuthorizedToCancel(msg.sender);

    uint64 now_ = _now();
    if (now_ >= p.expirationTime) revert Errors.VotingPeriodEnded(p.expirationTime);

    cancelled[proposalId] = true;
    p.isResolved = true;
    p.resolutionTime = now_;

    emit ProposalCancelled(proposalId);
}
```

**Step 4: Update getProposalState**

In `getProposalState()`, after the `executed` check, add:
```solidity
if (cancelled[proposalId]) {
    return ProposalState.CANCELLED;
}
```

**Step 5: Add interface declaration**

In IGovernance.sol, add:
```solidity
function cancel(uint64 proposalId) external;
```

**Step 6: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 11: GCC-009 — Execution Expiration Window

**Files:**
- Modify: `src/runtime/GovernanceConfig.sol` (add executionWindowMicros)
- Modify: `src/governance/Governance.sol` (add expiration check in execute)
- Modify: `src/governance/IGovernance.sol`
- Modify: `src/foundation/Errors.sol`
- Modify: `src/Genesis.sol` (add parameter)
- Modify: `genesis-tool/src/genesis.rs`
- Modify: `genesis-tool/config/genesis_config.json` + `genesis_config_single.json`
- Modify: test files for GovernanceConfig, Governance, Genesis

**Step 1: Add error**

```solidity
error ProposalExecutionExpired(uint64 proposalId);
error InvalidExecutionWindow();
```

**Step 2: Add executionWindowMicros to GovernanceConfig**

Add state variable:
```solidity
uint64 public executionWindowMicros;
```

Add to PendingConfig struct:
```solidity
uint64 executionWindowMicros;
```

Update `initialize()`, `setForNextEpoch()`, `applyPendingConfig()`, `_validateConfig()` to handle the new field. Validate `_executionWindowMicros != 0`.

**Step 3: Add expiration check in Governance.execute()**

After the execution delay check, add:
```solidity
uint64 executionWindow = _config().executionWindowMicros();
uint64 latestExecution = earliestExecution + executionWindow;
if (now_ > latestExecution) {
    revert Errors.ProposalExecutionExpired(proposalId);
}
```

**Step 4: Update Genesis.sol, genesis-tool, and configs**

Add `executionWindowMicros` parameter to GovernanceConfig.initialize() call in Genesis.sol. Default: `604_800_000_000` (7 days in microseconds).

Update genesis-tool Rust struct and config JSONs.

**Step 5: Update all affected tests**

Add the new parameter everywhere GovernanceConfig is initialized or setForNextEpoch is called.

**Step 6: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 12: GCC-006 — Source Chain ID Validation in GBridgeReceiver

**Files:**
- Modify: `src/oracle/evm/native_token_bridge/GBridgeReceiver.sol`
- Modify: `src/oracle/evm/native_token_bridge/IGBridgeReceiver.sol`

**Step 1: Add immutable and error**

```solidity
uint256 public immutable trustedSourceId;
error InvalidSourceChain(uint256 provided, uint256 expected);
```

**Step 2: Update constructor**

```solidity
constructor(address trustedBridge_, uint256 trustedSourceId_) {
    trustedBridge = trustedBridge_;
    trustedSourceId = trustedSourceId_;
}
```

**Step 3: Add validation in _handlePortalMessage**

Before the sender check (line 66), add:
```solidity
if (sourceId != trustedSourceId) {
    revert InvalidSourceChain(sourceId, trustedSourceId);
}
```

Remove the line that silences `sourceId` from the unused variables tuple.

**Step 4: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 13: GCC-016 — Fee Refund in GravityPortal

**Files:**
- Modify: `src/oracle/evm/GravityPortal.sol:60-78` (send)

**Step 1: Add refund logic**

After the fee validation in `send()`, add refund:
```solidity
// Refund excess fee
if (msg.value > requiredFee) {
    uint256 refund = msg.value - requiredFee;
    (bool success,) = msg.sender.call{value: refund}("");
    require(success, "Refund failed");
}
```

**Step 2: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 14: GCC-017 — Refund Race Condition in OracleRequestQueue

**Files:**
- Modify: `src/oracle/ondemand/OracleRequestQueue.sol:175-213` (refund)

**Step 1: Add grace period constant**

```solidity
uint64 public constant FULFILLMENT_GRACE_PERIOD = 300; // 5 minutes in seconds
```

**Step 2: Update refund expiration check**

Change line 194 from:
```solidity
if (block.timestamp < req.expiresAt) {
```
to:
```solidity
if (block.timestamp < req.expiresAt + FULFILLMENT_GRACE_PERIOD) {
```

Update the error emission to reflect the grace period:
```solidity
revert NotExpired(requestId, req.expiresAt + FULFILLMENT_GRACE_PERIOD, uint64(block.timestamp));
```

**Step 3: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 15: GCC-018 — Emergency Withdrawal for GBridgeSender

**Files:**
- Modify: `src/oracle/evm/native_token_bridge/GBridgeSender.sol`
- Modify: `src/oracle/evm/native_token_bridge/IGBridgeSender.sol`

**Step 1: Add state variables and events**

```solidity
uint256 public emergencyUnlockTime;
uint256 public constant EMERGENCY_TIMELOCK = 7 days;

event EmergencyWithdrawInitiated(uint256 unlockTime);
event EmergencyWithdraw(address indexed recipient, uint256 amount);
```

**Step 2: Add two-step withdrawal functions**

```solidity
function initiateEmergencyWithdraw() external onlyOwner {
    emergencyUnlockTime = block.timestamp + EMERGENCY_TIMELOCK;
    emit EmergencyWithdrawInitiated(emergencyUnlockTime);
}

function emergencyWithdraw(address recipient, uint256 amount) external onlyOwner {
    if (emergencyUnlockTime == 0) revert EmergencyNotInitiated();
    if (block.timestamp < emergencyUnlockTime) revert EmergencyTimelockNotExpired(emergencyUnlockTime);
    if (recipient == address(0)) revert ZeroRecipient();

    emergencyUnlockTime = 0; // Reset after use
    IERC20(gToken).safeTransfer(recipient, amount);
    emit EmergencyWithdraw(recipient, amount);
}
```

Add errors:
```solidity
error EmergencyNotInitiated();
error EmergencyTimelockNotExpired(uint256 unlockTime);
```

**Step 3: Add interface declarations in IGBridgeSender.sol**

**Step 4: Build and test**

Run: `/home/zz/.foundry/bin/forge build --force && /home/zz/.foundry/bin/forge test`

---

### Task 16: Final Verification and Commit

**Step 1: Format**

Run: `/home/zz/.foundry/bin/forge fmt`

**Step 2: Full build**

Run: `/home/zz/.foundry/bin/forge build --force`
Expected: Compilation succeeds with only pre-existing warnings.

**Step 3: Full test suite**

Run: `/home/zz/.foundry/bin/forge test`
Expected: All tests pass (891+ tests, 0 failures).

**Step 4: Commit**

```bash
git add <all modified files>
git commit -m "fix: address MEDIUM severity security vulnerabilities (GCC-004 through GCC-019)"
git push origin main
```

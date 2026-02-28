# LOW Severity Security Fixes Design (GCC-020 through GCC-043)

**Goal:** Address all 24 LOW severity findings from the security audit — input validation, missing events, code quality, design improvements, gas optimization, and security hardening.

## Category A — Missing Input Validation (5 fixes)

### GCC-020: Zero-address in StakePool role setters
Add `if (newX == address(0)) revert Errors.ZeroAddress();` to `setOperator()`, `setVoter()`, `setStaker()`.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-021: Zero-address in Staking.createPool
Add zero-address checks for `owner` and `staker` in `createPool()`.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-040: Zero-address for trustedBridge in GBridgeReceiver
Add `if (trustedBridge_ == address(0)) revert Errors.ZeroAddress();` in constructor.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-041: registerValidator doesn't check allowValidatorSetChange
Add check in `registerValidator()`.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-042: addStake lockup overflow
Add overflow check consistent with `renewLockUntil()`.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

## Category B — Missing Events (3 fixes)

### GCC-025: Fee recipient applied event
Emit `FeeRecipientApplied(stakePool, old, new)` in `_applyPendingFeeRecipients()`.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-027: Timestamp NIL block event
Only emit `GlobalTimeUpdated` when timestamp actually changes.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-037: Validator reverted inactive event
Emit `ValidatorRevertedInactive(stakePool, votingPower, minimumBond)` in `_applyRevertInactive()`.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

## Category C — Code Quality (5 fixes)

### GCC-023: Remove TODO comments

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-033: Blocker use Errors.AlreadyInitialized

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-039: Document seconds vs microseconds in OracleRequestQueue

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-043: GravityPortal use custom errors

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-031: Remove unchecked in PerformanceTracker

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

## Category D — Design / Architecture (5 fixes)

### GCC-022: Governance.execute() native token support — **NOT NEEDED (Removed)**
> Native token forwarding in governance proposals is not required. Governance calls should execute without forwarding ETH. The `uint256[] values` parameter, `payable` modifier, and ETH refund logic have been removed. Future audits should not consider the absence of native token support in `execute()` as a gap.

**Review Comments** reviewer: AlexYue; state: rejected; comments: Aptos does not have this implementation, we do not need it.

### GCC-024: Fee recipient parameter at registration — **NOT NEEDED (Removed)**
> The `feeRecipient` parameter is not needed at registration time. Fee recipient defaults to `msg.sender` (operator) at registration and can be changed post-registration via `setFeeRecipient()`. Future audits should not consider the absence of explicit `feeRecipient` at registration as a gap.

**Review Comments** reviewer: AlexYue; state: rejected; comments: Aptos does not have this implementation, we do not need it.

### GCC-026: Upper bound on config durations
Add max constants to StakingConfig and ValidatorConfig.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-030: OracleRequestQueue excess fee refund
Refund excess msg.value in `request()`.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-036: Genesis lockedUntil as parameter
Add `initialLockedUntilMicros` to GenesisInitParams.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

## Category E — Gas / Performance (2 fixes)

### GCC-034: O(1) pendingInactive lookups
Use temporary mapping for O(1) lookups.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-035: Incremental eviction counter
Track remainingActive as counter, not re-count.

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

## Category F — Security Hardening (4 fixes)

### GCC-028: GravityPortal.withdrawFees() onlyOwner

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-029: recordBatch validate blockNumbers length

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-032: Override renounceOwnership to revert

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A

### GCC-038: StakePool ReentrancyGuard

**Review Comments** reviewer: AlexYue; state: accepted; comments: N/A


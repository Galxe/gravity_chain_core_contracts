# LOW Severity Security Fixes Design (GCC-020 through GCC-043)

**Goal:** Address all 24 LOW severity findings from the security audit — input validation, missing events, code quality, design improvements, gas optimization, and security hardening.

## Category A — Missing Input Validation (5 fixes)

### GCC-020: Zero-address in StakePool role setters
Add `if (newX == address(0)) revert Errors.ZeroAddress();` to `setOperator()`, `setVoter()`, `setStaker()`.

### GCC-021: Zero-address in Staking.createPool
Add zero-address checks for `owner` and `staker` in `createPool()`.

### GCC-040: Zero-address for trustedBridge in GBridgeReceiver
Add `if (trustedBridge_ == address(0)) revert Errors.ZeroAddress();` in constructor.

### GCC-041: registerValidator doesn't check allowValidatorSetChange
Add check in `registerValidator()`.

### GCC-042: addStake lockup overflow
Add overflow check consistent with `renewLockUntil()`.

## Category B — Missing Events (3 fixes)

### GCC-025: Fee recipient applied event
Emit `FeeRecipientApplied(stakePool, old, new)` in `_applyPendingFeeRecipients()`.

### GCC-027: Timestamp NIL block event
Only emit `GlobalTimeUpdated` when timestamp actually changes.

### GCC-037: Validator reverted inactive event
Emit `ValidatorRevertedInactive(stakePool, votingPower, minimumBond)` in `_applyRevertInactive()`.

## Category C — Code Quality (5 fixes)

### GCC-023: Remove TODO comments
### GCC-033: Blocker use Errors.AlreadyInitialized
### GCC-039: Document seconds vs microseconds in OracleRequestQueue
### GCC-043: GravityPortal use custom errors
### GCC-031: Remove unchecked in PerformanceTracker

## Category D — Design / Architecture (5 fixes)

### GCC-022: Governance.execute() native token support — **NOT NEEDED (Removed)**
> Native token forwarding in governance proposals is not required. Governance calls should execute without forwarding ETH. The `uint256[] values` parameter, `payable` modifier, and ETH refund logic have been removed. Future audits should not consider the absence of native token support in `execute()` as a gap.

### GCC-024: Fee recipient parameter at registration
Add `feeRecipient` to `registerValidator()`.

### GCC-026: Upper bound on config durations
Add max constants to StakingConfig and ValidatorConfig.

### GCC-030: OracleRequestQueue excess fee refund
Refund excess msg.value in `request()`.

### GCC-036: Genesis lockedUntil as parameter
Add `initialLockedUntilMicros` to GenesisInitParams.

## Category E — Gas / Performance (2 fixes)

### GCC-034: O(1) pendingInactive lookups
Use temporary mapping for O(1) lookups.

### GCC-035: Incremental eviction counter
Track remainingActive as counter, not re-count.

## Category F — Security Hardening (4 fixes)

### GCC-028: GravityPortal.withdrawFees() onlyOwner
### GCC-029: recordBatch validate blockNumbers length
### GCC-032: Override renounceOwnership to revert
### GCC-038: StakePool ReentrancyGuard

# implement_stake_pool_fund_management

- **Agent**: implementation_analyzer
- **Status**: success
- **Duration**: 94967ms
- **Steps**: 1

## Report

Here is the factual implementation summary for the **StakePool** contract:

---

## Implementation Summary: StakePool

### Files/Contracts Involved

| File | Description |
|------|-------------|
| `src/staking/StakePool.sol` | Main implementation — individual stake pool with bucket-based withdrawal model |
| `src/staking/IStakePool.sol` | Interface defining structs (`PendingBucket`), events, and function signatures |
| `src/staking/IValidatorManagement.sol` | Interface used to check validator status during unstake |
| `src/runtime/ITimestamp.sol` | System time source — `nowMicroseconds()` returns `uint64` |
| `src/runtime/IStakingConfig.sol` | Config source — `lockupDurationMicros()`, `unbondingDelayMicros()`, `minimumStake()` |
| `src/runtime/IValidatorConfig.sol` | Config source — `minimumBond()` used during unstake |
| `src/blocker/IReconfiguration.sol` | Queried by `whenNotReconfiguring` modifier — `isTransitionInProgress()` |
| `src/foundation/Errors.sol` | Custom error library |
| `src/foundation/SystemAddresses.sol` | Compile-time constant addresses for system contracts |
| `src/foundation/Types.sol` | `ValidatorStatus` enum (INACTIVE=0, PENDING_ACTIVE=1, ACTIVE=2, PENDING_INACTIVE=3) |

### Inheritance & Guards

- Inherits **Ownable2Step** (from OpenZeppelin) — two-step ownership transfer
- Inherits **ReentrancyGuard** (from OpenZeppelin) — `nonReentrant` modifier
- Three custom modifiers: `onlyStaker`, `onlyFactory`, `whenNotReconfiguring`

### Two-Role Separation

- **Owner** (via Ownable2Step): `setOperator()`, `setVoter()`, `setStaker()` — administrative
- **Staker**: `addStake()`, `unstake()`, `withdrawAvailable()`, `unstakeAndWithdraw()`, `renewLockUntil()`, `withdrawRewards()` — fund management

---

### Key Functions

#### `constructor(address _owner, address _staker, address _operator, address _voter, uint64 _lockedUntil) payable`
1. Sets `FACTORY = msg.sender` (immutable)
2. Reads `now_` from `ITimestamp.nowMicroseconds()` and `minLockup` from `IStakingConfig.lockupDurationMicros()`
3. Validates `_lockedUntil >= now_ + minLockup`, reverts `LockupDurationTooShort` otherwise
4. Sets `staker`, `operator`, `voter`, `lockedUntil`
5. Sets `activeStake = msg.value`
6. Emits `StakeAdded`

#### `addStake() external payable onlyStaker whenNotReconfiguring`
1. Reverts if `msg.value == 0` (`ZeroAmount`)
2. `activeStake += msg.value`
3. Reads `now_` and `minLockup`
4. Overflow check: reverts if `now_ > type(uint64).max - minLockup` (`ExcessiveLockupDuration`)
5. Computes `newLockedUntil = now_ + minLockup`
6. If `newLockedUntil > lockedUntil`, updates `lockedUntil` (extends lockup)
7. Emits `StakeAdded`

#### `_unstake(uint256 amount) internal`
1. Reverts if `amount == 0` (`ZeroAmount`)
2. Reverts if `amount > activeStake` (`InsufficientAvailableStake`)
3. Queries `IValidatorManagement.isValidator(address(this))` at `SystemAddresses.VALIDATOR_MANAGER`
4. If pool is a validator with status `ACTIVE` or `PENDING_INACTIVE`:
   - Reads `minBond` from `IValidatorConfig.minimumBond()`
   - Reverts if `activeStake - amount < minBond` (`WithdrawalWouldBreachMinimumBond`)
5. `activeStake -= amount`
6. Calls `_addToPendingBucket(lockedUntil, amount)` — uses the pool's **current** `lockedUntil`
7. Emits `Unstaked(address(this), amount, lockedUntil)`

#### `_addToPendingBucket(uint64 bucketLockedUntil, uint256 amount) internal`
- **If array is empty**: pushes first bucket `{lockedUntil, cumulativeAmount: amount}`
- **If last bucket's `lockedUntil == bucketLockedUntil`**: merges by adding `amount` to `lastBucket.cumulativeAmount`
- **If last bucket's `lockedUntil < bucketLockedUntil`**:
  - Checks `len < MAX_PENDING_BUCKETS` (1000), reverts `TooManyPendingBuckets` otherwise
  - Pushes new bucket with `cumulativeAmount = lastBucket.cumulativeAmount + amount`
- **If last bucket's `lockedUntil > bucketLockedUntil`**: reverts `LockedUntilDecreased` (should never happen since lockup only extends)

**Invariant**: Buckets are sorted by strictly increasing `lockedUntil`; `cumulativeAmount` is a prefix sum.

#### `_withdrawAvailable(address recipient) internal returns (uint256 amount)`
1. Calls `_getClaimableAmount()` to compute `amount`
2. If `amount == 0`, returns 0
3. **State update (CEI)**: `claimedAmount += amount`
4. Emits `WithdrawalClaimed`
5. **External call**: `payable(recipient).call{value: amount}("")` — reverts `TransferFailed` on failure

#### `unstakeAndWithdraw(uint256 amount, address recipient) external onlyStaker whenNotReconfiguring`
1. Calls `_unstake(amount)`
2. Calls `_withdrawAvailable(recipient)`
3. Returns the withdrawn amount
- **Note**: This function does NOT have `nonReentrant` modifier. However, `_withdrawAvailable` is called inline (not via external `withdrawAvailable` which has `nonReentrant`).

#### `withdrawRewards(address recipient) external onlyStaker nonReentrant`
1. Calls `_getRewardBalance()` to compute `amount`
2. If `amount == 0`, returns 0
3. Emits `RewardsWithdrawn` **before** the transfer
4. **External call**: `payable(recipient).call{value: amount}("")` — reverts `TransferFailed` on failure
- **Note**: `_getRewardBalance()` reads `address(this).balance` and subtracts tracked amounts. The event is emitted before state is modified (no state variable is updated — the balance change from the transfer itself is the "state change").

#### `renewLockUntil(uint64 durationMicros) external onlyStaker whenNotReconfiguring`
1. Reverts if `durationMicros > MAX_LOCKUP_DURATION` (4 years in microseconds)
2. Computes `newLockedUntil = lockedUntil + durationMicros`
3. Overflow check: reverts if `newLockedUntil <= lockedUntil` (`LockupOverflow`)
4. Validates `newLockedUntil >= now_ + minLockup`
5. Updates `lockedUntil = newLockedUntil`
6. Emits `LockupRenewed`

#### `systemRenewLockup() external onlyFactory`
1. Computes `newLockedUntil = now_ + lockupDurationMicros`
2. If `newLockedUntil > lockedUntil`, updates `lockedUntil`
3. Emits `LockupRenewed`
- **No `whenNotReconfiguring` modifier** — called by factory during epoch transitions

---

### O(log n) Binary Search: `_getEffectiveStakeAt(uint64 atTime)`

1. `effectiveActive = (lockedUntil >= atTime) ? activeStake : 0`
2. Calls `_getCumulativeAmountAtTime(atTime)` to get cumulative amount of buckets with `lockedUntil < atTime` (ineffective pending)
3. Subtracts `claimedAmount` from ineffective (floor at 0)
4. Computes `totalPending = lastBucket.cumulativeAmount - claimedAmount`
5. Returns `effectiveActive + (totalPending - ineffective)`

#### `_getCumulativeAmountAtTime(uint64 threshold) internal view`
- Returns 0 if array empty or first bucket's `lockedUntil >= threshold`
- Returns last bucket's `cumulativeAmount` if all buckets have `lockedUntil < threshold`
- Otherwise: binary search on `[0, len-1)` — finds largest index where `lockedUntil < threshold`, returns that bucket's `cumulativeAmount`
- Uses `(left + right) >> 1` for midpoint calculation

#### `_getClaimableAmount() internal view`
1. Reads `now_` and `unbondingDelay`
2. Early return 0 if `now_ <= unbondingDelay`
3. Computes `threshold = now_ - unbondingDelay`
4. Calls `_getCumulativeAmountAtTime(threshold)` to get `claimableCumulative`
5. Returns `claimableCumulative - claimedAmount` (floor at 0)
- Claimable condition: `lockedUntil < now_ - unbondingDelay` (i.e., `now_ > lockedUntil + unbondingDelay`)

#### `_getRewardBalance() internal view`
1. `unclaimedPending = lastBucket.cumulativeAmount - claimedAmount` (or 0 if no buckets)
2. `trackedBalance = activeStake + unclaimedPending`
3. `reward = address(this).balance - trackedBalance` (returns 0 if balance <= tracked)

---

### State Changes Summary

| Function | Storage Modified |
|----------|-----------------|
| `constructor` | `staker`, `operator`, `voter`, `lockedUntil`, `activeStake` |
| `addStake()` | `activeStake` (increase), `lockedUntil` (potential increase) |
| `_unstake()` | `activeStake` (decrease), `_pendingBuckets` (push or merge) |
| `_withdrawAvailable()` | `claimedAmount` (increase) + ETH balance decrease via `call` |
| `renewLockUntil()` | `lockedUntil` (increase) |
| `systemRenewLockup()` | `lockedUntil` (potential increase) |
| `setOperator/Voter/Staker()` | `operator`/`voter`/`staker` |
| `withdrawRewards()` | ETH balance decrease via `call` (no storage variable update) |

### External Calls

| From | Target | Call |
|------|--------|------|
| Constructor, `addStake`, `renewLockUntil`, `_getClaimableAmount`, etc. | `SystemAddresses.TIMESTAMP` | `ITimestamp.nowMicroseconds()` (view) |
| Constructor, `addStake`, `renewLockUntil`, `_getClaimableAmount` | `SystemAddresses.STAKE_CONFIG` | `IStakingConfig.lockupDurationMicros()`, `unbondingDelayMicros()` (view) |
| `_unstake` | `SystemAddresses.VALIDATOR_MANAGER` | `IValidatorManagement.isValidator()`, `getValidatorStatus()` (view) |
| `_unstake` | `SystemAddresses.VALIDATOR_CONFIG` | `IValidatorConfig.minimumBond()` (view) |
| `whenNotReconfiguring` modifier | `SystemAddresses.RECONFIGURATION` | `IReconfiguration.isTransitionInProgress()` (view) |
| `_withdrawAvailable` | `recipient` | `payable(recipient).call{value: amount}("")` |
| `withdrawRewards` | `recipient` | `payable(recipient).call{value: amount}("")` |

### Access Control Map

| Function | Modifier(s) |
|----------|-------------|
| `addStake()` | `onlyStaker`, `whenNotReconfiguring` |
| `unstake()` | `onlyStaker`, `whenNotReconfiguring` |
| `withdrawAvailable()` | `onlyStaker`, `whenNotReconfiguring`, `nonReentrant` |
| `unstakeAndWithdraw()` | `onlyStaker`, `whenNotReconfiguring` |
| `renewLockUntil()` | `onlyStaker`, `whenNotReconfiguring` |
| `withdrawRewards()` | `onlyStaker`, `nonReentrant` |
| `setOperator/Voter/Staker()` | `onlyOwner` |
| `systemRenewLockup()` | `onlyFactory` |

### Constants

- `MAX_LOCKUP_DURATION`: `4 * 365 days * 1_000_000` (4 years in microseconds)
- `MAX_PENDING_BUCKETS`: 1000

### Contract Does Not Have `receive()` or `fallback()`

The contract has no `receive()` or `fallback()` function — ETH can only enter via `payable` functions (`constructor`, `addStake`). Reward deposits would need to come through a mechanism that can send ETH to contracts without `receive()` (e.g., `SELFDESTRUCT`, coinbase rewards, or system-level transfers).

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

task_int | Here is the factual implementation summary for the **StakePo | 94967ms |

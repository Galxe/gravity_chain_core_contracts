# implement_staking_factory_pool_creation

- **Agent**: implementation_analyzer
- **Status**: success
- **Duration**: 93127ms
- **Steps**: 1

## Report

## Implementation Summary: Staking Factory & StakePool

### Files/Contracts Involved

| File | Description |
|------|-------------|
| `src/staking/Staking.sol` | Factory contract — creates StakePool instances via CREATE2, maintains pool registry |
| `src/staking/StakePool.sol` | Individual pool contract — holds stake, manages lockups and withdrawals |
| `src/staking/IStaking.sol` | Interface for the Staking factory |
| `src/staking/IStakePool.sol` | Interface for individual StakePool contracts |
| `src/foundation/SystemAddresses.sol` | Compile-time constants for system contract addresses |
| `src/foundation/SystemAccessControl.sol` | `requireAllowed()` free functions for access control |
| `src/foundation/Errors.sol` | Custom error definitions |
| `src/blocker/IReconfiguration.sol` | Interface for epoch transition state checks |
| `src/runtime/IStakingConfig.sol` | Interface for staking parameters (minimumStake, lockupDuration, unbondingDelay) |

---

### Execution Path: `createPool()`

**`Staking.createPool(owner, staker, operator, voter, lockedUntil)`** (line 178–212)

1. **Reconfiguration guard**: Calls `IReconfiguration(RECONFIGURATION).isTransitionInProgress()` — reverts with `ReconfigurationInProgress()` if true.
2. **Zero-address validation**: Reverts with `ZeroAddress()` if `owner == address(0)` or `staker == address(0)`. Note: `operator` and `voter` are **not** checked for zero.
3. **Minimum stake check**: Reads `minimumStake()` from `IStakingConfig(STAKE_CONFIG)`. Reverts with `InsufficientStakeForPoolCreation` if `msg.value < minStake`.
4. **Nonce and salt**: Reads current `poolNonce`, post-increments it (`nonce = poolNonce++`), converts to `bytes32` salt.
5. **CREATE2 deployment**: Deploys `new StakePool{salt: salt, value: msg.value}(owner, staker, operator, voter, lockedUntil)`. The salt is `bytes32(nonce)`, making addresses deterministic based on `(factory_address, salt, init_code_hash)`.
6. **Registry update**: Pushes the new pool address to `_allPools` array AND sets `_isPool[pool] = true`.
7. **Event**: Emits `PoolCreated(msg.sender, pool, owner, staker, _allPools.length - 1)`. Note: the event signature in `IStaking` has 5 parameters (creator, pool, owner, staker, poolIndex) but the emit call only passes 4 values — `staker` position receives the staker address, but `poolIndex` is `_allPools.length - 1`.

---

### Execution Path: StakePool Constructor

**`StakePool(owner, staker, operator, voter, lockedUntil)`** (line 115–138)

1. Calls `Ownable(_owner)` — sets `_owner` in OpenZeppelin Ownable (inherited via Ownable2Step).
2. Sets `FACTORY = msg.sender` as immutable (the Staking factory address).
3. **Lockup validation**: Reads `nowMicroseconds()` from `ITimestamp(TIMESTAMP)` and `lockupDurationMicros()` from `IStakingConfig(STAKE_CONFIG)`. Reverts with `LockupDurationTooShort` if `_lockedUntil < now_ + minLockup`.
4. Sets `staker`, `operator`, `voter`, `lockedUntil`, and `activeStake = msg.value`.
5. Emits `StakeAdded(address(this), msg.value)`.

---

### Key Functions

#### Staking Factory (Staking.sol)

| Function | Access | Description |
|----------|--------|-------------|
| `isPool(address)` | public view | Returns `_isPool[pool]` |
| `getPool(uint256)` | public view | Returns `_allPools[index]`, reverts if OOB |
| `getAllPools()` | public view | Returns full `_allPools` array |
| `getPoolCount()` | public view | Returns `_allPools.length` |
| `getPoolNonce()` | public view | Returns `poolNonce` |
| `getMinimumStake()` | public view | Reads from `IStakingConfig(STAKE_CONFIG)` |
| `getPoolVotingPower(pool, atTime)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).getVotingPower(atTime)` |
| `getPoolVotingPowerNow(pool)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).getVotingPowerNow()` |
| `getPoolEffectiveStake(pool, atTime)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).getEffectiveStake(atTime)` |
| `getPoolActiveStake(pool)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).getActiveStake()` |
| `getPoolTotalPending(pool)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).getTotalPending()` |
| `getPoolOwner(pool)` | view, `onlyValidPool` | Calls `Ownable(pool).owner()` |
| `getPoolStaker(pool)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).getStaker()` |
| `getPoolVoter(pool)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).getVoter()` |
| `getPoolOperator(pool)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).getOperator()` |
| `getPoolLockedUntil(pool)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).getLockedUntil()` |
| `isPoolLocked(pool)` | view, `onlyValidPool` | Delegates to `IStakePool(pool).isLocked()` |
| `createPool(...)` | external payable | Deploys StakePool via CREATE2 (described above) |
| `renewPoolLockup(pool)` | external, `onlyValidPool` | Requires `msg.sender == VALIDATOR_MANAGER`, then calls `IStakePool(pool).systemRenewLockup()` |

#### StakePool (StakePool.sol)

| Function | Access | Description |
|----------|--------|-------------|
| `addStake()` | `onlyStaker`, `whenNotReconfiguring` | Adds `msg.value` to `activeStake`; extends `lockedUntil` to `max(current, now + minLockup)` with overflow check |
| `unstake(amount)` | `onlyStaker`, `whenNotReconfiguring` | Calls `_unstake(amount)` |
| `withdrawAvailable(recipient)` | `onlyStaker`, `whenNotReconfiguring`, `nonReentrant` | Calls `_withdrawAvailable(recipient)` |
| `unstakeAndWithdraw(amount, recipient)` | `onlyStaker`, `whenNotReconfiguring` | Calls `_unstake(amount)` then `_withdrawAvailable(recipient)` — note: **no** `nonReentrant` modifier on this combined function |
| `renewLockUntil(durationMicros)` | `onlyStaker`, `whenNotReconfiguring` | Extends `lockedUntil += durationMicros`; checks max lockup (4 years), overflow, and minimum lockup |
| `withdrawRewards(recipient)` | `onlyStaker`, `nonReentrant` | Withdraws `address(this).balance - activeStake - unclaimedPending` to recipient; **no** `whenNotReconfiguring` modifier |
| `setOperator(newOperator)` | `onlyOwner` | Sets `operator`; checks non-zero, skips no-op |
| `setVoter(newVoter)` | `onlyOwner` | Sets `voter`; checks non-zero, skips no-op |
| `setStaker(newStaker)` | `onlyOwner` | Sets `staker`; checks non-zero, skips no-op |
| `systemRenewLockup()` | `onlyFactory` | Sets `lockedUntil = max(current, now + lockupDuration)` |

#### Internal Functions (StakePool.sol)

| Function | Description |
|----------|-------------|
| `_unstake(amount)` | Validates amount > 0, amount <= activeStake. For active/pending_inactive validators: checks `activeStake - amount >= minimumBond`. Subtracts from `activeStake`, calls `_addToPendingBucket(lockedUntil, amount)`. |
| `_withdrawAvailable(recipient)` | Calculates claimable amount, updates `claimedAmount += amount` (CEI), transfers ETH via `payable(recipient).call{value: amount}("")`. |
| `_addToPendingBucket(lockedUntil, amount)` | If empty: creates first bucket. If last bucket has same `lockedUntil`: merges (adds to cumulative). If `lockedUntil` is strictly greater: appends new bucket (enforces max 1000 buckets). If `lockedUntil` is less than last bucket: reverts with `LockedUntilDecreased`. |
| `_getEffectiveStakeAt(atTime)` | If `lockedUntil >= atTime`: includes `activeStake`. Binary-searches pending buckets for ineffective amount (lockedUntil < atTime). Returns `effectiveActive + effectivePending`. |
| `_getCumulativeAmountAtTime(threshold)` | O(log n) binary search on `_pendingBuckets` for largest index where `lockedUntil < threshold`. Returns cumulative amount at that index. |
| `_getClaimableAmount()` | Calculates `threshold = now - unbondingDelay`. Binary-searches for cumulative amount where `lockedUntil < threshold`. Returns `claimableCumulative - claimedAmount`. |
| `_getRewardBalance()` | Returns `address(this).balance - activeStake - unclaimedPending`. Returns 0 if balance <= tracked. |

---

### State Changes

#### Staking Factory
| Variable | Modified by | Effect |
|----------|-------------|--------|
| `poolNonce` | `createPool()` | Post-incremented (`poolNonce++`) — used as pre-increment value for salt |
| `_allPools` | `createPool()` | New pool address pushed |
| `_isPool` | `createPool()` | `_isPool[pool] = true` |

#### StakePool
| Variable | Modified by | Effect |
|----------|-------------|--------|
| `activeStake` | constructor, `addStake()`, `_unstake()` | Set/increased/decreased respectively |
| `lockedUntil` | constructor, `addStake()`, `renewLockUntil()`, `systemRenewLockup()` | Set/extended (only increases, never decreases) |
| `staker` | constructor, `setStaker()` | Set/updated |
| `operator` | constructor, `setOperator()` | Set/updated |
| `voter` | constructor, `setVoter()` | Set/updated |
| `_pendingBuckets` | `_addToPendingBucket()` | New buckets pushed or last bucket's `cumulativeAmount` increased |
| `claimedAmount` | `_withdrawAvailable()` | Increased by withdrawn amount |
| ETH balance | constructor, `addStake()`, `_withdrawAvailable()`, `withdrawRewards()` | Received via `payable`, sent via `.call{value}` |

---

### Access Control Summary

| Operation | Who can call | Mechanism |
|-----------|-------------|-----------|
| `createPool()` | Anyone | No access restriction (permissionless) |
| `addStake()` / `unstake()` / `withdrawAvailable()` / `unstakeAndWithdraw()` / `renewLockUntil()` / `withdrawRewards()` | Pool's `staker` address | `onlyStaker` modifier |
| `setOperator()` / `setVoter()` / `setStaker()` / `transferOwnership()` / `acceptOwnership()` | Pool's `owner` address | `onlyOwner` modifier (from Ownable2Step) |
| `systemRenewLockup()` | Staking factory only | `onlyFactory` modifier (checks `msg.sender == FACTORY`) |
| `renewPoolLockup()` on factory | `VALIDATOR_MANAGER` only | `requireAllowed(SystemAddresses.VALIDATOR_MANAGER)` |

---

### External Dependencies

| Contract | Address | Called by | Functions used |
|----------|---------|-----------|----------------|
| `IReconfiguration` | `0x...1625F2003` | `Staking.createPool()`, StakePool `whenNotReconfiguring` modifier | `isTransitionInProgress()` |
| `IStakingConfig` | `0x...1625F1001` | `Staking.createPool()`, `Staking.getMinimumStake()`, StakePool constructor/`addStake()`/`renewLockUntil()`/`systemRenewLockup()`/`_getClaimableAmount()` | `minimumStake()`, `lockupDurationMicros()`, `unbondingDelayMicros()` |
| `ITimestamp` | `0x...1625F1000` | StakePool constructor/`addStake()`/`renewLockUntil()`/`systemRenewLockup()`/`getVotingPowerNow()`/`isLocked()`/`getRemainingLockup()`/`_getClaimableAmount()` | `nowMicroseconds()` |
| `IValidatorManagement` | `0x...1625F2001` | StakePool `_unstake()` | `isValidator(address)`, `getValidatorStatus(address)` |
| `IValidatorConfig` | `0x...1625F1002` | StakePool `_unstake()` | `minimumBond()` |
| `Ownable2Step` (OpenZeppelin) | Inherited by StakePool | Ownership management | `owner()`, `transferOwnership()`, `acceptOwnership()` |
| `ReentrancyGuard` (OpenZeppelin) | Inherited by StakePool | `nonReentrant` modifier on `withdrawAvailable()`, `withdrawRewards()` |

---

### Pool Registry Integrity (`_isPool` mapping)

- `_isPool[address]` is set to `true` **only** in `createPool()` at line 209, immediately after CREATE2 deployment.
- There is **no function** that sets `_isPool` to `false` or removes a pool from the registry. Pools, once created, are permanently registered.
- The `onlyValidPool` modifier (line 39–46) guards all delegated view functions and `renewPoolLockup()` — it checks `_isPool[pool]` and reverts with `InvalidPool` if false.

### Nonce Management

- `poolNonce` is a `uint256` public state variable, starts at 0 (default).
- In `createPool()`: `uint256 nonce = poolNonce++` — post-increment, so first pool uses salt `bytes32(0)`, second uses `bytes32(1)`, etc.
- The nonce is **never decremented or reset**. Each pool gets a unique monotonically increasing nonce.
- CREATE2 address = `keccak256(0xff ++ factory_address ++ salt ++ keccak256(creationCode ++ constructorArgs))`. Since constructor args include `owner`, `staker`, `operator`, `voter`, `lockedUntil`, and `msg.value`, the same nonce with different args would produce a different address.

### Factory-Only Trust

- StakePool stores `FACTORY = msg.sender` as immutable in constructor (line 122).
- `onlyFactory` modifier (line 87–92) ensures `systemRenewLockup()` can only be called by the deploying Staking factory.
- The Staking factory's `renewPoolLockup()` additionally requires `msg.sender == VALIDATOR_MANAGER` via `requireAllowed()`.
- The call chain is: `VALIDATOR_MANAGER → Staking.renewPoolLockup(pool) → StakePool.systemRenewLockup()`.

## Step Logs

| Step | Action | Input | Output | Duration |
|------|--------|-------|--------|----------|
| 1 | llm_query | Entry File: src/Genesis.sol
User Intent: 关注合约相关的功能

task_int | ## Implementation Summary: Staking Factory & StakePool

###  | 93127ms |

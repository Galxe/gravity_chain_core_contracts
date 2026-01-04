# Implement Two-Role Separation in Staking Contracts

**Date**: 2026-01-03  
**Type**: Breaking Change  
**Commit**: ea733f31e4c2793e4c0bdc5e872e897ea9725265

## Summary

Introduced a two-role separation pattern in StakePool contracts, distinguishing between **Owner** (administrative control) and **Staker** (fund management). This enables advanced use cases like DPOS and Liquid Staking Derivatives (LSD) where fund management can be delegated to smart contracts.

## Rationale

The previous design conflated pool ownership with fund management, limiting flexibility:
- LSD protocols need to manage funds on behalf of many users
- DPOS systems need to delegate staking operations to operators
- Users may want to separate administrative control from day-to-day fund operations

The two-role pattern solves this by splitting responsibilities:
- **Owner**: Controls administrative settings (operator, voter, staker addresses) and secure ownership transfers via Ownable2Step
- **Staker**: Manages funds (stake, unstake, renewLockUntil) and can be a smart contract

## Changes

### IStakePool.sol

New interface structure with two-role separation:

| Role | Functions | Description |
|------|-----------|-------------|
| Owner | `setOperator()`, `setVoter()`, `setStaker()` | Administrative control via Ownable2Step |
| Staker | `addStake()`, `withdraw()`, `renewLockUntil()` | Fund management operations |

New view functions:
- `getStaker()` - Returns the staker address
- `getVotingPower()` - Returns stake if locked, 0 if expired
- `getRemainingLockup()` - Returns remaining lockup duration
- `isLocked()` - Returns true if lockedUntil > now

New events:
- `StakerChanged(pool, oldStaker, newStaker)` - Emitted when staker is changed

### IStaking.sol (Factory)

Updated `createPool` function signature:

```solidity
// Before
function createPool(address operator, address voter, uint64 lockedUntil) external payable returns (address pool);

// After  
function createPool(
    address owner,
    address staker,
    address operator,
    address voter,
    uint64 lockedUntil
) external payable returns (address pool);
```

New view functions:
- `getPoolStaker(address pool)` - Get staker of a pool
- `isPoolLocked(address pool)` - Check if pool stake is locked

Updated event:
- `PoolCreated(creator, pool, owner, staker, poolIndex)` - Now includes owner and staker

### StakePool.sol

- Integrated OpenZeppelin's `Ownable2Step` for secure two-step ownership transfers
- Added `staker` role with `onlyStaker` modifier
- Fund operations (`addStake`, `withdraw`, `renewLockUntil`) now restricted to staker
- Administrative operations (`setOperator`, `setVoter`, `setStaker`) restricted to owner

### Staking.sol (Factory)

- Updated `createPool` to accept explicit owner, staker, operator, voter parameters
- Added `getPoolStaker()` and `isPoolLocked()` functions
- Removed hook-related functionality for simplified design

### Errors.sol

New error for unauthorized staker actions:

```solidity
error NotStaker(address caller, address staker);
```

### Removed Files

| File | Reason |
|------|--------|
| `src/staking/IStakingHook.sol` | Removed hook functionality for simplified design |

### Source Files Modified

| File | Change |
|------|--------|
| `src/staking/IStakePool.sol` | Two-role separation, new view functions and events |
| `src/staking/IStaking.sol` | Updated createPool signature, new query functions |
| `src/staking/StakePool.sol` | Ownable2Step integration, staker role |
| `src/staking/Staking.sol` | Updated factory logic, removed hooks |
| `src/foundation/Errors.sol` | Added NotStaker error |

### Test Files Modified

| File | Change |
|------|--------|
| `test/unit/staking/Staking.t.sol` | Updated for new createPool signature and role separation |
| `test/unit/staking/ValidatorManagement.t.sol` | Updated pool creation calls |
| `test/unit/governance/Governance.t.sol` | Updated pool creation calls |

### Spec Files Modified

| File | Change |
|------|--------|
| `spec_v2/staking.spec.md` | Documented two-role separation pattern |
| `spec_v2/foundation.spec.md` | Added NotStaker error documentation |

## Migration Notes

### createPool Signature Change

```solidity
// Before
staking.createPool{value: stake}(operator, voter, lockedUntil);

// After - explicit owner and staker
staking.createPool{value: stake}(owner, staker, operator, voter, lockedUntil);

// After - simple case (msg.sender is both owner and staker)
staking.createPool{value: stake}(msg.sender, msg.sender, operator, voter, lockedUntil);
```

### Staker Role Operations

Fund management operations now require the staker role:

```solidity
// Only staker can call these
pool.addStake{value: amount}();
pool.withdraw(amount, recipient);
pool.renewLockUntil(durationMicros);

// Only owner can change staker
pool.setStaker(newStaker);
```

### Ownership Transfer

Ownership now uses OpenZeppelin's two-step pattern:

```solidity
// Step 1: Current owner initiates transfer
pool.transferOwnership(newOwner);

// Step 2: New owner accepts
pool.acceptOwnership();
```

## Role Summary

| Role | Managed By | Responsibilities |
|------|------------|------------------|
| Owner | Ownable2Step (transferOwnership/acceptOwnership) | Set operator, voter, staker; ownership transfer |
| Staker | Owner (setStaker) | addStake, withdraw, renewLockUntil |
| Operator | Owner (setOperator) | Reserved for validator operations |
| Voter | Owner (setVoter) | Governance voting |


# Stake Module Specification

## Overview

The Stake Module manages validator staking on the Gravity L1 blockchain. This is a **simplified design** following
Ethereum's approach: validators stake their own tokens, with no protocol-level delegation.

## Design Philosophy

### What We Do

- Validator registration and management
- Self-staking (validators stake their own tokens)
- Validator set lifecycle (join, leave, status transitions)
- Stake configuration and limits
- Reward distribution to validators

### What We Don't Do (External to System Contracts)

- Delegation from non-validators
- Liquid staking derivatives
- Complex reward splitting

This separation follows the principle that **system contracts should be minimal and stable**, with complex business
logic implemented at higher layers (e.g., liquid staking protocols).

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                       Stake Module                           │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│   ┌─────────────────┐           ┌─────────────────┐          │
│   │   StakeConfig   │◄─────────▶│ ValidatorManager│          │
│   │  (parameters)   │           │  (validator set)│          │
│   └─────────────────┘           └─────────────────┘          │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Contract: `StakeConfig`

Stores staking parameters that can be updated via governance.

### State Variables

```solidity
/// @notice Minimum stake required to be a validator
uint256 public minValidatorStake;

/// @notice Maximum stake per validator (prevents concentration)
uint256 public maxValidatorStake;

/// @notice Whether validator set changes are currently allowed
bool public allowValidatorSetChange;
```

### Default Configuration

| Parameter                 | Default Value | Description                   |
| ------------------------- | ------------- | ----------------------------- |
| `minValidatorStake`       | 100,000 G     | Minimum to become validator   |
| `maxValidatorStake`       | 10,000,000 G  | Maximum per validator         |
| `allowValidatorSetChange` | true          | Can validators join/leave     |

### Interface

```solidity
interface IStakeConfig {
    // ========== Queries ==========
    function minValidatorStake() external view returns (uint256);
    function maxValidatorStake() external view returns (uint256);
    function allowValidatorSetChange() external view returns (bool);

    // ========== Admin ==========
    function initialize() external;
    function updateParam(bytes32 key, bytes calldata value) external;
}
```

## Contract: `ValidatorManager`

Manages the validator set and their lifecycle.

### Validator Status

```solidity
enum ValidatorStatus {
    INACTIVE,          // Not in validator set
    PENDING_ACTIVE,    // Queued to join next epoch
    ACTIVE,            // Currently validating
    PENDING_INACTIVE   // Queued to leave next epoch
}
```

### Validator Info

```solidity
struct ValidatorInfo {
    // Identity
    bytes consensusPublicKey;      // BLS public key for consensus
    string moniker;                // Human-readable name

    // Staking
    uint256 stake;                 // Current staked amount (also equals voting power)

    // Status
    ValidatorStatus status;
    bool registered;
    uint256 validatorIndex;        // Position in active set

    // Network
    bytes validatorNetworkAddresses;
    bytes fullnodeNetworkAddresses;
}
```

### Interface

```solidity
interface IValidatorManager {
    // ========== Registration ==========

    /// @notice Register as a new validator with initial stake
    /// @param params Registration parameters
    function registerValidator(ValidatorRegistrationParams calldata params) external payable;

    // ========== Validator Set Management ==========

    /// @notice Request to join the active validator set
    function joinValidatorSet() external;

    /// @notice Request to leave the active validator set
    function leaveValidatorSet() external;

    // ========== Staking ==========

    /// @notice Add more stake (validator only)
    function stake() external payable;

    /// @notice Request to unstake
    /// @param amount Amount to unstake
    function requestUnstake(uint256 amount) external;

    /// @notice Claim unstaked tokens after unbonding period
    function claimUnstaked() external;

    // ========== Configuration Updates ==========

    /// @notice Update consensus public key
    function updateConsensusKey(bytes calldata newKey) external;

    // ========== Queries ==========

    function getValidatorInfo(address validator) external view returns (ValidatorInfo memory);
    function getActiveValidators() external view returns (address[] memory);
    function getTotalStake() external view returns (uint256);
    function isActiveValidator(address validator) external view returns (bool);

    // ========== Epoch Transition ==========

    /// @notice Called by EpochManager on new epoch
    function onNewEpoch() external;
}
```

### Events

```solidity
event ValidatorRegistered(address indexed validator, bytes consensusKey, string moniker);
event ValidatorJoinRequested(address indexed validator, uint256 stake, uint256 epoch);
event ValidatorLeaveRequested(address indexed validator, uint256 epoch);
event ValidatorStatusChanged(address indexed validator, ValidatorStatus from, ValidatorStatus to);
event Staked(address indexed validator, uint256 amount);
event UnstakeRequested(address indexed validator, uint256 amount);
event UnstakeClaimed(address indexed validator, uint256 amount);
event RewardDistributed(address indexed validator, uint256 amount);
```

### Errors

```solidity
error ValidatorNotFound(address validator);
error ValidatorAlreadyRegistered(address validator);
error InsufficientStake(uint256 provided, uint256 required);
error StakeExceedsMaximum(uint256 provided, uint256 maximum);
error ValidatorNotActive(address validator);
error ValidatorSetChangeDisabled();
error UnbondingPeriodNotComplete();
error NotValidator(address caller);
```

## Validator Lifecycle

```
┌──────────────┐     register      ┌──────────────┐
│  Unregistered │────────────────▶│   INACTIVE   │
└──────────────┘                   └──────┬───────┘
                                          │
                                   joinValidatorSet
                                          │
                                          ▼
                                   ┌──────────────┐
                                   │PENDING_ACTIVE│
                                   └──────┬───────┘
                                          │
                                    epoch transition
                                          │
                                          ▼
                        ┌─────────────────────────────────┐
                        │            ACTIVE               │
                        └─────────────────┬───────────────┘
                                          │
                                   leaveValidatorSet
                                          │
                                          ▼
                                   ┌────────────────┐
                                   │PENDING_INACTIVE│
                                   └──────┬─────────┘
                                          │
                                    epoch transition
                                          │
                                          ▼
                                   ┌──────────────┐
                                   │   INACTIVE   │
                                   └──────────────┘
```

## Staking Flow

### Self-Staking (Validators Only)

```solidity
// 1. Register as validator with initial stake
validatorManager.registerValidator{value: 100000 ether}(params);

// 2. Add more stake
validatorManager.stake{value: 50000 ether}();

// 3. Request unstake
validatorManager.requestUnstake(30000 ether);

// 4. Wait for unbonding period...

// 5. Claim unstaked tokens
validatorManager.claimUnstaked();
```

## Epoch Transition

On each epoch transition, the `ValidatorManager` processes steps in a specific order. **The order is critical for
correct reward distribution.**

### Order of Operations

1. **Distribute Rewards FIRST**: Pay validators who worked during the ending epoch
2. **Activate Pending Validators**: Move PENDING_ACTIVE → ACTIVE
3. **Deactivate Leaving Validators**: Move PENDING_INACTIVE → INACTIVE
4. **Recalculate Total Stake**: Based on current stakes

### Why Rewards Must Be Distributed Before Validator Set Changes

| Validator Type            | Worked This Epoch?   | Should Get Rewards? |
| ------------------------- | -------------------- | ------------------- |
| ACTIVE → ACTIVE           | ✅ Yes               | ✅ Yes              |
| PENDING_ACTIVE → ACTIVE   | ❌ No (just joining) | ❌ No               |
| ACTIVE → PENDING_INACTIVE | ✅ Yes (leaving)     | ✅ Yes              |

If we distributed rewards **after** updating the validator set:

- **PENDING_INACTIVE** validators would be removed from `activeValidators` before distribution, losing their final epoch
  rewards
- **PENDING_ACTIVE** validators would be added to `activeValidators` before distribution, but they correctly get no
  rewards (no performance data)

By distributing rewards **before** validator set changes, we ensure validators are paid for the work they actually did.

```solidity
function onNewEpoch() external onlyEpochManager {
    // 1. Distribute rewards FIRST (to validators who worked this epoch)
    //    This must happen before validator set changes so that:
    //    - PENDING_INACTIVE validators receive their final epoch rewards
    //    - PENDING_ACTIVE validators don't receive rewards they didn't earn
    _distributeRewards();

    // 2. Now update the validator set for next epoch
    for (address v : pendingActive) {
        validators[v].status = ACTIVE;
        activeSet.add(v);
    }
    pendingActive.clear();

    // 3. Process pending inactive
    for (address v : pendingInactive) {
        validators[v].status = INACTIVE;
        activeSet.remove(v);
    }
    pendingInactive.clear();

    // 4. Recalculate total stake for next epoch
    _recalculateTotalStake();
}
```

## Reward Distribution

Rewards are distributed based on stake weight and performance:

```solidity
function _distributeRewards() internal {
    if (rewardPool == 0) return;

    uint256 totalWeight = 0;
    for (address v : activeValidators) {
        totalWeight += validators[v].stake;
    }

    for (address v : activeValidators) {
        uint256 reward = rewardPool * validators[v].stake / totalWeight;
        _sendReward(v, reward);
        emit RewardDistributed(v, reward);
    }

    rewardPool = 0;
}
```

> **Note**: Performance-based adjustments (proposal success rate, attestation rate) may be incorporated as multipliers
> if consensus provides this data.

## Access Control

| Function              | Caller         |
| --------------------- | -------------- |
| `initialize()`        | Genesis        |
| `registerValidator()` | Anyone (with stake) |
| `joinValidatorSet()`  | Validator      |
| `leaveValidatorSet()` | Validator      |
| `stake()`             | Validator      |
| `requestUnstake()`    | Validator      |
| `claimUnstaked()`     | Validator      |
| `updateConsensusKey()`| Validator      |
| `onNewEpoch()`        | EpochManager   |

## Security Considerations

1. **Minimum Stake**: Prevents spam validator registrations
2. **Maximum Stake**: Limits single-validator dominance
3. **Unbonding Period**: Prevents quick exit after misbehavior
4. **Epoch-based Changes**: Validator set only changes at epoch boundaries

## Invariants

1. `totalStake == sum(validator.stake) for all ACTIVE validators`
2. `validator.stake >= minValidatorStake` for registered validators
3. Only one status transition per epoch per validator

## Testing Requirements

1. **Unit Tests**:

   - Registration flow
   - Status transitions
   - Staking/unstaking
   - Reward distribution

2. **Integration Tests**:

   - Multi-epoch validator lifecycle
   - Epoch boundary transitions
   - Reward calculations

3. **Fuzz Tests**:

   - Random stake amounts
   - Random timing of operations
   - Stress test with many validators

4. **Invariant Tests**:
   - Total stake consistency
   - Stake balance conservation
   - Status transition validity

# Stake Module Specification

## Overview

The Stake Module manages validator staking on the Gravity L1 blockchain. This is a **simplified design** that focuses
only on validator staking, with delegation logic intentionally excluded from the system contracts to be implemented at a
higher layer.

## Design Philosophy

### What We Do

- Validator registration and management
- Self-staking (validators stake their own tokens)
- Validator set lifecycle (join, leave, status transitions)
- Stake configuration and limits
- Reward distribution to validators

### What We Don't Do (Delegated to External Contracts)

- Delegation from non-validators
- Complex reward splitting
- Liquid staking derivatives
- Delegation marketplace logic

This separation follows the principle that **system contracts should be minimal and stable**, with complex business
logic implemented at higher layers.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      Stake Module                         │
├──────────────────────────────────────────────────────────┤
│                                                           │
│  ┌─────────────────┐          ┌─────────────────┐        │
│  │  StakeConfig    │◄────────▶│ ValidatorManager│        │
│  │  (parameters)   │          │ (validator set) │        │
│  └─────────────────┘          └────────┬────────┘        │
│                                        │                  │
│                                        ▼                  │
│                          ┌─────────────────────┐         │
│                          │ External Delegation │         │
│                          │ (not system contract)│         │
│                          └─────────────────────┘         │
│                                                           │
└──────────────────────────────────────────────────────────┘
```

## Contract: `StakeConfig`

Stores staking parameters that can be updated via governance.

### State Variables

```solidity
/// @notice Minimum stake required to be a validator
uint256 public minValidatorStake;

/// @notice Maximum stake per validator
uint256 public maxValidatorStake;

/// @notice Lock amount that cannot be withdrawn
uint256 public lockAmount;

/// @notice Maximum commission rate (basis points, 10000 = 100%)
uint256 public maxCommissionRate;

/// @notice Whether validator set changes are currently allowed
bool public allowValidatorSetChange;
```

### Default Configuration

| Parameter                 | Default Value | Description                 |
| ------------------------- | ------------- | --------------------------- |
| `minValidatorStake`       | 100,000 G     | Minimum to become validator |
| `maxValidatorStake`       | 10,000,000 G  | Maximum per validator       |
| `lockAmount`              | 10,000 G      | Non-withdrawable amount     |
| `maxCommissionRate`       | 5000 (50%)    | Maximum commission          |
| `allowValidatorSetChange` | true          | Can validators join/leave   |

### Interface

```solidity
interface IStakeConfig {
    // ========== Queries ==========
    function minValidatorStake() external view returns (uint256);
    function maxValidatorStake() external view returns (uint256);
    function lockAmount() external view returns (uint256);
    function maxCommissionRate() external view returns (uint256);
    function allowValidatorSetChange() external view returns (bool);

    // ========== Admin ==========
    function initialize() external;
    function updateParam(string calldata key, bytes calldata value) external;
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
    address operator;              // Authorized operator address

    // Staking
    uint256 stake;                 // Current staked amount
    uint256 votingPower;           // Voting power (may differ from stake)

    // Commission
    uint64 commissionRate;         // Current rate (basis points)
    uint64 maxCommissionRate;      // Maximum allowed
    uint64 maxChangeRate;          // Max daily change
    uint64 lastCommissionUpdate;   // Last update timestamp

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

    /// @notice Register as a new validator
    /// @param params Registration parameters
    function registerValidator(ValidatorRegistrationParams calldata params) external payable;

    // ========== Validator Set Management ==========

    /// @notice Request to join the active validator set
    function joinValidatorSet(address validator) external;

    /// @notice Request to leave the active validator set
    function leaveValidatorSet(address validator) external;

    // ========== Staking ==========

    /// @notice Add stake to a validator
    /// @param validator Validator to stake on
    function stake(address validator) external payable;

    /// @notice Request to unstake from a validator
    /// @param validator Validator to unstake from
    /// @param amount Amount to unstake
    function requestUnstake(address validator, uint256 amount) external;

    /// @notice Claim unstaked tokens after unbonding period
    /// @param validator Validator to claim from
    function claimUnstaked(address validator) external;

    // ========== Configuration Updates ==========

    /// @notice Update consensus public key
    function updateConsensusKey(address validator, bytes calldata newKey) external;

    /// @notice Update commission rate
    function updateCommissionRate(address validator, uint64 newRate) external;

    /// @notice Update operator address
    function updateOperator(address validator, address newOperator) external;

    // ========== Queries ==========

    function getValidatorInfo(address validator) external view returns (ValidatorInfo memory);
    function getActiveValidators() external view returns (address[] memory);
    function getTotalVotingPower() external view returns (uint256);
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
event Staked(address indexed validator, address indexed staker, uint256 amount);
event UnstakeRequested(address indexed validator, address indexed staker, uint256 amount);
event UnstakeClaimed(address indexed validator, address indexed staker, uint256 amount);
event CommissionRateUpdated(address indexed validator, uint64 oldRate, uint64 newRate);
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
error InvalidCommissionRate(uint64 rate, uint64 max);
error CommissionUpdateTooFrequent();
error UnbondingPeriodNotComplete();
error NotOperator(address caller, address validator);
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

### Self-Staking (Validators)

```solidity
// 1. Register as validator with initial stake
validatorManager.registerValidator{value: 100000 ether}(params);

// 2. Add more stake
validatorManager.stake{value: 50000 ether}(myAddress);

// 3. Request unstake
validatorManager.requestUnstake(myAddress, 30000 ether);

// 4. Wait for unbonding period...

// 5. Claim unstaked tokens
validatorManager.claimUnstaked(myAddress);
```

## Delegation Hook Interface

For external delegation contracts to integrate:

```solidity
interface IStakeHook {
    /// @notice Called when stake is added to a validator
    /// @param validator The validator receiving stake
    /// @param staker The address staking
    /// @param amount The amount staked
    function onStake(address validator, address staker, uint256 amount) external;

    /// @notice Called when unstake is requested
    /// @param validator The validator unstaking from
    /// @param staker The address unstaking
    /// @param amount The amount unstaking
    function onUnstake(address validator, address staker, uint256 amount) external;

    /// @notice Called when rewards are distributed
    /// @param validator The validator receiving rewards
    /// @param amount The reward amount
    function onReward(address validator, uint256 amount) external;
}
```

External delegation contracts can register as hooks to receive notifications.

## Epoch Transition

On each epoch transition, the `ValidatorManager` processes steps in a specific order. **The order is critical for
correct reward distribution.**

### Order of Operations

1. **Process StakeCredit Transitions**: Update stake accounting
2. **Distribute Rewards FIRST**: Pay validators who worked during the ending epoch
3. **Activate Pending Validators**: Move PENDING_ACTIVE → ACTIVE
4. **Deactivate Leaving Validators**: Move PENDING_INACTIVE → INACTIVE
5. **Recalculate Voting Power**: Based on current stakes

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
    // 1. Process StakeCredit transitions
    _processAllStakeCreditsNewEpoch();

    // 2. Distribute rewards FIRST (to validators who worked this epoch)
    //    This must happen before validator set changes so that:
    //    - PENDING_INACTIVE validators receive their final epoch rewards
    //    - PENDING_ACTIVE validators don't receive rewards they didn't earn
    _distributeRewards();

    // 3. Now update the validator set for next epoch
    for (address v : pendingActive) {
        validators[v].status = ACTIVE;
        activeSet.add(v);
    }
    pendingActive.clear();

    // 4. Process pending inactive
    for (address v : pendingInactive) {
        validators[v].status = INACTIVE;
        activeSet.remove(v);
    }
    pendingInactive.clear();

    // 5. Recalculate voting power for next epoch
    _recalculateVotingPower();
}
```

## Reward Distribution

Rewards are distributed based on:

1. Voting power (stake-weighted)
2. Performance (proposal success rate)

```solidity
function _distributeRewards() internal {
    if (rewardPool == 0) return;

    uint256 totalWeight = 0;
    for (address v : activeValidators) {
        uint256 weight = validators[v].votingPower * getPerformanceMultiplier(v);
        weights[v] = weight;
        totalWeight += weight;
    }

    for (address v : activeValidators) {
        uint256 reward = rewardPool * weights[v] / totalWeight;
        _sendReward(v, reward);
    }

    rewardPool = 0;
}
```

## Access Control

| Function                 | Caller                |
| ------------------------ | --------------------- |
| `initialize()`           | Genesis               |
| `registerValidator()`    | Anyone (with stake)   |
| `joinValidatorSet()`     | Validator or Operator |
| `leaveValidatorSet()`    | Validator or Operator |
| `stake()`                | Anyone                |
| `requestUnstake()`       | Staker                |
| `claimUnstaked()`        | Staker                |
| `updateConsensusKey()`   | Validator or Operator |
| `updateCommissionRate()` | Validator or Operator |
| `updateOperator()`       | Validator only        |
| `onNewEpoch()`           | EpochManager          |

## Security Considerations

1. **Minimum Stake**: Prevents spam validator registrations
2. **Maximum Stake**: Limits single-validator dominance
3. **Commission Limits**: Protects delegators from excessive fees
4. **Rate Limiting**: Commission changes limited per day
5. **Unbonding Period**: Prevents quick exit after misbehavior
6. **Operator Separation**: Validator can delegate operations

## Invariants

1. `totalVotingPower == sum(validator.votingPower) for all ACTIVE validators`
2. `validator.stake >= lockAmount` for registered validators
3. `validator.commissionRate <= validator.maxCommissionRate`
4. Only one status transition per epoch per validator

## Testing Requirements

1. **Unit Tests**:

   - Registration flow
   - Status transitions
   - Staking/unstaking
   - Commission updates
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
   - Total voting power consistency
   - Stake balance conservation
   - Status transition validity

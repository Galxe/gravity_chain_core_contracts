# Gravity Chain — Build Plan Specification

**Last updated**: 2026-01-01  
**Principles**: KISS (Keep It Simple, Stupid) + SOLID
**Status**: Draft


## Implementation Status

We use this section to track the implementation status of the contracts.

### Layer 0: Foundation



---

## Executive Summary

Gravity is an **EVM L1 blockchain** using the **Aptos consensus engine**. This document provides a bottom-up implementation plan for the core system contracts, organized by dependency layers.

### Key Simplifications from Aptos

| Aptos Feature | Gravity Approach |
|---------------|------------------|
| Delegation pools | **Decoupled** — validators implement their own externally |
| Staking = Validators | **Decoupled** — staking is separate from validator registration |
| Complex reward curves | **Simplified** — EIP-1559 fee model |
| Move resources | **Solidity** structs/mappings |
| Multiple token types | **Native token only** |
| Slashing | **Deferred** — future extension |

### Key Architectural Decision: Decoupled Staking

**Gravity decouples staking from validator registration:**

| Concern | Aptos (Coupled) | Gravity (Decoupled) |
|---------|-----------------|---------------------|
| Governance voting | Validator stake pools only | **Anyone** who stakes tokens |
| Validator bond | Part of stake pool | Separate minimum bond |
| Delegation | Built-in delegation pools | **External** — validators implement their own |
| Voting power source | Validator bonds | Generic staking contract |

**Benefits:**
1. **More inclusive governance** — anyone can stake and vote, not just validators
2. **Simpler validator registry** — just consensus identity + minimum bond
3. **Flexible delegation** — validators can innovate on their own staking pool designs
4. **Single responsibility** — each contract does one thing well

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      GRAVITY SYSTEM CONTRACTS (DECOUPLED)                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │                    LAYER 6: GOVERNANCE                              │     │
│  │  GravityGovernance.sol                                              │     │
│  │  (uses Staking for voting power, NOT validators)                    │     │
│  └──────────────────────────────────┬─────────────────────────────────┘     │
│                                     │                                        │
│  ┌──────────────────────────────────┴─────────────────────────────────┐     │
│  │                    LAYER 5: RECONFIGURATION                         │     │
│  │  Reconfiguration.sol                                                │     │
│  └──────────────────────────────────┬─────────────────────────────────┘     │
│                                     │                                        │
│  ┌──────────────────────────────────┴─────────────────────────────────┐     │
│  │                    LAYER 4: BLOCK                                   │     │
│  │  Block.sol (block prologue, epoch timeout check)                    │     │
│  └──────────────────────────────────┬─────────────────────────────────┘     │
│                                     │                                        │
│  ┌──────────────────────────────────┴─────────────────────────────────┐     │
│  │                    LAYER 3: VALIDATOR REGISTRY (SIMPLIFIED)         │     │
│  │  ValidatorRegistry.sol (consensus identity + minimum bond)          │     │
│  │  IValidatorStakingPool.sol (interface for custom delegation)        │     │
│  └──────────────────────────────────┬─────────────────────────────────┘     │
│                                     │                                        │
│  ┌──────────────────────────────────┴─────────────────────────────────┐     │
│  │                    LAYER 2: STAKING + VOTING                        │     │
│  │  Staking.sol (generic governance staking — ANYONE can stake)        │     │
│  │  Voting.sol (generic proposal/vote/resolve engine)                  │     │
│  └──────────────────────────────────┬─────────────────────────────────┘     │
│                                     │                                        │
│  ┌──────────────────────────────────┴─────────────────────────────────┐     │
│  │                    LAYER 1: CONFIG + TIME                           │     │
│  │  Timestamp.sol + StakingConfig.sol + ValidatorConfig.sol            │     │
│  └──────────────────────────────────┬─────────────────────────────────┘     │
│                                     │                                        │
│  ┌──────────────────────────────────┴─────────────────────────────────┐     │
│  │                    LAYER 0: FOUNDATION                              │     │
│  │  SystemAddresses.sol + Types.sol + Errors.sol                       │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                    EXTERNAL (Validator-Owned, Optional)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  CustomStakingPool.sol (implements IValidatorStakingPool)                    │
│  - Commission handling                                                       │
│  - Delegation shares                                                         │
│  - Reward distribution                                                       │
│  - Each validator can deploy their own implementation                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Layer 0: Foundation

**No dependencies**. Pure data types, constants, and utility functions.

### Contract: `SystemAddresses.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SystemAddresses
/// @notice Well-known system addresses for Gravity
library SystemAddresses {
    /// @notice The framework/system account (similar to @aptos_framework 0x1)
    address public constant FRAMEWORK = address(0x1);
    
    /// @notice The VM/consensus caller address
    address public constant VM = address(0x0);
    
    /// @notice Core system contracts
    address public constant TIMESTAMP = address(0x100);
    address public constant STAKING_CONFIG = address(0x101);
    address public constant VALIDATOR_CONFIG = address(0x102);
    address public constant STAKING = address(0x103);
    address public constant VOTING = address(0x104);
    address public constant VALIDATOR_REGISTRY = address(0x105);
    address public constant BLOCK = address(0x106);
    address public constant RECONFIGURATION = address(0x107);
    address public constant GOVERNANCE = address(0x108);
    
    /// @notice Asserts caller is the VM (system call)
    function assertVM() internal view {
        require(msg.sender == VM, "SystemAddresses: not VM");
    }
    
    /// @notice Asserts caller is the framework account
    function assertFramework() internal view {
        require(msg.sender == FRAMEWORK, "SystemAddresses: not framework");
    }
}
```

### Contract: `Types.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Types
/// @notice Core data types for Gravity system contracts

// ============================================================================
// STAKING TYPES (for governance participation — anyone can stake)
// ============================================================================

/// @notice Stake position for governance voting
struct StakePosition {
    uint256 amount;             // Staked amount
    uint64 lockedUntil;         // Lockup expiration timestamp
    uint64 stakedAt;            // When stake was deposited
}

// ============================================================================
// VALIDATOR TYPES (for consensus participation — simplified)
// ============================================================================

/// @notice Validator status enum
enum ValidatorStatus {
    INACTIVE,           // 0: Not in validator set
    PENDING_ACTIVE,     // 1: Queued to join next epoch
    ACTIVE,             // 2: Currently validating
    PENDING_INACTIVE    // 3: Queued to leave next epoch
}

/// @notice Validator consensus info (used by consensus engine)
struct ValidatorConsensusInfo {
    address validator;          // Validator identity address
    bytes consensusPubkey;
    bytes consensusPop;
    uint256 votingPower;        // From validator bond (NOT governance staking)
}

/// @notice Validator record (SIMPLIFIED — no complex stake buckets)
struct ValidatorRecord {
    address validator;          // Immutable identity
    string moniker;             // Display name (< 32 bytes)
    address owner;              // Controls bond + can set operator
    address operator;           // Can rotate keys, request join/leave
    ValidatorStatus status;
    
    // Simple bond model (no 4-bucket complexity)
    uint256 bond;               // Current validator bond
    uint256 pendingUnbond;      // Requested unbond (effective next epoch)
    uint64 unbondAvailableAt;   // When unbond becomes withdrawable
    
    // Consensus key material (no EVM validation)
    bytes consensusPubkey;
    bytes consensusPop;
    bytes networkAddresses;
    bytes fullnodeAddresses;
    
    // Fee recipient (for proposer tips)
    address feeRecipient;
    address pendingFeeRecipient;
    
    // Optional: link to external staking pool for delegation
    address stakingPool;        // Address of IValidatorStakingPool (0x0 if none)
    
    // Per-epoch index (only valid when ACTIVE/PENDING_INACTIVE)
    uint64 validatorIndex;
}

/// @notice Validator info (compact form for consensus)
struct ValidatorInfo {
    address validator;
    uint64 votingPower;
    uint64 validatorIndex;
    bytes consensusPubkey;
}

// ============================================================================
// GOVERNANCE TYPES
// ============================================================================

/// @notice Governance proposal state
enum ProposalState {
    PENDING,    // 0: Voting active
    SUCCEEDED,  // 1: Passed, ready to execute
    FAILED,     // 2: Did not pass
    EXECUTED,   // 3: Already executed
    CANCELLED   // 4: Cancelled
}

/// @notice Governance proposal
struct Proposal {
    uint64 id;
    address proposer;           // Who created the proposal
    bytes32 executionHash;      // Hash of script to execute
    string metadataUri;         // IPFS/URL to proposal details
    uint64 creationTime;
    uint64 expirationTime;
    uint128 minVoteThreshold;
    uint128 yesVotes;
    uint128 noVotes;
    bool isResolved;
    uint64 resolutionTime;
}
```

### Contract: `Errors.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Errors
/// @notice Custom errors for Gravity system contracts
library Errors {
    // === Staking errors ===
    error NoStakePosition(address staker);
    error InsufficientStake(uint256 required, uint256 actual);
    error LockupNotExpired(uint64 lockedUntil, uint64 currentTime);
    error ZeroAmount();
    
    // === ValidatorRegistry errors ===
    error ValidatorNotFound(address validator);
    error ValidatorAlreadyExists(address validator);
    error InvalidStatus(uint8 expected, uint8 actual);
    error InsufficientBond(uint256 required, uint256 actual);
    error ExceedsMaximumBond(uint256 maximum, uint256 actual);
    error NotOwner(address expected, address actual);
    error NotOperator(address expected, address actual);
    error ValidatorSetChangesDisabled();
    error MaxValidatorSetSizeReached(uint256 maxSize);
    error VotingPowerIncreaseLimitExceeded(uint256 limit, uint256 actual);
    error MonikerTooLong(uint256 maxLength, uint256 actualLength);
    error UnbondNotReady(uint64 availableAt, uint64 currentTime);
    
    // === Reconfiguration errors ===
    error ReconfigurationInProgress();
    error ReconfigurationNotInProgress();
    error EpochNotYetEnded(uint64 nextEpochTime, uint64 currentTime);
    
    // === Governance errors ===
    error ProposalNotFound(uint64 proposalId);
    error VotingPeriodEnded(uint64 expirationTime);
    error VotingPeriodNotEnded(uint64 expirationTime);
    error ProposalAlreadyResolved(uint64 proposalId);
    error ExecutionHashMismatch(bytes32 expected, bytes32 actual);
    error InsufficientLockup(uint64 required, uint64 actual);
    error AtomicResolutionNotAllowed();
    error InsufficientVotingPower(uint256 required, uint256 actual);
}
```

---

## Layer 1: Config + Time

**Depends on**: Layer 0

### Contract: `Timestamp.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SystemAddresses.sol";

/// @title Timestamp
/// @notice On-chain time source (updated by VM in block prologue)
contract Timestamp {
    /// @notice Current Unix timestamp in microseconds
    uint64 public microseconds;
    
    /// @notice Get current time in seconds
    function nowSeconds() external view returns (uint64) {
        return microseconds / 1_000_000;
    }
    
    /// @notice Get current time in microseconds
    function nowMicroseconds() external view returns (uint64) {
        return microseconds;
    }
    
    /// @notice Update global time (VM-only)
    /// @param newTimeMicroseconds New timestamp in microseconds
    function updateGlobalTime(uint64 newTimeMicroseconds) external {
        SystemAddresses.assertVM();
        require(newTimeMicroseconds >= microseconds, "Timestamp: cannot go backwards");
        microseconds = newTimeMicroseconds;
    }
}
```

### Contract: `StakingConfig.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SystemAddresses.sol";

/// @title StakingConfig
/// @notice Configuration for governance staking (ANYONE can stake)
contract StakingConfig {
    // === Storage ===
    
    /// @notice Minimum stake amount for governance participation
    uint256 public minimumStake;
    
    /// @notice Lockup duration in seconds for governance staking
    uint64 public lockupDurationSecs;
    
    /// @notice Minimum stake required to create governance proposals
    uint256 public minimumProposalStake;
    
    // === Events ===
    event ConfigUpdated(string paramName, uint256 oldValue, uint256 newValue);
    
    // === Initialization ===
    
    function initialize(
        uint256 _minimumStake,
        uint64 _lockupDurationSecs,
        uint256 _minimumProposalStake
    ) external {
        require(minimumStake == 0, "Already initialized");
        require(_lockupDurationSecs > 0, "lockup must be > 0");
        
        minimumStake = _minimumStake;
        lockupDurationSecs = _lockupDurationSecs;
        minimumProposalStake = _minimumProposalStake;
    }
    
    // === Governance setters (framework-only) ===
    
    function setMinimumStake(uint256 _minimumStake) external {
        SystemAddresses.assertFramework();
        emit ConfigUpdated("minimumStake", minimumStake, _minimumStake);
        minimumStake = _minimumStake;
    }
    
    function setLockupDurationSecs(uint64 _duration) external {
        SystemAddresses.assertFramework();
        require(_duration > 0, "duration must be > 0");
        emit ConfigUpdated("lockupDurationSecs", lockupDurationSecs, _duration);
        lockupDurationSecs = _duration;
    }
    
    function setMinimumProposalStake(uint256 _stake) external {
        SystemAddresses.assertFramework();
        emit ConfigUpdated("minimumProposalStake", minimumProposalStake, _stake);
        minimumProposalStake = _stake;
    }
}
```

### Contract: `ValidatorConfig.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SystemAddresses.sol";

/// @title ValidatorConfig
/// @notice Configuration for validator registry (consensus participation)
contract ValidatorConfig {
    // === Constants ===
    uint64 public constant MAX_VOTING_POWER_INCREASE_LIMIT = 50; // 50%
    uint256 public constant MAX_VALIDATOR_SET_SIZE = 65536;
    
    // === Storage ===
    
    /// @notice Minimum bond to join validator set
    uint256 public minimumBond;
    
    /// @notice Maximum bond per validator (caps voting power)
    uint256 public maximumBond;
    
    /// @notice Unbonding delay in seconds
    uint64 public unbondingDelaySecs;
    
    /// @notice Whether validators can join/leave post-genesis
    bool public allowValidatorSetChange;
    
    /// @notice Max % of voting power that can join per epoch (1-50)
    uint64 public votingPowerIncreaseLimitPct;
    
    /// @notice Max validators in the set
    uint256 public maxValidatorSetSize;
    
    // === Events ===
    event ConfigUpdated(string paramName, uint256 oldValue, uint256 newValue);
    
    // === Initialization ===
    
    function initialize(
        uint256 _minimumBond,
        uint256 _maximumBond,
        uint64 _unbondingDelaySecs,
        bool _allowValidatorSetChange,
        uint64 _votingPowerIncreaseLimitPct,
        uint256 _maxValidatorSetSize
    ) external {
        require(minimumBond == 0, "Already initialized");
        require(_minimumBond > 0, "minimumBond must be > 0");
        require(_maximumBond >= _minimumBond, "maximumBond must be >= minimumBond");
        require(_unbondingDelaySecs > 0, "unbonding delay must be > 0");
        require(_votingPowerIncreaseLimitPct > 0 && 
                _votingPowerIncreaseLimitPct <= MAX_VOTING_POWER_INCREASE_LIMIT,
                "Invalid votingPowerIncreaseLimitPct");
        require(_maxValidatorSetSize > 0 && 
                _maxValidatorSetSize <= MAX_VALIDATOR_SET_SIZE,
                "Invalid maxValidatorSetSize");
        
        minimumBond = _minimumBond;
        maximumBond = _maximumBond;
        unbondingDelaySecs = _unbondingDelaySecs;
        allowValidatorSetChange = _allowValidatorSetChange;
        votingPowerIncreaseLimitPct = _votingPowerIncreaseLimitPct;
        maxValidatorSetSize = _maxValidatorSetSize;
    }
    
    // === Governance setters (framework-only) ===
    
    function setMinimumBond(uint256 _bond) external {
        SystemAddresses.assertFramework();
        require(_bond > 0, "bond must be > 0");
        require(_bond <= maximumBond, "minimumBond must be <= maximumBond");
        emit ConfigUpdated("minimumBond", minimumBond, _bond);
        minimumBond = _bond;
    }
    
    function setMaximumBond(uint256 _bond) external {
        SystemAddresses.assertFramework();
        require(_bond >= minimumBond, "maximumBond must be >= minimumBond");
        emit ConfigUpdated("maximumBond", maximumBond, _bond);
        maximumBond = _bond;
    }
    
    function setUnbondingDelaySecs(uint64 _delay) external {
        SystemAddresses.assertFramework();
        require(_delay > 0, "delay must be > 0");
        emit ConfigUpdated("unbondingDelaySecs", unbondingDelaySecs, _delay);
        unbondingDelaySecs = _delay;
    }
    
    function setAllowValidatorSetChange(bool _allow) external {
        SystemAddresses.assertFramework();
        allowValidatorSetChange = _allow;
    }
    
    function setVotingPowerIncreaseLimitPct(uint64 _limit) external {
        SystemAddresses.assertFramework();
        require(_limit > 0 && _limit <= MAX_VOTING_POWER_INCREASE_LIMIT, "Invalid limit");
        emit ConfigUpdated("votingPowerIncreaseLimitPct", votingPowerIncreaseLimitPct, _limit);
        votingPowerIncreaseLimitPct = _limit;
    }
    
    function setMaxValidatorSetSize(uint256 _size) external {
        SystemAddresses.assertFramework();
        require(_size > 0 && _size <= MAX_VALIDATOR_SET_SIZE, "Invalid size");
        emit ConfigUpdated("maxValidatorSetSize", maxValidatorSetSize, _size);
        maxValidatorSetSize = _size;
    }
}
```

### Contract: `ConfigBuffer.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SystemAddresses.sol";

/// @title ConfigBuffer
/// @notice Buffered config pattern: set_for_next_epoch() + on_new_epoch() applies
contract ConfigBuffer {
    /// @notice Pending config changes (key => encoded value)
    mapping(bytes32 => bytes) internal pendingConfigs;
    
    /// @notice Check if a config is pending
    mapping(bytes32 => bool) internal hasPending;
    
    // === Events ===
    event ConfigBuffered(bytes32 indexed key);
    event ConfigApplied(bytes32 indexed key);
    
    // === Internal functions (used by config modules) ===
    
    function _bufferConfig(bytes32 key, bytes memory value) internal {
        pendingConfigs[key] = value;
        hasPending[key] = true;
        emit ConfigBuffered(key);
    }
    
    function _extractConfig(bytes32 key) internal returns (bytes memory) {
        require(hasPending[key], "No pending config");
        bytes memory value = pendingConfigs[key];
        delete pendingConfigs[key];
        hasPending[key] = false;
        emit ConfigApplied(key);
        return value;
    }
    
    function _hasPendingConfig(bytes32 key) internal view returns (bool) {
        return hasPending[key];
    }
}
```

---

## Layer 2: Staking + Voting

**Depends on**: Layer 0, Layer 1

### Interface: `IStaking.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Types.sol";

/// @title IStaking
/// @notice Generic staking for governance participation (ANYONE can stake)
interface IStaking {
    // === Events ===
    event Staked(address indexed staker, uint256 amount, uint64 lockedUntil);
    event Unstaked(address indexed staker, uint256 amount);
    event Withdrawn(address indexed staker, uint256 amount);
    event LockupExtended(address indexed staker, uint64 newLockedUntil);
    
    // === View functions ===
    function getStake(address staker) external view returns (StakePosition memory);
    function getVotingPower(address staker) external view returns (uint256);
    function getTotalStaked() external view returns (uint256);
    function isLocked(address staker) external view returns (bool);
    
    // === Mutating functions ===
    function stake() external payable;
    function unstake(uint256 amount) external;
    function withdraw() external;
    function extendLockup() external;
}
```

### Contract: `Staking.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IStaking.sol";
import "./Timestamp.sol";
import "./StakingConfig.sol";
import "./SystemAddresses.sol";
import "./Errors.sol";

/// @title Staking
/// @notice Generic staking contract for governance participation
/// @dev ANYONE can stake tokens and participate in governance voting
contract Staking is IStaking {
    // === Immutables ===
    Timestamp public immutable timestamp;
    StakingConfig public immutable config;
    
    // === Storage ===
    mapping(address => StakePosition) public stakes;
    uint256 public totalStaked;
    
    // === Constructor ===
    constructor(address _timestamp, address _config) {
        timestamp = Timestamp(_timestamp);
        config = StakingConfig(_config);
    }
    
    // === View functions ===
    
    function getStake(address staker) external view override returns (StakePosition memory) {
        return stakes[staker];
    }
    
    function getVotingPower(address staker) external view override returns (uint256) {
        StakePosition storage pos = stakes[staker];
        // Only locked stake counts for voting
        if (pos.lockedUntil <= timestamp.nowSeconds()) {
            return 0; // Lockup expired, no voting power
        }
        return pos.amount;
    }
    
    function getTotalStaked() external view override returns (uint256) {
        return totalStaked;
    }
    
    function isLocked(address staker) public view override returns (bool) {
        return stakes[staker].lockedUntil > timestamp.nowSeconds();
    }
    
    // === Mutating functions ===
    
    /// @notice Stake native tokens for governance participation
    function stake() external payable override {
        if (msg.value == 0) revert Errors.ZeroAmount();
        
        uint64 now_ = timestamp.nowSeconds();
        uint64 lockupDuration = config.lockupDurationSecs();
        uint64 newLockedUntil = now_ + lockupDuration;
        
        StakePosition storage pos = stakes[msg.sender];
        
        if (pos.amount == 0) {
            // New stake position
            pos.stakedAt = now_;
        }
        
        pos.amount += msg.value;
        
        // Extend lockup if new lockup is longer
        if (newLockedUntil > pos.lockedUntil) {
            pos.lockedUntil = newLockedUntil;
        }
        
        totalStaked += msg.value;
        
        emit Staked(msg.sender, msg.value, pos.lockedUntil);
    }
    
    /// @notice Request to unstake (must wait for lockup)
    function unstake(uint256 amount) external override {
        StakePosition storage pos = stakes[msg.sender];
        if (pos.amount == 0) revert Errors.NoStakePosition(msg.sender);
        if (amount == 0) revert Errors.ZeroAmount();
        if (amount > pos.amount) revert Errors.InsufficientStake(amount, pos.amount);
        
        uint64 now_ = timestamp.nowSeconds();
        if (pos.lockedUntil > now_) {
            revert Errors.LockupNotExpired(pos.lockedUntil, now_);
        }
        
        pos.amount -= amount;
        totalStaked -= amount;
        
        emit Unstaked(msg.sender, amount);
        
        // Immediate withdrawal since lockup expired
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Staking: transfer failed");
        
        emit Withdrawn(msg.sender, amount);
    }
    
    /// @notice Withdraw all unstaked funds (alias for convenience)
    function withdraw() external override {
        StakePosition storage pos = stakes[msg.sender];
        if (pos.amount == 0) revert Errors.NoStakePosition(msg.sender);
        
        uint64 now_ = timestamp.nowSeconds();
        if (pos.lockedUntil > now_) {
            revert Errors.LockupNotExpired(pos.lockedUntil, now_);
        }
        
        uint256 amount = pos.amount;
        pos.amount = 0;
        totalStaked -= amount;
        
        emit Unstaked(msg.sender, amount);
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Staking: transfer failed");
        
        emit Withdrawn(msg.sender, amount);
    }
    
    /// @notice Extend lockup to maintain voting power
    function extendLockup() external override {
        StakePosition storage pos = stakes[msg.sender];
        if (pos.amount == 0) revert Errors.NoStakePosition(msg.sender);
        
        uint64 now_ = timestamp.nowSeconds();
        uint64 newLockedUntil = now_ + config.lockupDurationSecs();
        
        require(newLockedUntil > pos.lockedUntil, "Staking: lockup not extended");
        
        pos.lockedUntil = newLockedUntil;
        
        emit LockupExtended(msg.sender, newLockedUntil);
    }
}
```

### Interface: `IVoting.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Types.sol";

/// @title IVoting
/// @notice Generic voting engine interface
interface IVoting {
    // === Events ===
    event ProposalCreated(uint64 indexed proposalId, address indexed proposer, bytes32 executionHash);
    event VoteCast(uint64 indexed proposalId, address indexed voter, bool support, uint128 votingPower);
    event ProposalResolved(uint64 indexed proposalId, ProposalState state);
    
    // === View functions ===
    function getProposal(uint64 proposalId) external view returns (Proposal memory);
    function getProposalState(uint64 proposalId) external view returns (ProposalState);
    function isVotingClosed(uint64 proposalId) external view returns (bool);
    function canBeResolvedEarly(uint64 proposalId) external view returns (bool);
    
    // === Mutating functions ===
    function createProposal(
        address proposer,
        address /*unused*/,
        bytes32 executionHash,
        string calldata metadataUri,
        uint128 minVoteThreshold,
        uint64 votingDurationSecs
    ) external returns (uint64 proposalId);
    
    function vote(
        uint64 proposalId,
        address voter,
        uint128 votingPower,
        bool support
    ) external;
    
    function resolve(uint64 proposalId) external returns (ProposalState);
}
```

### Contract: `Voting.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVoting.sol";
import "./Timestamp.sol";
import "./SystemAddresses.sol";
import "./Errors.sol";

/// @title Voting
/// @notice Generic proposal/vote/resolve engine (used by governance)
contract Voting is IVoting {
    // === Storage ===
    Timestamp public immutable timestamp;
    
    uint64 public nextProposalId;
    mapping(uint64 => Proposal) public proposals;
    
    /// @notice Early resolution threshold (e.g., 50% of total voting power)
    uint128 public earlyResolutionThreshold;
    
    // === Constructor ===
    constructor(address _timestamp) {
        timestamp = Timestamp(_timestamp);
        nextProposalId = 1;
    }
    
    // === View functions ===
    
    function getProposal(uint64 proposalId) external view override returns (Proposal memory) {
        return proposals[proposalId];
    }
    
    function getProposalState(uint64 proposalId) public view override returns (ProposalState) {
        Proposal storage p = proposals[proposalId];
        if (p.id == 0) revert Errors.ProposalNotFound(proposalId);
        
        if (p.isResolved) {
            if (p.yesVotes > p.noVotes && p.yesVotes + p.noVotes >= p.minVoteThreshold) {
                return ProposalState.EXECUTED;
            }
            return ProposalState.FAILED;
        }
        
        uint64 now_ = timestamp.nowSeconds();
        if (now_ < p.expirationTime) {
            return ProposalState.PENDING;
        }
        
        // Voting ended
        if (p.yesVotes > p.noVotes && p.yesVotes + p.noVotes >= p.minVoteThreshold) {
            return ProposalState.SUCCEEDED;
        }
        return ProposalState.FAILED;
    }
    
    function isVotingClosed(uint64 proposalId) public view override returns (bool) {
        Proposal storage p = proposals[proposalId];
        return timestamp.nowSeconds() >= p.expirationTime || p.isResolved;
    }
    
    function canBeResolvedEarly(uint64 proposalId) public view override returns (bool) {
        Proposal storage p = proposals[proposalId];
        if (earlyResolutionThreshold == 0) return false;
        return p.yesVotes >= earlyResolutionThreshold || p.noVotes >= earlyResolutionThreshold;
    }
    
    // === Mutating functions ===
    
    function createProposal(
        address proposer,
        address /* unused - kept for interface compatibility */,
        bytes32 executionHash,
        string calldata metadataUri,
        uint128 minVoteThreshold,
        uint64 votingDurationSecs
    ) external override returns (uint64 proposalId) {
        proposalId = nextProposalId++;
        uint64 now_ = timestamp.nowSeconds();
        
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: proposer,
            executionHash: executionHash,
            metadataUri: metadataUri,
            creationTime: now_,
            expirationTime: now_ + votingDurationSecs,
            minVoteThreshold: minVoteThreshold,
            yesVotes: 0,
            noVotes: 0,
            isResolved: false,
            resolutionTime: 0
        });
        
        emit ProposalCreated(proposalId, proposer, executionHash);
    }
    
    function vote(
        uint64 proposalId,
        address voter,
        uint128 votingPower,
        bool support
    ) external override {
        Proposal storage p = proposals[proposalId];
        if (p.id == 0) revert Errors.ProposalNotFound(proposalId);
        if (isVotingClosed(proposalId)) revert Errors.VotingPeriodEnded(p.expirationTime);
        
        if (support) {
            p.yesVotes += votingPower;
        } else {
            p.noVotes += votingPower;
        }
        
        emit VoteCast(proposalId, voter, support, votingPower);
    }
    
    function resolve(uint64 proposalId) external override returns (ProposalState) {
        Proposal storage p = proposals[proposalId];
        if (p.id == 0) revert Errors.ProposalNotFound(proposalId);
        if (p.isResolved) revert Errors.ProposalAlreadyResolved(proposalId);
        
        // Must be either expired or early-resolvable
        uint64 now_ = timestamp.nowSeconds();
        bool votingEnded = now_ >= p.expirationTime;
        bool canResolveEarly = canBeResolvedEarly(proposalId);
        
        if (!votingEnded && !canResolveEarly) {
            revert Errors.VotingPeriodNotEnded(p.expirationTime);
        }
        
        p.isResolved = true;
        p.resolutionTime = now_;
        
        ProposalState state = getProposalState(proposalId);
        emit ProposalResolved(proposalId, state);
        
        return state;
    }
    
    // === Admin functions ===
    
    function setEarlyResolutionThreshold(uint128 threshold) external {
        SystemAddresses.assertFramework();
        earlyResolutionThreshold = threshold;
    }
}
```

---

## Layer 3: Validator Registry (SIMPLIFIED)

**Depends on**: Layer 0, Layer 1

The validator registry is now **much simpler** because:
1. Governance voting power comes from `Staking.sol`, not validators
2. No complex 4-bucket stake model — just simple bond/unbond
3. Delegation is external (validators deploy their own staking pools)

### Interface: `IValidatorRegistry.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Types.sol";

/// @title IValidatorRegistry
/// @notice Validator registry for consensus participation (SIMPLIFIED)
/// @dev Governance voting is handled by Staking.sol, not this contract
interface IValidatorRegistry {
    // === Events ===
    event ValidatorRegistered(address indexed validator, address owner, address operator);
    event OperatorUpdated(address indexed validator, address oldOperator, address newOperator);
    event FeeRecipientUpdated(address indexed validator, address oldRecipient, address newRecipient);
    event Bonded(address indexed validator, uint256 amount);
    event UnbondRequested(address indexed validator, uint256 amount);
    event Withdrawn(address indexed validator, address to, uint256 amount);
    event JoinRequested(address indexed validator);
    event LeaveRequested(address indexed validator);
    event ValidatorActivated(address indexed validator, uint64 epoch);
    event ValidatorDeactivated(address indexed validator, uint64 epoch);
    event ConsensusKeyRotated(address indexed validator);
    event NetworkAddressesUpdated(address indexed validator);
    event StakingPoolSet(address indexed validator, address stakingPool);
    event EpochProcessed(uint64 epoch, uint256 activeCount, uint256 totalVotingPower);
    
    // === Consensus-facing view functions ===
    function getEpoch() external view returns (uint64);
    function getActiveValidatorCount() external view returns (uint256);
    function getActiveValidators() external view returns (address[] memory);
    function getActiveValidatorSetPacked() external view returns (bytes memory);
    function getValidatorIndex(address validator) external view returns (uint64);
    function getValidatorVotingPower(address validator) external view returns (uint256);
    function getValidatorConsensusKey(address validator) external view returns (bytes memory pubkey, bytes memory pop);
    function getTotalVotingPower() external view returns (uint256);
    function getFeeRecipient(address validator) external view returns (address);
    
    // === Validator info ===
    function getValidator(address validator) external view returns (ValidatorRecord memory);
    function validatorExists(address validator) external view returns (bool);
    function getStakingPool(address validator) external view returns (address);
    
    // === Registration and role management ===
    function registerValidator(
        address validator,
        string calldata moniker,
        address owner,
        address operator,
        bytes calldata consensusPubkey,
        bytes calldata consensusPop,
        bytes calldata networkAddresses,
        bytes calldata fullnodeAddresses
    ) external;
    
    function setOperator(address validator, address newOperator) external;
    function setFeeRecipient(address validator, address newRecipient) external;
    function setStakingPool(address validator, address stakingPool) external;
    
    // === Bonding / unbonding (simple model) ===
    function bond(address validator) external payable;
    function requestUnbond(address validator, uint256 amount) external;
    function withdraw(address validator, address payable to) external;
    
    // === Join / leave validator set ===
    function requestJoin(address validator) external;
    function requestLeave(address validator) external;
    
    // === Operational metadata ===
    function rotateConsensusKey(address validator, bytes calldata newPubkey, bytes calldata newPop) external;
    function updateNetworkAddresses(address validator, bytes calldata networkAddrs, bytes calldata fullnodeAddrs) external;
    
    // === System entrypoint ===
    function onNewEpoch(uint64 epochNumber, uint64 timestampSecs, bytes calldata extraData) external;
}
```

### Interface: `IValidatorStakingPool.sol` (External — Validator-Owned)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IValidatorStakingPool
/// @notice Interface for custom validator staking pools (EXTERNAL)
/// @dev Validators can implement their own delegation/commission logic
interface IValidatorStakingPool {
    // === Events ===
    event Delegated(address indexed delegator, uint256 amount);
    event Undelegated(address indexed delegator, uint256 amount);
    event RewardsDistributed(uint256 totalRewards, uint256 commission);
    
    // === View functions ===
    function validator() external view returns (address);
    function totalDelegated() external view returns (uint256);
    function getDelegation(address delegator) external view returns (uint256);
    function getCommissionRate() external view returns (uint256); // In basis points
    function getPendingRewards(address delegator) external view returns (uint256);
    
    // === Delegator functions ===
    function delegate() external payable;
    function undelegate(uint256 amount) external;
    function claimRewards() external;
    
    // === Validator functions ===
    function setCommissionRate(uint256 rateBps) external;
    
    // === Called by protocol when validator receives proposer fees ===
    function distributeRewards() external payable;
}
```

### Contract: `ValidatorRegistry.sol` (SIMPLIFIED)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IValidatorRegistry.sol";
import "./Timestamp.sol";
import "./ValidatorConfig.sol";
import "./SystemAddresses.sol";
import "./Errors.sol";

/// @title ValidatorRegistry
/// @notice Simplified validator registry for consensus participation
/// @dev Governance voting is handled by Staking.sol, not this contract
contract ValidatorRegistry is IValidatorRegistry {
    // === Constants ===
    uint256 public constant MAX_MONIKER_LENGTH = 31;
    
    // === Immutables ===
    Timestamp public immutable timestamp;
    ValidatorConfig public immutable config;
    
    // === Storage: Global state ===
    uint64 public epoch;
    uint64 public lastReconfigurationTime;
    uint256 public totalVotingPower;
    uint256 public totalJoiningPowerThisEpoch;
    
    // === Storage: Validator sets ===
    address[] public activeValidators;
    address[] public pendingActive;
    address[] public pendingInactive;
    
    // === Storage: Per-validator records ===
    mapping(address => ValidatorRecord) internal _validators;
    mapping(address => bool) public validatorExists;
    
    // === Modifiers ===
    
    modifier onlyOwner(address validator) {
        ValidatorRecord storage v = _validators[validator];
        if (v.owner != msg.sender) revert Errors.NotOwner(v.owner, msg.sender);
        _;
    }
    
    modifier onlyOperator(address validator) {
        ValidatorRecord storage v = _validators[validator];
        if (v.operator != msg.sender) revert Errors.NotOperator(v.operator, msg.sender);
        _;
    }
    
    modifier mustExist(address validator) {
        if (!validatorExists[validator]) revert Errors.ValidatorNotFound(validator);
        _;
    }
    
    // === Constructor ===
    
    constructor(address _timestamp, address _config) {
        timestamp = Timestamp(_timestamp);
        config = ValidatorConfig(_config);
        epoch = 1;
    }
    
    // === Consensus-facing view functions ===
    
    function getEpoch() external view override returns (uint64) {
        return epoch;
    }
    
    function getActiveValidatorCount() external view override returns (uint256) {
        return activeValidators.length;
    }
    
    function getActiveValidators() external view override returns (address[] memory) {
        return activeValidators;
    }
    
    function getActiveValidatorSetPacked() external view override returns (bytes memory) {
        uint256 len = activeValidators.length;
        ValidatorConsensusInfo[] memory infos = new ValidatorConsensusInfo[](len);
        
        for (uint256 i = 0; i < len; i++) {
            address val = activeValidators[i];
            ValidatorRecord storage v = _validators[val];
            infos[i] = ValidatorConsensusInfo({
                validator: val,
                consensusPubkey: v.consensusPubkey,
                consensusPop: v.consensusPop,
                votingPower: v.bond  // Simple: voting power = bond
            });
        }
        
        return abi.encode(infos);
    }
    
    function getValidatorIndex(address validator) external view override mustExist(validator) returns (uint64) {
        return _validators[validator].validatorIndex;
    }
    
    function getValidatorVotingPower(address validator) external view override mustExist(validator) returns (uint256) {
        ValidatorRecord storage v = _validators[validator];
        if (v.status == ValidatorStatus.ACTIVE || v.status == ValidatorStatus.PENDING_INACTIVE) {
            return v.bond;
        }
        return 0;
    }
    
    function getValidatorConsensusKey(address validator) external view override mustExist(validator) 
        returns (bytes memory pubkey, bytes memory pop) 
    {
        ValidatorRecord storage v = _validators[validator];
        return (v.consensusPubkey, v.consensusPop);
    }
    
    function getTotalVotingPower() external view override returns (uint256) {
        return totalVotingPower;
    }
    
    function getFeeRecipient(address validator) external view override mustExist(validator) returns (address) {
        ValidatorRecord storage v = _validators[validator];
        // If validator has a staking pool, fees go there for distribution
        if (v.stakingPool != address(0)) {
            return v.stakingPool;
        }
        return v.feeRecipient;
    }
    
    // === Validator info ===
    
    function getValidator(address validator) external view override returns (ValidatorRecord memory) {
        return _validators[validator];
    }
    
    function getStakingPool(address validator) external view override mustExist(validator) returns (address) {
        return _validators[validator].stakingPool;
    }
    
    // === Registration ===
    
    function registerValidator(
        address validator,
        string calldata moniker,
        address owner,
        address operator,
        bytes calldata consensusPubkey,
        bytes calldata consensusPop,
        bytes calldata networkAddresses,
        bytes calldata fullnodeAddresses
    ) external override {
        if (validatorExists[validator]) revert Errors.ValidatorAlreadyExists(validator);
        if (bytes(moniker).length > MAX_MONIKER_LENGTH) {
            revert Errors.MonikerTooLong(MAX_MONIKER_LENGTH, bytes(moniker).length);
        }
        
        _validators[validator] = ValidatorRecord({
            validator: validator,
            moniker: moniker,
            owner: owner,
            operator: operator,
            status: ValidatorStatus.INACTIVE,
            bond: 0,
            pendingUnbond: 0,
            unbondAvailableAt: 0,
            consensusPubkey: consensusPubkey,
            consensusPop: consensusPop,
            networkAddresses: networkAddresses,
            fullnodeAddresses: fullnodeAddresses,
            feeRecipient: owner,
            pendingFeeRecipient: address(0),
            stakingPool: address(0),
            validatorIndex: 0
        });
        
        validatorExists[validator] = true;
        emit ValidatorRegistered(validator, owner, operator);
    }
    
    // === Role management ===
    
    function setOperator(address validator, address newOperator) external override onlyOwner(validator) {
        ValidatorRecord storage v = _validators[validator];
        address oldOperator = v.operator;
        v.operator = newOperator;
        emit OperatorUpdated(validator, oldOperator, newOperator);
    }
    
    function setFeeRecipient(address validator, address newRecipient) external override onlyOwner(validator) {
        ValidatorRecord storage v = _validators[validator];
        v.pendingFeeRecipient = newRecipient;
        // Applied at next epoch in onNewEpoch()
    }
    
    function setStakingPool(address validator, address stakingPool) external override onlyOwner(validator) {
        ValidatorRecord storage v = _validators[validator];
        v.stakingPool = stakingPool;
        emit StakingPoolSet(validator, stakingPool);
    }
    
    // === Bonding (SIMPLIFIED — no 4-bucket model) ===
    
    function bond(address validator) external payable override onlyOwner(validator) {
        if (msg.value == 0) revert Errors.ZeroAmount();
        
        ValidatorRecord storage v = _validators[validator];
        uint256 newBond = v.bond + msg.value;
        
        // Check maximum bond
        if (newBond > config.maximumBond()) {
            revert Errors.ExceedsMaximumBond(config.maximumBond(), newBond);
        }
        
        v.bond = newBond;
        emit Bonded(validator, msg.value);
    }
    
    function requestUnbond(address validator, uint256 amount) external override onlyOwner(validator) {
        if (amount == 0) revert Errors.ZeroAmount();
        
        ValidatorRecord storage v = _validators[validator];
        if (amount > v.bond) revert Errors.InsufficientBond(amount, v.bond);
        
        // Check minimum bond requirement if still active
        if (v.status == ValidatorStatus.ACTIVE || v.status == ValidatorStatus.PENDING_ACTIVE) {
            uint256 remainingBond = v.bond - amount;
            if (remainingBond < config.minimumBond()) {
                revert Errors.InsufficientBond(config.minimumBond(), remainingBond);
            }
        }
        
        v.bond -= amount;
        v.pendingUnbond += amount;
        v.unbondAvailableAt = timestamp.nowSeconds() + config.unbondingDelaySecs();
        
        emit UnbondRequested(validator, amount);
    }
    
    function withdraw(address validator, address payable to) external override onlyOwner(validator) {
        ValidatorRecord storage v = _validators[validator];
        
        uint64 now_ = timestamp.nowSeconds();
        if (v.unbondAvailableAt > now_) {
            revert Errors.UnbondNotReady(v.unbondAvailableAt, now_);
        }
        
        uint256 amount = v.pendingUnbond;
        if (amount == 0) revert Errors.ZeroAmount();
        
        v.pendingUnbond = 0;
        
        (bool success, ) = to.call{value: amount}("");
        require(success, "ValidatorRegistry: transfer failed");
        
        emit Withdrawn(validator, to, amount);
    }
    
    // === Join / leave validator set ===
    
    function requestJoin(address validator) external override onlyOperator(validator) {
        if (!config.allowValidatorSetChange()) revert Errors.ValidatorSetChangesDisabled();
        
        ValidatorRecord storage v = _validators[validator];
        if (v.status != ValidatorStatus.INACTIVE) {
            revert Errors.InvalidStatus(uint8(ValidatorStatus.INACTIVE), uint8(v.status));
        }
        
        // Check minimum bond
        if (v.bond < config.minimumBond()) {
            revert Errors.InsufficientBond(config.minimumBond(), v.bond);
        }
        
        // Check validator set size
        if (activeValidators.length + pendingActive.length >= config.maxValidatorSetSize()) {
            revert Errors.MaxValidatorSetSizeReached(config.maxValidatorSetSize());
        }
        
        v.status = ValidatorStatus.PENDING_ACTIVE;
        pendingActive.push(validator);
        
        emit JoinRequested(validator);
    }
    
    function requestLeave(address validator) external override onlyOperator(validator) {
        if (!config.allowValidatorSetChange()) revert Errors.ValidatorSetChangesDisabled();
        
        ValidatorRecord storage v = _validators[validator];
        
        if (v.status == ValidatorStatus.PENDING_ACTIVE) {
            // Remove from pendingActive
            _removeFromArray(pendingActive, validator);
            v.status = ValidatorStatus.INACTIVE;
        } else if (v.status == ValidatorStatus.ACTIVE) {
            v.status = ValidatorStatus.PENDING_INACTIVE;
            pendingInactive.push(validator);
        } else {
            revert Errors.InvalidStatus(uint8(ValidatorStatus.ACTIVE), uint8(v.status));
        }
        
        emit LeaveRequested(validator);
    }
    
    // === Operational metadata ===
    
    function rotateConsensusKey(
        address validator, 
        bytes calldata newPubkey, 
        bytes calldata newPop
    ) external override onlyOperator(validator) {
        ValidatorRecord storage v = _validators[validator];
        v.consensusPubkey = newPubkey;
        v.consensusPop = newPop;
        emit ConsensusKeyRotated(validator);
    }
    
    function updateNetworkAddresses(
        address validator, 
        bytes calldata networkAddrs, 
        bytes calldata fullnodeAddrs
    ) external override onlyOperator(validator) {
        ValidatorRecord storage v = _validators[validator];
        v.networkAddresses = networkAddrs;
        v.fullnodeAddresses = fullnodeAddrs;
        emit NetworkAddressesUpdated(validator);
    }
    
    // === System entrypoint: epoch transition ===
    
    function onNewEpoch(uint64 epochNumber, uint64 timestampSecs, bytes calldata extraData) external override {
        SystemAddresses.assertVM();
        
        // 1. Activate pending validators
        for (uint256 i = 0; i < pendingActive.length; i++) {
            address val = pendingActive[i];
            ValidatorRecord storage v = _validators[val];
            
            // Verify still meets requirements
            if (v.bond >= config.minimumBond() && v.consensusPubkey.length > 0) {
                v.status = ValidatorStatus.ACTIVE;
                v.validatorIndex = uint64(activeValidators.length);
                activeValidators.push(val);
                emit ValidatorActivated(val, epochNumber);
            } else {
                v.status = ValidatorStatus.INACTIVE;
            }
        }
        delete pendingActive;
        
        // 2. Deactivate leaving validators
        for (uint256 i = 0; i < pendingInactive.length; i++) {
            address val = pendingInactive[i];
            ValidatorRecord storage v = _validators[val];
            v.status = ValidatorStatus.INACTIVE;
            _removeFromArray(activeValidators, val);
            emit ValidatorDeactivated(val, epochNumber);
        }
        delete pendingInactive;
        
        // 3. Apply pending fee recipient changes
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorRecord storage v = _validators[activeValidators[i]];
            if (v.pendingFeeRecipient != address(0)) {
                address old = v.feeRecipient;
                v.feeRecipient = v.pendingFeeRecipient;
                v.pendingFeeRecipient = address(0);
                emit FeeRecipientUpdated(activeValidators[i], old, v.feeRecipient);
            }
        }
        
        // 4. Recompute total voting power and validator indices
        totalVotingPower = 0;
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorRecord storage v = _validators[activeValidators[i]];
            v.validatorIndex = uint64(i);
            totalVotingPower += v.bond;
        }
        
        // 5. Update epoch
        epoch = epochNumber;
        lastReconfigurationTime = timestampSecs;
        totalJoiningPowerThisEpoch = 0;
        
        emit EpochProcessed(epochNumber, activeValidators.length, totalVotingPower);
    }
    
    // === Internal helpers ===
    
    function _removeFromArray(address[] storage arr, address val) internal {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == val) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }
}
```

---

## Layer 4: Block

**Depends on**: Layer 0, Layer 1, Layer 3

### Contract: `Block.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SystemAddresses.sol";
import "./Timestamp.sol";
import "./IValidatorRegistry.sol";

/// @title Block
/// @notice Block prologue/epilogue, epoch timeout check
contract Block {
    // === Storage ===
    uint64 public height;
    uint64 public epochIntervalMicroseconds;
    
    Timestamp public immutable timestamp;
    IValidatorRegistry public immutable validatorRegistry;
    
    // === Events ===
    event BlockProduced(uint64 indexed height, address indexed proposer, uint64 timestamp);
    event EpochTimeoutTriggered(uint64 epoch);
    
    // === Constructor ===
    constructor(address _timestamp, address _validatorRegistry, uint64 _epochIntervalMicroseconds) {
        timestamp = Timestamp(_timestamp);
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        epochIntervalMicroseconds = _epochIntervalMicroseconds;
    }
    
    /// @notice Block prologue (called by VM at start of each block)
    /// @param proposer Block proposer address
    /// @param timestampMicros Block timestamp in microseconds
    function blockPrologue(
        address proposer,
        uint64 timestampMicros
    ) external {
        SystemAddresses.assertVM();
        
        // Update timestamp
        timestamp.updateGlobalTime(timestampMicros);
        
        // Increment block height
        height++;
        
        emit BlockProduced(height, proposer, timestampMicros);
        
        // Check epoch timeout (simplified - actual implementation would call reconfiguration)
        // uint64 lastReconfig = reconfiguration.lastReconfigurationTime();
        // if (timestampMicros - lastReconfig >= epochIntervalMicroseconds) {
        //     emit EpochTimeoutTriggered(validatorRegistry.getEpoch());
        //     // Trigger reconfiguration
        // }
    }
    
    /// @notice Update epoch interval (framework-only)
    function setEpochIntervalMicroseconds(uint64 interval) external {
        SystemAddresses.assertFramework();
        require(interval > 0, "Block: interval must be > 0");
        epochIntervalMicroseconds = interval;
    }
}
```

---

## Layer 5: Reconfiguration

**Depends on**: Layer 0, Layer 1, Layer 3, Layer 4

### Interface: `IReconfiguration.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IReconfiguration
/// @notice Epoch transition driver
interface IReconfiguration {
    // === Events ===
    event NewEpoch(uint64 indexed epoch);
    event ReconfigurationStarted(uint64 epoch);
    event ReconfigurationFinished(uint64 epoch);
    
    // === View functions ===
    function currentEpoch() external view returns (uint64);
    function lastReconfigurationTime() external view returns (uint64);
    function isInProgress() external view returns (bool);
    
    // === Mutating functions ===
    function reconfigure() external;
}
```

### Contract: `Reconfiguration.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IReconfiguration.sol";
import "./IValidatorRegistry.sol";
import "./Timestamp.sol";
import "./SystemAddresses.sol";
import "./Errors.sol";

/// @title Reconfiguration
/// @notice Epoch transition driver
contract Reconfiguration is IReconfiguration {
    // === Storage ===
    uint64 public epoch;
    uint64 public lastReconfigurationTime;
    bool public inProgress;
    
    Timestamp public immutable timestamp;
    IValidatorRegistry public immutable validatorRegistry;
    
    // === Constructor ===
    constructor(address _timestamp, address _validatorRegistry) {
        timestamp = Timestamp(_timestamp);
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        epoch = 1;
    }
    
    // === View functions ===
    
    function currentEpoch() external view override returns (uint64) {
        return epoch;
    }
    
    function lastReconfigurationTime() external view override returns (uint64) {
        return lastReconfigurationTime;
    }
    
    function isInProgress() external view override returns (bool) {
        return inProgress;
    }
    
    // === Reconfigure (framework-only or system-only) ===
    
    function reconfigure() external override {
        // Can be called by framework (governance) or block prologue
        if (msg.sender != SystemAddresses.FRAMEWORK && msg.sender != SystemAddresses.BLOCK) {
            revert("Reconfiguration: unauthorized");
        }
        
        if (inProgress) revert Errors.ReconfigurationInProgress();
        
        uint64 now_ = timestamp.nowMicroseconds();
        
        // Prevent multiple reconfigurations in same block
        if (now_ == lastReconfigurationTime && lastReconfigurationTime != 0) {
            return; // Deduplicate
        }
        
        // Start reconfiguration
        inProgress = true;
        emit ReconfigurationStarted(epoch);
        
        // Call validator registry's epoch transition
        validatorRegistry.onNewEpoch(epoch + 1, timestamp.nowSeconds(), "");
        
        // Increment epoch
        epoch++;
        lastReconfigurationTime = now_;
        
        // Finish reconfiguration
        inProgress = false;
        emit ReconfigurationFinished(epoch);
        emit NewEpoch(epoch);
    }
}
```

---

## Layer 6: Governance

**Depends on**: All layers

**KEY CHANGE**: Governance voting power now comes from `Staking.sol`, NOT from validator bonds.
Anyone who stakes tokens can participate in governance, not just validators.

### Interface: `IGravityGovernance.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IGravityGovernance
/// @notice On-chain governance interface
/// @dev Voting power comes from Staking.sol, NOT validators
interface IGravityGovernance {
    // === Events ===
    event ProposalCreated(uint64 indexed proposalId, address indexed proposer);
    event Voted(uint64 indexed proposalId, address indexed voter, bool support, uint128 votingPower);
    event ProposalExecuted(uint64 indexed proposalId, bytes32 executionHash);
    
    // === View functions ===
    function getGovernanceConfig() external view returns (
        uint128 minVotingThreshold,
        uint256 requiredProposerStake,
        uint64 votingDurationSecs
    );
    
    // === Mutating functions ===
    
    /// @notice Create a governance proposal (requires staked tokens)
    function createProposal(
        bytes32 executionHash,
        string calldata metadataUri
    ) external returns (uint64 proposalId);
    
    /// @notice Vote on a proposal (voting power = staked tokens)
    function vote(
        uint64 proposalId,
        bool support
    ) external;
    
    /// @notice Resolve a passed proposal
    function resolve(uint64 proposalId, bytes32 executionHash) external;
    
    /// @notice Trigger epoch reconfiguration after governance action
    function reconfigure() external;
}
```

### Contract: `GravityGovernance.sol` (DECOUPLED — uses Staking for voting)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IGravityGovernance.sol";
import "./IVoting.sol";
import "./IStaking.sol";
import "./IReconfiguration.sol";
import "./Timestamp.sol";
import "./StakingConfig.sol";
import "./SystemAddresses.sol";
import "./Errors.sol";

/// @title GravityGovernance
/// @notice On-chain governance for Gravity
/// @dev KEY CHANGE: Voting power comes from Staking.sol, NOT validators
///      ANYONE who stakes tokens can participate in governance
contract GravityGovernance is IGravityGovernance {
    // === Storage: Config ===
    uint128 public minVotingThreshold;
    uint256 public requiredProposerStake;
    uint64 public votingDurationSecs;
    
    // === Storage: Approved execution hashes ===
    mapping(uint64 => bytes32) public approvedExecutionHashes;
    
    // === Storage: Voting records (per voter per proposal) ===
    mapping(address => mapping(uint64 => uint128)) public votingRecords;
    
    // === Immutables ===
    IVoting public immutable voting;
    IStaking public immutable staking;
    IReconfiguration public immutable reconfiguration;
    Timestamp public immutable timestamp;
    StakingConfig public immutable stakingConfig;
    
    // === Constructor ===
    constructor(
        address _voting,
        address _staking,
        address _reconfiguration,
        address _timestamp,
        address _stakingConfig,
        uint128 _minVotingThreshold,
        uint256 _requiredProposerStake,
        uint64 _votingDurationSecs
    ) {
        voting = IVoting(_voting);
        staking = IStaking(_staking);
        reconfiguration = IReconfiguration(_reconfiguration);
        timestamp = Timestamp(_timestamp);
        stakingConfig = StakingConfig(_stakingConfig);
        minVotingThreshold = _minVotingThreshold;
        requiredProposerStake = _requiredProposerStake;
        votingDurationSecs = _votingDurationSecs;
    }
    
    // === View functions ===
    
    function getGovernanceConfig() external view override returns (
        uint128, uint256, uint64
    ) {
        return (minVotingThreshold, requiredProposerStake, votingDurationSecs);
    }
    
    // === Create proposal (ANYONE with sufficient stake can create) ===
    
    function createProposal(
        bytes32 executionHash,
        string calldata metadataUri
    ) external override returns (uint64 proposalId) {
        // Get proposer's voting power from staking contract
        uint256 votingPower = staking.getVotingPower(msg.sender);
        
        // Verify sufficient stake
        if (votingPower < requiredProposerStake) {
            revert Errors.InsufficientVotingPower(requiredProposerStake, votingPower);
        }
        
        // Verify lockup covers voting duration
        StakePosition memory pos = staking.getStake(msg.sender);
        uint64 proposalExpiration = timestamp.nowSeconds() + votingDurationSecs;
        if (pos.lockedUntil < proposalExpiration) {
            revert Errors.InsufficientLockup(proposalExpiration, pos.lockedUntil);
        }
        
        // Create proposal via voting engine
        proposalId = voting.createProposal(
            msg.sender,
            msg.sender,  // stakePool field now just stores proposer
            executionHash,
            metadataUri,
            minVotingThreshold,
            votingDurationSecs
        );
        
        emit ProposalCreated(proposalId, msg.sender);
    }
    
    // === Vote (ANYONE with stake can vote) ===
    
    function vote(
        uint64 proposalId,
        bool support
    ) external override {
        // Get voter's voting power from staking contract
        uint256 votingPower = staking.getVotingPower(msg.sender);
        if (votingPower == 0) {
            revert Errors.InsufficientVotingPower(1, 0);
        }
        
        // Verify lockup covers proposal expiration
        Proposal memory proposal = voting.getProposal(proposalId);
        StakePosition memory pos = staking.getStake(msg.sender);
        if (pos.lockedUntil < proposal.expirationTime) {
            revert Errors.InsufficientLockup(proposal.expirationTime, pos.lockedUntil);
        }
        
        // Calculate remaining voting power (supports partial voting)
        uint128 usedPower = votingRecords[msg.sender][proposalId];
        uint128 remainingPower = uint128(votingPower) - usedPower;
        
        require(remainingPower > 0, "GravityGovernance: no voting power remaining");
        
        // Record vote
        votingRecords[msg.sender][proposalId] = uint128(votingPower);
        
        // Cast vote
        voting.vote(proposalId, msg.sender, remainingPower, support);
        
        emit Voted(proposalId, msg.sender, support, remainingPower);
        
        // Check for early resolution and add to approved hashes if passed
        ProposalState state = voting.getProposalState(proposalId);
        if (state == ProposalState.SUCCEEDED) {
            approvedExecutionHashes[proposalId] = proposal.executionHash;
        }
    }
    
    // === Resolve and execute ===
    
    function resolve(uint64 proposalId, bytes32 executionHash) external override {
        // Resolve proposal
        ProposalState state = voting.resolve(proposalId);
        require(state == ProposalState.SUCCEEDED, "GravityGovernance: proposal did not pass");
        
        // Verify execution hash matches
        Proposal memory proposal = voting.getProposal(proposalId);
        if (executionHash != proposal.executionHash) {
            revert Errors.ExecutionHashMismatch(proposal.executionHash, executionHash);
        }
        
        // Add to approved hashes
        approvedExecutionHashes[proposalId] = executionHash;
        
        emit ProposalExecuted(proposalId, executionHash);
    }
    
    // === Trigger reconfiguration (after governance proposal passes) ===
    
    function reconfigure() external override {
        SystemAddresses.assertFramework();
        reconfiguration.reconfigure();
    }
    
    // === Config setters (framework-only) ===
    
    function setMinVotingThreshold(uint128 threshold) external {
        SystemAddresses.assertFramework();
        minVotingThreshold = threshold;
    }
    
    function setRequiredProposerStake(uint256 stake) external {
        SystemAddresses.assertFramework();
        requiredProposerStake = stake;
    }
    
    function setVotingDurationSecs(uint64 duration) external {
        SystemAddresses.assertFramework();
        votingDurationSecs = duration;
    }
}
```

---

## Implementation Checklist

### Phase 1: Foundation (Week 1)
- [ ] `SystemAddresses.sol` — System address constants
- [ ] `Types.sol` — Core data types (StakePosition, ValidatorRecord, Proposal)
- [ ] `Errors.sol` — Custom errors

### Phase 2: Config + Time (Week 1-2)
- [ ] `Timestamp.sol` — On-chain time
- [ ] `StakingConfig.sol` — Governance staking parameters
- [ ] `ValidatorConfig.sol` — Validator registry parameters
- [ ] `ConfigBuffer.sol` — Buffered config pattern (optional)

### Phase 3: Staking + Voting (Week 2-3) ⭐ NEW
- [ ] `IStaking.sol` — Staking interface
- [ ] `Staking.sol` — Generic governance staking (ANYONE can stake)
  - [ ] stake() / unstake() / withdraw()
  - [ ] getVotingPower() — for governance
  - [ ] extendLockup()
- [ ] `IVoting.sol` — Voting interface
- [ ] `Voting.sol` — Generic voting engine
- [ ] Unit tests for staking lifecycle

### Phase 4: Validator Registry (Week 3-4) — SIMPLIFIED
- [ ] `IValidatorRegistry.sol` — Simplified interface
- [ ] `ValidatorRegistry.sol` — Consensus validator registry
  - [ ] Registration + role management
  - [ ] Simple bond / unbond / withdraw (no 4-bucket model)
  - [ ] Join / leave validator set
  - [ ] Consensus key rotation
  - [ ] setStakingPool() — link to external delegation pool
  - [ ] `onNewEpoch()` — epoch transition logic
- [ ] `IValidatorStakingPool.sol` — External interface for custom pools
- [ ] Unit tests for validator lifecycle

### Phase 5: Block + Reconfiguration (Week 4-5)
- [ ] `Block.sol` — Block prologue/epilogue
- [ ] `IReconfiguration.sol` — Reconfiguration interface
- [ ] `Reconfiguration.sol` — Epoch driver
- [ ] Integration tests: epoch transitions

### Phase 6: Governance (Week 5-6)
- [ ] `IGravityGovernance.sol` — Governance interface
- [ ] `GravityGovernance.sol` — Full implementation (uses Staking, not validators)
- [ ] Integration tests: proposal lifecycle

### Phase 7: Integration + Genesis (Week 6-7)
- [ ] Genesis bootstrap script
- [ ] End-to-end integration tests
- [ ] Gas optimization
- [ ] Security audit preparation

### Phase 8: Optional — Example Validator Staking Pool (Week 7-8)
- [ ] `ExampleStakingPool.sol` — Reference implementation of IValidatorStakingPool
  - [ ] Delegation shares accounting
  - [ ] Commission handling
  - [ ] Reward distribution

---

## Testing Strategy

### Unit Tests (per contract)
- State transitions
- Access control (owner/operator/system)
- Edge cases (min/max stake/bond, lockup boundaries)
- Revert conditions

### Integration Tests — Staking
- Stake → extend lockup → vote → unstake → withdraw
- Voting power calculation with lockup expiration
- Multiple stakers with overlapping proposals

### Integration Tests — Validators
- Full validator lifecycle: register → bond → join → validate → leave → withdraw
- Epoch transitions with multiple validators
- setStakingPool() integration with external delegation

### Integration Tests — Governance
- Proposal lifecycle: create → vote → resolve → execute
- Config changes via governance
- Anyone (not just validators) can create proposals and vote

### Invariant Tests
- Staking: totalStaked == sum of all stake positions
- Validators: validator set membership consistency
- Validators: totalVotingPower == sum of active validator bonds

---

## Security Considerations

1. **Reentrancy**: Use checks-effects-interactions, consider ReentrancyGuard for `withdraw()`
2. **Access control**: Strict owner/operator/system separation
3. **Epoch transition bounds**: Limit validator set size, avoid unbounded loops
4. **Key validation**: Consensus validates keys off-chain; contract trusts `extraData`
5. **Flash loan protection**: Non-atomic proposal resolution
6. **Integer overflow**: Use Solidity 0.8+ built-in checks

---

## Future Extensions (Out of Scope for MVP)

- **Slashing**: Define slashable offenses, reporting path, penalties
- **Jailing**: Temporary removal without full unbond
- **DKG integration**: `ReconfigurationWithDKG.sol` for randomness
- **Stake snapshots**: Explicit per-epoch snapshots for governance
- **Liquid staking**: LST tokens representing staked governance tokens
- **Quadratic voting**: Alternative voting power calculation
- **Delegation within Staking**: Optional delegation for governance staking

---

## References

- `gravity_docs/about_gravity.md` — Gravity design constraints
- `gravity_docs/validator_management_spec.md` — Full validator spec
- `gravity_docs/staking_gov.md` — Aptos staking/governance reference
- `gravity_docs/aptos_on_chain_parameters.md` — On-chain parameters
- `gravity_docs/aptos_contract_dependency_diagram.md` — Dependency layers


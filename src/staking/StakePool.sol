// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IStakePool} from "./IStakePool.sol";
import {IStakingHook} from "./IStakingHook.sol";
import {SystemAddresses} from "../foundation/SystemAddresses.sol";
import {Errors} from "../foundation/Errors.sol";

/// @notice Interface for Timestamp contract
interface ITimestampPool {
    function nowMicroseconds() external view returns (uint64);
}

/// @notice Interface for StakingConfig contract
interface IStakingConfigPool {
    function lockupDurationMicros() external view returns (uint64);
}

/// @title StakePool
/// @author Gravity Team
/// @notice Individual stake pool contract for a single owner
/// @dev Created via CREATE2 by the Staking factory. Each user creates their own pool.
///      Implements role separation: Owner / Operator / Voter (like Aptos)
contract StakePool is IStakePool {
    // ========================================================================
    // IMMUTABLES
    // ========================================================================

    /// @notice Address of the Staking factory that created this pool
    address public immutable FACTORY;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Owner address (controls funds, can set operator/voter/hook)
    address public owner;

    /// @notice Operator address (reserved for validator operations)
    address public operator;

    /// @notice Delegated voter address (votes in governance using pool's stake)
    address public voter;

    /// @notice Total staked amount
    uint256 public stake;

    /// @notice Lockup expiration timestamp (microseconds)
    uint64 public lockedUntil;

    /// @notice Optional hook contract for callbacks
    address public hook;

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @notice Restricts function to owner only
    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert Errors.NotOwner(msg.sender, owner);
        }
        _;
    }

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /// @notice Initialize the stake pool with owner and initial stake
    /// @param _owner Owner address for this pool
    /// @dev Called by factory during CREATE2 deployment
    constructor(address _owner) payable {
        FACTORY = msg.sender;
        owner = _owner;
        operator = _owner; // Default: owner is also operator
        voter = _owner; // Default: owner is also voter

        // Set initial stake from constructor value
        stake = msg.value;

        // Set initial lockup
        uint64 now_ = ITimestampPool(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 minLockup = IStakingConfigPool(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();
        lockedUntil = now_ + minLockup;

        emit StakeAdded(address(this), msg.value);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStakePool
    function getOwner() external view returns (address) {
        return owner;
    }

    /// @inheritdoc IStakePool
    function getOperator() external view returns (address) {
        return operator;
    }

    /// @inheritdoc IStakePool
    function getVoter() external view returns (address) {
        return voter;
    }

    /// @inheritdoc IStakePool
    function getStake() external view returns (uint256) {
        return stake;
    }

    /// @inheritdoc IStakePool
    function getVotingPower() external view returns (uint256) {
        uint64 now_ = ITimestampPool(SystemAddresses.TIMESTAMP).nowMicroseconds();
        if (lockedUntil > now_) {
            return stake;
        }
        return 0;
    }

    /// @inheritdoc IStakePool
    function getLockedUntil() external view returns (uint64) {
        return lockedUntil;
    }

    /// @inheritdoc IStakePool
    function getRemainingLockup() external view returns (uint64) {
        uint64 now_ = ITimestampPool(SystemAddresses.TIMESTAMP).nowMicroseconds();
        if (lockedUntil > now_) {
            return lockedUntil - now_;
        }
        return 0;
    }

    /// @inheritdoc IStakePool
    function isLocked() external view returns (bool) {
        uint64 now_ = ITimestampPool(SystemAddresses.TIMESTAMP).nowMicroseconds();
        return lockedUntil > now_;
    }

    /// @inheritdoc IStakePool
    function getHook() external view returns (address) {
        return hook;
    }

    // ========================================================================
    // OWNER FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStakePool
    function addStake() external payable onlyOwner {
        if (msg.value == 0) {
            revert Errors.ZeroAmount();
        }

        stake += msg.value;

        // Extend lockup if needed: lockedUntil = max(current, now + minLockupDuration)
        uint64 now_ = ITimestampPool(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 minLockup = IStakingConfigPool(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();
        uint64 newLockedUntil = now_ + minLockup;

        if (newLockedUntil > lockedUntil) {
            lockedUntil = newLockedUntil;
        }

        // Call hook if set
        if (hook != address(0)) {
            IStakingHook(hook).onStakeAdded(msg.value);
        }

        emit StakeAdded(address(this), msg.value);
    }

    /// @inheritdoc IStakePool
    function withdraw(uint256 amount) external onlyOwner {
        uint64 now_ = ITimestampPool(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // Check lockup expired
        if (lockedUntil > now_) {
            revert Errors.LockupNotExpired(lockedUntil, now_);
        }

        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        if (amount > stake) {
            revert Errors.InsufficientStake(amount, stake);
        }

        stake -= amount;

        // Call hook if set
        if (hook != address(0)) {
            IStakingHook(hook).onStakeWithdrawn(amount);
        }

        emit StakeWithdrawn(address(this), amount);

        // Transfer tokens to owner (CEI pattern - effects before interactions)
        (bool success,) = payable(owner).call{value: amount}("");
        require(success, "StakePool: transfer failed");
    }

    /// @inheritdoc IStakePool
    function increaseLockup(uint64 durationMicros) external onlyOwner {
        uint64 minLockup = IStakingConfigPool(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();

        // Duration must be at least minLockupDuration
        if (durationMicros < minLockup) {
            revert Errors.LockupDurationTooShort(durationMicros, minLockup);
        }

        // Check for overflow
        uint64 newLockedUntil = lockedUntil + durationMicros;
        if (newLockedUntil <= lockedUntil) {
            revert Errors.LockupOverflow(lockedUntil, durationMicros);
        }

        uint64 oldLockedUntil = lockedUntil;
        lockedUntil = newLockedUntil;

        // Call hook if set
        if (hook != address(0)) {
            IStakingHook(hook).onLockupIncreased(newLockedUntil);
        }

        emit LockupIncreased(address(this), oldLockedUntil, newLockedUntil);
    }

    /// @inheritdoc IStakePool
    function setOperator(address newOperator) external onlyOwner {
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorChanged(address(this), oldOperator, newOperator);
    }

    /// @inheritdoc IStakePool
    function setVoter(address newVoter) external onlyOwner {
        address oldVoter = voter;
        voter = newVoter;
        emit VoterChanged(address(this), oldVoter, newVoter);
    }

    /// @inheritdoc IStakePool
    function setHook(address newHook) external onlyOwner {
        address oldHook = hook;
        hook = newHook;
        emit HookChanged(address(this), oldHook, newHook);
    }
}


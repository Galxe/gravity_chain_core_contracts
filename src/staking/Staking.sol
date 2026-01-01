// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IStaking} from "./IStaking.sol";
import {StakePosition} from "../foundation/Types.sol";
import {SystemAddresses} from "../foundation/SystemAddresses.sol";
import {Errors} from "../foundation/Errors.sol";

/// @notice Interface for Timestamp contract
interface ITimestamp {
    function nowMicroseconds() external view returns (uint64);
}

/// @notice Interface for StakingConfig contract
interface IStakingConfig {
    function lockupDurationMicros() external view returns (uint64);
    function minimumStake() external view returns (uint256);
}

/// @title Staking
/// @author Gravity Team
/// @notice Governance staking contract - anyone can stake tokens to participate in governance
/// @dev Uses lockup-only model:
///      - Staking creates/extends lockup to `now + lockupDurationMicros`
///      - Voting power = stake amount only if `lockedUntil > now`
///      - Unstake/withdraw only allowed when `lockedUntil <= now`
contract Staking is IStaking {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Mapping of staker address to their stake position
    mapping(address => StakePosition) internal _stakes;

    /// @notice Total staked tokens across all stakers
    uint256 public totalStaked;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStaking
    function getStake(address staker) external view returns (StakePosition memory) {
        return _stakes[staker];
    }

    /// @inheritdoc IStaking
    function getVotingPower(address staker) external view returns (uint256) {
        StakePosition storage pos = _stakes[staker];
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // Only locked stake counts for voting power
        if (pos.lockedUntil <= now_) {
            return 0;
        }
        return pos.amount;
    }

    /// @inheritdoc IStaking
    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }

    /// @inheritdoc IStaking
    function isLocked(address staker) external view returns (bool) {
        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        return _stakes[staker].lockedUntil > now_;
    }

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStaking
    function stake() external payable {
        if (msg.value == 0) {
            revert Errors.ZeroAmount();
        }

        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 lockupDuration = IStakingConfig(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();
        uint64 newLockedUntil = now_ + lockupDuration;

        StakePosition storage pos = _stakes[msg.sender];

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

    /// @inheritdoc IStaking
    function unstake(uint256 amount) external {
        StakePosition storage pos = _stakes[msg.sender];

        if (pos.amount == 0) {
            revert Errors.NoStakePosition(msg.sender);
        }
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }
        if (amount > pos.amount) {
            revert Errors.InsufficientStake(amount, pos.amount);
        }

        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        if (pos.lockedUntil > now_) {
            revert Errors.LockupNotExpired(pos.lockedUntil, now_);
        }

        pos.amount -= amount;
        totalStaked -= amount;

        emit Unstaked(msg.sender, amount);

        // Transfer tokens back to staker
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Staking: transfer failed");
    }

    /// @inheritdoc IStaking
    function withdraw() external {
        StakePosition storage pos = _stakes[msg.sender];

        if (pos.amount == 0) {
            revert Errors.NoStakePosition(msg.sender);
        }

        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        if (pos.lockedUntil > now_) {
            revert Errors.LockupNotExpired(pos.lockedUntil, now_);
        }

        uint256 amount = pos.amount;
        pos.amount = 0;
        totalStaked -= amount;

        emit Unstaked(msg.sender, amount);

        // Transfer tokens back to staker
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Staking: transfer failed");
    }

    /// @inheritdoc IStaking
    function extendLockup() external {
        StakePosition storage pos = _stakes[msg.sender];

        if (pos.amount == 0) {
            revert Errors.NoStakePosition(msg.sender);
        }

        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 lockupDuration = IStakingConfig(SystemAddresses.STAKE_CONFIG).lockupDurationMicros();
        uint64 newLockedUntil = now_ + lockupDuration;

        // Only extend if new lockup is longer
        if (newLockedUntil <= pos.lockedUntil) {
            revert Errors.LockupNotExpired(pos.lockedUntil, now_);
        }

        pos.lockedUntil = newLockedUntil;

        emit LockupExtended(msg.sender, newLockedUntil);
    }
}


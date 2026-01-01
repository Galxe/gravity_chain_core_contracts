// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {StakePosition} from "../foundation/Types.sol";

/// @title IStaking
/// @author Gravity Team
/// @notice Interface for governance staking (anyone can stake)
/// @dev Staking provides voting power for governance. Uses lockup-only model:
///      - Staking creates/extends lockup to `now + lockupDurationMicros`
///      - Voting power = stake amount only if `lockedUntil > now`
///      - Unstake/withdraw only allowed when `lockedUntil <= now`
interface IStaking {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when tokens are staked
    /// @param staker Address that staked
    /// @param amount Amount staked
    /// @param lockedUntil New lockup expiration (microseconds)
    event Staked(address indexed staker, uint256 amount, uint64 lockedUntil);

    /// @notice Emitted when tokens are unstaked/withdrawn
    /// @param staker Address that unstaked
    /// @param amount Amount unstaked
    event Unstaked(address indexed staker, uint256 amount);

    /// @notice Emitted when lockup is extended
    /// @param staker Address that extended lockup
    /// @param newLockedUntil New lockup expiration (microseconds)
    event LockupExtended(address indexed staker, uint64 newLockedUntil);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get stake position for an address
    /// @param staker Address to query
    /// @return Stake position (amount, lockedUntil, stakedAt)
    function getStake(address staker) external view returns (StakePosition memory);

    /// @notice Get current voting power for an address
    /// @dev Returns 0 if lockup has expired (lockedUntil <= now)
    /// @param staker Address to query
    /// @return Voting power (stake amount if locked, 0 otherwise)
    function getVotingPower(address staker) external view returns (uint256);

    /// @notice Get total staked tokens across all stakers
    /// @return Total staked amount
    function getTotalStaked() external view returns (uint256);

    /// @notice Check if an address has locked stake
    /// @param staker Address to query
    /// @return True if stake is locked (lockedUntil > now)
    function isLocked(address staker) external view returns (bool);

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /// @notice Stake native tokens for governance participation
    /// @dev Creates new position or adds to existing. Extends lockup to max(current, now + lockupDuration)
    function stake() external payable;

    /// @notice Unstake tokens (only when lockup expired)
    /// @dev Reverts if lockup has not expired
    /// @param amount Amount to unstake
    function unstake(uint256 amount) external;

    /// @notice Withdraw all staked tokens (only when lockup expired)
    /// @dev Convenience function to withdraw entire stake
    function withdraw() external;

    /// @notice Extend lockup to maintain voting power
    /// @dev Sets lockedUntil to now + lockupDuration (only if it extends the lockup)
    function extendLockup() external;
}


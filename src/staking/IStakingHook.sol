// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IStakingHook
/// @author Gravity Team
/// @notice Optional callback interface for StakePool extensibility
/// @dev Hook contracts can implement custom logic that executes during stake lifecycle events.
///      Common use cases:
///      - Delegation Pool: Track delegator shares and distribute rewards
///      - Staking Vault: Mint/burn liquid staking tokens
///      - Notification Service: External contract notified of stake changes
///      - Vesting Contract: Enforce vesting schedules on withdrawals
interface IStakingHook {
    /// @notice Called when stake is added to the pool
    /// @param amount Amount of stake added
    function onStakeAdded(uint256 amount) external;

    /// @notice Called when stake is withdrawn
    /// @param amount Amount of stake withdrawn
    function onStakeWithdrawn(uint256 amount) external;

    /// @notice Called when lockup is increased
    /// @param newLockedUntil New lockup expiration timestamp (microseconds)
    function onLockupIncreased(uint64 newLockedUntil) external;
}


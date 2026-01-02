// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IStakePool
/// @author Gravity Team
/// @notice Interface for individual stake pool contracts
/// @dev Each user who wants to stake creates their own StakePool via the Staking factory.
///      Follows Aptos's role separation: Owner / Operator / Voter
interface IStakePool {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when stake is added to the pool
    /// @param pool Address of this pool
    /// @param amount Amount of stake added
    event StakeAdded(address indexed pool, uint256 amount);

    /// @notice Emitted when stake is withdrawn
    /// @param pool Address of this pool
    /// @param amount Amount of stake withdrawn
    event StakeWithdrawn(address indexed pool, uint256 amount);

    /// @notice Emitted when lockup is increased
    /// @param pool Address of this pool
    /// @param oldLockedUntil Previous lockup expiration (microseconds)
    /// @param newLockedUntil New lockup expiration (microseconds)
    event LockupIncreased(address indexed pool, uint64 oldLockedUntil, uint64 newLockedUntil);

    /// @notice Emitted when operator is changed
    /// @param pool Address of this pool
    /// @param oldOperator Previous operator address
    /// @param newOperator New operator address
    event OperatorChanged(address indexed pool, address oldOperator, address newOperator);

    /// @notice Emitted when voter is changed
    /// @param pool Address of this pool
    /// @param oldVoter Previous voter address
    /// @param newVoter New voter address
    event VoterChanged(address indexed pool, address oldVoter, address newVoter);

    /// @notice Emitted when hook is changed
    /// @param pool Address of this pool
    /// @param oldHook Previous hook address
    /// @param newHook New hook address
    event HookChanged(address indexed pool, address oldHook, address newHook);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get the owner address (controls funds, can set operator/voter/hook)
    /// @return Owner address
    function getOwner() external view returns (address);

    /// @notice Get the operator address (reserved for validator operations)
    /// @return Operator address
    function getOperator() external view returns (address);

    /// @notice Get the delegated voter address (votes in governance)
    /// @return Voter address
    function getVoter() external view returns (address);

    /// @notice Get the total staked amount
    /// @return Total stake in wei
    function getStake() external view returns (uint256);

    /// @notice Get the current voting power
    /// @dev Returns stake if locked, 0 if lockup expired
    /// @return Voting power in wei
    function getVotingPower() external view returns (uint256);

    /// @notice Get the lockup expiration timestamp
    /// @return Lockup expiration in microseconds
    function getLockedUntil() external view returns (uint64);

    /// @notice Get the remaining lockup duration
    /// @return Remaining lockup in microseconds (0 if expired)
    function getRemainingLockup() external view returns (uint64);

    /// @notice Check if the pool's stake is currently locked
    /// @return True if lockedUntil > now
    function isLocked() external view returns (bool);

    /// @notice Get the hook contract address
    /// @return Hook address (address(0) if none)
    function getHook() external view returns (address);

    // ========================================================================
    // OWNER FUNCTIONS
    // ========================================================================

    /// @notice Add native tokens to the stake pool
    /// @dev Only callable by owner. Voting power increases immediately.
    ///      Extends lockup to max(current, now + minLockupDuration)
    function addStake() external payable;

    /// @notice Withdraw stake (only when lockup expired)
    /// @dev Only callable by owner. Reverts if lockup not expired.
    /// @param amount Amount to withdraw
    function withdraw(uint256 amount) external;

    /// @notice Extend lockup by a specified duration
    /// @dev Only callable by owner. Duration must be >= minLockupDuration.
    ///      This is additive: extends from current lockedUntil, not from now.
    /// @param durationMicros Duration to add in microseconds
    function increaseLockup(uint64 durationMicros) external;

    /// @notice Change the operator address
    /// @dev Only callable by owner
    /// @param newOperator New operator address
    function setOperator(address newOperator) external;

    /// @notice Change the delegated voter address
    /// @dev Only callable by owner
    /// @param newVoter New voter address
    function setVoter(address newVoter) external;

    /// @notice Set or change the hook contract
    /// @dev Only callable by owner
    /// @param newHook New hook address (or address(0) to remove)
    function setHook(address newHook) external;
}


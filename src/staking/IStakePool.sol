// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IStakePool
/// @author Gravity Team
/// @notice Interface for individual stake pool contracts
/// @dev Each user who wants to stake creates their own StakePool via the Staking factory.
///      Implements two-role separation:
///      - Owner: Administrative control (set voter/operator/staker, ownership via Ownable2Step)
///      - Staker: Fund management (stake/unstake/renewLockUntil) - can be a contract for DPOS, LSD, etc.
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
    /// @param recipient Address that received the withdrawn funds
    event StakeWithdrawn(address indexed pool, uint256 amount, address indexed recipient);

    /// @notice Emitted when lockup is renewed/extended
    /// @param pool Address of this pool
    /// @param oldLockedUntil Previous lockup expiration (microseconds)
    /// @param newLockedUntil New lockup expiration (microseconds)
    event LockupRenewed(address indexed pool, uint64 oldLockedUntil, uint64 newLockedUntil);

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

    /// @notice Emitted when staker is changed
    /// @param pool Address of this pool
    /// @param oldStaker Previous staker address
    /// @param newStaker New staker address
    event StakerChanged(address indexed pool, address oldStaker, address newStaker);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get the staker address (manages funds: stake/unstake/renewLockUntil)
    /// @return Staker address
    function getStaker() external view returns (address);

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

    // ========================================================================
    // OWNER FUNCTIONS (via Ownable2Step)
    // ========================================================================

    /// @notice Change the operator address
    /// @dev Only callable by owner
    /// @param newOperator New operator address
    function setOperator(
        address newOperator
    ) external;

    /// @notice Change the delegated voter address
    /// @dev Only callable by owner
    /// @param newVoter New voter address
    function setVoter(
        address newVoter
    ) external;

    /// @notice Change the staker address
    /// @dev Only callable by owner
    /// @param newStaker New staker address
    function setStaker(
        address newStaker
    ) external;

    // ========================================================================
    // STAKER FUNCTIONS
    // ========================================================================

    /// @notice Add native tokens to the stake pool
    /// @dev Only callable by staker. Voting power increases immediately.
    function addStake() external payable;

    /// @notice Withdraw stake (only when lockup expired)
    /// @dev Only callable by staker. Reverts if lockup not expired.
    /// @param amount Amount to withdraw
    /// @param recipient Address to receive the withdrawn funds
    function withdraw(
        uint256 amount,
        address recipient
    ) external;

    /// @notice Extend lockup by a specified duration
    /// @dev Only callable by staker. The resulting lockedUntil must be >= now + minLockupDuration.
    ///      This is additive: extends from current lockedUntil, not from now.
    /// @param durationMicros Duration to add in microseconds
    function renewLockUntil(
        uint64 durationMicros
    ) external;
}

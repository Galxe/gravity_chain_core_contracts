// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IStakePool
/// @author Gravity Team
/// @notice Interface for individual stake pool contracts with O(log n) withdrawal model
/// @dev Each user who wants to stake creates their own StakePool via the Staking factory.
///      Implements two-role separation:
///      - Owner: Administrative control (set voter/operator/staker, ownership via Ownable2Step)
///      - Staker: Fund management (stake/unstake/withdraw) - can be a contract for DPOS, LSD, etc.
///
///      Withdrawal Model:
///      - unstake() moves funds from activeStake to pending buckets sorted by lockedUntil
///      - withdrawAvailable() claims all pending stake where (now > lockedUntil + unbondingDelay)
///      - unstakeAndWithdraw() helper combines both operations
///      - All operations are O(log n) using prefix-sum buckets with binary search
interface IStakePool {
    // ========================================================================
    // STRUCTS
    // ========================================================================

    /// @notice Represents an aggregated pending withdrawal bucket
    /// @dev Buckets are sorted by lockedUntil in strictly increasing order.
    ///      cumulativeAmount is a prefix sum for O(log n) lookups.
    /// @param lockedUntil Time when this stake stops being effective (microseconds)
    /// @param cumulativeAmount Prefix sum of all unstaked amounts up to and including this bucket
    struct PendingBucket {
        uint64 lockedUntil;
        uint256 cumulativeAmount;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when stake is added to the pool
    /// @param pool Address of this pool
    /// @param amount Amount of stake added
    event StakeAdded(address indexed pool, uint256 amount);

    /// @notice Emitted when stake is unstaked (moved to pending buckets)
    /// @param pool Address of this pool
    /// @param amount Amount unstaked
    /// @param lockedUntil When this stake stops being effective (microseconds)
    event Unstaked(address indexed pool, uint256 amount, uint64 lockedUntil);

    /// @notice Emitted when pending withdrawals are claimed
    /// @param pool Address of this pool
    /// @param amount Total amount withdrawn
    /// @param recipient Address that received the funds
    event WithdrawalClaimed(address indexed pool, uint256 amount, address indexed recipient);

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

    /// @notice Get the staker address (manages funds: stake/unstake/withdraw)
    /// @return Staker address
    function getStaker() external view returns (address);

    /// @notice Get the operator address (reserved for validator operations)
    /// @return Operator address
    function getOperator() external view returns (address);

    /// @notice Get the delegated voter address (votes in governance)
    /// @return Voter address
    function getVoter() external view returns (address);

    /// @notice Get the active stake amount (not including pending withdrawals)
    /// @return Active stake in wei
    function getActiveStake() external view returns (uint256);

    /// @notice Get the total pending withdrawal amount
    /// @return Total pending amount in wei
    function getTotalPending() external view returns (uint256);

    /// @notice Get the voting power at a specific time T
    /// @dev Voting power = activeStake + effective pending (where lockedUntil > T)
    ///      Uses O(log n) binary search on pending buckets.
    /// @param atTime The timestamp (microseconds) to calculate voting power at
    /// @return Voting power in wei
    function getVotingPower(
        uint64 atTime
    ) external view returns (uint256);

    /// @notice Get the current voting power (convenience function)
    /// @return Voting power in wei at current time
    function getVotingPowerNow() external view returns (uint256);

    /// @notice Get the effective stake at a specific time T
    /// @dev Effective stake = activeStake + pending where lockedUntil > T
    ///      Uses O(log n) binary search on pending buckets.
    /// @param atTime The timestamp (microseconds) to calculate effective stake at
    /// @return Effective stake in wei
    function getEffectiveStake(
        uint64 atTime
    ) external view returns (uint256);

    /// @notice Get the lockup expiration timestamp
    /// @return Lockup expiration in microseconds
    function getLockedUntil() external view returns (uint64);

    /// @notice Get the remaining lockup duration
    /// @return Remaining lockup in microseconds (0 if expired)
    function getRemainingLockup() external view returns (uint64);

    /// @notice Check if the pool's stake is currently locked
    /// @return True if lockedUntil > now
    function isLocked() external view returns (bool);

    /// @notice Get the number of pending buckets
    /// @return Number of pending buckets
    function getPendingBucketCount() external view returns (uint256);

    /// @notice Get a pending bucket by index
    /// @param index The bucket index (0-based)
    /// @return The pending bucket at that index
    function getPendingBucket(
        uint256 index
    ) external view returns (PendingBucket memory);

    /// @notice Get the amount already claimed from pending buckets
    /// @return Cumulative amount that has been claimed
    function getClaimedAmount() external view returns (uint256);

    /// @notice Get the amount available in withdrawAvailable()
    /// @dev Returns pending stake where (now > lockedUntil + unbondingDelay)
    /// @return Amount available for withdrawal in wei
    function getClaimableAmount() external view returns (uint256);

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
    ///      Extends lockedUntil to max(current, now + minLockupDuration)
    function addStake() external payable;

    /// @notice Unstake tokens (move from active stake to pending bucket)
    /// @dev Only callable by staker. Creates or merges into a pending bucket.
    ///      The unstaked amount becomes ineffective for voting power when lockedUntil passes.
    ///      Tokens remain in contract until withdrawAvailable() is called after unbonding.
    ///      For active validators, ensures effective stake at (now + minLockup) >= minimumBond.
    /// @param amount Amount to unstake
    function unstake(
        uint256 amount
    ) external;

    /// @notice Withdraw all available pending stake
    /// @dev Only callable by staker. Withdraws all pending buckets where:
    ///      now > lockedUntil + unbondingDelay
    ///      Uses claim pointer model - O(log n) binary search, no iteration.
    /// @param recipient Address to receive the withdrawn funds
    /// @return amount Total amount withdrawn
    function withdrawAvailable(
        address recipient
    ) external returns (uint256 amount);

    /// @notice Helper: unstake and withdraw in one call
    /// @dev Only callable by staker. Calls unstake(amount) then withdrawAvailable(recipient).
    ///      Useful for users who want to unstake and immediately claim any previously
    ///      pending amounts that have completed unbonding.
    /// @param amount Amount to unstake
    /// @param recipient Address to receive any available withdrawn funds
    /// @return withdrawn Amount actually withdrawn (may be 0 if nothing is claimable yet)
    function unstakeAndWithdraw(
        uint256 amount,
        address recipient
    ) external returns (uint256 withdrawn);

    /// @notice Extend lockup by a specified duration
    /// @dev Only callable by staker. The resulting lockedUntil must be >= now + minLockupDuration.
    ///      This is additive: extends from current lockedUntil, not from now.
    /// @param durationMicros Duration to add in microseconds
    function renewLockUntil(
        uint64 durationMicros
    ) external;

    // ========================================================================
    // SYSTEM FUNCTIONS
    // ========================================================================

    /// @notice Renew lockup for active validators (called by Staking factory during epoch transitions)
    /// @dev Only callable by the Staking factory. Sets lockedUntil = now + lockupDurationMicros.
    ///      This implements Aptos-style auto-renewal for active validators.
    ///      Does NOT affect existing pending buckets - they keep their original lockedUntil.
    function systemRenewLockup() external;
}

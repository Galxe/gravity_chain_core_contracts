// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IStakePool
/// @author Gravity Team
/// @notice Interface for individual stake pool contracts with queue-based withdrawals
/// @dev Each user who wants to stake creates their own StakePool via the Staking factory.
///      Implements two-role separation:
///      - Owner: Administrative control (set voter/operator/staker, ownership via Ownable2Step)
///      - Staker: Fund management (stake/requestWithdrawal/claimWithdrawal) - can be a contract for DPOS, LSD, etc.
///
///      Withdrawal Model:
///      - Withdrawals are queued with a nonce and claimable when lockedUntil expires
///      - Voting power = stake - pending withdrawals (where claimableTime < atTime + minLockupDuration)
///      - Active validators can request withdrawals but must maintain minimumBond
interface IStakePool {
    // ========================================================================
    // STRUCTS
    // ========================================================================

    /// @notice Represents a pending withdrawal request
    /// @param amount Amount of stake to withdraw
    /// @param claimableTime When the withdrawal can be claimed (= lockedUntil at request time)
    struct PendingWithdrawal {
        uint256 amount;
        uint64 claimableTime;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when stake is added to the pool
    /// @param pool Address of this pool
    /// @param amount Amount of stake added
    event StakeAdded(address indexed pool, uint256 amount);

    /// @notice Emitted when a withdrawal is requested
    /// @param pool Address of this pool
    /// @param nonce Unique identifier for this withdrawal
    /// @param amount Amount of stake requested for withdrawal
    /// @param claimableTime When the withdrawal can be claimed (microseconds)
    event WithdrawalRequested(address indexed pool, uint256 indexed nonce, uint256 amount, uint64 claimableTime);

    /// @notice Emitted when a withdrawal is claimed
    /// @param pool Address of this pool
    /// @param nonce Unique identifier for this withdrawal
    /// @param amount Amount of stake claimed
    /// @param recipient Address that received the withdrawn funds
    event WithdrawalClaimed(address indexed pool, uint256 indexed nonce, uint256 amount, address indexed recipient);

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

    /// @notice Get the staker address (manages funds: stake/requestWithdrawal/claimWithdrawal)
    /// @return Staker address
    function getStaker() external view returns (address);

    /// @notice Get the operator address (reserved for validator operations)
    /// @return Operator address
    function getOperator() external view returns (address);

    /// @notice Get the delegated voter address (votes in governance)
    /// @return Voter address
    function getVoter() external view returns (address);

    /// @notice Get the total staked amount (includes pending withdrawals until claimed)
    /// @return Total stake in wei
    function getStake() external view returns (uint256);

    /// @notice Get the voting power at a specific time T
    /// @dev Voting power = stake - pending withdrawals where (claimableTime - T) < minLockupDuration
    ///      Returns 0 if lockedUntil <= atTime
    /// @param atTime The timestamp (microseconds) to calculate voting power at
    /// @return Voting power in wei
    function getVotingPower(
        uint64 atTime
    ) external view returns (uint256);

    /// @notice Get the current voting power (convenience function)
    /// @return Voting power in wei at current time
    function getVotingPowerNow() external view returns (uint256);

    /// @notice Get the effective stake at a specific time T
    /// @dev Effective stake = stake - pending withdrawals with insufficient lockup
    ///      This is the stake that counts towards voting power
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

    /// @notice Get a pending withdrawal by nonce
    /// @param nonce The withdrawal nonce
    /// @return The pending withdrawal struct (amount=0 if not found or claimed)
    function getPendingWithdrawal(
        uint256 nonce
    ) external view returns (PendingWithdrawal memory);

    /// @notice Get the total amount in pending withdrawals
    /// @return Total pending withdrawal amount in wei
    function getTotalPendingWithdrawals() external view returns (uint256);

    /// @notice Get the current withdrawal nonce (next nonce to be assigned)
    /// @return Current nonce value
    function getWithdrawalNonce() external view returns (uint256);

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

    /// @notice Request a withdrawal (queue-based)
    /// @dev Only callable by staker. Creates a pending withdrawal with claimableTime = lockedUntil.
    ///      For active validators, ensures effective stake after withdrawal >= minimumBond.
    /// @param amount Amount to withdraw
    /// @return nonce The unique identifier for this withdrawal request
    function requestWithdrawal(
        uint256 amount
    ) external returns (uint256 nonce);

    /// @notice Claim a pending withdrawal
    /// @dev Only callable by staker. Reverts if claimableTime not reached.
    /// @param nonce The withdrawal nonce to claim
    /// @param recipient Address to receive the withdrawn funds
    function claimWithdrawal(
        uint256 nonce,
        address recipient
    ) external;

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
    ///      Does NOT affect existing pending withdrawals - they keep their original claimableTime.
    function systemRenewLockup() external;
}

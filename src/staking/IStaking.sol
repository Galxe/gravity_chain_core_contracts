// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IStaking
/// @author Gravity Team
/// @notice Interface for the StakePool factory contract
/// @dev Factory that creates individual StakePool contracts via CREATE2.
///      Anyone can create a pool with no permission required.
///      Only pools created by this factory are trusted by the system.
interface IStaking {
    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a new pool is created
    /// @param creator Address that called createPool
    /// @param pool Address of the new StakePool
    /// @param owner Address set as the pool owner
    /// @param staker Address set as the pool staker
    /// @param poolIndex Index of the pool in the registry
    event PoolCreated(
        address indexed creator, address indexed pool, address indexed owner, address staker, uint256 poolIndex
    );

    // ========================================================================
    // VIEW FUNCTIONS - Pool Registry
    // ========================================================================

    /// @notice Check if an address is a valid pool created by this factory
    /// @dev SECURITY CRITICAL: Only pools created by this factory should be trusted
    /// @param pool Address to check
    /// @return True if the address is a valid pool created by this factory
    function isPool(
        address pool
    ) external view returns (bool);

    /// @notice Get pool address by index
    /// @param index Pool index (0-based)
    /// @return Pool address
    function getPool(
        uint256 index
    ) external view returns (address);

    /// @notice Get all pool addresses
    /// @return Array of all pool addresses
    function getAllPools() external view returns (address[] memory);

    /// @notice Get total number of pools created
    /// @return Number of pools
    function getPoolCount() external view returns (uint256);

    /// @notice Get the current pool nonce (next nonce to be used)
    /// @return Current nonce value
    function getPoolNonce() external view returns (uint256);

    /// @notice Get the minimum stake required to create a pool
    /// @return Minimum stake in wei
    function getMinimumStake() external view returns (uint256);

    // ========================================================================
    // VIEW FUNCTIONS - Pool Status Queries (for Validators)
    // ========================================================================

    /// @notice Get voting power of a specific pool
    /// @dev Reverts if pool is not valid. Returns 0 if pool's lockup has expired.
    /// @param pool Address of the pool
    /// @return Voting power in wei (stake if locked, 0 if unlocked)
    function getPoolVotingPower(
        address pool
    ) external view returns (uint256);

    /// @notice Get stake amount of a specific pool
    /// @dev Reverts if pool is not valid
    /// @param pool Address of the pool
    /// @return Stake amount in wei
    function getPoolStake(
        address pool
    ) external view returns (uint256);

    /// @notice Get owner of a specific pool
    /// @dev Reverts if pool is not valid
    /// @param pool Address of the pool
    /// @return Owner address
    function getPoolOwner(
        address pool
    ) external view returns (address);

    /// @notice Get staker of a specific pool
    /// @dev Reverts if pool is not valid
    /// @param pool Address of the pool
    /// @return Staker address
    function getPoolStaker(
        address pool
    ) external view returns (address);

    /// @notice Get delegated voter of a specific pool
    /// @dev Reverts if pool is not valid
    /// @param pool Address of the pool
    /// @return Voter address
    function getPoolVoter(
        address pool
    ) external view returns (address);

    /// @notice Get operator of a specific pool
    /// @dev Reverts if pool is not valid
    /// @param pool Address of the pool
    /// @return Operator address
    function getPoolOperator(
        address pool
    ) external view returns (address);

    /// @notice Get lockup expiration of a specific pool
    /// @dev Reverts if pool is not valid
    /// @param pool Address of the pool
    /// @return Lockup expiration timestamp in microseconds
    function getPoolLockedUntil(
        address pool
    ) external view returns (uint64);

    /// @notice Check if a specific pool's stake is locked
    /// @dev Reverts if pool is not valid
    /// @param pool Address of the pool
    /// @return True if pool's stake is locked (lockedUntil > now)
    function isPoolLocked(
        address pool
    ) external view returns (bool);

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /// @notice Create a new StakePool with all parameters specified
    /// @dev Anyone can create multiple pools. msg.value becomes initial stake.
    ///      Reverts if msg.value < minimumStake or if lockedUntil is invalid.
    /// @param owner Address to set as pool owner (administrative control)
    /// @param staker Address to set as pool staker (fund management)
    /// @param operator Address to set as pool operator (validator operations)
    /// @param voter Address to set as pool voter (governance voting)
    /// @param lockedUntil Initial lockup expiration timestamp (must be >= now + minLockup)
    /// @return pool Address of the newly created pool
    function createPool(
        address owner,
        address staker,
        address operator,
        address voter,
        uint64 lockedUntil
    ) external payable returns (address pool);

    // ========================================================================
    // SYSTEM FUNCTIONS
    // ========================================================================

    /// @notice Renew lockup for an active validator's stake pool
    /// @dev Only callable by VALIDATOR_MANAGER during epoch transitions.
    ///      Implements Aptos-style auto-renewal for active validators.
    ///      Sets pool's lockedUntil = now + lockupDurationMicros.
    /// @param pool Address of the pool to renew
    function renewPoolLockup(
        address pool
    ) external;
}

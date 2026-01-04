// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IStaking } from "./IStaking.sol";
import { IStakePool } from "./IStakePool.sol";
import { StakePool } from "./StakePool.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";
import { IStakingConfig } from "../runtime/IStakingConfig.sol";

/// @title Staking
/// @author Gravity Team
/// @notice Factory contract that creates individual StakePool contracts via CREATE2
/// @dev Anyone can create a pool. Each pool is deployed with a deterministic address.
///      Only pools created by this factory are trusted by the system.
contract Staking is IStaking {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Array of all StakePool addresses
    address[] internal _allPools;

    /// @notice Mapping to check if an address is a valid pool created by this factory
    /// @dev SECURITY CRITICAL: Only pools in this mapping should be trusted
    mapping(address => bool) internal _isPool;

    /// @notice Counter for CREATE2 salt (increments with each pool created)
    uint256 public poolNonce;

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /// @notice Ensures the address is a valid pool created by this factory
    modifier onlyValidPool(
        address pool
    ) {
        if (!_isPool[pool]) {
            revert Errors.InvalidPool(pool);
        }
        _;
    }

    // ========================================================================
    // VIEW FUNCTIONS - Pool Registry
    // ========================================================================

    /// @inheritdoc IStaking
    function isPool(
        address pool
    ) external view returns (bool) {
        return _isPool[pool];
    }

    /// @inheritdoc IStaking
    function getPool(
        uint256 index
    ) external view returns (address) {
        if (index >= _allPools.length) {
            revert Errors.PoolIndexOutOfBounds(index, _allPools.length);
        }
        return _allPools[index];
    }

    /// @inheritdoc IStaking
    function getAllPools() external view returns (address[] memory) {
        return _allPools;
    }

    /// @inheritdoc IStaking
    function getPoolCount() external view returns (uint256) {
        return _allPools.length;
    }

    /// @inheritdoc IStaking
    function getPoolNonce() external view returns (uint256) {
        return poolNonce;
    }

    /// @inheritdoc IStaking
    function getMinimumStake() external view returns (uint256) {
        return IStakingConfig(SystemAddresses.STAKE_CONFIG).minimumStake();
    }

    // ========================================================================
    // VIEW FUNCTIONS - Pool Status Queries (for Validators)
    // ========================================================================

    /// @inheritdoc IStaking
    function getPoolVotingPower(
        address pool,
        uint64 atTime
    ) external view onlyValidPool(pool) returns (uint256) {
        return IStakePool(pool).getVotingPower(atTime);
    }

    /// @inheritdoc IStaking
    function getPoolVotingPowerNow(
        address pool
    ) external view onlyValidPool(pool) returns (uint256) {
        return IStakePool(pool).getVotingPowerNow();
    }

    /// @inheritdoc IStaking
    function getPoolEffectiveStake(
        address pool,
        uint64 atTime
    ) external view onlyValidPool(pool) returns (uint256) {
        return IStakePool(pool).getEffectiveStake(atTime);
    }

    /// @inheritdoc IStaking
    function getPoolStake(
        address pool
    ) external view onlyValidPool(pool) returns (uint256) {
        return IStakePool(pool).getStake();
    }

    /// @inheritdoc IStaking
    function getPoolOwner(
        address pool
    ) external view onlyValidPool(pool) returns (address) {
        // StakePool inherits Ownable2Step which has owner() from Ownable
        return Ownable(pool).owner();
    }

    /// @inheritdoc IStaking
    function getPoolStaker(
        address pool
    ) external view onlyValidPool(pool) returns (address) {
        return IStakePool(pool).getStaker();
    }

    /// @inheritdoc IStaking
    function getPoolVoter(
        address pool
    ) external view onlyValidPool(pool) returns (address) {
        return IStakePool(pool).getVoter();
    }

    /// @inheritdoc IStaking
    function getPoolOperator(
        address pool
    ) external view onlyValidPool(pool) returns (address) {
        return IStakePool(pool).getOperator();
    }

    /// @inheritdoc IStaking
    function getPoolLockedUntil(
        address pool
    ) external view onlyValidPool(pool) returns (uint64) {
        return IStakePool(pool).getLockedUntil();
    }

    /// @inheritdoc IStaking
    function isPoolLocked(
        address pool
    ) external view onlyValidPool(pool) returns (bool) {
        return IStakePool(pool).isLocked();
    }

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStaking
    function createPool(
        address owner,
        address staker,
        address operator,
        address voter,
        uint64 lockedUntil
    ) external payable returns (address pool) {
        // Check minimum stake
        uint256 minStake = IStakingConfig(SystemAddresses.STAKE_CONFIG).minimumStake();
        if (msg.value < minStake) {
            revert Errors.InsufficientStakeForPoolCreation(msg.value, minStake);
        }

        // Increment nonce and use as salt
        uint256 nonce = poolNonce++;
        bytes32 salt = bytes32(nonce);

        // Deploy StakePool via CREATE2 with initial stake and all parameters
        pool = address(new StakePool{ salt: salt, value: msg.value }(owner, staker, operator, voter, lockedUntil));

        // Register pool in both array and mapping
        _allPools.push(pool);
        _isPool[pool] = true;

        emit PoolCreated(msg.sender, pool, owner, staker, _allPools.length - 1);
    }

    // ========================================================================
    // SYSTEM FUNCTIONS
    // ========================================================================

    /// @inheritdoc IStaking
    function renewPoolLockup(
        address pool
    ) external onlyValidPool(pool) {
        requireAllowed(SystemAddresses.VALIDATOR_MANAGER);

        // Call the pool's system renewal function
        IStakePool(pool).systemRenewLockup();
    }
}

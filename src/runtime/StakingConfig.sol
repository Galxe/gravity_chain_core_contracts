// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title StakingConfig
/// @author Gravity Team
/// @notice Configuration parameters for governance staking
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      Uses pending config pattern: changes are queued and applied at epoch boundaries.
contract StakingConfig {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum lockup duration: 4 years in microseconds
    uint64 public constant MAX_LOCKUP_DURATION = uint64(4 * 365 days) * 1_000_000;

    /// @notice Maximum unbonding delay: 1 year in microseconds
    uint64 public constant MAX_UNBONDING_DELAY = uint64(365 days) * 1_000_000;

    // ========================================================================
    // TYPES
    // ========================================================================

    /// @notice Pending configuration data structure
    struct PendingConfig {
        uint256 minimumStake;
        uint64 lockupDurationMicros;
        uint64 unbondingDelayMicros;
        /// @dev DEPRECATED: kept as storage gap to preserve slot layout for hardfork compatibility.
        uint256 __deprecated_minimumProposalStake;
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Minimum stake amount for governance participation
    uint256 public minimumStake;

    /// @notice Lockup duration in microseconds
    uint64 public lockupDurationMicros;

    /// @notice Unbonding delay in microseconds (additional wait after lockedUntil before withdrawal)
    uint64 public unbondingDelayMicros;

    /// @notice DEPRECATED: kept as storage gap to preserve slot layout for hardfork compatibility.
    /// @dev Was `minimumProposalStake` in v1.2.0; removed functionally but retained to avoid
    ///      shifting subsequent storage slots (_initialized, _pendingConfig, hasPendingConfig).
    uint256 private __deprecated_minimumProposalStake;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    /// @notice Pending configuration for next epoch
    PendingConfig private _pendingConfig;

    /// @notice Whether a pending configuration exists
    bool public hasPendingConfig;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when configuration is applied at epoch boundary
    event StakingConfigUpdated();

    /// @notice Emitted when pending configuration is set by governance
    event PendingStakingConfigSet();

    /// @notice Emitted when pending configuration is cleared (applied or removed)
    event PendingStakingConfigCleared();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the staking configuration
    /// @dev Can only be called once by GENESIS
    /// @param _minimumStake Minimum stake for governance participation (must be > 0)
    /// @param _lockupDurationMicros Lockup duration in microseconds (must be > 0)
    /// @param _unbondingDelayMicros Unbonding delay in microseconds (must be > 0)
    function initialize(
        uint256 _minimumStake,
        uint64 _lockupDurationMicros,
        uint64 _unbondingDelayMicros
    ) external {
        requireAllowed(SystemAddresses.GENESIS);
        if (_initialized) revert Errors.AlreadyInitialized();
        _validateConfig(_minimumStake, _lockupDurationMicros, _unbondingDelayMicros);

        minimumStake = _minimumStake;
        lockupDurationMicros = _lockupDurationMicros;
        unbondingDelayMicros = _unbondingDelayMicros;
        _initialized = true;

        emit StakingConfigUpdated();
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get pending configuration if any
    /// @return hasPending Whether a pending config exists
    /// @return config The pending configuration (only valid if hasPending is true)
    function getPendingConfig() external view returns (bool hasPending, PendingConfig memory config) {
        _requireInitialized();
        return (hasPendingConfig, _pendingConfig);
    }

    /// @notice Check if the contract has been initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    // ========================================================================
    // GOVERNANCE FUNCTIONS (GOVERNANCE only)
    // ========================================================================

    /// @notice Set configuration for next epoch
    /// @dev Only callable by GOVERNANCE. Config will be applied at epoch boundary.
    /// @param _minimumStake Minimum stake for governance participation (must be > 0)
    /// @param _lockupDurationMicros Lockup duration in microseconds (must be > 0)
    /// @param _unbondingDelayMicros Unbonding delay in microseconds (must be > 0)
    function setForNextEpoch(
        uint256 _minimumStake,
        uint64 _lockupDurationMicros,
        uint64 _unbondingDelayMicros
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();
        _validateConfig(_minimumStake, _lockupDurationMicros, _unbondingDelayMicros);

        _pendingConfig = PendingConfig({
            minimumStake: _minimumStake,
            lockupDurationMicros: _lockupDurationMicros,
            unbondingDelayMicros: _unbondingDelayMicros,
            __deprecated_minimumProposalStake: 0
        });
        hasPendingConfig = true;
        emit PendingStakingConfigSet();
    }

    /// @notice Set only the minimum stake for next epoch; other fields keep
    ///         their current-or-pending values.
    /// @dev Convenience wrapper so a governance proposal can change one
    ///      parameter at a time. If a pending config already exists, that
    ///      pending config's other fields are preserved and only the
    ///      minimumStake is overwritten.
    function setMinimumStakeForNextEpoch(
        uint256 _minimumStake
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();
        (uint64 lockup, uint64 unbonding) = _otherPendingOrCurrent();
        _validateConfig(_minimumStake, lockup, unbonding);
        _pendingConfig = PendingConfig({
            minimumStake: _minimumStake,
            lockupDurationMicros: lockup,
            unbondingDelayMicros: unbonding,
            __deprecated_minimumProposalStake: 0
        });
        hasPendingConfig = true;
        emit PendingStakingConfigSet();
    }

    /// @notice Set only the lockup duration for next epoch; other fields keep
    ///         their current-or-pending values.
    function setLockupDurationForNextEpoch(
        uint64 _lockupDurationMicros
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();
        uint256 minStake = hasPendingConfig ? _pendingConfig.minimumStake : minimumStake;
        uint64 unbonding = hasPendingConfig ? _pendingConfig.unbondingDelayMicros : unbondingDelayMicros;
        _validateConfig(minStake, _lockupDurationMicros, unbonding);
        _pendingConfig = PendingConfig({
            minimumStake: minStake,
            lockupDurationMicros: _lockupDurationMicros,
            unbondingDelayMicros: unbonding,
            __deprecated_minimumProposalStake: 0
        });
        hasPendingConfig = true;
        emit PendingStakingConfigSet();
    }

    /// @notice Set only the unbonding delay for next epoch; other fields keep
    ///         their current-or-pending values.
    function setUnbondingDelayForNextEpoch(
        uint64 _unbondingDelayMicros
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();
        uint256 minStake = hasPendingConfig ? _pendingConfig.minimumStake : minimumStake;
        uint64 lockup = hasPendingConfig ? _pendingConfig.lockupDurationMicros : lockupDurationMicros;
        _validateConfig(minStake, lockup, _unbondingDelayMicros);
        _pendingConfig = PendingConfig({
            minimumStake: minStake,
            lockupDurationMicros: lockup,
            unbondingDelayMicros: _unbondingDelayMicros,
            __deprecated_minimumProposalStake: 0
        });
        hasPendingConfig = true;
        emit PendingStakingConfigSet();
    }

    /// @notice Read the fields other than minimumStake, preferring pending if set
    function _otherPendingOrCurrent() internal view returns (uint64 lockup, uint64 unbonding) {
        if (hasPendingConfig) {
            return (_pendingConfig.lockupDurationMicros, _pendingConfig.unbondingDelayMicros);
        }
        return (lockupDurationMicros, unbondingDelayMicros);
    }

    // ========================================================================
    // EPOCH TRANSITION (RECONFIGURATION only)
    // ========================================================================

    /// @notice Apply pending configuration at epoch boundary
    /// @dev Only callable by RECONFIGURATION during epoch transition.
    ///      If no pending config exists, this is a no-op.
    function applyPendingConfig() external {
        requireAllowed(SystemAddresses.RECONFIGURATION);
        _requireInitialized();
        if (!hasPendingConfig) return;

        minimumStake = _pendingConfig.minimumStake;
        lockupDurationMicros = _pendingConfig.lockupDurationMicros;
        unbondingDelayMicros = _pendingConfig.unbondingDelayMicros;
        hasPendingConfig = false;

        // Clear pending config storage
        delete _pendingConfig;

        emit StakingConfigUpdated();
        emit PendingStakingConfigCleared();
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Validate configuration parameters
    /// @param _minimumStake Minimum stake
    /// @param _lockupDurationMicros Lockup duration
    /// @param _unbondingDelayMicros Unbonding delay
    function _validateConfig(
        uint256 _minimumStake,
        uint64 _lockupDurationMicros,
        uint64 _unbondingDelayMicros
    ) internal pure {
        if (_minimumStake == 0) revert Errors.InvalidMinimumStake();
        if (_lockupDurationMicros == 0) revert Errors.InvalidLockupDuration();
        if (_lockupDurationMicros > MAX_LOCKUP_DURATION) {
            revert Errors.ExcessiveDuration(_lockupDurationMicros, MAX_LOCKUP_DURATION);
        }
        if (_unbondingDelayMicros == 0) revert Errors.InvalidUnbondingDelay();
        if (_unbondingDelayMicros > MAX_UNBONDING_DELAY) {
            revert Errors.ExcessiveDuration(_unbondingDelayMicros, MAX_UNBONDING_DELAY);
        }
    }

    /// @notice Require the contract to be initialized
    function _requireInitialized() internal view {
        if (!_initialized) revert Errors.StakingConfigNotInitialized();
    }
}

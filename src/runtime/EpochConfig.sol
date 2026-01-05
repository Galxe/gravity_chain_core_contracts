// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title EpochConfig
/// @author Gravity Team
/// @notice Configuration parameters for epoch timing
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      Uses pending config pattern: changes are queued and applied at epoch boundaries.
///      The epoch interval determines how long each epoch lasts.
contract EpochConfig {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Epoch duration in microseconds
    /// @dev Must be > 0. Determines how often epoch transitions occur.
    uint64 public epochIntervalMicros;

    /// @notice Pending epoch interval for next epoch
    uint64 private _pendingEpochIntervalMicros;

    /// @notice Whether a pending configuration exists
    bool public hasPendingConfig;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when the epoch interval is updated at epoch boundary
    /// @param oldValue Previous epoch interval (microseconds)
    /// @param newValue New epoch interval (microseconds)
    event EpochIntervalUpdated(uint64 oldValue, uint64 newValue);

    /// @notice Emitted when pending epoch interval is set by governance
    /// @param pendingInterval The interval to be applied at next epoch
    event PendingEpochIntervalSet(uint64 pendingInterval);

    /// @notice Emitted when pending configuration is cleared (applied or removed)
    event PendingEpochConfigCleared();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the epoch configuration
    /// @dev Can only be called once by GENESIS
    /// @param _epochIntervalMicros Epoch duration in microseconds (must be > 0)
    function initialize(
        uint64 _epochIntervalMicros
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.EpochConfigAlreadyInitialized();
        }

        if (_epochIntervalMicros == 0) {
            revert Errors.InvalidEpochInterval();
        }

        epochIntervalMicros = _epochIntervalMicros;
        _initialized = true;

        emit EpochIntervalUpdated(0, _epochIntervalMicros);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Check if the contract has been initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    /// @notice Get pending configuration if any
    /// @return hasPending Whether a pending config exists
    /// @return pendingInterval The pending epoch interval (only valid if hasPending is true)
    function getPendingConfig() external view returns (bool hasPending, uint64 pendingInterval) {
        _requireInitialized();
        return (hasPendingConfig, _pendingEpochIntervalMicros);
    }

    // ========================================================================
    // GOVERNANCE FUNCTIONS (GOVERNANCE only)
    // ========================================================================

    /// @notice Set epoch interval for next epoch
    /// @dev Only callable by GOVERNANCE. Config will be applied at epoch boundary.
    /// @param _epochIntervalMicros New epoch interval in microseconds (must be > 0)
    function setForNextEpoch(
        uint64 _epochIntervalMicros
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();

        if (_epochIntervalMicros == 0) {
            revert Errors.InvalidEpochInterval();
        }

        _pendingEpochIntervalMicros = _epochIntervalMicros;
        hasPendingConfig = true;

        emit PendingEpochIntervalSet(_epochIntervalMicros);
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

        if (!hasPendingConfig) {
            // No pending config, nothing to apply
            return;
        }

        uint64 oldValue = epochIntervalMicros;
        epochIntervalMicros = _pendingEpochIntervalMicros;
        hasPendingConfig = false;
        _pendingEpochIntervalMicros = 0;

        emit EpochIntervalUpdated(oldValue, epochIntervalMicros);
        emit PendingEpochConfigCleared();
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Require the contract to be initialized
    function _requireInitialized() internal view {
        if (!_initialized) {
            revert Errors.EpochConfigNotInitialized();
        }
    }
}

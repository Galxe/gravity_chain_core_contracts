// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title VersionConfig
/// @author Gravity Team
/// @notice Configuration for protocol versioning
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      Uses pending config pattern: changes are queued and applied at epoch boundaries.
///      The major version must always increase (never decrease).
///      Used to gate new features and coordinate upgrades.
contract VersionConfig {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Major protocol version number
    /// @dev Must only increase, never decrease
    uint64 public majorVersion;

    /// @notice Pending major version for next epoch
    uint64 private _pendingMajorVersion;

    /// @notice Whether a pending configuration exists
    bool public hasPendingConfig;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when the major version is updated at epoch boundary
    /// @param oldVersion Previous version number
    /// @param newVersion New version number
    event VersionUpdated(uint64 oldVersion, uint64 newVersion);

    /// @notice Emitted when pending version is set by governance
    /// @param pendingVersion The version to be applied at next epoch
    event PendingVersionSet(uint64 pendingVersion);

    /// @notice Emitted when pending configuration is cleared (applied or removed)
    event PendingVersionCleared();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the version configuration
    /// @dev Can only be called once by GENESIS
    /// @param _majorVersion Initial major version number
    function initialize(
        uint64 _majorVersion
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.VersionAlreadyInitialized();
        }

        majorVersion = _majorVersion;
        _initialized = true;

        emit VersionUpdated(0, _majorVersion);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Check if the contract has been initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    /// @notice Get pending version if any
    /// @return hasPending Whether a pending version exists
    /// @return pendingVersion The pending version (only valid if hasPending is true)
    function getPendingConfig() external view returns (bool hasPending, uint64 pendingVersion) {
        _requireInitialized();
        return (hasPendingConfig, _pendingMajorVersion);
    }

    // ========================================================================
    // GOVERNANCE FUNCTIONS (GOVERNANCE only)
    // ========================================================================

    /// @notice Set major version for next epoch
    /// @dev Only callable by GOVERNANCE. Config will be applied at epoch boundary.
    ///      Version must be strictly greater than current version.
    /// @param _majorVersion New major version number (must be > current)
    function setForNextEpoch(
        uint64 _majorVersion
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();

        // Version must be greater than current (monotonic increase)
        if (_majorVersion <= majorVersion) {
            revert Errors.VersionMustIncrease(majorVersion, _majorVersion);
        }

        _pendingMajorVersion = _majorVersion;
        hasPendingConfig = true;

        emit PendingVersionSet(_majorVersion);
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

        uint64 oldVersion = majorVersion;
        majorVersion = _pendingMajorVersion;
        hasPendingConfig = false;
        _pendingMajorVersion = 0;

        emit VersionUpdated(oldVersion, majorVersion);
        emit PendingVersionCleared();
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Require the contract to be initialized
    function _requireInitialized() internal view {
        if (!_initialized) {
            revert Errors.VersionNotInitialized();
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title VersionConfig
/// @author Gravity Team
/// @notice Configuration for protocol versioning
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      The major version must always increase (never decrease).
///      Used to gate new features and coordinate upgrades.
contract VersionConfig {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Major protocol version number
    /// @dev Must only increase, never decrease
    uint64 public majorVersion;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when the major version is updated
    /// @param oldVersion Previous version number
    /// @param newVersion New version number
    event VersionUpdated(uint64 oldVersion, uint64 newVersion);

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

    // ========================================================================
    // GOVERNANCE SETTERS (GOVERNANCE only)
    // ========================================================================

    /// @notice Update major version
    /// @dev Only callable by GOVERNANCE. Version must be strictly greater than current.
    /// @param _majorVersion New major version number (must be > current)
    function setMajorVersion(
        uint64 _majorVersion
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();

        if (_majorVersion <= majorVersion) {
            revert Errors.VersionMustIncrease(majorVersion, _majorVersion);
        }

        uint64 oldVersion = majorVersion;
        majorVersion = _majorVersion;

        emit VersionUpdated(oldVersion, _majorVersion);
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


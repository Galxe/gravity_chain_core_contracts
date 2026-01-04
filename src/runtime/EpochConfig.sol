// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title EpochConfig
/// @author Gravity Team
/// @notice Configuration parameters for epoch timing
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      The epoch interval determines how long each epoch lasts.
contract EpochConfig {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Epoch duration in microseconds
    /// @dev Must be > 0. Determines how often epoch transitions occur.
    uint64 public epochIntervalMicros;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when the epoch interval is updated
    /// @param oldValue Previous epoch interval (microseconds)
    /// @param newValue New epoch interval (microseconds)
    event EpochIntervalUpdated(uint64 oldValue, uint64 newValue);

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

    // ========================================================================
    // GOVERNANCE SETTERS (GOVERNANCE only)
    // ========================================================================

    /// @notice Update epoch interval
    /// @dev Only callable by GOVERNANCE
    /// @param _epochIntervalMicros New epoch interval in microseconds (must be > 0)
    function setEpochIntervalMicros(
        uint64 _epochIntervalMicros
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();

        if (_epochIntervalMicros == 0) {
            revert Errors.InvalidEpochInterval();
        }

        uint64 oldValue = epochIntervalMicros;
        epochIntervalMicros = _epochIntervalMicros;

        emit EpochIntervalUpdated(oldValue, _epochIntervalMicros);
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


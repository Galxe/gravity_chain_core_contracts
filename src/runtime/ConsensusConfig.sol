// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title ConsensusConfig
/// @author Gravity Team
/// @notice Configuration parameters for consensus
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      Uses pending config pattern: changes are queued and applied at epoch boundaries.
///      The config is stored as opaque bytes (BCS-serialized), interpreted off-chain by nodes.
contract ConsensusConfig {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Current active configuration (BCS-serialized bytes)
    bytes private _currentConfig;

    /// @notice Pending configuration for next epoch
    bytes private _pendingConfig;

    /// @notice Whether a pending configuration exists
    bool public hasPendingConfig;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when configuration is applied at epoch boundary
    /// @param configHash Hash of the new configuration
    event ConsensusConfigUpdated(bytes32 indexed configHash);

    /// @notice Emitted when pending configuration is set by governance
    /// @param configHash Hash of the pending configuration
    event PendingConsensusConfigSet(bytes32 indexed configHash);

    /// @notice Emitted when pending configuration is cleared (applied or removed)
    event PendingConsensusConfigCleared();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the consensus configuration
    /// @dev Can only be called once by GENESIS
    /// @param config Initial configuration (BCS-serialized bytes)
    function initialize(
        bytes calldata config
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.ConsensusConfigAlreadyInitialized();
        }

        if (config.length == 0) {
            revert Errors.EmptyConfig();
        }

        _currentConfig = config;
        _initialized = true;

        emit ConsensusConfigUpdated(keccak256(config));
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get current active configuration
    /// @return Current configuration bytes
    function getCurrentConfig() external view returns (bytes memory) {
        _requireInitialized();
        return _currentConfig;
    }

    /// @notice Get pending configuration if any
    /// @return hasPending Whether a pending config exists
    /// @return config The pending configuration (only valid if hasPending is true)
    function getPendingConfig() external view returns (bool hasPending, bytes memory config) {
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
    /// @param newConfig New configuration to apply at next epoch
    function setForNextEpoch(
        bytes calldata newConfig
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();

        if (newConfig.length == 0) {
            revert Errors.EmptyConfig();
        }

        _pendingConfig = newConfig;
        hasPendingConfig = true;

        emit PendingConsensusConfigSet(keccak256(newConfig));
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

        _currentConfig = _pendingConfig;
        hasPendingConfig = false;

        // Clear pending config storage
        delete _pendingConfig;

        emit ConsensusConfigUpdated(keccak256(_currentConfig));
        emit PendingConsensusConfigCleared();
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Require the contract to be initialized
    function _requireInitialized() internal view {
        if (!_initialized) {
            revert Errors.ConsensusConfigNotInitialized();
        }
    }
}


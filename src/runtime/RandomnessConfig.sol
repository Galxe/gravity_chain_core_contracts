// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SystemAddresses} from "../foundation/SystemAddresses.sol";
import {requireAllowed} from "../foundation/SystemAccessControl.sol";
import {Errors} from "../foundation/Errors.sol";

/// @title RandomnessConfig
/// @author Gravity Team
/// @notice Configuration parameters for on-chain randomness (DKG thresholds)
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      Uses pending config pattern: changes are queued and applied at epoch boundaries.
///      Threshold values use fixed-point representation (value / 2^64).
contract RandomnessConfig {
    // ========================================================================
    // TYPES
    // ========================================================================

    /// @notice Configuration variant enum
    /// @dev Off = randomness disabled, V2 = enabled with thresholds
    enum ConfigVariant {
        Off,
        V2
    }

    /// @notice V2 configuration data with DKG thresholds
    /// @dev All thresholds are fixed-point values (value / 2^64)
    ///      representing stake ratios (e.g., 0.5 = 2^63)
    struct ConfigV2Data {
        /// @notice Minimum stake ratio to keep randomness secret
        /// @dev Any subset with power/total <= this cannot reconstruct
        /// @dev Uses fixed-point representation (value / 2^64), stored as uint128
        uint128 secrecyThreshold;
        /// @notice Minimum stake ratio to reveal randomness
        /// @dev Any subset with power/total > this can reconstruct
        uint128 reconstructionThreshold;
        /// @notice Threshold for optimistic fast path execution
        uint128 fastPathSecrecyThreshold;
    }

    /// @notice Complete randomness configuration
    struct RandomnessConfigData {
        /// @notice Configuration variant (Off or V2)
        ConfigVariant variant;
        /// @notice V2 configuration data (only valid when variant == V2)
        ConfigV2Data configV2;
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Current active configuration
    RandomnessConfigData private _currentConfig;

    /// @notice Pending configuration for next epoch
    RandomnessConfigData private _pendingConfig;

    /// @notice Whether a pending configuration exists
    bool public hasPendingConfig;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when configuration is applied at epoch boundary
    /// @param oldVariant Previous configuration variant
    /// @param newVariant New configuration variant
    event RandomnessConfigUpdated(
        ConfigVariant indexed oldVariant,
        ConfigVariant indexed newVariant
    );

    /// @notice Emitted when pending configuration is set by governance
    /// @param variant The pending configuration variant
    event PendingRandomnessConfigSet(ConfigVariant indexed variant);

    /// @notice Emitted when pending configuration is cleared (applied or removed)
    event PendingRandomnessConfigCleared();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the randomness configuration
    /// @dev Can only be called once by GENESIS
    /// @param config Initial configuration
    function initialize(RandomnessConfigData calldata config) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.RandomnessAlreadyInitialized();
        }

        _validateConfig(config);

        _currentConfig = config;
        _initialized = true;

        emit RandomnessConfigUpdated(ConfigVariant.Off, config.variant);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Check if randomness is enabled
    /// @return True if variant is not Off
    function enabled() external view returns (bool) {
        _requireInitialized();
        return _currentConfig.variant != ConfigVariant.Off;
    }

    /// @notice Get current active configuration
    /// @return Current configuration data
    function getCurrentConfig()
        external
        view
        returns (RandomnessConfigData memory)
    {
        _requireInitialized();
        return _currentConfig;
    }

    /// @notice Get pending configuration if any
    /// @return hasPending Whether a pending config exists
    /// @return config The pending configuration (only valid if hasPending is true)
    function getPendingConfig()
        external
        view
        returns (bool hasPending, RandomnessConfigData memory config)
    {
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
    function setForNextEpoch(RandomnessConfigData calldata newConfig) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();

        _validateConfig(newConfig);

        _pendingConfig = newConfig;
        hasPendingConfig = true;

        emit PendingRandomnessConfigSet(newConfig.variant);
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

        ConfigVariant oldVariant = _currentConfig.variant;
        _currentConfig = _pendingConfig;
        hasPendingConfig = false;

        // Clear pending config storage
        delete _pendingConfig;

        emit RandomnessConfigUpdated(oldVariant, _currentConfig.variant);
        emit PendingRandomnessConfigCleared();
    }

    // ========================================================================
    // CONFIG BUILDERS (Pure Functions)
    // ========================================================================

    /// @notice Create an Off configuration (randomness disabled)
    /// @return Configuration with Off variant
    function newOff() external pure returns (RandomnessConfigData memory) {
        return
            RandomnessConfigData({
                variant: ConfigVariant.Off,
                configV2: ConfigV2Data(0, 0, 0)
            });
    }

    /// @notice Create a V2 configuration with thresholds
    /// @param secrecyThreshold Minimum stake ratio to keep secret (fixed-point)
    /// @param reconstructionThreshold Minimum stake ratio to reveal (fixed-point)
    /// @param fastPathSecrecyThreshold Threshold for fast path (fixed-point)
    /// @return Configuration with V2 variant
    function newV2(
        uint128 secrecyThreshold,
        uint128 reconstructionThreshold,
        uint128 fastPathSecrecyThreshold
    ) external pure returns (RandomnessConfigData memory) {
        return
            RandomnessConfigData({
                variant: ConfigVariant.V2,
                configV2: ConfigV2Data({
                    secrecyThreshold: secrecyThreshold,
                    reconstructionThreshold: reconstructionThreshold,
                    fastPathSecrecyThreshold: fastPathSecrecyThreshold
                })
            });
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Validate configuration data
    /// @param config Configuration to validate
    function _validateConfig(
        RandomnessConfigData calldata config
    ) internal pure {
        if (config.variant == ConfigVariant.V2) {
            // For V2, reconstruction threshold must be >= secrecy threshold
            if (
                config.configV2.reconstructionThreshold <
                config.configV2.secrecyThreshold
            ) {
                revert Errors.InvalidRandomnessConfig(
                    "reconstruction must be >= secrecy"
                );
            }
        }
        // ConfigVariant.Off requires no validation
    }

    /// @notice Require the contract to be initialized
    function _requireInitialized() internal view {
        if (!_initialized) {
            revert Errors.RandomnessNotInitialized();
        }
    }
}

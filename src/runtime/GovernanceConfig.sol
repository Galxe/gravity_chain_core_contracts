// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title GovernanceConfig
/// @author Gravity Team
/// @notice Configuration parameters for on-chain governance
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      Uses pending config pattern: changes are queued and applied at epoch boundaries.
contract GovernanceConfig {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum allowed early resolution threshold (100% = 10000 basis points)
    uint128 public constant MAX_EARLY_RESOLUTION_THRESHOLD_BPS = 10000;

    // ========================================================================
    // TYPES
    // ========================================================================

    /// @notice Pending configuration data structure
    struct PendingConfig {
        uint128 minVotingThreshold;
        uint256 requiredProposerStake;
        uint64 votingDurationMicros;
        uint128 earlyResolutionThresholdBps;
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Minimum total votes (yes + no) required for quorum
    uint128 public minVotingThreshold;

    /// @notice Minimum voting power required to create a proposal
    uint256 public requiredProposerStake;

    /// @notice Duration of voting period in microseconds
    uint64 public votingDurationMicros;

    /// @notice Threshold for early resolution (basis points, e.g., 5000 = 50%)
    /// @dev If yes or no votes exceed this % of total staked, proposal can resolve early
    uint128 public earlyResolutionThresholdBps;

    /// @notice Pending configuration for next epoch
    PendingConfig private _pendingConfig;

    /// @notice Whether a pending configuration exists
    bool public hasPendingConfig;

    /// @notice Whether contract has been initialized
    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when configuration is applied at epoch boundary
    event GovernanceConfigUpdated();

    /// @notice Emitted when pending configuration is set by governance
    event PendingGovernanceConfigSet();

    /// @notice Emitted when pending configuration is cleared (applied or removed)
    event PendingGovernanceConfigCleared();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the governance configuration
    /// @dev Can only be called once by GENESIS
    /// @param _minVotingThreshold Minimum votes for quorum
    /// @param _requiredProposerStake Minimum stake to create proposal
    /// @param _votingDurationMicros Voting period duration in microseconds
    /// @param _earlyResolutionThresholdBps Early resolution threshold in basis points
    function initialize(
        uint128 _minVotingThreshold,
        uint256 _requiredProposerStake,
        uint64 _votingDurationMicros,
        uint128 _earlyResolutionThresholdBps
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        // Validate parameters
        _validateConfig(_votingDurationMicros, _earlyResolutionThresholdBps);

        minVotingThreshold = _minVotingThreshold;
        requiredProposerStake = _requiredProposerStake;
        votingDurationMicros = _votingDurationMicros;
        earlyResolutionThresholdBps = _earlyResolutionThresholdBps;

        _initialized = true;

        emit GovernanceConfigUpdated();
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
    /// @param _minVotingThreshold Minimum votes for quorum
    /// @param _requiredProposerStake Minimum stake to create proposal
    /// @param _votingDurationMicros Voting period duration in microseconds (must be > 0)
    /// @param _earlyResolutionThresholdBps Early resolution threshold in basis points (max 10000)
    function setForNextEpoch(
        uint128 _minVotingThreshold,
        uint256 _requiredProposerStake,
        uint64 _votingDurationMicros,
        uint128 _earlyResolutionThresholdBps
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();

        // Validate parameters
        _validateConfig(_votingDurationMicros, _earlyResolutionThresholdBps);

        _pendingConfig = PendingConfig({
            minVotingThreshold: _minVotingThreshold,
            requiredProposerStake: _requiredProposerStake,
            votingDurationMicros: _votingDurationMicros,
            earlyResolutionThresholdBps: _earlyResolutionThresholdBps
        });
        hasPendingConfig = true;

        emit PendingGovernanceConfigSet();
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

        minVotingThreshold = _pendingConfig.minVotingThreshold;
        requiredProposerStake = _pendingConfig.requiredProposerStake;
        votingDurationMicros = _pendingConfig.votingDurationMicros;
        earlyResolutionThresholdBps = _pendingConfig.earlyResolutionThresholdBps;

        hasPendingConfig = false;

        // Clear pending config storage
        delete _pendingConfig;

        emit GovernanceConfigUpdated();
        emit PendingGovernanceConfigCleared();
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Validate configuration parameters
    /// @param _votingDurationMicros Voting duration
    /// @param _earlyResolutionThresholdBps Early resolution threshold
    function _validateConfig(
        uint64 _votingDurationMicros,
        uint128 _earlyResolutionThresholdBps
    ) internal pure {
        if (_votingDurationMicros == 0) {
            revert Errors.InvalidVotingDuration();
        }

        if (_earlyResolutionThresholdBps > MAX_EARLY_RESOLUTION_THRESHOLD_BPS) {
            revert Errors.InvalidEarlyResolutionThreshold(_earlyResolutionThresholdBps);
        }
    }

    /// @notice Require the contract to be initialized
    function _requireInitialized() internal view {
        if (!_initialized) {
            revert Errors.GovernanceConfigNotInitialized();
        }
    }
}

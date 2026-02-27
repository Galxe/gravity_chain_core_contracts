// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title ValidatorConfig
/// @author Gravity Team
/// @notice Configuration parameters for validator registry
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      Uses pending config pattern: changes are queued and applied at epoch boundaries.
///      Controls validator bonding, set size limits, and join/leave rules.
contract ValidatorConfig {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum allowed voting power increase limit (50%)
    uint64 public constant MAX_VOTING_POWER_INCREASE_LIMIT = 50;

    /// @notice Maximum allowed validator set size
    uint256 public constant MAX_VALIDATOR_SET_SIZE = 65536;

    /// @notice Maximum unbonding delay: 1 year in microseconds
    uint64 public constant MAX_UNBONDING_DELAY = uint64(365 days) * 1_000_000;

    // ========================================================================
    // TYPES
    // ========================================================================

    /// @notice Pending configuration data structure
    struct PendingConfig {
        uint256 minimumBond;
        uint256 maximumBond;
        uint64 unbondingDelayMicros;
        bool allowValidatorSetChange;
        uint64 votingPowerIncreaseLimitPct;
        uint256 maxValidatorSetSize;
        bool autoEvictEnabled;
        uint256 autoEvictThreshold;
    }

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Minimum bond to join validator set
    uint256 public minimumBond;

    /// @notice Maximum bond per validator (caps voting power)
    uint256 public maximumBond;

    /// @notice Unbonding delay in microseconds
    uint64 public unbondingDelayMicros;

    /// @notice Whether validators can join/leave post-genesis
    bool public allowValidatorSetChange;

    /// @notice Max % of voting power that can join per epoch (1-50)
    uint64 public votingPowerIncreaseLimitPct;

    /// @notice Maximum number of validators in the set
    uint256 public maxValidatorSetSize;

    /// @notice Whether auto-eviction of underperforming validators is enabled
    bool public autoEvictEnabled;

    /// @notice Minimum successful proposals required to avoid auto-eviction
    /// @dev Validators with successfulProposals <= this threshold are evicted at epoch boundary.
    ///      Default 0 means only validators with zero successful proposals are evicted.
    uint256 public autoEvictThreshold;

    /// @notice Pending configuration for next epoch
    PendingConfig private _pendingConfig;

    /// @notice Whether a pending configuration exists
    bool public hasPendingConfig;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when configuration is applied at epoch boundary
    event ValidatorConfigUpdated();

    /// @notice Emitted when pending configuration is set by governance
    event PendingValidatorConfigSet();

    /// @notice Emitted when pending configuration is cleared (applied or removed)
    event PendingValidatorConfigCleared();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the validator configuration
    /// @dev Can only be called once by GENESIS
    /// @param _minimumBond Minimum bond to join validator set (must be > 0)
    /// @param _maximumBond Maximum bond per validator (must be >= minimumBond)
    /// @param _unbondingDelayMicros Unbonding delay in microseconds (must be > 0)
    /// @param _allowValidatorSetChange Whether validators can join/leave post-genesis
    /// @param _votingPowerIncreaseLimitPct Max % voting power join per epoch (1-50)
    /// @param _maxValidatorSetSize Max validators in set (1-65536)
    /// @param _autoEvictEnabled Whether auto-eviction is enabled at genesis
    /// @param _autoEvictThreshold Minimum successful proposals to avoid eviction
    function initialize(
        uint256 _minimumBond,
        uint256 _maximumBond,
        uint64 _unbondingDelayMicros,
        bool _allowValidatorSetChange,
        uint64 _votingPowerIncreaseLimitPct,
        uint256 _maxValidatorSetSize,
        bool _autoEvictEnabled,
        uint256 _autoEvictThreshold
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        // Validate parameters
        _validateConfig(
            _minimumBond, _maximumBond, _unbondingDelayMicros, _votingPowerIncreaseLimitPct, _maxValidatorSetSize
        );

        minimumBond = _minimumBond;
        maximumBond = _maximumBond;
        unbondingDelayMicros = _unbondingDelayMicros;
        allowValidatorSetChange = _allowValidatorSetChange;
        votingPowerIncreaseLimitPct = _votingPowerIncreaseLimitPct;
        maxValidatorSetSize = _maxValidatorSetSize;
        autoEvictEnabled = _autoEvictEnabled;
        autoEvictThreshold = _autoEvictThreshold;

        _initialized = true;

        emit ValidatorConfigUpdated();
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
    /// @param _minimumBond Minimum bond to join validator set (must be > 0)
    /// @param _maximumBond Maximum bond per validator (must be >= minimumBond)
    /// @param _unbondingDelayMicros Unbonding delay in microseconds (must be > 0)
    /// @param _allowValidatorSetChange Whether validators can join/leave post-genesis
    /// @param _votingPowerIncreaseLimitPct Max % voting power join per epoch (1-50)
    /// @param _maxValidatorSetSize Max validators in set (1-65536)
    /// @param _autoEvictEnabled Whether auto-eviction is enabled
    /// @param _autoEvictThreshold Minimum successful proposals to avoid eviction
    function setForNextEpoch(
        uint256 _minimumBond,
        uint256 _maximumBond,
        uint64 _unbondingDelayMicros,
        bool _allowValidatorSetChange,
        uint64 _votingPowerIncreaseLimitPct,
        uint256 _maxValidatorSetSize,
        bool _autoEvictEnabled,
        uint256 _autoEvictThreshold
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();

        // Validate parameters
        _validateConfig(
            _minimumBond, _maximumBond, _unbondingDelayMicros, _votingPowerIncreaseLimitPct, _maxValidatorSetSize
        );

        _pendingConfig = PendingConfig({
            minimumBond: _minimumBond,
            maximumBond: _maximumBond,
            unbondingDelayMicros: _unbondingDelayMicros,
            allowValidatorSetChange: _allowValidatorSetChange,
            votingPowerIncreaseLimitPct: _votingPowerIncreaseLimitPct,
            maxValidatorSetSize: _maxValidatorSetSize,
            autoEvictEnabled: _autoEvictEnabled,
            autoEvictThreshold: _autoEvictThreshold
        });
        hasPendingConfig = true;

        emit PendingValidatorConfigSet();
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

        minimumBond = _pendingConfig.minimumBond;
        maximumBond = _pendingConfig.maximumBond;
        unbondingDelayMicros = _pendingConfig.unbondingDelayMicros;
        allowValidatorSetChange = _pendingConfig.allowValidatorSetChange;
        votingPowerIncreaseLimitPct = _pendingConfig.votingPowerIncreaseLimitPct;
        maxValidatorSetSize = _pendingConfig.maxValidatorSetSize;
        autoEvictEnabled = _pendingConfig.autoEvictEnabled;
        autoEvictThreshold = _pendingConfig.autoEvictThreshold;

        hasPendingConfig = false;

        // Clear pending config storage
        delete _pendingConfig;

        emit ValidatorConfigUpdated();
        emit PendingValidatorConfigCleared();
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Validate configuration parameters
    /// @param _minimumBond Minimum bond value
    /// @param _maximumBond Maximum bond value
    /// @param _unbondingDelayMicros Unbonding delay
    /// @param _votingPowerIncreaseLimitPct Voting power increase limit
    /// @param _maxValidatorSetSize Max validator set size
    function _validateConfig(
        uint256 _minimumBond,
        uint256 _maximumBond,
        uint64 _unbondingDelayMicros,
        uint64 _votingPowerIncreaseLimitPct,
        uint256 _maxValidatorSetSize
    ) internal pure {
        if (_minimumBond == 0) {
            revert Errors.InvalidMinimumBond();
        }

        if (_maximumBond < _minimumBond) {
            revert Errors.MinimumBondExceedsMaximum(_minimumBond, _maximumBond);
        }

        if (_unbondingDelayMicros == 0) {
            revert Errors.InvalidUnbondingDelay();
        }

        if (_unbondingDelayMicros > MAX_UNBONDING_DELAY) {
            revert Errors.ExcessiveDuration(_unbondingDelayMicros, MAX_UNBONDING_DELAY);
        }
        if (_votingPowerIncreaseLimitPct == 0 || _votingPowerIncreaseLimitPct > MAX_VOTING_POWER_INCREASE_LIMIT) {
            revert Errors.InvalidVotingPowerIncreaseLimit(_votingPowerIncreaseLimitPct);
        }

        if (_maxValidatorSetSize == 0 || _maxValidatorSetSize > MAX_VALIDATOR_SET_SIZE) {
            revert Errors.InvalidValidatorSetSize(_maxValidatorSetSize);
        }
    }

    /// @notice Require the contract to be initialized
    function _requireInitialized() internal view {
        if (!_initialized) {
            revert Errors.ValidatorConfigNotInitialized();
        }
    }
}

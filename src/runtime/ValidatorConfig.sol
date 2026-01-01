// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SystemAddresses} from "../foundation/SystemAddresses.sol";
import {requireAllowed} from "../foundation/SystemAccessControl.sol";
import {Errors} from "../foundation/Errors.sol";

/// @title ValidatorConfig
/// @author Gravity Team
/// @notice Configuration parameters for validator registry
/// @dev Initialized at genesis, updatable via governance (TIMELOCK).
///      Controls validator bonding, set size limits, and join/leave rules.
contract ValidatorConfig {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum allowed voting power increase limit (50%)
    uint64 public constant MAX_VOTING_POWER_INCREASE_LIMIT = 50;

    /// @notice Maximum allowed validator set size
    uint256 public constant MAX_VALIDATOR_SET_SIZE = 65536;

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

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a configuration parameter is updated
    /// @param param Parameter name hash
    /// @param oldValue Previous value
    /// @param newValue New value
    event ConfigUpdated(bytes32 indexed param, uint256 oldValue, uint256 newValue);

    /// @notice Emitted when allowValidatorSetChange is updated
    /// @param oldValue Previous value
    /// @param newValue New value
    event ValidatorSetChangeAllowedUpdated(bool oldValue, bool newValue);

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
    function initialize(
        uint256 _minimumBond,
        uint256 _maximumBond,
        uint64 _unbondingDelayMicros,
        bool _allowValidatorSetChange,
        uint64 _votingPowerIncreaseLimitPct,
        uint256 _maxValidatorSetSize
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        // Validate parameters
        if (_minimumBond == 0) {
            revert Errors.InvalidMinimumBond();
        }

        if (_maximumBond < _minimumBond) {
            revert Errors.MinimumBondExceedsMaximum(_minimumBond, _maximumBond);
        }

        if (_unbondingDelayMicros == 0) {
            revert Errors.InvalidUnbondingDelay();
        }

        if (_votingPowerIncreaseLimitPct == 0 || _votingPowerIncreaseLimitPct > MAX_VOTING_POWER_INCREASE_LIMIT) {
            revert Errors.InvalidVotingPowerIncreaseLimit(_votingPowerIncreaseLimitPct);
        }

        if (_maxValidatorSetSize == 0 || _maxValidatorSetSize > MAX_VALIDATOR_SET_SIZE) {
            revert Errors.InvalidValidatorSetSize(_maxValidatorSetSize);
        }

        minimumBond = _minimumBond;
        maximumBond = _maximumBond;
        unbondingDelayMicros = _unbondingDelayMicros;
        allowValidatorSetChange = _allowValidatorSetChange;
        votingPowerIncreaseLimitPct = _votingPowerIncreaseLimitPct;
        maxValidatorSetSize = _maxValidatorSetSize;

        _initialized = true;
    }

    // ========================================================================
    // GOVERNANCE SETTERS (TIMELOCK only)
    // ========================================================================

    /// @notice Update minimum bond
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _minimumBond New minimum bond value (must be > 0 and <= maximumBond)
    function setMinimumBond(uint256 _minimumBond) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        if (_minimumBond == 0) {
            revert Errors.InvalidMinimumBond();
        }

        if (_minimumBond > maximumBond) {
            revert Errors.MinimumBondExceedsMaximum(_minimumBond, maximumBond);
        }

        uint256 oldValue = minimumBond;
        minimumBond = _minimumBond;

        emit ConfigUpdated("minimumBond", oldValue, _minimumBond);
    }

    /// @notice Update maximum bond
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _maximumBond New maximum bond value (must be >= minimumBond)
    function setMaximumBond(uint256 _maximumBond) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        if (_maximumBond < minimumBond) {
            revert Errors.MinimumBondExceedsMaximum(minimumBond, _maximumBond);
        }

        uint256 oldValue = maximumBond;
        maximumBond = _maximumBond;

        emit ConfigUpdated("maximumBond", oldValue, _maximumBond);
    }

    /// @notice Update unbonding delay
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _unbondingDelayMicros New unbonding delay in microseconds (must be > 0)
    function setUnbondingDelayMicros(uint64 _unbondingDelayMicros) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        if (_unbondingDelayMicros == 0) {
            revert Errors.InvalidUnbondingDelay();
        }

        uint256 oldValue = unbondingDelayMicros;
        unbondingDelayMicros = _unbondingDelayMicros;

        emit ConfigUpdated("unbondingDelayMicros", oldValue, _unbondingDelayMicros);
    }

    /// @notice Update allow validator set change flag
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _allow New value for allowValidatorSetChange
    function setAllowValidatorSetChange(bool _allow) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        bool oldValue = allowValidatorSetChange;
        allowValidatorSetChange = _allow;

        emit ValidatorSetChangeAllowedUpdated(oldValue, _allow);
    }

    /// @notice Update voting power increase limit
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _votingPowerIncreaseLimitPct New limit (1-50)
    function setVotingPowerIncreaseLimitPct(uint64 _votingPowerIncreaseLimitPct) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        if (_votingPowerIncreaseLimitPct == 0 || _votingPowerIncreaseLimitPct > MAX_VOTING_POWER_INCREASE_LIMIT) {
            revert Errors.InvalidVotingPowerIncreaseLimit(_votingPowerIncreaseLimitPct);
        }

        uint256 oldValue = votingPowerIncreaseLimitPct;
        votingPowerIncreaseLimitPct = _votingPowerIncreaseLimitPct;

        emit ConfigUpdated("votingPowerIncreaseLimitPct", oldValue, _votingPowerIncreaseLimitPct);
    }

    /// @notice Update max validator set size
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _maxValidatorSetSize New max size (1-65536)
    function setMaxValidatorSetSize(uint256 _maxValidatorSetSize) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        if (_maxValidatorSetSize == 0 || _maxValidatorSetSize > MAX_VALIDATOR_SET_SIZE) {
            revert Errors.InvalidValidatorSetSize(_maxValidatorSetSize);
        }

        uint256 oldValue = maxValidatorSetSize;
        maxValidatorSetSize = _maxValidatorSetSize;

        emit ConfigUpdated("maxValidatorSetSize", oldValue, _maxValidatorSetSize);
    }
}


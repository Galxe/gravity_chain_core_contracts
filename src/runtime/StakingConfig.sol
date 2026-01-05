// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";

/// @title StakingConfig
/// @author Gravity Team
/// @notice Configuration parameters for governance staking
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      Anyone can stake tokens to participate in governance voting.
///      TODO(yxia): onNewEpoch() and pending config pattern?
contract StakingConfig {
    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Minimum stake amount for governance participation
    uint256 public minimumStake;

    /// @notice Lockup duration in microseconds
    uint64 public lockupDurationMicros;

    /// @notice Unbonding delay in microseconds (additional wait after lockedUntil before withdrawal)
    uint64 public unbondingDelayMicros;

    /// @notice Minimum stake required to create governance proposals
    uint256 public minimumProposalStake;

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

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the staking configuration
    /// @dev Can only be called once by GENESIS
    /// @param _minimumStake Minimum stake for governance participation
    /// @param _lockupDurationMicros Lockup duration in microseconds (must be > 0)
    /// @param _unbondingDelayMicros Unbonding delay in microseconds (must be > 0)
    /// @param _minimumProposalStake Minimum stake to create proposals
    function initialize(
        uint256 _minimumStake,
        uint64 _lockupDurationMicros,
        uint64 _unbondingDelayMicros,
        uint256 _minimumProposalStake
    ) external {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        if (_lockupDurationMicros == 0) {
            revert Errors.InvalidLockupDuration();
        }

        if (_unbondingDelayMicros == 0) {
            revert Errors.InvalidUnbondingDelay();
        }

        minimumStake = _minimumStake;
        lockupDurationMicros = _lockupDurationMicros;
        unbondingDelayMicros = _unbondingDelayMicros;
        minimumProposalStake = _minimumProposalStake;

        _initialized = true;
    }

    // ========================================================================
    // GOVERNANCE SETTERS (GOVERNANCE only)
    // ========================================================================

    /// @notice Update minimum stake
    /// @dev Only callable by GOVERNANCE
    /// @param _minimumStake New minimum stake value
    function setMinimumStake(
        uint256 _minimumStake
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        uint256 oldValue = minimumStake;
        minimumStake = _minimumStake;

        emit ConfigUpdated("minimumStake", oldValue, _minimumStake);
    }

    /// @notice Update lockup duration
    /// @dev Only callable by GOVERNANCE
    /// @param _lockupDurationMicros New lockup duration in microseconds (must be > 0)
    function setLockupDurationMicros(
        uint64 _lockupDurationMicros
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        if (_lockupDurationMicros == 0) {
            revert Errors.InvalidLockupDuration();
        }

        uint256 oldValue = lockupDurationMicros;
        lockupDurationMicros = _lockupDurationMicros;

        emit ConfigUpdated("lockupDurationMicros", oldValue, _lockupDurationMicros);
    }

    /// @notice Update unbonding delay
    /// @dev Only callable by GOVERNANCE
    /// @param _unbondingDelayMicros New unbonding delay in microseconds (must be > 0)
    function setUnbondingDelayMicros(
        uint64 _unbondingDelayMicros
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);

        if (_unbondingDelayMicros == 0) {
            revert Errors.InvalidUnbondingDelay();
        }

        uint256 oldValue = unbondingDelayMicros;
        unbondingDelayMicros = _unbondingDelayMicros;

        emit ConfigUpdated("unbondingDelayMicros", oldValue, _unbondingDelayMicros);
    }

    /// @notice Update minimum proposal stake
    /// @dev Only callable by GOVERNANCE
    /// @param _minimumProposalStake New minimum proposal stake value
    function setMinimumProposalStake(
        uint256 _minimumProposalStake
    ) external {
        // TODO(yxia): should be moved to GovernanceConfig.
        requireAllowed(SystemAddresses.GOVERNANCE);

        uint256 oldValue = minimumProposalStake;
        minimumProposalStake = _minimumProposalStake;

        emit ConfigUpdated("minimumProposalStake", oldValue, _minimumProposalStake);
    }
}


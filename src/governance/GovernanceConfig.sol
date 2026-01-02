// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SystemAddresses} from "../foundation/SystemAddresses.sol";
import {requireAllowed} from "../foundation/SystemAccessControl.sol";
import {Errors} from "../foundation/Errors.sol";

/// @title GovernanceConfig
/// @author Gravity Team
/// @notice Configuration parameters for on-chain governance
/// @dev Initialized at genesis, updatable via governance (TIMELOCK)
contract GovernanceConfig {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Maximum allowed early resolution threshold (100% = 10000 basis points)
    uint128 public constant MAX_EARLY_RESOLUTION_THRESHOLD_BPS = 10000;

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

    /// @notice Whether contract has been initialized
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

        if (_votingDurationMicros == 0) {
            revert Errors.InvalidVotingDuration();
        }

        if (_earlyResolutionThresholdBps > MAX_EARLY_RESOLUTION_THRESHOLD_BPS) {
            revert Errors.InvalidEarlyResolutionThreshold(_earlyResolutionThresholdBps);
        }

        minVotingThreshold = _minVotingThreshold;
        requiredProposerStake = _requiredProposerStake;
        votingDurationMicros = _votingDurationMicros;
        earlyResolutionThresholdBps = _earlyResolutionThresholdBps;

        _initialized = true;
    }

    // ========================================================================
    // SETTERS (TIMELOCK only)
    // ========================================================================

    /// @notice Update minimum voting threshold
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _minVotingThreshold New minimum voting threshold
    function setMinVotingThreshold(uint128 _minVotingThreshold) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        emit ConfigUpdated(keccak256("minVotingThreshold"), minVotingThreshold, _minVotingThreshold);
        minVotingThreshold = _minVotingThreshold;
    }

    /// @notice Update required proposer stake
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _requiredProposerStake New required proposer stake
    function setRequiredProposerStake(uint256 _requiredProposerStake) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        emit ConfigUpdated(keccak256("requiredProposerStake"), requiredProposerStake, _requiredProposerStake);
        requiredProposerStake = _requiredProposerStake;
    }

    /// @notice Update voting duration
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _votingDurationMicros New voting duration in microseconds
    function setVotingDurationMicros(uint64 _votingDurationMicros) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        if (_votingDurationMicros == 0) {
            revert Errors.InvalidVotingDuration();
        }

        emit ConfigUpdated(keccak256("votingDurationMicros"), votingDurationMicros, _votingDurationMicros);
        votingDurationMicros = _votingDurationMicros;
    }

    /// @notice Update early resolution threshold
    /// @dev Only callable by TIMELOCK (governance)
    /// @param _earlyResolutionThresholdBps New threshold in basis points
    function setEarlyResolutionThresholdBps(uint128 _earlyResolutionThresholdBps) external {
        requireAllowed(SystemAddresses.TIMELOCK);

        if (_earlyResolutionThresholdBps > MAX_EARLY_RESOLUTION_THRESHOLD_BPS) {
            revert Errors.InvalidEarlyResolutionThreshold(_earlyResolutionThresholdBps);
        }

        emit ConfigUpdated(
            keccak256("earlyResolutionThresholdBps"), earlyResolutionThresholdBps, _earlyResolutionThresholdBps
        );
        earlyResolutionThresholdBps = _earlyResolutionThresholdBps;
    }
}


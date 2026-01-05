// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IReconfiguration } from "./IReconfiguration.sol";
import { IValidatorManagement } from "../staking/IValidatorManagement.sol";
import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";
import { ValidatorConsensusInfo } from "../foundation/Types.sol";
import { RandomnessConfig } from "../runtime/RandomnessConfig.sol";
import { IDKG } from "../runtime/IDKG.sol";
import { IRandomnessConfig } from "../runtime/IRandomnessConfig.sol";
import { ITimestamp } from "../runtime/ITimestamp.sol";
import { EpochConfig } from "../runtime/EpochConfig.sol";
import { ConsensusConfig } from "../runtime/ConsensusConfig.sol";
import { ExecutionConfig } from "../runtime/ExecutionConfig.sol";
import { ValidatorConfig } from "../runtime/ValidatorConfig.sol";
import { VersionConfig } from "../runtime/VersionConfig.sol";
import { GovernanceConfig } from "../runtime/GovernanceConfig.sol";

/// @title Reconfiguration
/// @author Gravity Team
/// @notice Central orchestrator for epoch transitions with DKG coordination
/// @dev Manages epoch lifecycle following Aptos patterns. Coordinates with DKG,
///      RandomnessConfig, and ValidatorManagement for epoch transitions.
///      Epoch interval is configured via EpochConfig contract.
///      Entry points: checkAndStartTransition() from Blocker, finishTransition() from consensus/governance.
contract Reconfiguration is IReconfiguration {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Microseconds per second for conversion
    uint64 public constant MICRO_CONVERSION_FACTOR = 1_000_000;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Current epoch number (starts at 0)
    uint64 public override currentEpoch;

    /// @notice Timestamp of last reconfiguration (microseconds)
    uint64 public override lastReconfigurationTime;

    /// @notice Current transition state
    TransitionState private _transitionState;

    /// @notice Epoch when transition was started (for validation)
    uint64 private _transitionStartedAtEpoch;

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @inheritdoc IReconfiguration
    function initialize() external override {
        requireAllowed(SystemAddresses.GENESIS);

        if (_initialized) {
            revert Errors.AlreadyInitialized();
        }

        currentEpoch = 0;
        lastReconfigurationTime = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        _transitionState = TransitionState.Idle;
        _transitionStartedAtEpoch = 0;
        _initialized = true;

        // Emit initial epoch event (epoch 0)
        emit EpochTransitioned(0, lastReconfigurationTime);
    }

    // ========================================================================
    // TRANSITION CONTROL
    // ========================================================================

    /// @inheritdoc IReconfiguration
    function checkAndStartTransition() external override returns (bool started) {
        requireAllowed(SystemAddresses.BLOCK);
        _requireInitialized();

        // 1. Skip if already in progress
        if (_transitionState == TransitionState.DkgInProgress) {
            return false;
        }

        // 2. Check if time has elapsed
        if (!_canTransition()) {
            return false;
        }

        // 3. Get randomness config to check if DKG is enabled
        RandomnessConfig.RandomnessConfigData memory config =
            IRandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).getCurrentConfig();

        // 4. Handle based on DKG mode
        if (config.variant == RandomnessConfig.ConfigVariant.Off) {
            // Simple reconfiguration: DKG disabled, do immediate epoch transition
            _doImmediateReconfigure();
        } else {
            // Async reconfiguration with DKG: start DKG session
            _startDkgSession(config);
        }

        return true;
    }

    /// @inheritdoc IReconfiguration
    function finishTransition(
        bytes calldata dkgResult
    ) external override {
        // Allow SYSTEM_CALLER (consensus engine) or GOVERNANCE (governance force-end)
        requireAllowed(SystemAddresses.SYSTEM_CALLER, SystemAddresses.GOVERNANCE);
        _requireInitialized();

        // 1. Validate state
        if (_transitionState != TransitionState.DkgInProgress) {
            revert Errors.ReconfigurationNotInProgress();
        }

        // 2. Finish DKG session if result provided
        if (dkgResult.length > 0) {
            IDKG(SystemAddresses.DKG).finish(dkgResult);
        }
        IDKG(SystemAddresses.DKG).tryClearIncompleteSession();

        // 3. Apply reconfiguration (configs + validator manager + epoch increment)
        _applyReconfiguration();
    }

    /// @inheritdoc IReconfiguration
    function governanceReconfigure() external override {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();

        // If transition already in progress, governance can just call finishTransition() directly
        if (_transitionState == TransitionState.DkgInProgress) {
            revert Errors.ReconfigurationInProgress();
        }

        // Get randomness config to check if DKG is enabled
        RandomnessConfig.RandomnessConfigData memory config =
            IRandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).getCurrentConfig();

        // If DKG is disabled (variant == Off), do immediate reconfigure
        // Otherwise, start DKG and require finishTransition() to complete
        if (config.variant == RandomnessConfig.ConfigVariant.Off) {
            // DKG disabled: perform immediate reconfigure
            _doImmediateReconfigure();
        } else {
            // DKG enabled: start DKG session
            _startDkgSession(config);
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @inheritdoc IReconfiguration
    function canTriggerEpochTransition() external view override returns (bool) {
        if (!_initialized) return false;
        return _canTransition();
    }

    /// @inheritdoc IReconfiguration
    function isTransitionInProgress() external view override returns (bool) {
        return _transitionState == TransitionState.DkgInProgress;
    }

    /// @inheritdoc IReconfiguration
    function getTransitionState() external view override returns (TransitionState) {
        return _transitionState;
    }

    /// @inheritdoc IReconfiguration
    function getRemainingTimeSeconds() external view override returns (uint64) {
        if (!_initialized) return 0;

        uint64 currentTime = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 epochInterval = EpochConfig(SystemAddresses.EPOCH_CONFIG).epochIntervalMicros();
        uint64 nextEpochTime = lastReconfigurationTime + epochInterval;

        if (currentTime >= nextEpochTime) {
            return 0;
        }

        return (nextEpochTime - currentTime) / MICRO_CONVERSION_FACTOR;
    }

    /// @notice Check if the contract has been initialized
    /// @return True if initialized
    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @notice Check if epoch transition can occur based on time
    /// @dev Reads epoch interval from EpochConfig contract
    function _canTransition() internal view returns (bool) {
        uint64 currentTime = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 epochInterval = EpochConfig(SystemAddresses.EPOCH_CONFIG).epochIntervalMicros();
        return currentTime >= lastReconfigurationTime + epochInterval;
    }

    /// @notice Require the contract to be initialized
    function _requireInitialized() internal view {
        if (!_initialized) {
            revert Errors.ReconfigurationNotInitialized();
        }
    }

    /// @notice Start a DKG session for epoch transition
    /// @param config Randomness config for DKG
    function _startDkgSession(
        RandomnessConfig.RandomnessConfigData memory config
    ) internal {
        // Get validator consensus infos
        ValidatorConsensusInfo[] memory dealers =
            IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getCurValidatorConsensusInfos();
        ValidatorConsensusInfo[] memory targets =
            IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getNextValidatorConsensusInfos();

        // Clear any stale DKG session
        IDKG(SystemAddresses.DKG).tryClearIncompleteSession();

        // Start DKG session
        IDKG(SystemAddresses.DKG).start(currentEpoch, config, dealers, targets);

        // Update state
        _transitionState = TransitionState.DkgInProgress;
        _transitionStartedAtEpoch = currentEpoch;

        emit EpochTransitionStarted(currentEpoch);
    }

    /// @notice Perform immediate reconfigure when DKG is disabled
    /// @dev Used by checkAndStartTransition() and governanceReconfigure() when randomness variant is Off
    function _doImmediateReconfigure() internal {
        // Clear any stale DKG session
        IDKG(SystemAddresses.DKG).tryClearIncompleteSession();

        // Apply reconfiguration (no start event for immediate reconfigure)
        _applyReconfiguration();
    }

    /// @notice Apply pending configs, notify validator manager, and increment epoch
    /// @dev Core reconfiguration logic shared by finishTransition() and _doImmediateReconfigure()
    ///      Following Aptos pattern: all config modules apply pending changes at epoch boundary
    function _applyReconfiguration() internal {
        // 1. Apply pending configs BEFORE validator changes
        //    This ensures new configs are active for the new epoch's first block
        IRandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).applyPendingConfig();
        ConsensusConfig(SystemAddresses.CONSENSUS_CONFIG).applyPendingConfig();
        ExecutionConfig(SystemAddresses.EXECUTION_CONFIG).applyPendingConfig();
        ValidatorConfig(SystemAddresses.VALIDATOR_CONFIG).applyPendingConfig();
        VersionConfig(SystemAddresses.VERSION_CONFIG).applyPendingConfig();
        GovernanceConfig(SystemAddresses.GOVERNANCE_CONFIG).applyPendingConfig();
        EpochConfig(SystemAddresses.EPOCH_CONFIG).applyPendingConfig();

        // 2. Notify validator manager BEFORE incrementing epoch (Aptos pattern)
        //    Following Aptos reconfiguration.move: stake::on_new_epoch() is called
        //    before config_ref.epoch is incremented. This ensures validator set
        //    changes are processed in the context of the current epoch.
        IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).onNewEpoch();

        // 3. Increment epoch and update timestamp
        uint64 newEpoch = currentEpoch + 1;
        currentEpoch = newEpoch;
        lastReconfigurationTime = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // 4. Reset state
        _transitionState = TransitionState.Idle;

        // 5. Emit transition event
        emit EpochTransitioned(newEpoch, lastReconfigurationTime);
    }
}


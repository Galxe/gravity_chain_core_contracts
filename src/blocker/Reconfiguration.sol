// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IReconfiguration} from "./IReconfiguration.sol";
import {SystemAddresses} from "../foundation/SystemAddresses.sol";
import {requireAllowed} from "../foundation/SystemAccessControl.sol";
import {Errors} from "../foundation/Errors.sol";
import {ValidatorConsensusInfo} from "../foundation/Types.sol";
import {RandomnessConfig} from "../runtime/RandomnessConfig.sol";

/// @notice Interface for Timestamp contract
interface ITimestamp {
    function nowMicroseconds() external view returns (uint64);
}

/// @notice Interface for DKG contract
interface IDKG {
    function start(
        uint64 dealerEpoch,
        RandomnessConfig.RandomnessConfigData calldata randomnessConfig,
        ValidatorConsensusInfo[] calldata dealerValidatorSet,
        ValidatorConsensusInfo[] calldata targetValidatorSet
    ) external;
    function finish(bytes calldata transcript) external;
    function tryClearIncompleteSession() external;
    function isInProgress() external view returns (bool);
}

/// @notice Interface for RandomnessConfig contract
interface IRandomnessConfig {
    function getCurrentConfig() external view returns (RandomnessConfig.RandomnessConfigData memory);
    function applyPendingConfig() external;
}

/// @notice Interface for ValidatorManagement contract
interface IValidatorManagement {
    function getActiveValidators() external view returns (ValidatorConsensusInfo[] memory);
    function onNewEpoch(uint64 newEpoch) external;
}

/// @title Reconfiguration
/// @author Gravity Team
/// @notice Central orchestrator for epoch transitions with DKG coordination
/// @dev Manages epoch lifecycle following Aptos patterns. Coordinates with DKG,
///      RandomnessConfig, and ValidatorManagement for epoch transitions.
///      Entry points: checkAndStartTransition() from Blocker, finishTransition() from consensus/governance.
contract Reconfiguration is IReconfiguration {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Default epoch interval (2 hours in microseconds)
    uint64 public constant DEFAULT_EPOCH_INTERVAL_MICROS = 2 hours * 1_000_000;

    /// @notice Microseconds per second for conversion
    uint64 public constant MICRO_CONVERSION_FACTOR = 1_000_000;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice Current epoch number (starts at 0)
    uint64 public override currentEpoch;

    /// @notice Timestamp of last reconfiguration (microseconds)
    uint64 public override lastReconfigurationTime;

    /// @notice Epoch interval in microseconds
    uint64 public override epochIntervalMicros;

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
        epochIntervalMicros = DEFAULT_EPOCH_INTERVAL_MICROS;
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

        // 3. Get validator consensus infos from ValidatorManagement
        // Note: For dealers (current validators) and targets (next epoch validators),
        // we use the same set since we don't have a separate "next" set mechanism yet.
        // In a more sophisticated implementation, targets would be the projected next set.
        ValidatorConsensusInfo[] memory currentVals =
            IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getActiveValidators();

        // 4. Get randomness config
        RandomnessConfig.RandomnessConfigData memory config =
            IRandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).getCurrentConfig();

        // 5. Clear any stale DKG session
        IDKG(SystemAddresses.DKG).tryClearIncompleteSession();

        // 6. Start DKG session - emits DKGStartEvent for consensus engine
        // Using currentVals for both dealers and targets for now
        IDKG(SystemAddresses.DKG).start(currentEpoch, config, currentVals, currentVals);

        // 7. Update state
        _transitionState = TransitionState.DkgInProgress;
        _transitionStartedAtEpoch = currentEpoch;

        emit EpochTransitionStarted(currentEpoch);
        return true;
    }

    /// @inheritdoc IReconfiguration
    function finishTransition(bytes calldata dkgResult) external override {
        // Allow SYSTEM_CALLER (consensus engine) or TIMELOCK (governance force-end)
        requireAllowed(SystemAddresses.SYSTEM_CALLER, SystemAddresses.TIMELOCK);
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

        // 3. Apply pending configs BEFORE incrementing epoch
        //    This ensures new configs are active for the new epoch's first block
        IRandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).applyPendingConfig();

        // 4. Increment epoch
        uint64 newEpoch = currentEpoch + 1;
        currentEpoch = newEpoch;
        lastReconfigurationTime = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // 5. Notify validator manager to apply changes with the new epoch
        IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).onNewEpoch(newEpoch);

        // 6. Reset state
        _transitionState = TransitionState.Idle;

        // 7. Emit transition event
        emit EpochTransitioned(newEpoch, lastReconfigurationTime);
    }

    // ========================================================================
    // GOVERNANCE
    // ========================================================================

    /// @inheritdoc IReconfiguration
    function setEpochIntervalMicros(uint64 newIntervalMicros) external override {
        requireAllowed(SystemAddresses.TIMELOCK);
        _requireInitialized();

        if (newIntervalMicros == 0) {
            revert Errors.InvalidEpochInterval();
        }

        uint64 oldInterval = epochIntervalMicros;
        epochIntervalMicros = newIntervalMicros;

        emit EpochDurationUpdated(oldInterval, newIntervalMicros);
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
        uint64 nextEpochTime = lastReconfigurationTime + epochIntervalMicros;

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
    function _canTransition() internal view returns (bool) {
        uint64 currentTime = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        return currentTime >= lastReconfigurationTime + epochIntervalMicros;
    }

    /// @notice Require the contract to be initialized
    function _requireInitialized() internal view {
        if (!_initialized) {
            revert Errors.ReconfigurationNotInitialized();
        }
    }
}


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

        // 3. Get validator consensus infos from ValidatorManagement
        //    - Dealers: Current validators (active + pending_inactive) who run DKG
        //    - Targets: Projected next epoch validators who receive DKG keys
        //    Following Aptos's reconfiguration_with_dkg.move pattern
        ValidatorConsensusInfo[] memory dealers =
            IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getCurValidatorConsensusInfos();
        ValidatorConsensusInfo[] memory targets =
            IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getNextValidatorConsensusInfos();

        // 4. Get randomness config
        RandomnessConfig.RandomnessConfigData memory config =
            IRandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).getCurrentConfig();

        // 5. Clear any stale DKG session
        IDKG(SystemAddresses.DKG).tryClearIncompleteSession();

        // 6. Start DKG session - emits DKGStartEvent for consensus engine
        //    Dealers are current validators, targets are projected next epoch validators
        IDKG(SystemAddresses.DKG).start(currentEpoch, config, dealers, targets);

        // 7. Update state
        _transitionState = TransitionState.DkgInProgress;
        _transitionStartedAtEpoch = currentEpoch;

        emit EpochTransitionStarted(currentEpoch);
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

        // 3. Apply pending configs BEFORE validator changes
        //    This ensures new configs are active for the new epoch's first block
        IRandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).applyPendingConfig();

        // 4. Notify validator manager BEFORE incrementing epoch (Aptos pattern)
        //    Following Aptos reconfiguration.move: stake::on_new_epoch() is called
        //    before config_ref.epoch is incremented. This ensures validator set
        //    changes are processed in the context of the current epoch.
        IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).onNewEpoch();

        // 5. NOW increment epoch and update timestamp
        uint64 newEpoch = currentEpoch + 1;
        currentEpoch = newEpoch;
        lastReconfigurationTime = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();

        // 6. Reset state
        _transitionState = TransitionState.Idle;

        // 7. Emit transition event
        emit EpochTransitioned(newEpoch, lastReconfigurationTime);
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
}


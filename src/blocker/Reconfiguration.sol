// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IReconfiguration } from "./IReconfiguration.sol";
import { IValidatorPerformanceTracker } from "./IValidatorPerformanceTracker.sol";
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
import { StakingConfig } from "../runtime/StakingConfig.sol";

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
    // FAULT-TOLERANCE EVENTS
    // ========================================================================

    /// @notice Emitted when a non-fatal step fails during reconfiguration
    /// @param step Human-readable step identifier
    /// @param reason ABI-encoded revert reason
    event ReconfigurationStepFailed(string step, bytes reason);

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

        currentEpoch = 1;
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

        // 3. Pre-transition actions: evict underperforming validators based on closing epoch's performance and rules
        //    Non-fatal: if eviction fails, skip it and proceed with epoch transition
        try IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).evictUnderperformingValidators() { }
        catch (bytes memory reason) {
            emit ReconfigurationStepFailed("evictUnderperformingValidators", reason);
        }

        // 4. Get randomness config to check if DKG is enabled
        RandomnessConfig.RandomnessConfigData memory config =
            IRandomnessConfig(SystemAddresses.RANDOMNESS_CONFIG).getCurrentConfig();

        // 5. Handle based on DKG mode
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

        // Pre-transition actions: evict underperforming validators based on closing epoch's performance and rules
        try IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).evictUnderperformingValidators() { }
        catch (bytes memory reason) {
            emit ReconfigurationStepFailed("evictUnderperformingValidators", reason);
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
        // Clear any stale DKG session (non-fatal)
        try IDKG(SystemAddresses.DKG).tryClearIncompleteSession() { }
        catch (bytes memory reason) {
            emit ReconfigurationStepFailed("dkg.tryClearIncompleteSession", reason);
        }

        // Apply reconfiguration (no start event for immediate reconfigure)
        _applyReconfiguration();
    }

    /// @notice Apply pending configs, notify validator manager, and increment epoch
    /// @dev Core reconfiguration logic shared by finishTransition() and _doImmediateReconfigure()
    ///      Following Aptos pattern: all config modules apply pending changes at epoch boundary.
    ///      All non-fatal steps are wrapped in try-catch to prevent chain deadlock (Issue #59).
    ///      The epoch MUST always increment to guarantee liveness.
    function _applyReconfiguration() internal {
        // 1. Apply pending configs (each independently, non-fatal)
        //    If any config fails to apply, the old config remains active for the next epoch.
        _tryApplyConfig(SystemAddresses.RANDOMNESS_CONFIG, "RandomnessConfig");
        _tryApplyConfig(SystemAddresses.CONSENSUS_CONFIG, "ConsensusConfig");
        _tryApplyConfig(SystemAddresses.EXECUTION_CONFIG, "ExecutionConfig");
        _tryApplyConfig(SystemAddresses.VALIDATOR_CONFIG, "ValidatorConfig");
        _tryApplyConfig(SystemAddresses.VERSION_CONFIG, "VersionConfig");
        _tryApplyConfig(SystemAddresses.GOVERNANCE_CONFIG, "GovernanceConfig");
        _tryApplyConfig(SystemAddresses.STAKE_CONFIG, "StakingConfig");
        _tryApplyConfig(SystemAddresses.EPOCH_CONFIG, "EpochConfig");

        // 2. Notify validator manager BEFORE incrementing epoch (Aptos pattern)
        //    Following Aptos reconfiguration.move: stake::on_new_epoch() is called
        //    before config_ref.epoch is incremented. This ensures validator set
        //    changes are processed in the context of the current epoch.
        //    Non-fatal: if this fails, the old validator set continues for the next epoch.
        try IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).onNewEpoch() { }
        catch (bytes memory reason) {
            emit ReconfigurationStepFailed("validatorManagement.onNewEpoch", reason);
        }

        // 3. Reset performance tracker for the new epoch
        //    ORDERING INVARIANT: This call destructively erases all epoch performance data.
        //    It MUST happen AFTER ValidatorManagement.onNewEpoch().
        //    Non-fatal: if this fails, stale performance data may persist but chain stays live.
        try IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getActiveValidatorCount() returns (
            uint256 newValidatorCount
        ) {
            try IValidatorPerformanceTracker(SystemAddresses.PERFORMANCE_TRACKER).onNewEpoch(newValidatorCount) { }
            catch (bytes memory reason) {
                emit ReconfigurationStepFailed("performanceTracker.onNewEpoch", reason);
            }
        } catch (bytes memory reason) {
            emit ReconfigurationStepFailed("validatorManagement.getActiveValidatorCount", reason);
        }

        // 4. Increment epoch and update timestamp
        //    CRITICAL: This section MUST succeed to guarantee chain liveness.
        //    Pure storage writes — cannot revert under normal conditions.
        uint64 newEpoch = currentEpoch + 1;
        currentEpoch = newEpoch;
        // Timestamp read is safe (pure view on storage), but wrap defensively
        try ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds() returns (uint64 ts) {
            lastReconfigurationTime = ts;
        } catch {
            // If timestamp read fails, use previous timestamp to avoid blocking epoch increment
            // lastReconfigurationTime stays unchanged
        }

        // 5. Reset state
        _transitionState = TransitionState.Idle;

        // 6. Get finalized validator set for NewEpochEvent (non-fatal)
        //    If queries fail, emit EpochTransitioned with minimal info but still advance the epoch.
        ValidatorConsensusInfo[] memory validatorSet;
        uint256 totalVotingPower;
        try IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getActiveValidators() returns (
            ValidatorConsensusInfo[] memory vs
        ) {
            validatorSet = vs;
        } catch (bytes memory reason) {
            emit ReconfigurationStepFailed("validatorManagement.getActiveValidators", reason);
        }
        try IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getTotalVotingPower() returns (uint256 tvp) {
            totalVotingPower = tvp;
        } catch (bytes memory reason) {
            emit ReconfigurationStepFailed("validatorManagement.getTotalVotingPower", reason);
        }

        // 7. Emit events
        //    - EpochTransitioned: simple event for internal tracking
        //    - NewEpochEvent: full validator set for consensus engine
        emit EpochTransitioned(newEpoch, lastReconfigurationTime);
        emit NewEpochEvent(newEpoch, validatorSet, totalVotingPower, lastReconfigurationTime);
    }

    /// @notice Try to apply pending config for a given config contract (non-fatal)
    /// @param configAddr Address of the config contract
    /// @param name Human-readable name for error reporting
    function _tryApplyConfig(
        address configAddr,
        string memory name
    ) internal {
        // All config contracts share the same applyPendingConfig() signature via IApplyConfig
        // Use low-level call since config contracts don't share a common interface
        (bool success, bytes memory reason) = configAddr.call(abi.encodeWithSignature("applyPendingConfig()"));
        if (!success) {
            emit ReconfigurationStepFailed(name, reason);
        }
    }
}


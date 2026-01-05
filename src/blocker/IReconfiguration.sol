// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IReconfiguration
/// @author Gravity Team
/// @notice Interface for the Reconfiguration contract (epoch lifecycle management)
/// @dev Coordinates epoch transitions with DKG. Called by Blocker during block prologue.
interface IReconfiguration {
    // ========================================================================
    // TYPES
    // ========================================================================

    /// @notice Transition states for the epoch state machine
    enum TransitionState {
        Idle, // No transition in progress, waiting for time
        DkgInProgress // DKG started, waiting for completion
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when epoch transition starts (DKG initiated)
    /// @param epoch The epoch number when transition started
    event EpochTransitionStarted(uint64 indexed epoch);

    /// @notice Emitted when epoch transition completes
    /// @param newEpoch The new epoch number
    /// @param transitionTime Timestamp when transition completed (microseconds)
    event EpochTransitioned(uint64 indexed newEpoch, uint64 transitionTime);

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the contract (genesis only)
    function initialize() external;

    // ========================================================================
    // TRANSITION CONTROL
    // ========================================================================

    /// @notice Check and start epoch transition if conditions are met
    /// @dev Called by Blocker at each block. Starts DKG if time has elapsed.
    /// @return started True if DKG was started
    function checkAndStartTransition() external returns (bool started);

    /// @notice Finish epoch transition after DKG completes
    /// @dev Called by consensus engine (SYSTEM_CALLER) or governance (GOVERNANCE) after DKG completes
    /// @param dkgResult The DKG transcript (empty bytes if DKG disabled or force-ending epoch)
    function finishTransition(
        bytes calldata dkgResult
    ) external;

    /// @notice Force epoch transition via governance (emergency reconfigure)
    /// @dev Only callable by GOVERNANCE. If DKG is disabled, does immediate reconfigure.
    ///      If DKG is enabled, starts DKG and requires finishTransition() to complete.
    ///      Use for emergency situations like removing a malicious validator.
    function governanceReconfigure() external;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get current epoch number
    /// @return Current epoch
    function currentEpoch() external view returns (uint64);

    /// @notice Get timestamp of last reconfiguration (microseconds)
    /// @return Last reconfiguration time
    function lastReconfigurationTime() external view returns (uint64);

    /// @notice Check if epoch transition can be triggered (time-based)
    /// @return True if current time >= next epoch boundary
    function canTriggerEpochTransition() external view returns (bool);

    /// @notice Check if transition is in progress
    /// @return True if transition is in progress
    function isTransitionInProgress() external view returns (bool);

    /// @notice Get current transition state
    /// @return Current transition state
    function getTransitionState() external view returns (TransitionState);

    /// @notice Get remaining time until next epoch (seconds)
    /// @return Remaining seconds (0 if ready to transition)
    function getRemainingTimeSeconds() external view returns (uint64);
}

